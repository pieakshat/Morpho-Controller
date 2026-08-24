/**
 * PURE. Turns an `aggregate3` response into the `VaultState` the planner consumes.
 *
 * Pairs with `calls.ts`: the layout it produced carries a typed decoder per slot, so nothing
 * here indexes the result array by hand.
 *
 * The interesting part is `assertReaderAgreesWithVault`. This package has no golden vectors of
 * its own and does not need any, because the response contains its own oracle:
 *
 *     core.totalAssets(idle, positions)  ===  vault.totalAssets()
 *
 * The left side is the mirror deriving a number from raw position and market data. The right
 * side is the contract reporting the same number about itself. Both come from the same
 * `eth_call`, at the same instant, so they cannot disagree for any benign reason. A position
 * assembled from the wrong market's data, a `uint128` tuple unpacked in the wrong order, or a
 * read that landed before its `accrueInterest` all break the equality. Nothing else in this
 * package would have caught them.
 */

import { totalAssets as mirrorTotalAssets, type Id, type MarketState, type PositionInputs, type Position } from "@morphoagg/core";
import type { MarketRiskLimits, MarketSnapshot, VaultState } from "@morphoagg/planner";
import type { Address } from "viem";

import type { StateLayout, Topology } from "./calls.js";
import type { Multicall3Result } from "./multicall.js";

export function decodeVaultState(
  topology: Topology,
  layout: StateLayout,
  results: readonly Multicall3Result[],
): VaultState {
  const markets = new Map<Id, MarketSnapshot>();
  const perMarket = new Map<Id, MarketRiskLimits>();

  for (const m of layout.markets) {
    const config = m.config.decode(results);
    const [supplyShares, borrowShares, collateral] = m.position.decode(results);
    const market = decodeMarketState(m.market.decode(results));
    const price = m.price.decode(results);

    const position: Position = { supplyShares, borrowShares, collateral };

    markets.set(m.topology.id, {
      id: m.topology.id,
      // From the vault's own registry rather than from the topology copy. If the two ever
      // disagreed, the registry is the one the contract will check the action against.
      params: config.params,
      enabled: config.enabled,
      maxLeverage: config.maxLeverage,
      maxSlippageBps: config.maxSlippageBps,
      position,
      market,
      // `undefined` from an allowFailure slot means the oracle reverted. `null` is how the
      // planner and the valuation mirror both spell that, and the distinction from a genuine
      // zero matters: zero would be a price, null is the absence of one.
      price: price ?? null,
    });

    perMarket.set(m.topology.id, {
      minHealthFactor: m.minHealthFactor.decode(results),
      maxPriceDeviationBps: m.maxPriceDeviationBps.decode(results),
      maxExposureChangePerWindow: m.maxExposureChangePerWindow.decode(results),
      windowStart: m.windowStart.decode(results),
      windowExposureChange: m.windowExposureChange.decode(results),
      lastObservedPrice: m.lastObservedPrice.decode(results),
      lastObservedAt: m.lastObservedAt.decode(results),
    });
  }

  const maxAssetExposure = new Map<Address, bigint>();
  for (const entry of layout.assetExposure) {
    maxAssetExposure.set(entry.token, entry.cap.decode(results));
  }

  return {
    blockNumber: layout.blockNumber.decode(results),
    timestamp: layout.timestamp.decode(results),

    vault: topology.vault,
    asset: topology.asset,
    idle: layout.idle.decode(results),
    totalAssets: layout.totalAssets.decode(results),
    actionDropToleranceBps: layout.actionDropToleranceBps.decode(results),

    markets,
    riskLimits: {
      address: topology.riskLimits,
      paused: layout.paused.decode(results),
      maxAggregateDebt: layout.maxAggregateDebt.decode(results),
      maxSlippageBpsCeiling: layout.maxSlippageBpsCeiling.decode(results),
      rateLimitWindowSeconds: layout.rateLimitWindowSeconds.decode(results),
      priceObservationMaxAge: layout.priceObservationMaxAge.decode(results),
      perMarket,
      maxAssetExposure,
    },
  };
}

/**
 * Morpho's auto-generated getters return the struct's fields as a raw tuple, not a struct.
 * Unpacking them positionally is required, and getting the order wrong swaps supply for borrow
 * without any decode error. The self-check below is what notices.
 */
function decodeMarketState(t: readonly [bigint, bigint, bigint, bigint, bigint, bigint]): MarketState {
  const [totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee] = t;
  return { totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee };
}

export interface ReaderMismatch {
  vaultReported: bigint;
  mirrorDerived: bigint;
  difference: bigint;
}

/**
 * Compares the mirror's derivation against the vault's own report.
 *
 * Exact equality, with no tolerance. Both sides run the same integer arithmetic on the same
 * inputs at the same block; there is no rounding difference for a tolerance to absorb, so any
 * gap at all is a real defect and a band would only hide small ones.
 */
export function checkReaderAgreesWithVault(state: VaultState): ReaderMismatch | null {
  const positions: PositionInputs[] = [];
  for (const m of state.markets.values()) {
    positions.push({ position: m.position, market: m.market, price: m.price });
  }

  const mirrorDerived = mirrorTotalAssets(state.idle, positions);
  if (mirrorDerived === state.totalAssets) return null;

  return {
    vaultReported: state.totalAssets,
    mirrorDerived,
    difference: mirrorDerived > state.totalAssets ? mirrorDerived - state.totalAssets : state.totalAssets - mirrorDerived,
  };
}

export function assertReaderAgreesWithVault(state: VaultState): void {
  const mismatch = checkReaderAgreesWithVault(state);
  if (!mismatch) return;
  throw new Error(
    `state reader disagrees with the vault at block ${state.blockNumber}: ` +
      `vault.totalAssets() = ${mismatch.vaultReported}, mirror derived ${mismatch.mirrorDerived} ` +
      `(off by ${mismatch.difference}). The snapshot is not trustworthy; do not plan against it.`,
  );
}
