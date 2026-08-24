/**
 * Parses a JSON intent list for the CLI.
 *
 * Tier 4 replaces this with a `Strategy` producing intents in process. Until then the intent
 * source is a file an operator writes, and it is the only place a human types numbers that
 * become a transaction, so it is validated harder than anything else here.
 *
 * Amounts are decimal STRINGS, never JSON numbers. `leverage` is 1e18-scaled and
 * `ownAmount` is in the asset's own units; both exceed what a double holds exactly, and the
 * failure from losing precision is silent.
 */

import { FULL_CLOSE, type Id } from "@morphoagg/core";
import type { Intent } from "@morphoagg/planner";
import { readFileSync } from "node:fs";
import { z } from "zod";

const marketId = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, "marketId must be a 0x-prefixed 32-byte hex string")
  .transform((s) => s as Id);

const uint = z
  .string()
  .regex(/^\d+$/, "must be a non-negative decimal string")
  .transform((s) => BigInt(s));

/** WAD-scaled and at least 1x. Below 1e18 the contract reverts `LeverageBelowOneX`. */
const leverage = uint.refine((v) => v >= 10n ** 18n, "leverage must be at least 1e18 (1x)");

const intentSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("increase"), marketId, ownAmount: uint, leverage }),
  z.object({ kind: z.literal("decreaseByCollateral"), marketId, collateralAmount: uint }),
  z.object({ kind: z.literal("closeFully"), marketId }),
  z.object({ kind: z.literal("deleverageTo"), marketId, targetLeverage: leverage }),
]);

export const intentFileSchema = z.object({
  intents: z.array(intentSchema).max(16),
});

export function parseIntents(json: unknown): Intent[] {
  return intentFileSchema.parse(json).intents;
}

export function loadIntents(path: string): Intent[] {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    throw new Error(`cannot read intents file at ${path}`);
  }
  return parseIntents(JSON.parse(raw));
}

/**
 * What the action's `amount` field will carry, for display only.
 *
 * `closeFully` is worth showing explicitly: it encodes `type(uint256).max`, and seeing that
 * number in a dry-run summary is the difference between recognising a full close and
 * wondering what went wrong.
 */
export function describeIntent(intent: Intent): string {
  switch (intent.kind) {
    case "increase":
      return `increase ${intent.marketId} by ${intent.ownAmount} own at ${formatWad(intent.leverage)}x`;
    case "decreaseByCollateral":
      return `decrease ${intent.marketId} by ${intent.collateralAmount} collateral`;
    case "closeFully":
      return `close ${intent.marketId} fully (amount = ${FULL_CLOSE})`;
    case "deleverageTo":
      return `deleverage ${intent.marketId} to ${formatWad(intent.targetLeverage)}x`;
  }
}

export function formatWad(wad: bigint): string {
  const whole = wad / 10n ** 18n;
  const frac = (wad % 10n ** 18n).toString().padStart(18, "0").slice(0, 4).replace(/0+$/, "");
  return frac.length > 0 ? `${whole}.${frac}` : `${whole}`;
}
