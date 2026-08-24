import { describe, expect, it } from "vitest";
import { BaseError, encodeErrorResult, RawContractError } from "viem";
import { riskLimitsAbi, vaultAbi } from "@morphoagg/core";
import { decodeVaultError } from "@morphoagg/planner";
import type { Plan } from "@morphoagg/planner";

import { assertBatchFresh, extractRevertData, StalePlanError } from "../src/simulate.js";
import type { Policy } from "../src/config.js";
import { MARKET_A } from "./world.js";

const POLICY: Policy = {
  maxPlanAgeBlocksStable: 30n,
  maxPlanAgeBlocksDrifts: 1n,
  quoteSlippageBps: 50n,
  accrualBufferBps: 25n,
};

function planAt(stateBlock: bigint, driftClass: "stable" | "drifts"): Plan {
  return {
    kind: driftClass === "drifts" ? "deleverage" : "increase",
    marketId: MARKET_A,
    stateBlock,
    driftClass,
    isIncrease: driftClass !== "drifts",
    actionAmount: 1n,
    actionLeverage: 2n * 10n ** 18n,
    swap: {
      tokenIn: "0x0000000000000000000000000000000000000001",
      tokenOut: "0x0000000000000000000000000000000000000002",
      amountIn: 1n,
      recipient: "0x0000000000000000000000000000000000000003",
      oracleExpectedOut: 1n,
      minOutFloor: 1n,
    },
    ...(driftClass === "drifts"
      ? { isIncrease: false as const, collateralToWithdraw: 1n, repayAssets: 0n, repayShares: 1n, flashloanAmount: 1n, isFullClose: false }
      : { ownAmount: 1n, totalAmount: 2n, borrowAmount: 1n }),
  } as Plan;
}

describe("freshness gate", () => {
  it("lets a stable plan age but not a drifting one", () => {
    const head = 1_000n;

    expect(() => assertBatchFresh([planAt(head - 5n, "stable")], head, POLICY)).not.toThrow();
    // Same age, different class, opposite verdict. That asymmetry is the whole point of
    // classifying drift rather than using one budget.
    expect(() => assertBatchFresh([planAt(head - 5n, "drifts")], head, POLICY)).toThrow(StalePlanError);
  });

  it("accepts a plan exactly at its budget and refuses one block past it", () => {
    const head = 1_000n;
    expect(() => assertBatchFresh([planAt(head - 1n, "drifts")], head, POLICY)).not.toThrow();
    expect(() => assertBatchFresh([planAt(head - 2n, "drifts")], head, POLICY)).toThrow(StalePlanError);
  });

  it("fails the whole batch when any single leg is stale", () => {
    const head = 1_000n;
    const batch = [planAt(head, "stable"), planAt(head - 900n, "stable")];
    expect(() => assertBatchFresh(batch, head, POLICY)).toThrow(/900 blocks old/);
  });
});

describe("revert extraction", () => {
  /**
   * Without the raw bytes every custom error degrades to "execution reverted", which throws
   * away the entire named-error catalogue the contracts were written to provide.
   */
  it("digs the payload out of viem's nested wrapping and names the error", () => {
    const data = encodeErrorResult({
      abi: riskLimitsAbi,
      errorName: "Paused",
      args: [],
    });

    const wrapped = new BaseError("execution reverted", {
      cause: new BaseError("inner", { cause: new RawContractError({ data }) }),
    });

    expect(extractRevertData(wrapped)).toBe(data);
    expect(decodeVaultError(extractRevertData(wrapped))).toEqual({
      kind: "custom",
      name: "Paused",
      args: [],
    });
  });

  it("finds a payload a transport attached as a plain object", () => {
    const data = encodeErrorResult({ abi: vaultAbi, errorName: "TotalAssetsDropped", args: [100n, 90n, 99n] });
    expect(extractRevertData({ cause: { cause: { data } } })).toBe(data);
  });

  it("returns undefined rather than throwing when there is nothing to find", () => {
    expect(extractRevertData(new Error("connection refused"))).toBeUndefined();
    expect(extractRevertData(undefined)).toBeUndefined();
    // A self-referencing cause chain must not spin.
    const looped: { cause?: unknown } = {};
    looped.cause = looped;
    expect(extractRevertData(looped)).toBeUndefined();
  });
});
