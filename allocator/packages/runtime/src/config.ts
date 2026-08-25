/**
 * Everything the runtime needs to start, and where each piece comes from.
 *
 * The split is deliberate and worth stating once, because it is the main defence against a
 * config file quietly disagreeing with the chain:
 *
 *   - ADDRESSES come from `deployments/<chainid>.json`, which `Deploy.s.sol` writes. Those
 *     cannot be read from anywhere else, so they have to be supplied.
 *   - PARAMETERS (maxLeverage, maxSlippageBps, every RiskLimits threshold, decimals) are read
 *     from the chain on every tick, never from `script/config/<chainid>.json`. That file is
 *     deploy-time input; treating it as runtime truth would let an edited local copy produce
 *     plans the contracts reject, and the failure would surface as an opaque revert.
 *   - POLICY (freshness budgets, our own slippage bound) comes from the environment, because
 *     it is an operator decision with no on-chain counterpart.
 */

import { parseDeployment, type Deployment } from "@morphoagg/core";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";
import { z } from "zod";

/**
 * Canonical across every chain this is likely to run on, since Multicall3 is deployed at the
 * same address through a deterministic deployer. Overridable anyway: a fresh or exotic chain
 * may not have it, and finding that out through a silent empty return would be miserable.
 */
export const DEFAULT_MULTICALL3 = getAddress("0xcA11bde05977b3631167028862bE2a173976CA11");

const address = z
  .string()
  .refine((s) => isAddress(s, { strict: false }), "must be a 0x-prefixed 20-byte address")
  .transform((s) => getAddress(s));

const privateKey = z
  .string()
  .refine((s) => isHex(s) && s.length === 66, "must be a 0x-prefixed 32-byte hex private key")
  .transform((s) => s as Hex);

/** Env vars arrive as strings; nothing here accepts a bare number. */
const positiveInt = z
  .string()
  .regex(/^\d+$/, "must be a non-negative integer")
  .transform((s) => Number(s))
  .pipe(z.number().int().positive());

const bpsString = z
  .string()
  .regex(/^\d+$/, "must be a non-negative integer")
  .transform((s) => BigInt(s))
  .pipe(z.bigint().nonnegative().max(10_000n));

const blockCount = z
  .string()
  .regex(/^\d+$/, "must be a non-negative integer")
  .transform((s) => BigInt(s));

export const envSchema = z.object({
  RPC_URL: z.string().url(),
  CHAIN_ID: positiveInt,

  /**
   * Absent is a supported mode, not an error: every read, plan and simulate path works
   * without a key, and `--dry-run` is the default. Only `submit` demands one, and it says so
   * by name at the point it needs it rather than refusing to boot.
   */
  ALLOCATOR_PRIVATE_KEY: privateKey.optional(),

  DEPLOYMENTS_DIR: z.string().optional(),
  /**
   * Mirrors `DEPLOYMENT_LABEL` in script/Config.sol. An anvil fork of Arbitrum still reports
   * chainid 42161, so a local run writes `42161.local.json` rather than overwriting the real
   * record. The runtime has to be able to point at the same labelled file or it would read
   * production addresses while talking to a fork.
   */
  DEPLOYMENT_LABEL: z.string().optional(),

  MULTICALL3_ADDRESS: address.optional(),

  /**
   * Per-request RPC timeout.
   *
   * The default is generous because simulating a bundle is not a normal `eth_call`: it runs a
   * full DEX route, and against a forked node every untouched storage slot is a fresh upstream
   * fetch. viem's 10s default times out on exactly the call that matters most.
   */
  RPC_TIMEOUT_MS: positiveInt.optional(),

  /**
   * How stale a plan may be at submission, in WALL-CLOCK SECONDS.
   *
   * Seconds rather than blocks because what age costs is a price move, and price moves in
   * seconds. A block-denominated budget silently means something different on every chain:
   * the same "30" is 7.5 seconds on Arbitrum and 6 minutes on Ethereum.
   *
   * What actually binds is the oracle floor, and it binds at EXECUTION, not at plan time. The
   * engine recomputes `oracleExpectedOut` from the live price and takes `max(submitted,
   * floor)`, so a plan is stale exactly when the price has moved far enough that the route can
   * no longer clear the floor the contract will compute. On this market the floor allows 50
   * bps, an honest route uses about 8 of them and price impact at size another 14, leaving
   * roughly 28 bps of room for an adverse move. 45 seconds is comfortably inside that while
   * leaving room for the quote, encode and simulate round trips, which run 1 to 3 seconds.
   */
  MAX_PLAN_AGE_SECONDS: positiveInt.optional(),

  /**
   * Backstop, in blocks, against a node reporting a timestamp that is wrong or frozen.
   *
   * Not the binding gate. Set it loose enough that it never fires ahead of the seconds budget
   * on a healthy chain.
   */
  MAX_PLAN_AGE_BLOCKS: blockCount.optional(),

  /**
   * Which block the pre-submit simulation runs against. `pending` by default, and that is the
   * right production answer: pending is the state the transaction will execute against if it
   * lands in the next block, so simulating at `latest` re-opens by exactly one block the gap
   * the simulation exists to close.
   *
   * `latest` exists for FORK work only, and for one specific reason worth writing down because
   * it costs an hour to rediscover. On a long-lived anvil fork, `latest` stays frozen near the
   * forked block's timestamp while `pending` is stamped with wall-clock time, so the two drift
   * apart by however long the fork has been up. Live DEX routes stop executing once that gap
   * grows: measured here, a route that simulates fine at `latest` fails as `SwapCallFailed()`
   * at `pending` with only 75 seconds of drift. Nothing is wrong with the batch; the fork's
   * clock has simply left the state its pools are frozen in.
   */
  SIMULATE_BLOCK_TAG: z.enum(["pending", "latest"]).optional(),

  /** Our own bound on top of the oracle floor the contract enforces. See `encode`. */
  QUOTE_SLIPPAGE_BPS: bpsString.optional(),
  ACCRUAL_BUFFER_BPS: bpsString.optional(),

  VELORA_BASE_URL: z.string().url().optional(),
  VELORA_PARTNER: z.string().min(1).optional(),
  VELORA_SLIPPAGE_BPS: positiveInt.optional(),
});

