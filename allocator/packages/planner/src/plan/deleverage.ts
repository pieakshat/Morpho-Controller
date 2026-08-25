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
 * The shape to understand: the withdrawal is grossed up by the market's slippage tolerance so
 * the swap can always repay the flashloan, and the target debt is then SOLVED for so the
 * position still lands on `targetLeverage` once that surplus has left it.
 *
 * Both halves are load-bearing. Sizing the withdrawal to the repay's own oracle value is the
 * obvious thing and cannot work: the flashloan is taken by GeneralAdapter1 and Morpho reclaims
 * from GeneralAdapter1 inside the callback, so the swap proceeds are the only funds present,
 * and a real route always fills below the oracle. And once the withdrawal is grossed up, the
 * naive `equity * (target - 1)` target debt leaves the position ABOVE the request, by 0.7% at
 * this market's 50bps and 21% at the registry's 1000bps ceiling.
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

  let repayShares: bigint;
  if (target === WAD) {
    // 1x means no debt at all. Repaying the exact share count avoids the rounding dust a
    // value-derived amount would leave.
    repayShares = borrowShares;
  } else {
    const newDebtValue = targetDebtValue(target, equity, debtValue, m.maxSlippageBps);
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
  // Mirrors `_collateralToCoverRepay`: sell enough that even the worst fill this market
  // permits still repays the flashloan.
  const collateralToWithdraw = mulDivUp(
    mulDivUp(flashloanAmount, 10_000n, 10_000n - m.maxSlippageBps),
    ORACLE_PRICE_SCALE,
    price,
  );

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

/**
 * Mirrors `MorphoLeverageEngine._targetDebtValue`.
 *
 * Writing D for debt, E for equity, k for `target - 1e18` and m for the slippage fraction
 * `s / (10_000 - s)`, the post-state has to satisfy `D_f = k * (E - (D - D_f) * m)`, because
 * the surplus `(D - D_f) * m` is what the grossed-up withdrawal sends to idle. Solving gives
 * `D_f = k * (E - D*m) / (1 - k*m)`, multiplied through by `10_000 - s` to stay in integers.
 */
function targetDebtValue(target: bigint, equity: bigint, debtValue: bigint, maxSlippageBps: bigint): bigint {
  // Nothing is grossed up when no slippage is tolerated, so the naive target is already exact.
  if (maxSlippageBps === 0n) return ((target - WAD) * equity) / WAD;

  const denom = 10_000n - maxSlippageBps;
  const k = target - WAD;

  // Both say the same thing from different directions: the slippage this market permits has to
  // be affordable out of the equity being worked with. Only reachable for a market pairing very
  // high leverage with a very loose bound, which the contract rejects as DeleverageTooCostly.
  if (equity * denom <= debtValue * maxSlippageBps || WAD * denom <= k * maxSlippageBps) {
    fail({ code: "DeleverageTooCostly" });
  }

  return (k * (equity * denom - debtValue * maxSlippageBps)) / (WAD * denom - k * maxSlippageBps);
}
