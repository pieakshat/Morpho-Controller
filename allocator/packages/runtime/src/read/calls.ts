/**
 * PURE. Turns a known set of markets into the exact call list one `aggregate3` needs.
 *
 * No network access, no clients, nothing async. That is what lets the ordering rule below be
 * asserted in an offline unit test rather than discovered on a fork.
 *
 * THE ORDERING RULE: every `accrueInterest` goes first, before any read. `_planDecrease` and
 * `_planDeleverage` both accrue before they read, so a plain `market()` at the head of the
 * list returns pre-accrual totals and understates debt. Everything the planner derives from
 * that is then too small, and the flashloan comes up short at execution. `aggregate3` makes
 * this work because it is not a view call: writes from an earlier sub-call are visible to
 * later ones within the same `eth_call`.
 */

import { morphoAbi, oracleAbi, riskLimitsAbi, vaultAbi, type Id, type MarketParams } from "@morphoagg/core";
import type { Address } from "viem";

import { CallBuilder, erc20Abi, multicall3Abi, type Multicall3Call, type Slot } from "./multicall.js";

/**
 * The parts of the deployment that do not change between ticks.
 *
 * Discovered once at startup (see `topology.ts`) rather than re-read every loop. Market
 * registration and token decimals are owner-only or immutable, so re-reading them every tick would
 * cost round trips to learn nothing. The tradeoff is that a market registered while the
 * process is running is invisible until restart, which is the correct default for something
 * holding a hot key.
 */
export interface Topology {
  vault: Address;
  asset: Address;
  assetDecimals: number;
  riskLimits: Address;
  swapExecutor: Address;
  morpho: Address;
  generalAdapter1: Address;
  markets: readonly MarketTopology[];
}

export interface MarketTopology {
  id: Id;
  params: MarketParams;
  /** Needed by the quote layer, which identifies tokens by address rather than symbol. */
  collateralDecimals: number;
}

/** Where every value lives in the `aggregate3` response. Consumed only by `decode.ts`. */
export interface StateLayout {
  blockNumber: Slot<bigint>;
  timestamp: Slot<bigint>;

  totalAssets: Slot<bigint>;
  idle: Slot<bigint>;
  actionDropToleranceBps: Slot<bigint>;

  paused: Slot<boolean>;
  maxAggregateDebt: Slot<bigint>;
  maxSlippageBpsCeiling: Slot<bigint>;
  rateLimitWindowSeconds: Slot<bigint>;
  priceObservationMaxAge: Slot<bigint>;

  markets: readonly MarketLayout[];
  /** One per DISTINCT collateral token, not one per market: the cap is keyed by token. */
  assetExposure: readonly { token: Address; cap: Slot<bigint> }[];
}

export interface MarketLayout {
  topology: MarketTopology;

  config: Slot<{ params: MarketParams; maxLeverage: bigint; maxSlippageBps: bigint; enabled: boolean }>;
  position: Slot<readonly [bigint, bigint, bigint]>;
  market: Slot<readonly [bigint, bigint, bigint, bigint, bigint, bigint]>;
  /** `undefined` when the oracle reverted, which becomes `price: null` in the snapshot. */
  price: Slot<bigint | undefined>;

  minHealthFactor: Slot<bigint>;
  maxPriceDeviationBps: Slot<bigint>;
  maxExposureChangePerWindow: Slot<bigint>;
  windowStart: Slot<bigint>;
  windowExposureChange: Slot<bigint>;
  lastObservedPrice: Slot<bigint>;
  lastObservedAt: Slot<bigint>;
}

export interface StateCalls {
  calls: readonly Multicall3Call[];
  layout: StateLayout;
}

