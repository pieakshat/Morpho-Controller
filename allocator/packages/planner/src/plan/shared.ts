import type { Id } from "@morphoagg/core";

import { fail } from "../errors.js";
import type { MarketSnapshot, VaultState } from "../state.js";

/**
 * Mirrors `MorphoLeverageEngine._effectiveMinOut`'s floor half.
 *
 * The contract then takes `max(submitted, floor)`. The planner only computes the floor here;
 * choosing the number actually submitted is `encode`'s job, once a real quote exists.
 */
export function oracleFloor(oracleExpectedOut: bigint, maxSlippageBps: bigint): bigint {
  return (oracleExpectedOut * (10_000n - maxSlippageBps)) / 10_000n;
}

export function requireMarket(state: VaultState, marketId: Id): MarketSnapshot {
  const m = state.markets.get(marketId);
  if (!m) fail({ code: "MarketNotInSnapshot", marketId });
  return m;
}

/**
 * Every path that has to derive a swap floor needs a live price.
 *
 * Valuation degrades gracefully when an oracle is down (collateral counted as worthless,
 * debt still counted), but increases and deleverages revert outright, because neither can
 * compute `oracleExpectedOut` without one. Refusing here is the same rule, applied earlier.
 */
export function requirePrice(m: MarketSnapshot): bigint {
  if (m.price === null) fail({ code: "OracleUnavailable", marketId: m.id });
  return m.price;
}
