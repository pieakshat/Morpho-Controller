/**
 * Shares <-> assets conversion, mirroring `MorphoSharesMath` bit for bit.
 *
 * That library is itself pinned against morpho-org/morpho-blue v1.0.0
 * (55d2d99304fb3fb930c688462ae2ccabb1d533ad). The formula, the constants, and above all the
 * ROUNDING DIRECTIONS must stay identical. A single flipped direction here does not produce
 * a slightly wrong number, it produces calldata Morpho rejects: computing a repay from an
 * independently-rounded value estimate is exactly what caused the repay-overshoot underflow
 * inside Morpho during the build, twice.
 *
 * The rule, in both directions: round so the result never understates what is owed.
 */

import { addUint256, mulDivDown, mulDivUp } from "./fixed.js";

export const VIRTUAL_SHARES = 10n ** 6n;
export const VIRTUAL_ASSETS = 1n;

/** Value of `shares` in assets, rounding DOWN. Supply side: never over-report a claim. */
export function toAssetsDown(shares: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivDown(
    shares,
    addUint256("toAssetsDown", totalAssets, VIRTUAL_ASSETS),
    addUint256("toAssetsDown", totalShares, VIRTUAL_SHARES),
  );
}

/** Value of `shares` in assets, rounding UP. Debt side: never under-report a liability. */
export function toAssetsUp(shares: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivUp(
    shares,
    addUint256("toAssetsUp", totalAssets, VIRTUAL_ASSETS),
    addUint256("toAssetsUp", totalShares, VIRTUAL_SHARES),
  );
}

/** Value of `assets` in shares, rounding DOWN. */
export function toSharesDown(assets: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivDown(
    assets,
    addUint256("toSharesDown", totalShares, VIRTUAL_SHARES),
    addUint256("toSharesDown", totalAssets, VIRTUAL_ASSETS),
  );
}

/** Value of `assets` in shares, rounding UP. */
export function toSharesUp(assets: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivUp(
    assets,
    addUint256("toSharesUp", totalShares, VIRTUAL_SHARES),
    addUint256("toSharesUp", totalAssets, VIRTUAL_ASSETS),
  );
}
