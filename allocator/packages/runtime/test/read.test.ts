import { describe, expect, it } from "vitest";
import { decodeFunctionData, getAddress } from "viem";
import { morphoAbi } from "@morphoagg/core";

import { buildStateCalls, distinctCollateralTokens } from "../src/read/calls.js";
import { assertReaderAgreesWithVault, checkReaderAgreesWithVault, decodeVaultState } from "../src/read/decode.js";
import { runAggregate3, topologyOf, vaultTotalAssets, postAccrual } from "./fakeChain.js";
import { ADDRESSES, MARKET_A, MARKET_B, makeWorld } from "./world.js";

function read(world = makeWorld(), multicall3 = ADDRESSES.multicall3) {
  const topology = topologyOf(world);
  const built = buildStateCalls(topology, multicall3);
  const results = runAggregate3(world, built.calls);
  return { topology, built, results, state: decodeVaultState(topology, built.layout, results) };
}

describe("call list ordering", () => {
  it("puts every accrueInterest before any read", () => {
    const world = makeWorld();
    const { calls } = buildStateCalls(topologyOf(world), ADDRESSES.multicall3);

    const isAccrue = calls.map((c) => {
      if (getAddress(c.target) !== getAddress(world.morpho)) return false;
      return decodeFunctionData({ abi: morphoAbi, data: c.callData }).functionName === "accrueInterest";
    });

    const accrueCount = isAccrue.filter(Boolean).length;
    expect(accrueCount).toBe(world.markets.length);

    // The rule stated as an index: no accrual may appear after the first non-accrual.
    const firstRead = isAccrue.indexOf(false);
    expect(firstRead).toBe(accrueCount);
    expect(isAccrue.slice(firstRead).some(Boolean)).toBe(false);
  });

  it("reads one asset-exposure cap per distinct collateral token", () => {
    const world = makeWorld();
    // Point both markets at the same collateral. The cap is keyed by token, so it must
    // collapse to one read rather than two.
    world.markets[1]!.params = { ...world.markets[1]!.params, collateralToken: ADDRESSES.wstETH };

    expect(distinctCollateralTokens(topologyOf(world))).toEqual([ADDRESSES.wstETH]);

    const { layout } = buildStateCalls(topologyOf(world), ADDRESSES.multicall3);
    expect(layout.assetExposure).toHaveLength(1);
  });

  it("allows only the oracle read to fail", () => {
    const world = makeWorld();
    const { calls, layout } = buildStateCalls(topologyOf(world), ADDRESSES.multicall3);

    const permitted = calls.filter((c) => c.allowFailure).length;
    expect(permitted).toBe(world.markets.length);
    for (const m of layout.markets) expect(m.price.allowFailure).toBe(true);
  });
});

describe("decoding a snapshot", () => {
  it("assembles both markets with the right position, config and limits", () => {
    const world = makeWorld();
    const { state } = read(world);

    expect(state.blockNumber).toBe(world.blockNumber);
    expect(state.timestamp).toBe(world.timestamp);
    expect(state.idle).toBe(world.idle);
    expect(state.actionDropToleranceBps).toBe(world.actionDropToleranceBps);
    expect(state.markets.size).toBe(2);

    const a = state.markets.get(MARKET_A)!;
    expect(a.enabled).toBe(true);
    expect(a.maxLeverage).toBe(5n * 10n ** 18n);
    expect(a.maxSlippageBps).toBe(50n);
    expect(a.position.collateral).toBe(250n * 10n ** 18n);
    expect(a.params.collateralToken).toBe(ADDRESSES.wstETH);

    const b = state.markets.get(MARKET_B)!;
    expect(b.enabled).toBe(false);
    expect(b.maxLeverage).toBe(3n * 10n ** 18n);
    expect(b.position.collateral).toBe(5n * 10n ** 18n);
    expect(b.params.collateralToken).toBe(ADDRESSES.wbtc);

    // Per-market limits must not be swapped between markets, which is the failure a single
    // -market test cannot see.
    expect(state.riskLimits.perMarket.get(MARKET_A)!.maxPriceDeviationBps).toBe(500n);
    expect(state.riskLimits.perMarket.get(MARKET_B)!.maxPriceDeviationBps).toBe(300n);
    expect(state.riskLimits.maxAssetExposure.get(ADDRESSES.wstETH)).toBe(8_000_000_000_000n);
    expect(state.riskLimits.maxAssetExposure.get(ADDRESSES.wbtc)).toBe(3_000_000_000_000n);
  });

  it("returns post-accrual totals, not stored ones", () => {
    const world = makeWorld();
    const { state } = read(world);

    for (const m of world.markets) {
      const snapshot = state.markets.get(m.id)!;
      expect(snapshot.market.totalBorrowAssets).toBe(postAccrual(m).totalBorrowAssets);
      expect(snapshot.market.totalBorrowAssets).toBeGreaterThan(m.preAccrual.totalBorrowAssets);
      // Interest moves assets, never shares. Measured against real Arbitrum state before this
      // design was built on it.
      expect(snapshot.market.totalBorrowShares).toBe(m.preAccrual.totalBorrowShares);
    }
  });

  it("maps a reverting oracle to null rather than zero", () => {
    const world = makeWorld();
    world.markets[0]!.price = null;
    const { state } = read(world);

    expect(state.markets.get(MARKET_A)!.price).toBeNull();
    expect(state.markets.get(MARKET_B)!.price).not.toBeNull();
  });
});

