import type { Id } from "@morphoagg/core";

/**
 * What a strategy is allowed to ask for.
 *
 * Four kinds, matching the contract's four execution modes exactly. The mapping onto
 * `MarketAction` is not one-to-one with its fields, which is the point of having this type
 * at all: `MarketAction` packs mode selection into the interaction between `amount` and
 * `leverage`, and two of those combinations are traps.
 *
 * | Intent               | isIncrease | amount            | leverage  |
 * |----------------------|------------|-------------------|-----------|
 * | increase             | true       | own contribution  | >= 1e18   |
 * | decreaseByCollateral | false      | collateral out    | 0         |
 * | closeFully           | false      | type(uint256).max | 0         |
 * | deleverageTo         | false      | 0 (ignored)       | >= 1e18   |
 *
 * `closeFully` is deliberately its own kind rather than a flag on `decreaseByCollateral`.
 * The contract's sentinel rule is `amount >= collateralRaw`, so passing the exact collateral
 * balance is also a full close, while any value strictly between `collateralRaw` and
 * `type(uint256).max` reverts `InvalidDecreaseAmount`. Making that band unrepresentable is
 * cheaper than documenting it and hoping.
 *
 * A decrease with `0 < leverage < 1e18` reverts `LeverageBelowOneX`, which is why
 * `deleverageTo` carries a target rather than a delta.
 */
export type Intent =
  | IncreaseIntent
  | DecreaseByCollateralIntent
  | CloseFullyIntent
  | DeleverageToIntent;

export interface IncreaseIntent {
  kind: "increase";
  marketId: Id;
  /**
   * The vault's OWN contribution, not the resulting position size. Total exposure is
   * `ownAmount * leverage / 1e18`, and the difference is what gets borrowed.
   *
   * The vault must hold at least this much idle: the engine does a plain `safeTransfer` to
   * GeneralAdapter1 before the flashloan, which reverts with a bare ERC20 error rather than
   * anything named if the balance is short.
   */
  ownAmount: bigint;
  /** WAD. 1e18 is 1x, which supplies collateral with no borrow at all. */
  leverage: bigint;
}

export interface DecreaseByCollateralIntent {
  kind: "decreaseByCollateral";
  marketId: Id;
  /**
   * Collateral units to withdraw. Debt is repaid in proportion, so a request whose share of
   * the debt rounds to zero reverts `DecreaseAmountTooSmall` rather than quietly pulling
   * collateral out for free.
   */
  collateralAmount: bigint;
}

export interface CloseFullyIntent {
  kind: "closeFully";
  marketId: Id;
}

export interface DeleverageToIntent {
  kind: "deleverageTo";
  marketId: Id;
  /**
   * WAD, and must be strictly below the position's current leverage or the contract reverts
   * `TargetLeverageNotBelowCurrent`. Note the current leverage the contract computes is an
   * upper bound (collateral value rounds down, debt rounds up), so a target very close to it
   * can still be rejected.
   *
   * Exactly 1e18 repays the whole debt while keeping the collateral, which is distinct from
   * `closeFully`.
   */
  targetLeverage: bigint;
}

/** True for the intents that add exposure, and therefore the ones RiskLimits can block. */
export function isRiskIncreasing(intent: Intent): boolean {
  return intent.kind === "increase";
}
