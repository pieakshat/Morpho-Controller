#!/usr/bin/env node
/**
 * The allocator CLI.
 *
 * Three commands, and the important thing about them is what is NOT the default: nothing
 * signs unless `--submit` is passed. `state` and `run` are both read-only, so the normal way
 * to use this is to look at the snapshot, dry-run the intents, read the projection, and only
 * then submit.
 *
 *   allocator state
 *   allocator run    --intents intents.json [--submit]
 *   allocator loop   --intents intents.json --interval 60 [--submit]
 *
 * Configuration comes from the environment; see `src/config.ts` for the schema and for why
 * addresses come from the deployment record while every parameter is read from the chain.
 */

import { createVeloraQuoteProvider, type Intent } from "@morphoagg/planner";
import { formatUnits } from "viem";

import { assertChainMatches, createClients } from "../src/clients.js";
import { loadConfig, type RuntimeConfig } from "../src/config.js";
import { describeIntent, formatWad, loadIntents } from "../src/intentFile.js";
import { startLoop, stopOnSignals } from "../src/loop.js";
import { runOnce, type PipelineDeps, type RunResult } from "../src/pipeline.js";
import { discoverTopology } from "../src/read/topology.js";
import { readVaultState } from "../src/read/state.js";
import { healthFactor } from "@morphoagg/core";

interface Args {
  command: string;
  intents: string | undefined;
  intervalSeconds: number;
  submit: boolean;
}

function parseArgs(argv: readonly string[]): Args {
  const [command = "help", ...rest] = argv;
  let intents: string | undefined;
  let intervalSeconds = 60;
  let submit = false;

  for (let i = 0; i < rest.length; i++) {
    const flag = rest[i];
    if (flag === "--submit") submit = true;
    else if (flag === "--intents") intents = rest[++i];
    else if (flag === "--interval") intervalSeconds = Number(rest[++i]);
    else throw new Error(`unrecognised argument: ${flag}`);
  }

  if (!Number.isFinite(intervalSeconds) || intervalSeconds <= 0) {
    throw new Error("--interval must be a positive number of seconds");
  }
  return { command, intents, intervalSeconds, submit };
}

async function buildDeps(config: RuntimeConfig): Promise<PipelineDeps> {
  const clients = createClients(config);
  await assertChainMatches(clients, config);
  const topology = await discoverTopology(clients.publicClient, config);

  const quotes = createVeloraQuoteProvider({
    ...(config.velora.baseUrl === undefined ? {} : { baseUrl: config.velora.baseUrl }),
    ...(config.velora.partner === undefined ? {} : { partner: config.velora.partner }),
    ...(config.velora.slippageBps === undefined ? {} : { slippageBps: config.velora.slippageBps }),
  });

  return { clients, config, topology, quotes };
}

async function commandState(config: RuntimeConfig): Promise<void> {
  const deps = await buildDeps(config);
  const state = await readVaultState(deps.clients.publicClient, deps.topology, config.multicall3);
  const d = deps.topology.assetDecimals;

  console.log(`vault      ${state.vault}`);
  console.log(`block      ${state.blockNumber}  (t=${state.timestamp})`);
  console.log(`totalAssets ${formatUnits(state.totalAssets, d)}`);
  console.log(`idle        ${formatUnits(state.idle, d)}  (${percentOf(state.idle, state.totalAssets)} of total)`);
  console.log(`dropTolerance ${state.actionDropToleranceBps} bps`);
  console.log(`riskLimits  ${state.riskLimits.address}  paused=${state.riskLimits.paused}`);
  console.log("");

  for (const m of state.markets.values()) {
    const hf =
      m.price === null ? null : healthFactor(m.position, m.market, m.price, m.params.lltv);
    console.log(`market ${m.id}`);
    console.log(`  enabled=${m.enabled}  maxLeverage=${formatWad(m.maxLeverage)}x  maxSlippage=${m.maxSlippageBps}bps`);
    console.log(`  collateral ${m.position.collateral}  borrowShares ${m.position.borrowShares}`);
    console.log(`  price      ${m.price === null ? "UNAVAILABLE (oracle reverted)" : m.price}`);
    // No debt means no liquidation risk, which the contract represents as uint256 max. The
    // dash is that, not a missing read.
    console.log(`  healthFactor ${hf === null ? "-" : formatWad(hf)}`);
  }
}

