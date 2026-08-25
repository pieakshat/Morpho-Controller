import { describe, expect, it } from "vitest";
import { BaseError, encodeErrorResult, RawContractError } from "viem";
import { riskLimitsAbi, vaultAbi } from "@morphoagg/core";
import { decodeVaultError } from "@morphoagg/planner";
import type { Plan } from "@morphoagg/planner";

import { assertBatchFresh, extractRevertData, StalePlanError } from "../src/simulate.js";
import type { Policy } from "../src/config.js";
import { MARKET_A } from "./world.js";

const POLICY: Policy = {
  simulateBlockTag: "pending",
  maxPlanAgeSeconds: 45,
  maxPlanAgeBlocks: 600n,
  quoteSlippageBps: 50n,
  accrualBufferBps: 25n,
};

const SNAPSHOT = { blockNumber: 1_000n, timestamp: 1_800_000_000n };
const at = (secondsLater: bigint, blocksLater = 1n) => ({
  blockNumber: SNAPSHOT.blockNumber + blocksLater,
  timestamp: SNAPSHOT.timestamp + secondsLater,
});

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
  const stable = planAt(SNAPSHOT.blockNumber, "stable");
  const drifts = planAt(SNAPSHOT.blockNumber, "drifts");

  it("measures age in seconds, not blocks", () => {
    // 400 blocks is a quarter of the block backstop, but on a sub-second chain it is only a
    // hundred seconds of wall clock. Seconds is what decides.
    expect(() => assertBatchFresh([stable], SNAPSHOT, at(10n, 400n), POLICY)).not.toThrow();
    expect(() => assertBatchFresh([stable], SNAPSHOT, at(46n, 2n), POLICY)).toThrow(StalePlanError);
  });

  /**
   * The correction this whole change is about. The earlier version held a deleverage to one
   * block on the theory that accrual made it stale immediately. Measured, a 100k position
   * accrues 0.000033 USDC per Arbitrum block against a 250 USDC buffer, so the gate was
   * refusing at a quarter of a second to protect three weeks of headroom, and every deleverage
   * died before it reached simulation.
   */
  it("holds a drifting plan to exactly the same clock as a stable one", () => {
    const justInside = at(45n);
    const justOutside = at(46n);

    for (const plan of [stable, drifts]) {
      expect(() => assertBatchFresh([plan], SNAPSHOT, justInside, POLICY)).not.toThrow();
      expect(() => assertBatchFresh([plan], SNAPSHOT, justOutside, POLICY)).toThrow(StalePlanError);
    }
  });

  it("survives the round trip a real quote actually costs", () => {
    // A Velora call plus encode plus simulate runs 1 to 3 seconds. Under the old one-block
    // budget that was already several budgets' worth.
    expect(() => assertBatchFresh([drifts], SNAPSHOT, at(3n, 12n), POLICY)).not.toThrow();
  });

  it("keeps blocks as a backstop for a frozen or wrong clock", () => {
    // A node reporting a stuck timestamp would otherwise make every plan look brand new.
    const frozenClock = { blockNumber: SNAPSHOT.blockNumber + 601n, timestamp: SNAPSHOT.timestamp };
    expect(() => assertBatchFresh([stable], SNAPSHOT, frozenClock, POLICY)).toThrow(/601 blocks old/);
  });

  it("refuses to judge a plan built against a different snapshot", () => {
    const foreign = planAt(SNAPSHOT.blockNumber - 5n, "stable");
    expect(() => assertBatchFresh([foreign], SNAPSHOT, at(1n), POLICY)).toThrow(
      /plans from different snapshots cannot be submitted together/,
    );
  });

  it("fails the whole batch when any single leg is stale", () => {
    expect(() => assertBatchFresh([stable, drifts], SNAPSHOT, at(500n), POLICY)).toThrow(StalePlanError);
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
