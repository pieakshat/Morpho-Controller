import type { Id } from "@morphoagg/core";

import { fail } from "../errors.js";
import type { VaultState } from "../state.js";

/**
 * Predicts whether `RiskLimits.checkBeforeIncrease` would revert.
 *
 * Only the before-hook is reproduced. The after-hook's checks (health factor, aggregate debt,
 * asset exposure, realized slippage) all read state that only exists once the bundle has run,
 * so predicting them means projecting a post-trade position rather than reading one. That
 * belongs with batch projection, not here.
 *
 * Worth remembering while reading this: RiskLimits gates by ACTION direction, not risk
 * direction. A 1x increase reduces a position's leverage and still passes through every check
 * below, pause included.
 */
export function checkBeforeIncrease(state: VaultState, marketId: Id, totalAmount: bigint): void {
  const rl = state.riskLimits;
  if (rl.paused) fail({ code: "RiskLimitsPaused" });

  const perMarket = rl.perMarket.get(marketId);
  if (!perMarket) return; // never configured: every threshold is fail-open at zero

  checkPriceDeviation(state, marketId);
  checkRateLimit(state, marketId, totalAmount);
}

/**
 * An anchor is only compared against when one exists and is recent enough.
 *
 * Past `priceObservationMaxAge` a threshold measures cumulative drift, which is
 * indistinguishable from a break, so the contract ignores stale anchors rather than rejecting
 * against them. A `maxAge` of zero means never expire.
 */
function checkPriceDeviation(state: VaultState, marketId: Id): void {
  const rl = state.riskLimits;
  const m = state.markets.get(marketId);
  const limits = rl.perMarket.get(marketId);
  if (!m || !limits || limits.maxPriceDeviationBps === 0n) return;
  if (m.price === null) return; // OracleUnavailable is raised earlier, by requirePrice

  const anchorExists = limits.lastObservedPrice !== 0n;
  const fresh =
    rl.priceObservationMaxAge === 0n || state.timestamp - limits.lastObservedAt <= rl.priceObservationMaxAge;
  if (!anchorExists || !fresh) return;

  const last = limits.lastObservedPrice;
  const diff = m.price > last ? m.price - last : last - m.price;
  if (diff > (last * limits.maxPriceDeviationBps) / 10_000n) {
    fail({
      code: "PriceDeviationExceeded",
      marketId,
      newPrice: m.price,
      lastPrice: last,
      maxBps: limits.maxPriceDeviationBps,
    });
  }
}

/**
 * Net exposure growth per fixed window. Increases consume budget, decreases release it.
 *
 * Two separate disable conditions, and both matter: a zero cap, and a zero window. The
 * contract refuses to accept a live cap while the window is zero, precisely because a zero
 * window makes every call look like a fresh period and turns a per-window budget into a
 * per-action one.
 */
function checkRateLimit(state: VaultState, marketId: Id, delta: bigint): void {
  const rl = state.riskLimits;
  const limits = rl.perMarket.get(marketId);
  if (!limits) return;

  const cap = limits.maxExposureChangePerWindow;
  if (cap === 0n || rl.rateLimitWindowSeconds === 0n) return;

  const expired = state.timestamp - limits.windowStart >= rl.rateLimitWindowSeconds;
  const attempted = expired ? delta : limits.windowExposureChange + delta;

  if (attempted > cap) fail({ code: "RateLimitExceeded", marketId, attempted, cap });
}