describe("the reader checks itself", () => {
  it("agrees with the vault's own totalAssets", () => {
    const world = makeWorld();
    const { state } = read(world);

    expect(state.totalAssets).toBe(vaultTotalAssets(world));
    expect(checkReaderAgreesWithVault(state)).toBeNull();
    expect(() => assertReaderAgreesWithVault(state)).not.toThrow();
  });

  it("still agrees when an oracle is down, counting the debt and not the collateral", () => {
    const world = makeWorld();
    world.markets[0]!.price = null;
    const { state } = read(world);

    expect(checkReaderAgreesWithVault(state)).toBeNull();
    // The dead market's collateral is worth nothing while its debt still counts, so the total
    // must be strictly below the healthy one. A reader that skipped the position entirely
    // would drop the debt too and report MORE.
    expect(state.totalAssets).toBeLessThan(vaultTotalAssets(makeWorld()));
  });

  it("catches a position paired with the wrong market's totals", () => {
    const { state } = read();

    const a = state.markets.get(MARKET_A)!;
    const b = state.markets.get(MARKET_B)!;
    const corrupted = structuredCloneState(state);
    corrupted.markets.set(MARKET_A, { ...a, market: b.market });

    const mismatch = checkReaderAgreesWithVault(corrupted);
    expect(mismatch).not.toBeNull();
    expect(() => assertReaderAgreesWithVault(corrupted)).toThrow(/disagrees with the vault/);
  });

  it("catches the uint128 tuple unpacked in the wrong order", () => {
    const { state } = read();
    const a = state.markets.get(MARKET_A)!;

    // Exactly the slip the getter invites: supply and borrow swapped. No decode error, just a
    // plausible-looking market with the wrong debt behind it.
    const corrupted = structuredCloneState(state);
    corrupted.markets.set(MARKET_A, {
      ...a,
      market: {
        ...a.market,
        totalBorrowAssets: a.market.totalSupplyAssets,
        totalSupplyAssets: a.market.totalBorrowAssets,
      },
    });

    expect(checkReaderAgreesWithVault(corrupted)).not.toBeNull();
  });

  it("catches a read that landed before its accrual", () => {
    const { state } = read();
    const a = state.markets.get(MARKET_A)!;
    const world = makeWorld();

    // What a call list that read before it accrued would have produced.
    const corrupted = structuredCloneState(state);
    corrupted.markets.set(MARKET_A, { ...a, market: world.markets[0]!.preAccrual });

    const mismatch = checkReaderAgreesWithVault(corrupted);
    expect(mismatch).not.toBeNull();
    // Understated debt reads as MORE assets, which is the direction that matters: it would
    // size a flashloan too small and fail at execution rather than refusing up front.
    expect(mismatch!.mirrorDerived).toBeGreaterThan(mismatch!.vaultReported);
  });

  it("is exact, with no tolerance for a one-wei drift", () => {
    const { state } = read();
    const drifted = { ...state, idle: state.idle + 1n };
    expect(checkReaderAgreesWithVault(drifted)!.difference).toBe(1n);
  });
});

/** A shallow copy with a mutable markets map, so a test can corrupt one entry. */
function structuredCloneState<T extends { markets: ReadonlyMap<string, unknown> }>(state: T): T & { markets: Map<string, never> } {
  return { ...state, markets: new Map(state.markets) } as T & { markets: Map<string, never> };
}
