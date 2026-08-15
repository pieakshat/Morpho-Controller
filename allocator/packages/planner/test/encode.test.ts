/**
 * Tests for the Plan + Quote -> MarketAction step.
 *
 * Every check in `encode` exists because of a specific way the transaction fails without it,
 * so each test here names that failure rather than just asserting a branch.
 *
 * The round-trip test at the end is the one that matters most: it decodes the emitted
 * calldata back through the real vault ABI, which is what catches a field ordering or type
 * mistake that no amount of TypeScript would.
 */

import { describe, expect, it } from "vitest";
import { decodeFunctionData, type Address, type Hex } from "viem";

import { vaultAbi, type MarketAction } from "@morphoagg/core";
import { encode, encodeExecuteActions, assertPlanFresh } from "../src/encode.js";
import { PlannerError } from "../src/errors.js";
import type { DecreasePlan, IncreasePlan, Plan } from "../src/plan/types.js";
import type { Quote } from "../src/quote.js";

const MARKET_ID = "0x33e0c8ab132390822b07e5dc95033cf250c963153320b7ffca73220664da2ea0" as Hex;
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" as Address;
const WSTETH = "0x5979D7b546E38E414F7E9822514be443A4800529" as Address;
const GA = "0x9954aFB60BB5A222714c478ac86990F221788B88" as Address;
const VENUE = "0x1111111254EEB25477B68fb85Ed929f73A960582" as Address;

/** 100,000 USDC in, oracle says 43.05 wstETH out, 50bps market tolerance. */
const ORACLE_OUT = 43_049_267_672_479_387_597n;
const FLOOR = (ORACLE_OUT * 9_950n) / 10_000n;

function increasePlan(): IncreasePlan {
  return {
    kind: "increase",
    marketId: MARKET_ID,
    stateBlock: 1_000n,
    driftClass: "stable",
    isIncrease: true,
    actionAmount: 50_000_000000n,
    actionLeverage: 2n * 10n ** 18n,
    ownAmount: 50_000_000000n,
    totalAmount: 100_000_000000n,
    borrowAmount: 50_000_000000n,
    swap: {
      tokenIn: USDC,
      tokenOut: WSTETH,
      amountIn: 100_000_000000n,
      recipient: GA,
      oracleExpectedOut: ORACLE_OUT,
      minOutFloor: FLOOR,
    },
  };
}

/** A deleverage: output is sized close to the repay, so the accrual buffer actually binds. */
function deleveragePlan(flashloanAmount = 50_000_000000n): DecreasePlan {
  const oracleOut = 50_200_000000n;
  return {
    kind: "deleverage",
    marketId: MARKET_ID,
    stateBlock: 1_000n,
    driftClass: "drifts",
    isIncrease: false,
    actionAmount: 0n,
    actionLeverage: 15n * 10n ** 17n,
    collateralToWithdraw: 21_547_760_756_500_327_672n,
    repayAssets: 0n,
    repayShares: 48_115_951_389_369_129n,
    flashloanAmount,
    isFullClose: false,
    swap: {
      tokenIn: WSTETH,
      tokenOut: USDC,
      amountIn: 21_547_760_756_500_327_672n,
      recipient: GA,
      oracleExpectedOut: oracleOut,
      minOutFloor: (oracleOut * 9_950n) / 10_000n,
    },
  };
}

function quoteFor(plan: Plan, expectedOut: bigint): Quote {
  return { to: VENUE, data: "0xdeadbeef", amountIn: plan.swap.amountIn, expectedOut };
}

describe("the amountIn equality check", () => {
  it("refuses a route built for a different amount", () => {
    const p = increasePlan();
    const q = { ...quoteFor(p, ORACLE_OUT), amountIn: p.swap.amountIn - 1n };
    try {
      encode(p, q);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect((e as PlannerError).failure.code).toBe("QuoteAmountMismatch");
    }
  });

  it("refuses even when the quote is for MORE than planned", () => {
    // Too large is the worse of the two: the router's transferFrom fails and the executor
    // surfaces a bare SwapCallFailed with the venue's reason discarded.
    const p = increasePlan();
    expect(() => encode(p, { ...quoteFor(p, ORACLE_OUT), amountIn: p.swap.amountIn + 1n })).toThrow(
      /QuoteAmountMismatch/,
    );
  });
});

describe("the oracle floor", () => {
  it("refuses a route that cannot clear it", () => {
    // Submitting a lower minOut would not help: the contract raises whatever we send up to
    // the floor, so the swap reverts SlippageExceeded either way.
    const p = increasePlan();
    expect(() => encode(p, quoteFor(p, FLOOR - 1n))).toThrow(/QuoteBelowOracleFloor/);
  });

  it("accepts a route sitting exactly on it", () => {
    const p = increasePlan();
    expect(() => encode(p, quoteFor(p, FLOOR))).not.toThrow();
  });

  it("never submits a minOut below the floor, even with loose quote slippage", () => {
    const p = increasePlan();
    const action = encode(p, quoteFor(p, ORACLE_OUT), { quoteSlippageBps: 9_000n });
    expect(action.minOut).toBe(FLOOR);
  });

  it("submits the tighter quote-derived bound when it exceeds the floor", () => {
    // The gap between the oracle floor and a real quote is value available to MEV. Leaving
    // minOut at the floor is legal and lazy.
    const p = increasePlan();
    const action = encode(p, quoteFor(p, ORACLE_OUT), { quoteSlippageBps: 10n });
    const fromQuote = (ORACLE_OUT * 9_990n) / 10_000n;
    expect(action.minOut).toBe(fromQuote);
    expect(action.minOut).toBeGreaterThan(FLOOR);
  });
});

