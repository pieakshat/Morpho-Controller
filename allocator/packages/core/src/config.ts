/**
 * Zod schemas for the two JSON files this repo's Solidity already reads and writes:
 * `script/config/<chainid>.json` (input) and `deployments/<chainid>.json` (output).
 *
 * These are the contract between the Solidity and the TypeScript. Foundry's `vm.parseJsonUint`
 * fails at the point of use with no context about which key was wrong; validating here fails
 * once, up front, naming the field.
 *
 * Every on-chain integer is a decimal string in JSON, never a JS number. USDC amounts already
 * exceed nothing dangerous, but leverage and price values are 1e18 and 1e36 scaled and would
 * silently lose precision as doubles.
 */

import { getAddress, isAddress, type Hex } from "viem";
import { z } from "zod";

/**
 * Validated with viem's own `isAddress` rather than a local regex, and typed as viem's
 * `Address` rather than a raw `0x${string}`. Both matter: abitype defines
 * `Address = ResolvedRegister['addressType']`, so the raw literal silently diverges from
 * `Address` if the register is ever configured, and a hand-rolled regex is a weaker
 * duplicate of a check viem already maintains.
 *
 * Non-strict, so an all-lowercase or all-uppercase address is accepted; `getAddress` then
 * normalises everything to checksummed form. That normalisation is what lets the refinements
 * below compare addresses with `===` instead of case-folding at every comparison site.
 */
const address = z
  .string()
  .refine((s) => isAddress(s, { strict: false }), "must be a 0x-prefixed 20-byte address")
  .transform((s) => getAddress(s));

/**
 * Morpho market ids. viem's `isHex` does not check length, and a wrong-length id would
 * otherwise sail through and only fail as an unregistered market on-chain.
 */
const hex32 = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, "must be a 0x-prefixed 32-byte hex string")
  .transform((s) => s as Hex);

/** Decimal string -> bigint. Rejects JS numbers outright rather than coercing them. */
const uint = z
  .string()
  .regex(/^\d+$/, "must be a non-negative decimal string")
  .transform((s) => BigInt(s));

/** For values small enough that a JSON number is unambiguous, e.g. basis points. */
const smallUint = z.number().int().nonnegative();

const marketEntry = z.object({
  name: z.string().min(1),
  loanToken: address,
  collateralToken: address,
  oracle: address,
  irm: address,
  lltv: uint,
  maxLeverage: uint,
  /** Registry hard-caps this at 1000. */
  maxSlippageBps: smallUint.max(1_000),
  minHealthFactor: uint,
  maxPriceDeviationBps: smallUint.max(10_000),
  maxExposureChangePerWindow: uint,
  assetExposureCap: uint,
});

const globalRiskLimits = z.object({
  paused: z.boolean(),
  priceObservationMaxAge: smallUint,
  rateLimitWindowSeconds: smallUint,
  maxAggregateDebt: uint,
  /** Mirrors MAX_SLIPPAGE_BPS_CEILING_LIMIT. */
  maxSlippageBpsCeiling: smallUint.max(1_000),
});

export const chainConfigSchema = z
  .object({
    chainName: z.string().min(1),
    core: z.object({
      morpho: address,
      bundler3: address,
      generalAdapter1: address,
    }),
    asset: address,
    assetDecimals: smallUint,
    marketCount: smallUint,
    markets: z.array(marketEntry).min(1),
    seed: z.object({
      amount: uint,
      burnAddress: address,
    }),
    vault: z.object({
      /** Vault hard-caps this at 1000. */
      actionDropToleranceBps: smallUint.max(1_000),
    }),
    riskLimits: globalRiskLimits,
  })
  // Foundry cannot read an array's length from JSON, so marketCount is what the deploy
  // script actually loops over. If it disagrees with the array, the script silently skips
  // markets or reverts reading past the end. Catch it here instead.
  .refine((c) => c.marketCount === c.markets.length, {
    message: "marketCount must equal markets.length",
    path: ["marketCount"],
  })
  // registerMarket reverts LoanTokenMismatch, but only once a transaction is already in
  // flight; this is the same rule checked before anything is broadcast. Plain `===` is safe
  // because `address` above has already normalised both sides to checksummed form.
  .refine((c) => c.markets.every((m) => m.loanToken === c.asset), {
    message: "every market's loanToken must equal the vault asset",
    path: ["markets"],
  })
  // A live cap with a zero window is the footgun RiskLimits.setMaxExposureChangePerWindow
  // rejects on-chain: a zero window makes every call look like a fresh period, turning a
  // per-window budget into a per-action one.
  .refine(
    (c) =>
      c.riskLimits.rateLimitWindowSeconds > 0 ||
      c.markets.every((m) => m.maxExposureChangePerWindow === 0n),
    {
      message: "rateLimitWindowSeconds must be set before any market sets maxExposureChangePerWindow",
      path: ["riskLimits", "rateLimitWindowSeconds"],
    },
  );

export type ChainConfig = z.infer<typeof chainConfigSchema>;

export const deploymentSchema = z.object({
  chainId: z.number().int().positive(),
  vault: address,
  swapExecutor: address,
  riskLimits: address,
  asset: address,
  morpho: address,
  bundler3: address,
  generalAdapter1: address,
  allocator: address,
  owner: address,
  markets: z.record(z.string(), hex32),
});

export type Deployment = z.infer<typeof deploymentSchema>;

export function parseChainConfig(json: unknown): ChainConfig {
  return chainConfigSchema.parse(json);
}

export function parseDeployment(json: unknown): Deployment {
  return deploymentSchema.parse(json);
}
