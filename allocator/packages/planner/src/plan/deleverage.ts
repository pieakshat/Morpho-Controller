import { ORACLE_PRICE_SCALE, mulDivDown, mulDivUp, toAssetsUp, toSharesDown } from "@morphoagg/core";
import type { Address } from "viem";

import { fail } from "../errors.js";
import type { DeleverageToIntent } from "../intents.js";
import type { VaultState } from "../state.js";
import { oracleFloor, requireMarket, requirePrice } from "./shared.js";
import type { DecreasePlan } from "./types.js";

const WAD = 10n ** 18n;

/**
 * Mirrors `MorphoLeverageEngine._planDeleverage`.
 *
 * The shape to understand: equity is held constant and the collateral value is rebased to
 * `targetLeverage * equity`, so the value withdrawn equals the value repaid and no capital
 * enters or leaves beyond that.
 *
 * The repay is derived in SHARES, not value, and that is not a stylistic choice. Computing an
 * asset amount from an independently-rounded value estimate can convert back to more shares
 * than the position holds once rounding compounds, which underflows Morpho's
 * `borrowShares -= shares`. That bug was hit twice during the build. Deriving `repayShares`
 * straight from `borrowShares` keeps the two commensurable by construction.
 *
 * Drift: this is the one mode where the swap amount itself moves. `collateralToWithdraw` is
 * derived from `flashloanAmount`, which is derived from accrued debt, so it grows between
 * planning and inclusion.
 */
export function planDeleverage(
  state: VaultState,
  intent: DeleverageToIntent,
  generalAdapter: Address,
): DecreasePlan {
  const m = requireMarket(state, intent.marketId);
  const target = intent.targetLeverage;

  if (target < WAD) fail({ code: "LeverageBelowOneX", requested: target });

  const price = requirePrice(m);
  const { collateral, borrowShares } = m.position;
  const { totalBorrowAssets, totalBorrowShares } = m.market;

  const collateralValue = mulDivDown(collateral, price, ORACLE_PRICE_SCALE);
  const debtValue = borrowShares > 0n ? toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares) : 0n;

  // On-chain this subtraction underflows and reverts when collateral no longer covers debt.
  // Deliberately not floored there, and not floored here: an underwater position cannot be
  // deleveraged at all, and hiding that behind a zero would turn a real condition into a
  // confusing downstream failure. Proportional decrease and full close still work.
  if (collateralValue < debtValue) fail({ code: "PositionHasNoEquity", marketId: m.id });

  const equity = collateralValue - debtValue;
  if (equity === 0n) fail({ code: "PositionHasNoEquity", marketId: m.id });

  // Both inputs are conservative (collateral rounds down, debt rounds up), so this is an
  // UPPER bound on the true leverage. A target very close to the real current ratio can
  // therefore still be rejected.
  const currentLeverage = (collateralValue * WAD) / equity;
  if (target >= currentLeverage) {
    fail({ code: "TargetLeverageNotBelowCurrent", target, current: currentLeverage });
  }

  const newCollateralValue = (target * equity) / WAD;

  let repayShares: bigint;
  if (target === WAD) {
    // 1x means no debt at all. Repaying the exact share count avoids the rounding dust a
    // value-derived amount would leave.
    repayShares = borrowShares;
  } else {
    const newDebtValue = newCollateralValue - equity;
    let targetBorrowShares = toSharesDown(newDebtValue, totalBorrowAssets, totalBorrowShares);
    // The up/down rounding chain can overshoot by a share or two at the margins. Clamp
    // rather than let the subtraction below underflow.
    if (targetBorrowShares > borrowShares) targetBorrowShares = borrowShares;
    repayShares = borrowShares - targetBorrowShares;
  }

  if (repayShares === 0n) fail({ code: "DeleverageAmountTooSmall" });

  // Both derived from repayShares rather than from a separately-rounded value estimate, so
  // the flashloan is always exactly enough to cover what Morpho charges for this many shares.
  const flashloanAmount = toAssetsUp(repayShares, totalBorrowAssets, totalBorrowShares);
  const collateralToWithdraw = mulDivUp(flashloanAmount, ORACLE_PRICE_SCALE, price);

  if (collateralToWithdraw > collateral) {
    fail({ code: "InvalidDecreaseAmount", requested: collateralToWithdraw, available: collateral });
  }

  const oracleExpectedOut = mulDivDown(collateralToWithdraw, price, ORACLE_PRICE_SCALE);

  return {
    kind: "deleverage",
    marketId: m.id,
    stateBlock: state.blockNumber,
    driftClass: "drifts",
    isIncrease: false,
    // Ignored by the contract in this mode, and set to zero to match what the engine reads.
    actionAmount: 0n,
    actionLeverage: target,
    collateralToWithdraw,
    repayAssets: 0n,
    repayShares,
    flashloanAmount,
    isFullClose: false,
    swap: {
      tokenIn: m.params.collateralToken,
      tokenOut: m.params.loanToken,
      amountIn: collateralToWithdraw,
      recipient: flashloanAmount > 0n ? generalAdapter : state.vault,
      oracleExpectedOut,
      minOutFloor: oracleFloor(oracleExpectedOut, m.maxSlippageBps),
    },
  };
}
