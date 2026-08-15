import type { Id, MarketParams, MarketState, Position } from "@morphoagg/core";
import type { Address } from "viem";

/**
 * Everything the planner reads. Assembled by the runtime; the planner never fetches.
 *
 * Keeping this a plain value rather than a client handle is what lets every plan function be
 * a pure function of its inputs, which in turn is what makes them checkable against golden
 * vectors dumped from the contracts.
 */
export interface VaultState {
  /** Block the snapshot was taken at. Every Plan carries this so staleness is measurable. */
  blockNumber: bigint;
  /** Unix seconds at `blockNumber`. Needed for RiskLimits' window and anchor-age checks. */
  timestamp: bigint;

  vault: Address;
  asset: Address;
  /** The vault's own loan-token balance. This is what an increase's own contribution spends. */
  idle: bigint;
  /** As the contract reports it: idle + surplus - shortfall, floored at zero. */
  totalAssets: bigint;
  actionDropToleranceBps: bigint;

  markets: ReadonlyMap<Id, MarketSnapshot>;
  riskLimits: RiskLimitsSnapshot;
}

export interface MarketSnapshot {
  id: Id;
  params: MarketParams;

  /** Registry config. `enabled` gates increases only; decreases just need registration. */
  enabled: boolean;
  maxLeverage: bigint;
  maxSlippageBps: bigint;

  position: Position;

  /**
   * MUST be post-accrual.
   *
   * Both `_planDecrease` and `_planDeleverage` call `MORPHO.accrueInterest` before reading,
   * so a plain `market()` at the current block returns pre-accrual totals and understates
   * debt. Every number the planner derives from this would then be too small, and the
   * flashloan would come up short at execution.
   *
   * The runtime gets the right values by batching `accrueInterest` and `market()` into a
   * single `eth_call` through Multicall3: state does not persist past the call, but it does
   * apply within it. Re-implementing the AdaptiveCurveIRM off-chain would be the alternative,
   * and would be a second drift surface for no gain.
   */
  market: MarketState;

  /**
   * The market oracle's `price()`, 1e36-scaled, or `null` when the call reverted.
   *
   * `null` is not merely "unknown". Increases and deleverages against a dead oracle revert
   * outright, because neither can derive a swap floor without a price, while valuation
   * degrades to counting the collateral as worthless. The planner has to refuse those intents
   * rather than plan them.
   */
  price: bigint | null;
}

/** The subset of RiskLimits state the planner needs to predict a rejection. */
export interface RiskLimitsSnapshot {
  address: Address;
  paused: boolean;

  /** Global. Zero means unenforced, for every field here and below. */
  maxAggregateDebt: bigint;
  maxSlippageBpsCeiling: bigint;
  rateLimitWindowSeconds: bigint;
  priceObservationMaxAge: bigint;

  perMarket: ReadonlyMap<Id, MarketRiskLimits>;
  /** Keyed by collateral token, summed across every active market sharing it. */
  maxAssetExposure: ReadonlyMap<Address, bigint>;
}

export interface MarketRiskLimits {
  minHealthFactor: bigint;
  maxPriceDeviationBps: bigint;

  /**
   * Net exposure growth allowed per window. Increases consume it, decreases release it.
   */
  maxExposureChangePerWindow: bigint;
  windowStart: bigint;
  windowExposureChange: bigint;

  lastObservedPrice: bigint;
  lastObservedAt: bigint;
}

export function marketOrThrow(state: VaultState, id: Id): MarketSnapshot {
  const m = state.markets.get(id);
  if (!m) throw new Error(`market ${id} is not present in the snapshot`);
  return m;
}