async function commandRun(config: RuntimeConfig, args: Args): Promise<void> {
  const intents = requireIntents(args);
  const deps = await buildDeps(config);

  console.log(`${intents.length} intent(s):`);
  for (const i of intents) console.log(`  ${describeIntent(i)}`);
  console.log("");

  const result = await runOnce(deps, intents, { dryRun: !args.submit });
  report(result, deps.topology.assetDecimals);
  if (result.outcome === "rejected") process.exitCode = 1;
}

async function commandLoop(config: RuntimeConfig, args: Args): Promise<void> {
  const intents = requireIntents(args);
  const deps = await buildDeps(config);

  console.log(
    `looping every ${args.intervalSeconds}s over ${intents.length} intent(s), ` +
      `${args.submit ? "SUBMITTING" : "dry-run only"}. Ctrl-C to stop.`,
  );

  const handle = startLoop(deps, () => intents, {
    intervalMs: args.intervalSeconds * 1000,
    dryRun: !args.submit,
    onTick: (result, tick) => {
      console.log(`\n--- tick ${tick} ---`);
      report(result, deps.topology.assetDecimals);
    },
    onError: (error, tick) => {
      // Logged and swallowed. A tick that throws must not end the process: the moment the RPC
      // is flaky is the moment positions most need watching.
      console.error(`\n--- tick ${tick} FAILED ---`);
      console.error(error instanceof Error ? error.message : String(error));
    },
  });

  stopOnSignals(handle);
  await handle.done;
  console.log("\nstopped");
}

function requireIntents(args: Args): Intent[] {
  if (!args.intents) throw new Error("--intents <file.json> is required for this command");
  return loadIntents(args.intents);
}

function report(result: RunResult, decimals: number): void {
  switch (result.outcome) {
    case "nothing-to-do":
      console.log("no intents; nothing to do");
      return;

    case "rejected":
      console.log(`REJECTED at ${result.stage}: ${result.reason}`);
      return;

    case "simulated":
    case "submitted": {
      const p = result.batch.projection;
      console.log(`${result.batch.actions.length} action(s) encoded, ${result.batch.calldata.length / 2 - 1} bytes`);
      for (let i = 0; i < result.batch.actions.length; i++) {
        const a = result.batch.actions[i]!;
        const q = result.batch.quotes[i]!;
        console.log(`  ${a.marketId} ${a.isIncrease ? "increase" : "decrease"}`);
        console.log(`    amountIn ${result.batch.plans[i]!.swap.amountIn}  expectedOut ${q.expectedOut}  minOut ${a.minOut}`);
        console.log(`    via ${q.source ?? "?"} at ${a.swapTarget}`);
      }
      console.log(
        `  worst case: ${formatUnits(p.worstCaseAssetsAfter, decimals)} against a floor of ` +
          `${formatUnits(p.floor, decimals)} (loss ${formatUnits(p.worstCaseLoss, decimals)})`,
      );

      if (result.outcome === "simulated") {
        console.log("SIMULATED OK (dry run; pass --submit to send)");
      } else {
        console.log(`SUBMITTED ${result.transaction.hash} in block ${result.transaction.receipt.blockNumber}`);
        console.log(`  gas used ${result.transaction.receipt.gasUsed} of ${result.transaction.gasLimit}`);
      }
      return;
    }
  }
}

function percentOf(part: bigint, whole: bigint): string {
  if (whole === 0n) return "n/a";
  return `${Number((part * 10_000n) / whole) / 100}%`;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  if (args.command === "help" || args.command === "--help" || args.command === "-h") {
    console.log(
      [
        "allocator state                                       read and print the vault snapshot",
        "allocator run   --intents f.json [--submit]           plan, quote, simulate, optionally send",
        "allocator loop  --intents f.json --interval 60 [--submit]",
        "",
        "Required env: RPC_URL, CHAIN_ID. ALLOCATOR_PRIVATE_KEY only for --submit.",
      ].join("\n"),
    );
    return;
  }

  const config = loadConfig();

  switch (args.command) {
    case "state":
      return commandState(config);
    case "run":
      return commandRun(config, args);
    case "loop":
      return commandLoop(config, args);
    default:
      throw new Error(`unknown command "${args.command}"; try: state, run, loop`);
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
