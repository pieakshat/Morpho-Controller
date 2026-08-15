import { vaultAbi, type MarketAction } from "@morphoagg/core";
import { encodeFunctionData, type Hex } from "viem";

import { fail } from "./errors.js";
import type { Plan } from "./plan/types.js";
import type { Quote } from "./quote.js";

/** Defaults chosen to be conservative; every one of them is worth tuning per deployment. */
export interface EncodeOptions {
  /**
   * How far below the quote's own expected output we are willing to be filled, in bps.
   *
   * This is slippage against the QUOTE, which is a different thing from the market's
   * `maxSlippageBps`: that one bounds the fill against the ORACLE and is enforced on-chain
   * regardless of what we submit. This is our own, tighter bound on top.
   */
  quoteSlippageBps?: bigint;

  /**
   * Headroom required over `flashloanAmount` on a decrease, in bps.
   *
   * Debt keeps accruing between planning and inclusion, so the amount Morpho reclaims is
   * strictly larger than the figure the plan computed. Without headroom a deleverage sized
   * exactly to its repay comes up short and the whole bundle reverts.
   */
  accrualBufferBps?: bigint;

  /**
   * Optional two-sided sanity band between the quote and the oracle, in bps.
   *
   * Unset by default because the one-sided case is already fatal and checked separately. The
   * reason to set it: a quote wildly better than the oracle usually means the oracle is
   * stale, and trading against a price the vault will later disagree with is how a swap
   * clears the floor and still loses money.
   */
  maxOracleDivergenceBps?: bigint;
}

const DEFAULTS = {
  quoteSlippageBps: 50n,
  accrualBufferBps: 25n,
} as const;

/**
 * Plan + Quote -> MarketAction. Pure.
 *
 * Everything here is a refusal to emit an action the contract would reject, or would accept
 * and then execute badly. Each check exists because of a specific failure mode, noted inline.
 */
export function encode(plan: Plan, quote: Quote, options: EncodeOptions = {}): MarketAction {
  const quoteSlippageBps = options.quoteSlippageBps ?? DEFAULTS.quoteSlippageBps;
  const accrualBufferBps = options.accrualBufferBps ?? DEFAULTS.accrualBufferBps;

  // 1. The route must be for exactly the amount the bundle will transfer in.
  if (quote.amountIn !== plan.swap.amountIn) {
    fail({ code: "QuoteAmountMismatch", planned: plan.swap.amountIn, quoted: quote.amountIn });
  }

  // 2. A route that cannot clear the oracle floor cannot be made to work by submitting a
  //    lower minOut: the contract raises whatever we send up to that floor, so the swap
  //    reverts SlippageExceeded regardless. Refuse rather than broadcast a certain failure.
  if (quote.expectedOut < plan.swap.minOutFloor) {
    fail({ code: "QuoteBelowOracleFloor", expectedOut: quote.expectedOut, floor: plan.swap.minOutFloor });
  }

  // 3. On a decrease with debt, the output has to cover what Morpho reclaims, plus room for
  //    the interest that accrues before inclusion.
  const requiredForFlashloan =
    !plan.isIncrease && plan.flashloanAmount > 0n
      ? (plan.flashloanAmount * (10_000n + accrualBufferBps)) / 10_000n
      : 0n;

  if (quote.expectedOut < requiredForFlashloan) {
    fail({ code: "QuoteCannotCoverFlashloan", expectedOut: quote.expectedOut, required: requiredForFlashloan });
  }

  // 4. Optional: a large disagreement in either direction means one of the two prices is
  //    wrong, and we do not know which.
  if (options.maxOracleDivergenceBps !== undefined) {
    const oracle = plan.swap.oracleExpectedOut;
    const diff = quote.expectedOut > oracle ? quote.expectedOut - oracle : oracle - quote.expectedOut;
    if (oracle > 0n && (diff * 10_000n) / oracle > options.maxOracleDivergenceBps) {
      fail({
        code: "OracleDivergesFromQuote",
        oracleImplied: oracle,
        quoted: quote.expectedOut,
        maxSlippageBps: options.maxOracleDivergenceBps,
      });
    }
  }

  // The submitted bound is the tightest of everything that must hold. Submitting the oracle
  // floor alone would be legal and lazy: it is the protocol's bound, not ours, and leaves the
  // whole gap between it and the real quote available to MEV.
  const fromQuote = (quote.expectedOut * (10_000n - quoteSlippageBps)) / 10_000n;
  const minOut = maxOf(fromQuote, plan.swap.minOutFloor, requiredForFlashloan);

  return {
    marketId: plan.marketId,
    isIncrease: plan.isIncrease,
    amount: plan.actionAmount,
    leverage: plan.actionLeverage,
    minOut,
    swapTarget: quote.to,
    swapCalldata: quote.data,
  };
}

function maxOf(...xs: bigint[]): bigint {
  return xs.reduce((a, b) => (a > b ? a : b));
}

/** Calldata for `MorphoLeverageVault.executeActions`. */
export function encodeExecuteActions(actions: readonly MarketAction[]): Hex {
  return encodeFunctionData({ abi: vaultAbi, functionName: "executeActions", args: [actions] });
}

/**
 * Refuses a plan that has gone stale.
 *
 * Worth calling for anything drift-sensitive. A deleverage's `collateralToWithdraw` is derived
 * from accrued debt, so an old plan encodes a swap amount that no longer matches what the
 * contract will compute, and the mismatch surfaces as a bundle revert rather than as anything
 * legible.
 */
export function assertPlanFresh(plan: Plan, currentBlock: bigint, maxAgeBlocks: bigint): void {
  const age = currentBlock - plan.stateBlock;
  if (age > maxAgeBlocks) {
    throw new Error(
      `plan for ${plan.marketId} is ${age} blocks old (max ${maxAgeBlocks}, driftClass=${plan.driftClass}); re-plan against fresh state`,
    );
  }
}
