/**
 * Batch planning is where "plan each action independently" stops being correct.
 *
 * `executeActions` runs its array in order against shared state, and the vault exists partly
 * to support a decrease funding an increase in the same call. These tests pin that the
 * planner threads idle through the sequence, and that the batch-wide value guard is projected
 * rather than assumed.
 */

import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";

import { planBatch, projectEncodedBatch } from "../src/batch.js";
import { PlannerError } from "../src/errors.js";
import type { Intent } from "../src/intents.js";
import type { MarketSnapshot, VaultState } from "../src/state.js";
import type { Plan } from "../src/plan/types.js";
import type { MarketAction } from "@morphoagg/core";

const MKT_A = "0x33e0c8ab132390822b07e5dc95033cf250c963153320b7ffca73220664da2ea0" as Hex;
const MKT_B = "0xca83d02be579485cc10945c9597a6141e772f1cf0e0aa28d09a327b6cbd8642c" as Hex;
const VAULT = "0x0000000000000000000000000000000000000001" as Address;
const GA = "0x9954aFB60BB5A222714c478ac86990F221788B88" as Address;
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" as Address;
const WSTETH = "0x5979D7b546E38E414F7E9822514be443A4800529" as Address;
const WETH = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" as Address;

/** ~2322.9 USDC per wstETH, the live Arbitrum reading. */
const PRICE = 2322919887065307219008086849n;

function market(id: Hex, collateralToken: Address, collateral: bigint, borrowShares: bigint): MarketSnapshot {
  return {
    id,
    params: { loanToken: USDC, collateralToken, oracle: VAULT, irm: VAULT, lltv: 860000000000000000n },
    enabled: true,
    maxLeverage: 10n ** 19n,
    maxSlippageBps: 50n,
    position: { supplyShares: 0n, borrowShares, collateral },
    market: {
      totalSupplyAssets: 0n,
      totalSupplyShares: 0n,
      totalBorrowAssets: 2_301_561_495_701n,
      totalBorrowShares: 2_213_647_843_922_413_810n,
      lastUpdate: 0n,
      fee: 0n,
    },
    price: PRICE,
  };
}

