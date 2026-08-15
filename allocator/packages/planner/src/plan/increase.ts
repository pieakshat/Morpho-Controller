import { ORACLE_PRICE_SCALE, mulDivDown } from "@morphoagg/core";

import { fail } from "../errors.js";
import type { IncreaseIntent } from "../intents.js";
import type { VaultState } from "../state.js";
import { checkBeforeIncrease } from "./riskLimits.js";
import { oracleFloor, requireMarket, requirePrice } from "./shared.js";
import type { IncreasePlan } from "./types.js";

/**
 * Mirrors `MorphoLeverageEngine._increasePosition`, in its order.
 *
 * The one figure that is not obvious: the swap goes loanToken -> collateralToken, so the
 * oracle's collateral-per-loan-token rate is the INVERSE of the price it quotes. Decreases go
 * the other way and apply it directly. Getting this backwards produces a floor off by the
 * square of the price, which fails loudly rather than subtly, but only at execution.
 *
 * Drift: none. `totalAmount` comes from the intent alone, with no accrual input, so the swap
 * amount planned here is the swap amount the contract will use whenever it lands.
 */
export function planIncrease(state: VaultState, intent: IncreaseIntent, generalAdapter: `0x${string}`): IncreasePlan {
  const m = requireMarket(state, intent.marketId);

  // Registry gates first, in the contract's own order, so the failure a caller sees matches
  // the one they would have got on-chain.
  if (!m.enabled) fail({ code: "MarketNotEnabled", marketId: m.id });
  if (intent.leverage < 10n ** 18n) fail({ code: "LeverageBelowOneX", requested: intent.leverage });
  if (intent.leverage > m.maxLeverage) {
    fail({ code: "LeverageExceedsMax", requested: intent.leverage, max: m.maxLeverage });
  }

  const price = requirePrice(m);
  const totalAmount = (intent.ownAmount * intent.leverage) / 10n ** 18n;
  const borrowAmount = totalAmount - intent.ownAmount;

  // Not enforced by any named error on-chain: the engine does a plain safeTransfer of the own
  // contribution to GeneralAdapter1 before the flashloan, so a short balance reverts with a
  // bare ERC20 failure. Catching it here gives the caller something to act on.
  if (state.idle < intent.ownAmount) {
    fail({ code: "InsufficientIdle", required: intent.ownAmount, available: state.idle });
  }

  checkBeforeIncrease(state, m.id, totalAmount);

  const oracleExpectedOut = mulDivDown(totalAmount, ORACLE_PRICE_SCALE, price);

  return {
    kind: "increase",
    marketId: m.id,
    stateBlock: state.blockNumber,
    driftClass: "stable",
    isIncrease: true,
    actionAmount: intent.ownAmount,
    actionLeverage: intent.leverage,
    ownAmount: intent.ownAmount,
    totalAmount,
    borrowAmount,
    swap: {
      tokenIn: m.params.loanToken,
      tokenOut: m.params.collateralToken,
      // The whole flashloaned amount is swapped, not just the vault's contribution.
      amountIn: totalAmount,
      // Always GeneralAdapter1 on an increase: the supply and borrow legs both run from
      // there inside the flashloan callback.
      recipient: generalAdapter,
      oracleExpectedOut,
      minOutFloor: oracleFloor(oracleExpectedOut, m.maxSlippageBps),
    },
  };
}
