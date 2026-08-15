/**
 * Differential test for the plan functions.
 *
 * Every vector is `_planDecrease` / `_planDeleverage` output, dumped by
 * test/vectors/PlanVectors.t.sol through the PlanHarness. The mirror gets the same inputs and
 * must produce the same `collateralToWithdraw`, `repayAssets`, `repayShares`, and
 * `flashloanAmount`, exactly.
 *
 * Exactly is the operative word. These figures feed calldata: a value one wei off on
 * `repayShares` underflows Morpho's `borrowShares -= shares`, and one wei off on
 * `collateralToWithdraw` desynchronises the swap amount from what the bundle transfers.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import { FULL_CLOSE, type Id } from "@morphoagg/core";
import { PlannerError } from "../src/errors.js";
import { planDecrease } from "../src/plan/decrease.js";
import { planDeleverage } from "../src/plan/deleverage.js";
import type { MarketSnapshot, VaultState } from "../src/state.js";

const here = dirname(fileURLToPath(import.meta.url));
const raw = JSON.parse(readFileSync(join(here, "vectors/plans.json"), "utf8")) as {
  maxSlippageBps: number;
  cases: string[];
};

const MARKET_ID = "0x33e0c8ab132390822b07e5dc95033cf250c963153320b7ffca73220664da2ea0" as Id;
const VAULT = "0x0000000000000000000000000000000000000001" as Address;
const GA = "0x9954aFB60BB5A222714c478ac86990F221788B88" as Address;
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" as Address;
const WSTETH = "0x5979D7b546E38E414F7E9822514be443A4800529" as Address;

interface Vector {
  kind: "dec" | "del";
  collateral: bigint;
  borrowShares: bigint;
  tba: bigint;
  tbs: bigint;
  price: bigint;
  request: bigint;
  collateralToWithdraw: bigint;
  repayAssets: bigint;
  repayShares: bigint;
  flashloanAmount: bigint;
  isFullClose: boolean;
}

const vectors: Vector[] = raw.cases.map((line) => {
  const f = line.split(",");
  return {
    kind: f[0] as "dec" | "del",
    collateral: BigInt(f[1]!),
    borrowShares: BigInt(f[2]!),
    tba: BigInt(f[3]!),
    tbs: BigInt(f[4]!),
    price: BigInt(f[5]!),
    request: BigInt(f[6]!),
    collateralToWithdraw: BigInt(f[7]!),
    repayAssets: BigInt(f[8]!),
    repayShares: BigInt(f[9]!),
    flashloanAmount: BigInt(f[10]!),
    isFullClose: f[11] === "1",
  };
});

function stateFor(v: Vector): VaultState {
  const market: MarketSnapshot = {
    id: MARKET_ID,
    params: { loanToken: USDC, collateralToken: WSTETH, oracle: VAULT, irm: VAULT, lltv: 860000000000000000n },
    enabled: true,
    maxLeverage: 10n ** 19n,
    maxSlippageBps: BigInt(raw.maxSlippageBps),
    position: { supplyShares: 0n, borrowShares: v.borrowShares, collateral: v.collateral },
    market: {
      totalSupplyAssets: 0n,
      totalSupplyShares: 0n,
      totalBorrowAssets: v.tba,
      totalBorrowShares: v.tbs,
      lastUpdate: 0n,
      fee: 0n,
    },
    price: v.price,
  };

  return {
    blockNumber: 1n,
    timestamp: 1n,
    vault: VAULT,
    asset: USDC,
    idle: 10n ** 24n,
    totalAssets: 10n ** 24n,
    actionDropToleranceBps: 100n,
    markets: new Map([[MARKET_ID, market]]),
    riskLimits: {
      address: VAULT,
      paused: false,
      maxAggregateDebt: 0n,
      maxSlippageBpsCeiling: 0n,
      rateLimitWindowSeconds: 0n,
      priceObservationMaxAge: 0n,
      perMarket: new Map(),
      maxAssetExposure: new Map(),
    },
  };
}

describe("plan vectors", () => {
  it("covers both modes and a real spread", () => {
    expect(vectors.filter((v) => v.kind === "dec").length).toBeGreaterThanOrEqual(6);
    expect(vectors.filter((v) => v.kind === "del").length).toBeGreaterThanOrEqual(4);
  });

  vectors.forEach((v, i) => {
    const label = v.kind === "dec" ? (v.isFullClose ? "full close" : "proportional") : "deleverage";

    it(`#${i} ${label} request=${v.request} reproduces the contract's plan`, () => {
      const state = stateFor(v);

      const p =
        v.kind === "dec"
          ? planDecrease(
              state,
              v.request === FULL_CLOSE
                ? { kind: "closeFully", marketId: MARKET_ID }
                : { kind: "decreaseByCollateral", marketId: MARKET_ID, collateralAmount: v.request },
              GA,
            )
          : planDeleverage(state, { kind: "deleverageTo", marketId: MARKET_ID, targetLeverage: v.request }, GA);

      expect(p.collateralToWithdraw).toBe(v.collateralToWithdraw);
      expect(p.repayAssets).toBe(v.repayAssets);
      expect(p.repayShares).toBe(v.repayShares);
      expect(p.flashloanAmount).toBe(v.flashloanAmount);
      if (v.kind === "dec") expect(p.isFullClose).toBe(v.isFullClose);

      // The swap must be sized to the collateral actually leaving, in every mode.
      expect(p.swap.amountIn).toBe(v.collateralToWithdraw);
      expect(p.swap.tokenIn).toBe(WSTETH);
      expect(p.swap.tokenOut).toBe(USDC);
    });
  });
});

describe("properties the vectors imply", () => {
  it("exactly one of repayAssets and repayShares is ever set", () => {
    for (const v of vectors) {
      expect(v.repayAssets === 0n || v.repayShares === 0n).toBe(true);
    }
  });

  it("a full close repays by exact shares, never by assets", () => {
    for (const v of vectors.filter((x) => x.isFullClose)) {
      expect(v.repayShares).toBe(v.borrowShares);
      expect(v.repayAssets).toBe(0n);
    }
  });

  it("both full-close spellings produce an identical plan", () => {
    // `type(uint256).max` and the exact collateral balance must take the same path. Routing
    // the latter through the proportional branch is what used to underflow inside Morpho.
    const sentinel = vectors.find((v) => v.kind === "dec" && v.request === FULL_CLOSE)!;
    const exact = vectors.find((v) => v.kind === "dec" && !v.isFullClose === false && v.request === v.collateral)!;
    expect(exact).toBeDefined();
    expect(exact.collateralToWithdraw).toBe(sentinel.collateralToWithdraw);
    expect(exact.repayShares).toBe(sentinel.repayShares);
    expect(exact.flashloanAmount).toBe(sentinel.flashloanAmount);
  });

  it("deleverage collateral drifts upward as interest accrues", () => {
    // Same 1.5x target, seven days apart. This is the drift the accrual buffer exists for.
    const at15x = vectors.filter((v) => v.kind === "del" && v.request === 1_500_000_000_000_000_000n);
    expect(at15x.length).toBe(2);
    expect(at15x[1]!.collateralToWithdraw).toBeGreaterThan(at15x[0]!.collateralToWithdraw);
    expect(at15x[1]!.flashloanAmount).toBeGreaterThan(at15x[0]!.flashloanAmount);
  });
});

describe("predicted failures match what the contract would reject", () => {
  const base = vectors.find((v) => v.kind === "dec" && !v.isFullClose)!;

  it("a decrease whose repay rounds to zero is refused", () => {
    const state = stateFor(base);
    expect(() =>
      planDecrease(state, { kind: "decreaseByCollateral", marketId: MARKET_ID, collateralAmount: 1n }, GA),
    ).toThrow(/DecreaseAmountTooSmall/);
  });

  it("an amount between the collateral balance and the sentinel is refused", () => {
    const state = stateFor(base);
    try {
      planDecrease(
        state,
        { kind: "decreaseByCollateral", marketId: MARKET_ID, collateralAmount: base.collateral + 1n },
        GA,
      );
      expect.unreachable("should have thrown");
    } catch (e) {
      expect((e as PlannerError).failure.code).toBe("InvalidDecreaseAmount");
    }
  });

  it("a decrease on an empty position is refused", () => {
    const state = stateFor({ ...base, collateral: 0n });
    expect(() => planDecrease(state, { kind: "closeFully", marketId: MARKET_ID }, GA)).toThrow(/NoPosition/);
  });

  it("a deleverage target at or above current leverage is refused", () => {
    const del = vectors.find((v) => v.kind === "del")!;
    const state = stateFor(del);
    try {
      planDeleverage(state, { kind: "deleverageTo", marketId: MARKET_ID, targetLeverage: 10n ** 19n }, GA);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect((e as PlannerError).failure.code).toBe("TargetLeverageNotBelowCurrent");
    }
  });

  it("a deleverage on an underwater position is refused, not floored", () => {
    // The contract underflows and reverts here deliberately, so a silent zero would hide a
    // real condition. Proportional decrease and full close still work on such a position.
    const del = vectors.find((v) => v.kind === "del")!;
    const state = stateFor({ ...del, collateral: 1n });
    try {
      planDeleverage(state, { kind: "deleverageTo", marketId: MARKET_ID, targetLeverage: 15n * 10n ** 17n }, GA);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect((e as PlannerError).failure.code).toBe("PositionHasNoEquity");
    }
  });

  it("a dead oracle blocks planning rather than producing a floorless swap", () => {
    const state = stateFor(base);
    const m = state.markets.get(MARKET_ID)!;
    const blinded = new Map(state.markets);
    blinded.set(MARKET_ID, { ...m, price: null });
    expect(() =>
      planDecrease({ ...state, markets: blinded }, { kind: "closeFully", marketId: MARKET_ID }, GA),
    ).toThrow(/OracleUnavailable/);
  });
});