function stateWith(idle: bigint, totalAssets = 1_000_000_000000n): VaultState {
  return {
    blockNumber: 1n,
    timestamp: 1n,
    vault: VAULT,
    asset: USDC,
    idle,
    totalAssets,
    actionDropToleranceBps: 100n,
    markets: new Map([
      [MKT_A, market(MKT_A, WSTETH, 86_098_535_344_958_775_195n, 96_180_260_577_753_035n)],
      [MKT_B, market(MKT_B, WETH, 80_131_736_459_777_543_039n, 95_142_019_997_196_733n)],
    ]),
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

const increase = (id: Hex, own: bigint, lev = 2n * 10n ** 18n): Intent => ({
  kind: "increase",
  marketId: id,
  ownAmount: own,
  leverage: lev,
});

describe("idle threading", () => {
  it("plans a lone increase against the starting idle", () => {
    const b = planBatch(stateWith(100_000_000000n), [increase(MKT_A, 50_000_000000n)], GA);
    expect(b.plans).toHaveLength(1);
    expect(b.projectedIdle).toBe(50_000_000000n);
  });

  it("refuses an increase the vault cannot fund", () => {
    try {
      planBatch(stateWith(10_000_000000n), [increase(MKT_A, 50_000_000000n)], GA);
      expect.unreachable("should have thrown");
    } catch (e) {
      const f = (e as PlannerError).failure;
      expect(f.code).toBe("InsufficientIdle");
      if (f.code === "InsufficientIdle") expect(f.available).toBe(10_000_000000n);
    }
  });

  it("spends idle across successive increases, not the starting balance twice", () => {
    // The bug this guards: planning both legs against the initial 100k would let a batch
    // through that spends 120k of a 100k balance.
    const intents = [increase(MKT_A, 60_000_000000n), increase(MKT_B, 60_000_000000n)];
    expect(() => planBatch(stateWith(100_000_000000n), intents, GA)).toThrow(/InsufficientIdle/);
  });

  it("lets a decrease fund an increase that the starting idle could not", () => {
    // The composition the vault documents. Idle starts at zero, so the increase is only
    // affordable out of what the decrease returns.
    const intents: Intent[] = [{ kind: "closeFully", marketId: MKT_A }, increase(MKT_B, 50_000_000000n)];

    const b = planBatch(stateWith(0n), intents, GA);
    expect(b.plans).toHaveLength(2);
    expect(b.plans[0]!.kind).toBe("closeFully");
    expect(b.plans[1]!.kind).toBe("increase");
  });

  it("and refuses that same pair when proceeds are not credited", () => {
    const intents: Intent[] = [{ kind: "closeFully", marketId: MKT_A }, increase(MKT_B, 50_000_000000n)];
    expect(() => planBatch(stateWith(0n), intents, GA, { creditDecreaseProceeds: false })).toThrow(
      /InsufficientIdle/,
    );
  });

  it("credits the decrease conservatively, at the oracle floor rather than the expectation", () => {
    // Over-estimating here would let a later increase be planned against money that may not
    // arrive, and the batch would revert on-chain instead of locally.
    const b = planBatch(stateWith(0n), [{ kind: "closeFully", marketId: MKT_A }], GA);
    const p = b.plans[0]!;
    if (p.kind === "increase") throw new Error("expected a decrease");

    expect(b.projectedIdle).toBe(p.swap.minOutFloor - p.flashloanAmount);
    expect(b.projectedIdle).toBeLessThan(p.swap.oracleExpectedOut - p.flashloanAmount);
  });
});

describe("one action per market", () => {
  it("refuses two actions on the same market", () => {
    // The second would need the position the first left behind, which means mirroring how
    // Morpho converts a repay into shares mid-batch. Refusing beats planning against stale
    // position state.
    const intents: Intent[] = [
      { kind: "decreaseByCollateral", marketId: MKT_A, collateralAmount: 10n ** 18n },
      increase(MKT_A, 1_000_000000n),
    ];
    try {
      planBatch(stateWith(100_000_000000n), intents, GA);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect((e as PlannerError).failure.code).toBe("DuplicateMarketInBatch");
    }
  });

  it("allows the same shapes across different markets", () => {
    const intents: Intent[] = [
      { kind: "decreaseByCollateral", marketId: MKT_A, collateralAmount: 10n ** 18n },
      increase(MKT_B, 1_000_000000n),
    ];
    expect(() => planBatch(stateWith(100_000_000000n), intents, GA)).not.toThrow();
  });
});

describe("the batch-wide value guard", () => {
  it("projects a worst case at the market's own slippage tolerance", () => {
    // 50bps on a 2x position from 50k of own capital: 100k total exposure, so ~500 USDC.
    const b = planBatch(stateWith(100_000_000000n), [increase(MKT_A, 50_000_000000n)], GA);

    expect(b.projection.worstCaseLoss).toBeGreaterThan(0n);
    expect(b.projection.worstCaseLoss).toBeLessThan(600_000000n);
    expect(b.projection.floor).toBe(990_000_000000n); // 1% of 1,000,000
    expect(b.projection.clearsWorstCase).toBe(true);
  });

  it("accumulates loss across legs rather than checking each alone", () => {
    // The failure mode the contract's batch guard exists for: legs that each clear their own
    // oracle floor while adding up to a breach.
    const one = planBatch(stateWith(500_000_000000n), [increase(MKT_A, 50_000_000000n)], GA);
    const two = planBatch(
      stateWith(500_000_000000n),
      [increase(MKT_A, 50_000_000000n), increase(MKT_B, 50_000_000000n)],
      GA,
    );
    expect(two.projection.worstCaseLoss).toBeGreaterThan(one.projection.worstCaseLoss);
  });

  it("flags a worst case that breaches, without throwing", () => {
    // Pessimistic by construction, so a breach here means unproven rather than doomed: real
    // quotes beat the floor. Throwing would reject legitimate batches.
    const tiny = stateWith(500_000_000000n, 20_000_000000n); // 1% floor is only 200 USDC
    const b = planBatch(tiny, [increase(MKT_A, 100_000_000000n)], GA);

    expect(b.projection.clearsWorstCase).toBe(false);
    expect(b.plans).toHaveLength(1); // still planned
  });
});

describe("re-projection with real minOuts", () => {
  const state = stateWith(100_000_000000n);
  const batch = planBatch(state, [increase(MKT_A, 50_000_000000n)], GA);

  const actionWith = (p: Plan, minOut: bigint): MarketAction => ({
    marketId: p.marketId,
    isIncrease: p.isIncrease,
    amount: p.actionAmount,
    leverage: p.actionLeverage,
    minOut,
    swapTarget: GA,
    swapCalldata: "0x",
  });

  it("a fill at the oracle expectation destroys nothing but round-trip dust", () => {
    // Not exactly zero, and the wei is genuine rather than a defect. `oracleExpectedOut`
    // floors converting loan token to collateral, and valuing that collateral back floors
    // again, so a perfect fill still reads as one wei short. Reporting it is correct; the
    // contract's own arithmetic has the same shape.
    const p = batch.plans[0]!;
    const proj = projectEncodedBatch(state, batch.plans, [actionWith(p, p.swap.oracleExpectedOut)]);
    expect(proj.worstCaseLoss).toBeLessThanOrEqual(2n);
  });

  it("a real quote beats the worst case", () => {
    const p = batch.plans[0]!;
    const good = p.swap.minOutFloor + (p.swap.oracleExpectedOut - p.swap.minOutFloor) / 2n;
    const proj = projectEncodedBatch(state, batch.plans, [actionWith(p, good)]);
    expect(proj.worstCaseLoss).toBeLessThan(batch.projection.worstCaseLoss);
  });

  it("throws when the projection really would trip the contract's guard", () => {
    const tiny = stateWith(100_000_000000n, 1_000_000000n); // floor is 990 USDC
    const b = planBatch(tiny, [increase(MKT_A, 50_000_000000n)], GA);
    const p = b.plans[0]!;
    try {
      projectEncodedBatch(tiny, b.plans, [actionWith(p, p.swap.minOutFloor)]);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect((e as PlannerError).failure.code).toBe("TotalAssetsDropBelowFloor");
    }
  });

  it("refuses a mismatched plans/actions pairing", () => {
    expect(() => projectEncodedBatch(state, batch.plans, [])).toThrow(/1 plans against 0 actions/);
  });
});