describe("the accrual buffer on decrease legs", () => {
  it("refuses a quote that only just covers the flashloan", () => {
    // Exactly enough at plan time is not enough at inclusion time: debt keeps accruing, so
    // Morpho reclaims more than the plan computed and the bundle reverts.
    const p = deleveragePlan();
    expect(() => encode(p, quoteFor(p, p.flashloanAmount), { accrualBufferBps: 25n })).toThrow(
      /QuoteCannotCoverFlashloan/,
    );
  });

  it("accepts once the output clears the buffered amount", () => {
    const p = deleveragePlan();
    const buffered = (p.flashloanAmount * 10_025n) / 10_000n;
    expect(() => encode(p, quoteFor(p, buffered), { accrualBufferBps: 25n })).not.toThrow();
  });

  it("raises minOut to the buffered flashloan when that is the binding constraint", () => {
    const p = deleveragePlan();
    const buffered = (p.flashloanAmount * 10_025n) / 10_000n;
    // Quote slippage alone would allow a fill below what Morpho will reclaim.
    const action = encode(p, quoteFor(p, buffered + 1_000_000n), {
      accrualBufferBps: 25n,
      quoteSlippageBps: 500n,
    });
    expect(action.minOut).toBeGreaterThanOrEqual(buffered);
  });

  it("does not apply to an increase, which has no repay leg", () => {
    const p = increasePlan();
    const action = encode(p, quoteFor(p, ORACLE_OUT), { accrualBufferBps: 10_000n });
    expect(action.minOut).toBeLessThanOrEqual(ORACLE_OUT);
  });

  it("does not apply to a debt-free decrease", () => {
    const p = deleveragePlan(0n);
    expect(() => encode(p, quoteFor(p, p.swap.minOutFloor), { accrualBufferBps: 10_000n })).not.toThrow();
  });
});

describe("the optional oracle divergence band", () => {
  it("is off unless asked for", () => {
    const p = increasePlan();
    expect(() => encode(p, quoteFor(p, ORACLE_OUT * 2n))).not.toThrow();
  });

  it("catches a quote wildly better than the oracle, which usually means a stale oracle", () => {
    const p = increasePlan();
    expect(() => encode(p, quoteFor(p, ORACLE_OUT * 2n), { maxOracleDivergenceBps: 100n })).toThrow(
      /OracleDivergesFromQuote/,
    );
  });

  it("allows a quote inside the band", () => {
    const p = increasePlan();
    const slightlyBetter = (ORACLE_OUT * 10_050n) / 10_000n;
    expect(() => encode(p, quoteFor(p, slightlyBetter), { maxOracleDivergenceBps: 100n })).not.toThrow();
  });
});

describe("the emitted action", () => {
  it("carries the plan's mode fields verbatim", () => {
    const p = deleveragePlan();
    const buffered = (p.flashloanAmount * 10_100n) / 10_000n;
    const action = encode(p, quoteFor(p, buffered));

    expect(action.marketId).toBe(MARKET_ID);
    expect(action.isIncrease).toBe(false);
    expect(action.amount).toBe(0n); // ignored by the contract in deleverage mode
    expect(action.leverage).toBe(15n * 10n ** 17n);
    expect(action.swapTarget).toBe(VENUE);
    expect(action.swapCalldata).toBe("0xdeadbeef");
  });

  it("round-trips through the real vault ABI", () => {
    // The check TypeScript cannot make: that the struct's field order and types line up with
    // what solc generated. Encoding and decoding through the actual ABI is what proves it.
    const p = increasePlan();
    const action = encode(p, quoteFor(p, ORACLE_OUT));
    const calldata = encodeExecuteActions([action]);

    const decoded = decodeFunctionData({ abi: vaultAbi, data: calldata });
    expect(decoded.functionName).toBe("executeActions");

    const [actions] = decoded.args as unknown as [readonly MarketAction[]];
    expect(actions).toHaveLength(1);
    expect(actions[0]!.marketId).toBe(action.marketId);
    expect(actions[0]!.isIncrease).toBe(true);
    expect(actions[0]!.amount).toBe(action.amount);
    expect(actions[0]!.leverage).toBe(action.leverage);
    expect(actions[0]!.minOut).toBe(action.minOut);
    expect(actions[0]!.swapTarget).toBe(VENUE);
    expect(actions[0]!.swapCalldata).toBe("0xdeadbeef");
  });

  it("encodes a multi-action batch, which the vault supports in one call", () => {
    const inc = encode(increasePlan(), quoteFor(increasePlan(), ORACLE_OUT));
    const del = deleveragePlan();
    const dec = encode(del, quoteFor(del, (del.flashloanAmount * 10_100n) / 10_000n));

    const decoded = decodeFunctionData({ abi: vaultAbi, data: encodeExecuteActions([dec, inc]) });
    const [actions] = decoded.args as unknown as [readonly MarketAction[]];
    // Order is preserved: a decrease first can fund an increase later in the same batch.
    expect(actions).toHaveLength(2);
    expect(actions[0]!.isIncrease).toBe(false);
    expect(actions[1]!.isIncrease).toBe(true);
  });
});

describe("staleness", () => {
  it("accepts a fresh plan", () => {
    expect(() => assertPlanFresh(increasePlan(), 1_003n, 5n)).not.toThrow();
  });

  it("refuses one past the budget, naming the drift class", () => {
    expect(() => assertPlanFresh(deleveragePlan(), 1_050n, 5n)).toThrow(/drifts/);
  });
});
