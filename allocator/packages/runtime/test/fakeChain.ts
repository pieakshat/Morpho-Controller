/**
 * An in-memory chain that answers an `aggregate3` call list.
 *
 * Built as a dispatcher over `(target, decoded call)` rather than as a fixed array of return
 * values, and that choice is the whole point. A fixture array would have to be written in the
 * order `buildStateCalls` happens to emit, so it would agree with any ordering the builder
 * chose, including a wrong one. This answers each call on its own terms, which lets it model
 * the property that actually matters:
 *
 *   `market()` returns PRE-accrual totals unless `accrueInterest` for that market appeared
 *   EARLIER in the same list.
 *
 * That is exactly how Morpho behaves inside a real `aggregate3`, and it means a call list that
 * reads before it accrues produces understated debt here too, rather than passing quietly.
 */

import { morphoAbi, oracleAbi, riskLimitsAbi, vaultAbi, type Id, type MarketParams, type MarketState, type Position } from "@morphoagg/core";
import { toAssetsUp } from "@morphoagg/core";
import { decodeFunctionData, encodeFunctionResult, getAddress, type Abi, type Address, type Hex } from "viem";

import { erc20Abi, multicall3Abi, type Multicall3Call, type Multicall3Result } from "../src/read/multicall.js";
import type { Topology } from "../src/read/calls.js";

export const ORACLE_PRICE_SCALE = 10n ** 36n;

export interface FakeMarket {
  id: Id;
  params: MarketParams;
  collateralDecimals: number;

  position: Position;
  /** As stored, i.e. before this block's interest is applied. */
  preAccrual: MarketState;
  /** Added to `totalBorrowAssets` (and to supply) the first time `accrueInterest` runs. */
  pendingInterest: bigint;

  /** `null` makes the oracle revert, which the reader must map to `price: null`. */
  price: bigint | null;

  config: { maxLeverage: bigint; maxSlippageBps: bigint; enabled: boolean };
  limits: {
    minHealthFactor: bigint;
    maxPriceDeviationBps: bigint;
    maxExposureChangePerWindow: bigint;
    windowStart: bigint;
    windowExposureChange: bigint;
    lastObservedPrice: bigint;
    lastObservedAt: bigint;
  };
}

export interface FakeWorld {
  vault: Address;
  asset: Address;
  assetDecimals: number;
  riskLimits: Address;
  swapExecutor: Address;
  morpho: Address;
  generalAdapter1: Address;
  multicall3: Address;

  blockNumber: bigint;
  timestamp: bigint;
  idle: bigint;
  actionDropToleranceBps: bigint;

  paused: boolean;
  maxAggregateDebt: bigint;
  maxSlippageBpsCeiling: bigint;
  rateLimitWindowSeconds: bigint;
  priceObservationMaxAge: bigint;
  maxAssetExposure: Map<Address, bigint>;

  markets: FakeMarket[];
}

export function topologyOf(w: FakeWorld): Topology {
  return {
    vault: w.vault,
    asset: w.asset,
    assetDecimals: w.assetDecimals,
    riskLimits: w.riskLimits,
    swapExecutor: w.swapExecutor,
    morpho: w.morpho,
    generalAdapter1: w.generalAdapter1,
    markets: w.markets.map((m) => ({ id: m.id, params: m.params, collateralDecimals: m.collateralDecimals })),
  };
}

/**
 * Runs a call list against the world, in order, tracking which markets have accrued.
 *
 * Sequential on purpose: the accrual flag is what makes ordering observable.
 */
export function runAggregate3(w: FakeWorld, calls: readonly Multicall3Call[]): Multicall3Result[] {
  const accrued = new Set<Id>();

  return calls.map((call): Multicall3Result => {
    try {
      return { success: true, returnData: answer(w, accrued, call) };
    } catch (error) {
      // A revert. The only one the reader tolerates is a dead oracle; anything else must
      // surface, which is what allowFailure=false on the other slots enforces.
      return { success: false, returnData: (error as { revertData?: Hex }).revertData ?? "0x" };
    }
  });
}

class Revert extends Error {
  constructor(readonly revertData: Hex = "0x") {
    super("reverted");
  }
}

