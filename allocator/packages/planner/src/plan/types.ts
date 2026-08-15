import type { Id } from "@morphoagg/core";
import type { Address } from "viem";

/**
 * The swap leg, fully determined before any aggregator is contacted.
 *
 * `amountIn` is the load-bearing field. `MorphoSwapExecutor` swaps its ENTIRE balance while
 * the calldata hardcodes an amount, so the route has to be requested for exactly this figure:
 * encode less and the residual is swept back to idle as undeployed capital, encode more and
 * the router's `transferFrom` fails as an opaque `SwapCallFailed` with the underlying reason
 * discarded.
 */
export interface SwapLeg {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;

  /**
   * Where the executor sends the output. Not cosmetic: on a decrease with debt it must be
   * GeneralAdapter1, because Morpho reclaims the flashloan synchronously inside the same
   * call and a later bundle step would be too late.
   */
  recipient: Address;

  /** What the market oracle says `amountIn` is worth, before slippage. */
  oracleExpectedOut: bigint;

  /**
   * `oracleExpectedOut * (10_000 - maxSlippageBps) / 10_000`, mirroring `_effectiveMinOut`.
   *
   * A one-way ratchet: the contract takes `max(submitted, this)`, so submitting less is
   * silently raised and submitting more binds tighter than the protocol requires.
   */
  minOutFloor: bigint;
}

/**
 * How much the swap amount can move between planning and inclusion.
 *
 * Both decrease planners call `MORPHO.accrueInterest` first, so anything derived from debt
 * moves with time. Which figures those are differs by mode, and that is what this classifies.
 */
export type DriftClass =
  /** `amountIn` is fixed by the intent or by collateral, neither of which accrues. */
  | "stable"
  /** `amountIn` derives from accrued debt and grows until the transaction lands. */
  | "drifts";

interface PlanBase {
  marketId: Id;
  swap: SwapLeg;

  /** Block the state snapshot came from. Freshness is the caller's to judge. */
  stateBlock: bigint;
  driftClass: DriftClass;

  /** Exactly what `MarketAction.isIncrease` / `.amount` / `.leverage` must be set to. */
  isIncrease: boolean;
  actionAmount: bigint;
  actionLeverage: bigint;
}

export interface IncreasePlan extends PlanBase {
  kind: "increase";
  isIncrease: true;
  /** The vault's own contribution. Must be available as idle before the bundle runs. */
  ownAmount: bigint;
  /** `ownAmount * leverage / 1e18`. Also the flashloan size and the swap's `amountIn`. */
  totalAmount: bigint;
  /** `totalAmount - ownAmount`. Zero at exactly 1x, where the borrow leg is omitted. */
  borrowAmount: bigint;
}

/**
 * Covers proportional decrease, full close, and deleverage. They share a shape because the
 * contract computes all three into the same `DecreasePlan` struct.
 *
 * Exactly one of `repayAssets` and `repayShares` is ever non-zero. Proportional decreases
 * repay by assets; full closes and deleverages repay by exact shares, which is what avoids
 * converting back to more shares than the position holds.
 */
export interface DecreasePlan extends PlanBase {
  kind: "decrease" | "closeFully" | "deleverage";
  isIncrease: false;
  collateralToWithdraw: bigint;
  repayAssets: bigint;
  repayShares: bigint;
  /** What Morpho will reclaim. The swap output must cover at least this much. */
  flashloanAmount: bigint;
  isFullClose: boolean;
}

export type Plan = IncreasePlan | DecreasePlan;

export function isIncreasePlan(p: Plan): p is IncreasePlan {
  return p.kind === "increase";
}