export type Env = z.infer<typeof envSchema>;

/**
 * One budget, not one per drift class, and that is a correction to an earlier version of this
 * file worth writing down so it is not reintroduced.
 *
 * The original split gave `drifts` a single block on the reasoning that a deleverage's swap
 * amount derives from debt that grows every block. The reasoning was right and the magnitude
 * was wrong by about seven orders of magnitude. Measured on the wstETH/USDC market at its real
 * 4.14% borrow APR, a 100k position accrues 0.000033 USDC per Arbitrum block, while the 25 bps
 * `accrualBufferBps` that `encode` already adds is 250 USDC, or twenty-two days of it. The gate
 * was refusing at a quarter of a second to protect a buffer good for three weeks, which in
 * practice meant every deleverage was rejected before it ever reached simulation: a Velora
 * round trip alone is several hundred milliseconds.
 *
 * Accrual is not what age costs. Price movement against the live oracle floor is, and that
 * applies identically to both classes. `driftClass` still says something true about whether the
 * encoded swap amount will match the one the contract computes; it is simply not a reason to
 * hold one plan to a tighter clock than another.
 */
const POLICY_DEFAULTS = {
  maxPlanAgeSeconds: 45,
  maxPlanAgeBlocks: 600n,
  quoteSlippageBps: 50n,
  accrualBufferBps: 25n,
} as const;

export interface Policy {
  simulateBlockTag: "pending" | "latest";
  maxPlanAgeSeconds: number;
  maxPlanAgeBlocks: bigint;
  quoteSlippageBps: bigint;
  accrualBufferBps: bigint;
}

export interface RuntimeConfig {
  rpcUrl: string;
  rpcTimeoutMs: number;
  chainId: number;
  allocatorKey: Hex | undefined;
  multicall3: Address;
  deployment: Deployment;
  policy: Policy;
  velora: {
    baseUrl: string | undefined;
    partner: string | undefined;
    slippageBps: number | undefined;
  };
}

/** Resolves `deployments/<chainid>[.<label>].json`, matching what Deploy.s.sol writes. */
export function deploymentPath(dir: string, chainId: number, label?: string | undefined): string {
  const suffix = label && label.length > 0 ? `.${label}` : "";
  return join(dir, `${chainId}${suffix}.json`);
}

export function loadDeployment(path: string): Deployment {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    throw new Error(
      `no deployment record at ${path}\n` +
        `Run script/Deploy.s.sol for this chain, or set DEPLOYMENTS_DIR / DEPLOYMENT_LABEL to point at the right file.`,
    );
  }
  return parseDeployment(JSON.parse(raw));
}

/**
 * Reads and validates the environment, then loads the deployment it names.
 *
 * The chain id is checked against the deployment file here and against the live RPC in
 * `clients.ts`. Both checks are cheap, and the failure they prevent is submitting a
 * transaction built from one chain's addresses to another chain.
 */
export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
  defaultDeploymentsDir = defaultDeploymentsDirectory(),
): RuntimeConfig {
  const parsed = envSchema.parse(env);

  const dir = parsed.DEPLOYMENTS_DIR ?? defaultDeploymentsDir;
  const path = deploymentPath(dir, parsed.CHAIN_ID, parsed.DEPLOYMENT_LABEL);
  const deployment = loadDeployment(path);

  if (deployment.chainId !== parsed.CHAIN_ID) {
    throw new Error(
      `${path} records chainId ${deployment.chainId} but CHAIN_ID is ${parsed.CHAIN_ID}`,
    );
  }

  return {
    rpcUrl: parsed.RPC_URL,
    rpcTimeoutMs: parsed.RPC_TIMEOUT_MS ?? 60_000,
    chainId: parsed.CHAIN_ID,
    allocatorKey: parsed.ALLOCATOR_PRIVATE_KEY,
    multicall3: parsed.MULTICALL3_ADDRESS ?? DEFAULT_MULTICALL3,
    deployment,
    policy: {
      simulateBlockTag: parsed.SIMULATE_BLOCK_TAG ?? "pending",
      maxPlanAgeSeconds: parsed.MAX_PLAN_AGE_SECONDS ?? POLICY_DEFAULTS.maxPlanAgeSeconds,
      maxPlanAgeBlocks: parsed.MAX_PLAN_AGE_BLOCKS ?? POLICY_DEFAULTS.maxPlanAgeBlocks,
      quoteSlippageBps: parsed.QUOTE_SLIPPAGE_BPS ?? POLICY_DEFAULTS.quoteSlippageBps,
      accrualBufferBps: parsed.ACCRUAL_BUFFER_BPS ?? POLICY_DEFAULTS.accrualBufferBps,
    },
    velora: {
      baseUrl: parsed.VELORA_BASE_URL,
      partner: parsed.VELORA_PARTNER,
      slippageBps: parsed.VELORA_SLIPPAGE_BPS,
    },
  };
}

/** `<repo>/deployments`, four levels up from `packages/runtime/src`. */
function defaultDeploymentsDirectory(): string {
  return new URL("../../../../deployments", import.meta.url).pathname;
}


