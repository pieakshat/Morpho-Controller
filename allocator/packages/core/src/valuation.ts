/**
 * Mirror of `MorphoPositionValuation` and `MorphoLeverageVault.totalAssets`.
 *
 * `_positionValue` and `_morphoSurplusAndShortfall` are `internal`, so there is no way to
 * read them from off-chain. They have to be reconstructed from `IMorpho.position`,
 * `IMorpho.market`, and the market oracle. That reconstruction is what this file is, and it
 * is why the golden-vector tests exist: nothing else would catch it drifting.
 *
 * Pure by design. Nothing here fetches. Callers pass the state they already read, which
 * keeps the mirror trivially testable and puts every RPC concern in the runtime package.
 */

import { mulDivDown, ORACLE_PRICE_SCALE } from "./math/fixed.js";
import { toAssetsUp } from "./math/shares.js";
import type { MarketState, Position } from "./types.js";

/**
 * One market's position, split by which side it lands on. Exactly one is ever non-zero.
 *
 * Returned as a pair rather than a single signed number for the same reason the contract
 * does it: a uint cannot express an underwater position, and clamping per position would
 * let the vault report more value than it has. Netting is the caller's job.
 */
export interface PositionValue {
  surplus: bigint;
  shortfall: bigint;
}

/** State needed to value a single position. `price` is null when the oracle is not answering. */
export interface PositionInputs {
  position: Position;
  market: MarketState;
  /**
   * The market oracle's `price()`, 1e36-scaled, or `null` if the call reverted.
   *
   * `null` is not the same as zero to a caller, but it produces the same valuation here, on
   * purpose: the contract's try/catch values the collateral at nothing while still counting
   * the debt. Skipping the position instead would drop the debt too and inflate the total
   * exactly when the vault can least justify it. Use `isMarketPriceable` to tell "worth
   * little" apart from "cannot currently see".
   */
  price: bigint | null;
}

/** Mirrors `MorphoPositionValuation._positionValue`. */
export function positionValue({ position, market, price }: PositionInputs): PositionValue {
  let debtValue = 0n;
  if (position.borrowShares > 0n) {
    // Rounds UP. Never under-report what the position owes.
    debtValue = toAssetsUp(position.borrowShares, market.totalBorrowAssets, market.totalBorrowShares);
  }

  let collateralValue = 0n;
  if (position.collateral > 0n && price !== null) {
    collateralValue = mulDivDown(position.collateral, price, ORACLE_PRICE_SCALE);
  }

  return collateralValue >= debtValue
    ? { surplus: collateralValue - debtValue, shortfall: 0n }
    : { surplus: 0n, shortfall: debtValue - collateralValue };
}

/**
 * Mirrors `_morphoSurplusAndShortfall`: sums each side independently across active markets.
 *
 * Summing separately rather than clamping per position is load-bearing. Clamping first would
 * discard whether a shortfall should eat into idle balance.
 */
export function surplusAndShortfall(positions: readonly PositionInputs[]): PositionValue {
  let surplus = 0n;
  let shortfall = 0n;
  for (const p of positions) {
    const v = positionValue(p);
    surplus += v.surplus;
    shortfall += v.shortfall;
  }
  return { surplus, shortfall };
}

/**
 * Mirrors `MorphoPositionValuation.totalMorphoAssets`. Informational only: it floors early,
 * which throws away whether a shortfall should have reduced idle balance.
 */
export function totalMorphoAssets(positions: readonly PositionInputs[]): bigint {
  const { surplus, shortfall } = surplusAndShortfall(positions);
  return surplus > shortfall ? surplus - shortfall : 0n;
}

/**
 * Mirrors `MorphoLeverageVault.totalAssets`: idle balance plus surplus, minus shortfall,
 * floored at zero.
 *
 * Note it nets the shortfall against IDLE, not just against other positions' surplus. Idle
 * stays withdrawable regardless of what markets are doing, so dropping the shortfall would
 * overstate the share price and let whoever redeemed first exit at a stale one.
 */
export function totalAssets(idleBalance: bigint, positions: readonly PositionInputs[]): bigint {
  const { surplus, shortfall } = surplusAndShortfall(positions);
  const gross = idleBalance + surplus;
  return gross > shortfall ? gross - shortfall : 0n;
}

/**
 * The floor `executeActions` checks its own result against:
 * `assetsBefore * (10_000 - dropToleranceBps) / 10_000`.
 *
 * Integer division, rounding down, so the on-chain floor is marginally more lenient than
 * exact arithmetic. Reproduced that way here rather than "corrected".
 */
export function dropToleranceFloor(assetsBefore: bigint, dropToleranceBps: bigint): bigint {
  return (assetsBefore * (10_000n - dropToleranceBps)) / 10_000n;
}

/**
 * Health factor as `RiskLimits._healthFactor` computes it: `collateralValue * lltv / debtValue`,
 * WAD-scaled, so 1e18 is the liquidation boundary. Returns null for a position with no debt,
 * which the contract represents as `type(uint256).max`.
 */
export function healthFactor(
  position: Position,
  market: MarketState,
  price: bigint,
  lltv: bigint,
): bigint | null {
  if (position.borrowShares === 0n) return null;
  const debtValue = toAssetsUp(position.borrowShares, market.totalBorrowAssets, market.totalBorrowShares);
  const collateralValue = mulDivDown(position.collateral, price, ORACLE_PRICE_SCALE);
  return (collateralValue * lltv) / debtValue;
}