function answer(w: FakeWorld, accrued: Set<Id>, call: Multicall3Call): Hex {
  const target = getAddress(call.target);

  if (target === getAddress(w.multicall3)) {
    const { functionName } = decode(multicall3Abi, call.callData);
    if (functionName === "getBlockNumber") return ret(multicall3Abi, "getBlockNumber", w.blockNumber);
    if (functionName === "getCurrentBlockTimestamp") return ret(multicall3Abi, "getCurrentBlockTimestamp", w.timestamp);
    throw new Revert();
  }

  if (target === getAddress(w.morpho)) return answerMorpho(w, accrued, call.callData);
  if (target === getAddress(w.vault)) return answerVault(w, call.callData);
  if (target === getAddress(w.riskLimits)) return answerRiskLimits(w, call.callData);
  if (target === getAddress(w.asset)) return answerErc20(w, call.callData);

  const oracleMarket = w.markets.find((m) => getAddress(m.params.oracle) === target);
  if (oracleMarket) {
    if (oracleMarket.price === null) throw new Revert();
    return ret(oracleAbi, "price", oracleMarket.price);
  }

  const collateral = w.markets.find((m) => getAddress(m.params.collateralToken) === target);
  if (collateral) return answerErc20(w, call.callData, collateral.collateralDecimals);

  throw new Error(`fake chain has no contract at ${target}`);
}

function answerMorpho(w: FakeWorld, accrued: Set<Id>, data: Hex): Hex {
  const { functionName, args } = decode(morphoAbi, data);

  if (functionName === "accrueInterest") {
    const params = args?.[0] as MarketParams;
    const m = marketByParams(w, params);
    accrued.add(m.id);
    return "0x";
  }

  if (functionName === "position") {
    const m = marketById(w, args?.[0] as Id);
    return ret(morphoAbi, "position", [m.position.supplyShares, m.position.borrowShares, m.position.collateral]);
  }

  if (functionName === "market") {
    const m = marketById(w, args?.[0] as Id);
    const s = accrued.has(m.id) ? postAccrual(m) : m.preAccrual;
    return ret(morphoAbi, "market", [
      s.totalSupplyAssets,
      s.totalSupplyShares,
      s.totalBorrowAssets,
      s.totalBorrowShares,
      s.lastUpdate,
      s.fee,
    ]);
  }

  if (functionName === "idToMarketParams") {
    const m = marketById(w, args?.[0] as Id);
    return ret(morphoAbi, "idToMarketParams", m.params);
  }

  throw new Revert();
}

/**
 * What `accrueInterest` does, reduced to the part this test needs: borrow assets grow, supply
 * assets grow by the same amount, `lastUpdate` moves to now, and SHARES do not move. That last
 * one is the property measured against real Arbitrum state before this design was committed to.
 */
export function postAccrual(m: FakeMarket): MarketState {
  return {
    ...m.preAccrual,
    totalBorrowAssets: m.preAccrual.totalBorrowAssets + m.pendingInterest,
    totalSupplyAssets: m.preAccrual.totalSupplyAssets + m.pendingInterest,
    lastUpdate: m.preAccrual.lastUpdate + 1n,
  };
}

function answerVault(w: FakeWorld, data: Hex): Hex {
  const { functionName, args } = decode(vaultAbi, data);

  if (functionName === "totalAssets") return ret(vaultAbi, "totalAssets", vaultTotalAssets(w));
  if (functionName === "actionDropToleranceBps") {
    return ret(vaultAbi, "actionDropToleranceBps", w.actionDropToleranceBps);
  }
  if (functionName === "registeredMarkets") {
    return ret(vaultAbi, "registeredMarkets", w.markets.map((m) => m.id));
  }
  if (functionName === "marketConfig") {
    const m = marketById(w, args?.[0] as Id);
    return ret(vaultAbi, "marketConfig", {
      params: m.params,
      maxLeverage: m.config.maxLeverage,
      maxSlippageBps: m.config.maxSlippageBps,
      enabled: m.config.enabled,
    });
  }
  throw new Revert();
}