export function buildStateCalls(topology: Topology, multicall3: Address): StateCalls {
  const b = new CallBuilder();

  // 1. Accrue first, for every market, before anything reads. See the ordering rule above.
  //
  //    allowFailure is false on purpose. An accrual that reverts means every debt figure in
  //    the rest of the response is stale, and a snapshot that is silently stale is worse than
  //    no snapshot: it plans successfully and fails on-chain.
  for (const m of topology.markets) {
    b.add(topology.morpho, morphoAbi, "accrueInterest", [m.params]);
  }

  // 2. Block context, read from Multicall3 itself so it belongs to the same call as
  //    everything else. Taking it from a separate `eth_blockNumber` would reintroduce exactly
  //    the torn snapshot this whole design exists to avoid.
  const blockNumber = b.add(multicall3, multicall3Abi, "getBlockNumber", []);
  const timestamp = b.add(multicall3, multicall3Abi, "getCurrentBlockTimestamp", []);

  // 3. Vault globals.
  //
  //    `totalAssets` is read even though `core.totalAssets` can derive it from the position
  //    data below. That redundancy is the point: the two must agree, and `decode.ts` checks
  //    it. See the self-check note there.
  const totalAssets = b.add(topology.vault, vaultAbi, "totalAssets", []);
  const idle = b.add(topology.asset, erc20Abi, "balanceOf", [topology.vault]);
  const actionDropToleranceBps = b.add(topology.vault, vaultAbi, "actionDropToleranceBps", []);

  // 4. RiskLimits globals.
  const rl = topology.riskLimits;
  const paused = b.add(rl, riskLimitsAbi, "paused", []);
  const maxAggregateDebt = b.add(rl, riskLimitsAbi, "maxAggregateDebt", []);
  const maxSlippageBpsCeiling = b.add(rl, riskLimitsAbi, "maxSlippageBpsCeiling", []);
  const rateLimitWindowSeconds = b.add(rl, riskLimitsAbi, "rateLimitWindowSeconds", []);
  const priceObservationMaxAge = b.add(rl, riskLimitsAbi, "priceObservationMaxAge", []);

  // 5. Per market.
  const markets = topology.markets.map((m): MarketLayout => ({
    topology: m,
    config: b.add(topology.vault, vaultAbi, "marketConfig", [m.id]),
    position: b.add(topology.morpho, morphoAbi, "position", [m.id, topology.vault]),
    market: b.add(topology.morpho, morphoAbi, "market", [m.id]),

    // The only read allowed to fail. A dead oracle is a state the planner models rather than
    // an error: valuation counts the collateral as worthless while still counting the debt,
    // and increases and deleverages refuse outright because neither can derive a swap floor.
    // Letting this revert the aggregate would blind the runtime precisely when a position is
    // most likely to need unwinding.
    price: b.addOptional(m.params.oracle, oracleAbi, "price", []),

    minHealthFactor: b.add(rl, riskLimitsAbi, "minHealthFactor", [m.id]),
    maxPriceDeviationBps: b.add(rl, riskLimitsAbi, "maxPriceDeviationBps", [m.id]),
    maxExposureChangePerWindow: b.add(rl, riskLimitsAbi, "maxExposureChangePerWindow", [m.id]),
    windowStart: b.add(rl, riskLimitsAbi, "windowStart", [m.id]),
    windowExposureChange: b.add(rl, riskLimitsAbi, "windowExposureChange", [m.id]),
    lastObservedPrice: b.add(rl, riskLimitsAbi, "lastObservedPrice", [m.id]),
    lastObservedAt: b.add(rl, riskLimitsAbi, "lastObservedAt", [m.id]),
  }));

  // 6. Asset exposure caps, once per distinct collateral token. Two markets sharing a
  //    collateral share one cap, and reading it twice would suggest otherwise to anyone
  //    reading the snapshot.
  const assetExposure = distinctCollateralTokens(topology).map((token) => ({
    token,
    cap: b.add(rl, riskLimitsAbi, "maxAssetExposure", [token]),
  }));

  return {
    calls: b.build(),
    layout: {
      blockNumber,
      timestamp,
      totalAssets,
      idle,
      actionDropToleranceBps,
      paused,
      maxAggregateDebt,
      maxSlippageBpsCeiling,
      rateLimitWindowSeconds,
      priceObservationMaxAge,
      markets,
      assetExposure,
    },
  };
}

export function distinctCollateralTokens(topology: Topology): readonly Address[] {
  const seen = new Set<Address>();
  const out: Address[] = [];
  for (const m of topology.markets) {
    if (seen.has(m.params.collateralToken)) continue;
    seen.add(m.params.collateralToken);
    out.push(m.params.collateralToken);
  }
  return out;
}
