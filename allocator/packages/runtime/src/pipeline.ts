/**
 * intents -> read -> plan -> quote -> encode -> project -> simulate -> submit.
 *
 * Every stage can stop the batch, and each one is cheaper than the stage after it. That
 * ordering is the whole design: planning costs a millisecond and rejects most bad intents,
 * quoting costs an aggregator round trip, simulating costs an RPC call, and only submission
 * costs gas. Nothing here reorders that.
 *
 * The one ordering constraint that is not about cost: quoting MUST come after planning.
 * `MorphoSwapExecutor` swaps its entire balance while the calldata hardcodes an amount, so the
 * exact `amountIn` has to be known before an aggregator is asked for a route. A route built
 * for any other figure is wrong in one of two ways, and `encode` refuses both.
 */

import type { MarketAction } from "@morphoagg/core";
import {
  encode,
  encodeExecuteActions,
  planBatch,
  projectEncodedBatch,
  type BatchProjection,
  type Intent,
  type Plan,
  type Quote,
  type QuoteProvider,
  type VaultState,
} from "@morphoagg/planner";
import type { Hex } from "viem";

import type { RuntimeConfig } from "./config.js";
import type { Clients } from "./clients.js";
import { requireAllocator } from "./clients.js";
import type { Topology } from "./read/calls.js";
import { readVaultState } from "./read/state.js";
import { assertBatchFresh, simulateExecuteActions, type SimulationResult } from "./simulate.js";
import { submitExecuteActions, type SubmitOptions, type SubmittedTransaction } from "./submit.js";

export interface PipelineDeps {
  clients: Clients;
  config: RuntimeConfig;
  topology: Topology;
  quotes: QuoteProvider;
}

export interface RunOptions {
  /** Stop after simulation. The default, so nothing signs unless it is asked to. */
  dryRun?: boolean;
  submit?: SubmitOptions;
}

export type RunResult =
  | { outcome: "nothing-to-do"; state: VaultState }
  | { outcome: "rejected"; state: VaultState; stage: PipelineStage; reason: string }
  | { outcome: "simulated"; state: VaultState; batch: PreparedBatch; simulation: SimulationResult }
  | { outcome: "submitted"; state: VaultState; batch: PreparedBatch; transaction: SubmittedTransaction };

export type PipelineStage = "plan" | "quote" | "encode" | "project" | "freshness" | "simulate";

export interface PreparedBatch {
  plans: readonly Plan[];
  quotes: readonly Quote[];
  actions: readonly MarketAction[];
  projection: BatchProjection;
  calldata: Hex;
}

export async function runOnce(
  deps: PipelineDeps,
  intents: readonly Intent[],
  options: RunOptions = {},
): Promise<RunResult> {
  const { clients, config, topology } = deps;
  const dryRun = options.dryRun ?? true;

  const state = await readVaultState(clients.publicClient, topology, config.multicall3);
  if (intents.length === 0) return { outcome: "nothing-to-do", state };

  let prepared: PreparedBatch;
  try {
    prepared = await prepareBatch(deps, state, intents);
  } catch (error) {
    return { outcome: "rejected", state, stage: stageOf(error), reason: messageOf(error) };
  }

  // Freshness is measured against the CURRENT head, not the block the state was read at.
  // Quoting sat between the two, and on a chain with sub-second blocks an aggregator round
  // trip is already several blocks of accrual.
  const head = await clients.publicClient.getBlockNumber();
  try {
    assertBatchFresh(prepared.plans, head, config.policy);
  } catch (error) {
    return { outcome: "rejected", state, stage: "freshness", reason: messageOf(error) };
  }

  const allocator = clients.account?.address ?? config.deployment.allocator;
  const simulation = await simulateExecuteActions(clients.publicClient, {
    vault: topology.vault,
    allocator,
    data: prepared.calldata,
    blockTag: config.policy.simulateBlockTag,
  });

  if (!simulation.ok) {
    return { outcome: "rejected", state, stage: "simulate", reason: simulation.description };
  }

  if (dryRun) return { outcome: "simulated", state, batch: prepared, simulation };

  const account = requireAllocator(clients);
  if (!clients.walletClient) throw new Error("wallet client missing despite an allocator account being present");

  const transaction = await submitExecuteActions(
    clients.publicClient,
    clients.walletClient,
    account,
    { vault: topology.vault, data: prepared.calldata },
    options.submit ?? {},
  );

  return { outcome: "submitted", state, batch: prepared, transaction };
}

