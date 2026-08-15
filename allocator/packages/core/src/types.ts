import type { Address, Hex } from "viem";

/** Morpho Blue market identifier: keccak256(abi.encode(MarketParams)). */
export type Id = Hex;

/** Morpho Blue's MarketParams, field order matching the struct exactly. */
export interface MarketParams {
  loanToken: Address;
  collateralToken: Address;
  oracle: Address;
  irm: Address;
  lltv: bigint;
}

/**
 * One instruction for `MorphoLeverageVault.executeActions`.
 *
 * `amount` and `leverage` interact in a way that is easy to get wrong, so the modes are
 * spelled out here rather than left to the reader:
 *
 * | isIncrease | leverage      | amount                                    |
 * |------------|---------------|-------------------------------------------|
 * | true       | >= 1e18       | the vault's OWN contribution, not the total |
 * | false      | 0             | collateral to withdraw, or MAX for a full close |
 * | false      | >= 1e18       | ignored; deleverages to that target ratio   |
 *
 * A decrease with `0 < leverage < 1e18` reverts `LeverageBelowOneX`.
 */
export interface MarketAction {
  marketId: Id;
  isIncrease: boolean;
  amount: bigint;
  leverage: bigint;
  minOut: bigint;
  swapTarget: Address;
  swapCalldata: Hex;
}

/** Sentinel accepted by a decrease's `amount` to mean "close the whole position". */
export const FULL_CLOSE = (1n << 256n) - 1n;

/** A vault position in one market, as returned by `IMorpho.position`. */
export interface Position {
  supplyShares: bigint;
  borrowShares: bigint;
  collateral: bigint;
}

/**
 * The subset of `IMorpho.market` this system reads.
 *
 * These MUST be post-accrual values. Both `_planDecrease` and `_planDeleverage` call
 * `MORPHO.accrueInterest` before reading, so a plain `market()` read at the current block
 * returns pre-accrual totals and understates debt. See the Multicall3 batching note in the
 * runtime package.
 */
export interface MarketState {
  totalSupplyAssets: bigint;
  totalSupplyShares: bigint;
  totalBorrowAssets: bigint;
  totalBorrowShares: bigint;
  lastUpdate: bigint;
  fee: bigint;
}
