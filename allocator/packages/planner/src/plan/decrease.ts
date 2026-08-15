import { FULL_CLOSE, ORACLE_PRICE_SCALE, mulDivDown, toAssetsUp } from "@morphoagg/core";
import type { Address } from "viem";

import { fail } from "../errors.js";
import type { CloseFullyIntent, DecreaseByCollateralIntent } from "../intents.js";
import type { VaultState } from "../state.js";
import { oracleFloor, requireMarket, requirePrice } from "./shared.js";
import type { DecreasePlan } from "./types.js";

/**
 * Mirrors `MorphoLeverageEngine._planDecrease`, covering both the proportional branch and the
 * full-close branch.
 *
 * The branch is selected by `requestedAmount >= collateralRaw`, not `==`, and the difference
 * matters: passing the exact collateral balance is also a full close. Routing that through
 * the proportional branch would compute `repayAssets == toAssetsUp(borrowShares)`, which
 * Morpho converts back to at least `borrowShares` and then underflows on. That was a real bug
 * during the build, and it is why `closeFully` is a separate intent.
 *
 * Drift: the swap amount is stable in both branches. Collateral does not accrue, so
 * `collateralToWithdraw` is fixed either by the intent or by the current balance. What DOES
 * move is `flashloanAmount` on a full close, since it is `toAssetsUp(borrowShares)` and
 * interest keeps accruing. The swap output has to keep covering it, which is `encode`'s
 * problem via the accrual buffer.
 */
export function planDecrease(
  state: VaultState,
  intent: DecreaseByCollateralIntent | CloseFullyIntent,
  generalAdapter: Address,
): DecreasePlan {
  const m = requireMarket(state, intent.marketId);

  // Note the contract checks `_isRegistered`, not `isMarketEnabled`. A disabled market can
  // always be unwound; only increases are gated.
  const collateralRaw = m.position.collateral;
  if (collateralRaw === 0n) fail({ code: "NoPosition", marketId: m.id });

  const requestedAmount = intent.kind === "closeFully" ? FULL_CLOSE : intent.collateralAmount;

  const isFullClose = requestedAmount >= collateralRaw;
  const collateralToWithdraw = isFullClose ? collateralRaw : requestedAmount;

  // The band strictly between collateralRaw and the sentinel is rejected on-chain. The intent
  // types make it unreachable from a strategy, but a hand-built intent could still land here.
  if (requestedAmount !== FULL_CLOSE && requestedAmount > collateralRaw) {
    fail({ code: "InvalidDecreaseAmount", requested: requestedAmount, available: collateralRaw });
  }

  let repayAssets = 0n;
  let repayShares = 0n;
  let flashloanAmount = 0n;

  const borrowShares = m.position.borrowShares;
  if (borrowShares > 0n) {
    const { totalBorrowAssets, totalBorrowShares } = m.market;

    if (isFullClose) {
      // Exact shares, so there is no dust mismatch from toAssetsUp's rounding: Morpho works
      // out the precise asset cost itself.
      repayShares = borrowShares;
      flashloanAmount = toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
    } else {
      const totalDebt = toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
      repayAssets = (totalDebt * collateralToWithdraw) / collateralRaw;

      // A withdrawal small enough that its share of the debt truncates to zero would skip the
      // repay leg entirely and pull collateral out for free, raising leverage on what is
      // supposed to be a proportional decrease.
      if (repayAssets === 0n) fail({ code: "DecreaseAmountTooSmall" });
      flashloanAmount = repayAssets;
    }
  }

  const price = requirePrice(m);
  // collateralToken -> loanToken, so the price applies directly rather than inverted.
  const oracleExpectedOut = mulDivDown(collateralToWithdraw, price, ORACLE_PRICE_SCALE);

  return {
    kind: intent.kind === "closeFully" ? "closeFully" : "decrease",
    marketId: m.id,
    stateBlock: state.blockNumber,
    driftClass: "stable",
    isIncrease: false,
    actionAmount: requestedAmount,
    actionLeverage: 0n,
    collateralToWithdraw,
    repayAssets,
    repayShares,
    flashloanAmount,
    isFullClose,
    swap: {
      tokenIn: m.params.collateralToken,
      tokenOut: m.params.loanToken,
      amountIn: collateralToWithdraw,
      // With debt, the proceeds must land on GeneralAdapter1: Morpho reclaims the flashloan
      // synchronously inside the same call, so a later sweep would be too late. Without debt
      // there is no flashloan, and the vault takes delivery directly.
      recipient: flashloanAmount > 0n ? generalAdapter : state.vault,
      oracleExpectedOut,
      minOutFloor: oracleFloor(oracleExpectedOut, m.maxSlippageBps),
    },
  };
}