/**
 * Everything between a snapshot and signable calldata. Separated out because it performs no
 * writes and no simulation, so a caller that only wants to see what would be built can call
 * it directly.
 */
export async function prepareBatch(
  deps: PipelineDeps,
  state: VaultState,
  intents: readonly Intent[],
): Promise<PreparedBatch> {
  const { config, topology } = deps;

  const { plans } = stage("plan", () => planBatch(state, intents, topology.generalAdapter1));

  // Quotes are fetched together rather than in sequence. They are independent requests and
  // the batch is only as fresh as its slowest one, so serialising them would age every plan
  // by the sum of the round trips instead of the maximum.
  const fetched = await stageAsync("quote", () =>
    Promise.all(plans.map((p) => quoteFor(deps, p))),
  );

  const actions = stage("encode", () =>
    plans.map((p, i) =>
      encode(p, fetched[i]!, {
        quoteSlippageBps: config.policy.quoteSlippageBps,
        accrualBufferBps: config.policy.accrualBufferBps,
      }),
    ),
  );

  // The guard the transaction is actually judged against, now that real minOuts exist.
  // `planBatch`'s own projection assumes every leg fills at its oracle floor, which is a lower
  // bound on quality rather than a prediction.
  const projection = stage("project", () => projectEncodedBatch(state, plans, actions));

  // Inside the stage wrapper too: viem validates every address as it encodes, so a malformed
  // `swapTarget` from an aggregator surfaces here rather than at the plan stage.
  const calldata = stage("encode", () => encodeExecuteActions(actions));

  return { plans, quotes: fetched, actions, projection, calldata };
}

async function quoteFor(deps: PipelineDeps, p: Plan): Promise<Quote> {
  const { config, topology, quotes } = deps;
  const collateral = topology.markets.find((m) => m.id === p.marketId);
  if (!collateral) throw new Error(`market ${p.marketId} is not in the discovered topology`);

  // An increase swaps loan -> collateral and a decrease goes the other way, so which decimals
  // belong to which side flips with the direction.
  const [srcDecimals, destDecimals] = p.isIncrease
    ? [topology.assetDecimals, collateral.collateralDecimals]
    : [collateral.collateralDecimals, topology.assetDecimals];

  return quotes.quote({
    chainId: config.chainId,
    tokenIn: p.swap.tokenIn,
    tokenOut: p.swap.tokenOut,
    amountIn: p.swap.amountIn,
    // The SWAP EXECUTOR, not `plan.swap.recipient`, and the distinction is load-bearing.
    // `executeSwap` measures its own balance delta to enforce minOut and only then forwards
    // to the recipient the engine hardcodes. A route that pays GeneralAdapter1 directly leaves
    // the executor's delta at zero, and the bundle dies on `SlippageExceeded(0, minOut)` with
    // the tokens already gone somewhere the check cannot see them.
    recipient: topology.swapExecutor,
    // The swap executor is `msg.sender` at the router, four hops below the allocator, and
    // aggregators encode against it. Passing the vault or the allocator here produces calldata
    // that prices correctly and reverts at execution.
    caller: topology.swapExecutor,
    txOrigin: deps.clients.account?.address ?? config.deployment.allocator,
    srcDecimals,
    destDecimals,
  });
}

/** Tags a thrown error with the stage it came from, so `rejected` can name it. */
class StageError extends Error {
  constructor(
    readonly stage: PipelineStage,
    readonly origin: unknown,
  ) {
    super(messageOf(origin));
    this.name = "StageError";
  }
}

function stage<T>(name: PipelineStage, fn: () => T): T {
  try {
    return fn();
  } catch (error) {
    throw new StageError(name, error);
  }
}

async function stageAsync<T>(name: PipelineStage, fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    throw new StageError(name, error);
  }
}

function stageOf(error: unknown): PipelineStage {
  return error instanceof StageError ? error.stage : "plan";
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