/**
 * The vault's own `totalAssets`, computed here independently of `core.valuation`.
 *
 * Independent in the part that matters. It shares `toAssetsUp` with the mirror, because
 * reimplementing Morpho's shares conversion in a test fixture would only prove the copy
 * matches. What it does NOT share is the assembly: which position belongs to which market,
 * how the `uint128` tuple unpacks, and whether the totals are post-accrual. Those are exactly
 * what the reader can get wrong, and exactly what the self-check exists to catch.
 *
 * ALWAYS post-accrual, unconditionally. The real `totalAssets()` reads stored state, but the
 * vault sits behind every `accrueInterest` in the call list, so by the time it is read the
 * accruals have already happened. Hardcoding that here is what makes a wrongly-ordered call
 * list fail: the reader would derive its total from pre-accrual debt while this reports the
 * post-accrual one, and the two would not match.
 */
export function vaultTotalAssets(w: FakeWorld): bigint {
  let surplus = 0n;
  let shortfall = 0n;

  for (const m of w.markets) {
    const s = postAccrual(m);
    const debt =
      m.position.borrowShares > 0n
        ? toAssetsUp(m.position.borrowShares, s.totalBorrowAssets, s.totalBorrowShares)
        : 0n;
    const collateral =
      m.position.collateral > 0n && m.price !== null
        ? (m.position.collateral * m.price) / ORACLE_PRICE_SCALE
        : 0n;

    if (collateral >= debt) surplus += collateral - debt;
    else shortfall += debt - collateral;
  }

  const gross = w.idle + surplus;
  return gross > shortfall ? gross - shortfall : 0n;
}

function answerRiskLimits(w: FakeWorld, data: Hex): Hex {
  const { functionName, args } = decode(riskLimitsAbi, data);

  switch (functionName) {
    case "paused":
      return ret(riskLimitsAbi, "paused", w.paused);
    case "maxAggregateDebt":
      return ret(riskLimitsAbi, "maxAggregateDebt", w.maxAggregateDebt);
    case "maxSlippageBpsCeiling":
      return ret(riskLimitsAbi, "maxSlippageBpsCeiling", w.maxSlippageBpsCeiling);
    case "rateLimitWindowSeconds":
      return ret(riskLimitsAbi, "rateLimitWindowSeconds", w.rateLimitWindowSeconds);
    case "priceObservationMaxAge":
      return ret(riskLimitsAbi, "priceObservationMaxAge", w.priceObservationMaxAge);
    case "maxAssetExposure":
      return ret(riskLimitsAbi, "maxAssetExposure", w.maxAssetExposure.get(getAddress(args?.[0] as Address)) ?? 0n);
    default: {
      const m = marketById(w, args?.[0] as Id);
      const limits = m.limits as Record<string, bigint>;
      const value = limits[functionName as string];
      if (value === undefined) throw new Revert();
      return ret(riskLimitsAbi, functionName, value);
    }
  }
}

function answerErc20(w: FakeWorld, data: Hex, decimals = w.assetDecimals): Hex {
  const { functionName } = decode(erc20Abi, data);
  if (functionName === "balanceOf") return ret(erc20Abi, "balanceOf", w.idle);
  if (functionName === "decimals") return ret(erc20Abi, "decimals", decimals);
  throw new Revert();
}

function decode(abi: Abi | readonly unknown[], data: Hex): { functionName: string; args: readonly unknown[] | undefined } {
  return decodeFunctionData({ abi: abi as Abi, data }) as { functionName: string; args: readonly unknown[] | undefined };
}

function ret(abi: Abi | readonly unknown[], functionName: string, result: unknown): Hex {
  return encodeFunctionResult({ abi: abi as Abi, functionName, result } as never);
}

function marketById(w: FakeWorld, id: Id): FakeMarket {
  const m = w.markets.find((x) => x.id.toLowerCase() === id.toLowerCase());
  if (!m) throw new Error(`fake chain has no market ${id}`);
  return m;
}

function marketByParams(w: FakeWorld, params: MarketParams): FakeMarket {
  const m = w.markets.find(
    (x) =>
      getAddress(x.params.collateralToken) === getAddress(params.collateralToken) &&
      getAddress(x.params.oracle) === getAddress(params.oracle) &&
      x.params.lltv === params.lltv,
  );
  if (!m) throw new Error(`fake chain has no market matching params ${JSON.stringify(params, replacer)}`);
  return m;
}

const replacer = (_k: string, v: unknown): unknown => (typeof v === "bigint" ? v.toString() : v);
