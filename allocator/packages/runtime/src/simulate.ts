/**
 * The last check before a key signs anything.
 *
 * `planBatch` already refuses everything it can predict from the snapshot, and it does so in
 * a millisecond without touching the network. This is the other half: the failures the
 * planner structurally cannot see, because they depend on what the swap venue actually does.
 *
 * Concretely, the planner cannot know:
 *   - whether the route still fills. It priced at quote time; pools have moved since.
 *   - whether `SlippageExceeded` trips. That compares the collateral actually received
 *     against the floor, and "actually received" only exists after the swap runs.
 *   - whether `RiskLimits.checkAfterIncrease` passes. Health factor, aggregate debt and
 *     realized slippage are all post-trade quantities.
 *   - whether the router reverts for its own reasons, which arrives as a bare
 *     `SwapCallFailed` with the venue's message discarded.
 *
 * None of that is a reason to skip planning. It is the reason simulation is mandatory rather
 * than advisory.
 */

import { decodeVaultError, describeRevert, type DecodedRevert, type Plan } from "@morphoagg/planner";
import {
  BaseError,
  HttpRequestError,
  RawContractError,
  RpcRequestError,
  TimeoutError,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";

import type { Policy } from "./config.js";

export type SimulationResult =
  | { ok: true }
  | { ok: false; revert: DecodedRevert; description: string };

/** A block and its timestamp. Both the snapshot and the head are described this way. */
export interface BlockStamp {
  blockNumber: bigint;
  timestamp: bigint;
}

/**
 * Refuses a batch whose plans have aged past their budget.
 *
 * Checked here rather than only inside `encode` because the age that matters is the age at
 * SUBMISSION, and everything between quoting and here takes time: an aggregator round trip is
 * hundreds of milliseconds and the simulation is another.
 *
 * Measured in SECONDS against the snapshot's own timestamp, with blocks only as a backstop.
 * What age costs is a price move, and the oracle floor it has to clear is recomputed from the
 * LIVE price at execution, not the one the plan was built on. A plan is stale exactly when the
 * price has moved far enough that the route can no longer clear the floor the contract will
 * compute for it. Blocks are the wrong unit for that: the same count means seconds on one chain
 * and minutes on another.
 *
 * Note this does NOT vary by drift class. See the reasoning in `config.ts` for why the earlier
 * per-class split was wrong.
 */
export function assertBatchFresh(
  plans: readonly Plan[],
  snapshot: BlockStamp,
  head: BlockStamp,
  policy: Policy,
): void {
  for (const p of plans) {
    // A batch is planned against one snapshot, so a plan carrying a different block did not
    // come from this one and its timestamp is unknown. Refusing beats measuring its age
    // against a clock that does not belong to it.
    if (p.stateBlock !== snapshot.blockNumber) {
      throw new Error(
        `plan for ${p.marketId} was built at block ${p.stateBlock}, but this batch is being ` +
          `checked against a snapshot at ${snapshot.blockNumber}; plans from different ` +
          `snapshots cannot be submitted together`,
      );
    }

    const ageSeconds = head.timestamp - snapshot.timestamp;
    const ageBlocks = head.blockNumber - p.stateBlock;

    if (ageSeconds > BigInt(policy.maxPlanAgeSeconds)) {
      throw new StalePlanError(p, ageSeconds, BigInt(policy.maxPlanAgeSeconds), "seconds", head);
    }
    if (ageBlocks > policy.maxPlanAgeBlocks) {
      throw new StalePlanError(p, ageBlocks, policy.maxPlanAgeBlocks, "blocks", head);
    }
  }
}

export class StalePlanError extends Error {
  constructor(
    readonly plan: Plan,
    readonly age: bigint,
    readonly budget: bigint,
    readonly unit: "seconds" | "blocks",
    readonly head: BlockStamp,
  ) {
    super(
      `plan for ${plan.marketId} (${plan.kind}, driftClass=${plan.driftClass}) was built at block ` +
        `${plan.stateBlock} and is now ${age} ${unit} old at block ${head.blockNumber}, past its ` +
        `budget of ${budget} ${unit}. Re-read state, re-plan and re-quote rather than submitting this.`,
    );
    this.name = "StalePlanError";
  }
}

/**
 * `eth_call` of `executeActions` as the allocator, at the pending block.
 *
 * `from` is the allocator and not some placeholder: `executeActions` is `onlyAllocator`, so
 * simulating from any other address tests the access modifier instead of the batch.
 *
 * Pending rather than latest, because pending is the state the transaction will actually
 * execute against if it lands in the next block. Simulating at latest re-opens, by exactly one
 * block, the gap this call exists to close. `SIMULATE_BLOCK_TAG` overrides it for fork work,
 * where anvil's pending clock drifts away from the state its pools are frozen in; see the note
 * on that setting in `config.ts`.
 */
export async function simulateExecuteActions(
  publicClient: PublicClient,
  args: { vault: Address; allocator: Address; data: Hex; blockTag?: "pending" | "latest" },
): Promise<SimulationResult> {
  try {
    await publicClient.call({
      account: args.allocator,
      to: args.vault,
      data: args.data,
      blockTag: args.blockTag ?? "pending",
    });
    return { ok: true };
  } catch (error) {
    // A transport failure is not a verdict on the batch. Reporting a timed-out RPC as
    // `ok: false` would tell the caller the intents are bad when nothing was ever evaluated,
    // and in a loop that reads as a permanent rejection rather than the transient it is.
    if (isTransportFailure(error)) throw error;

    const revert = decodeVaultError(extractRevertData(error));
    return { ok: false, revert, description: explain(revert, error) };
  }
}

/**
 * True when the call never reached execution, or reached it and we cannot tell.
 *
 * The distinction that matters is "the contract said no" versus "we did not get an answer".
 * Revert data present means the former, unambiguously. Absent it, a transport-class error is
 * the latter and must propagate.
 */
export function isTransportFailure(error: unknown): boolean {
  if (extractRevertData(error) !== undefined) return false;
  if (!(error instanceof BaseError)) return false;

  return (
    error.walk((e) => e instanceof TimeoutError) !== null ||
    error.walk((e) => e instanceof HttpRequestError) !== null ||
    // An `eth_call` that reverts also arrives as an RpcRequestError, so this only counts once
    // the checks above have established there is no revert payload to decode.
    error.walk((e) => e instanceof RpcRequestError && e.code !== 3) !== null
  );
}

/**
 * Digs the raw revert bytes out of whatever viem wrapped them in.
 *
 * viem nests the original error several layers deep and the depth varies by transport and by
 * node implementation, so walking the `cause` chain is more reliable than reaching for a
 * fixed path. Without the raw bytes every custom error degrades to "execution reverted",
 * which throws away the entire named-error catalogue the contracts were written to provide.
 */
export function extractRevertData(error: unknown): Hex | undefined {
  if (error instanceof BaseError) {
    const raw = error.walk((e) => e instanceof RawContractError);
    if (raw instanceof RawContractError) {
      const data = raw.data;
      if (typeof data === "string") return data as Hex;
      if (data && typeof data === "object" && "data" in data && typeof data.data === "string") {
        return data.data as Hex;
      }
    }
  }

  // Some transports surface `{ data: "0x..." }` without going through RawContractError.
  let cursor: unknown = error;
  for (let depth = 0; cursor && depth < 10; depth++) {
    if (typeof cursor === "object" && "data" in cursor) {
      const d = (cursor as { data?: unknown }).data;
      if (typeof d === "string" && d.startsWith("0x")) return d as Hex;
    }
    cursor = typeof cursor === "object" && "cause" in cursor ? (cursor as { cause?: unknown }).cause : undefined;
  }

  return undefined;
}

function explain(revert: DecodedRevert, error: unknown): string {
  const decoded = describeRevert(revert);

  // A revert nobody could decode is the one case where viem's own message is worth keeping:
  // it usually carries the node's reason string, and an undecodable payload is most often a
  // swap venue's error that `MorphoSwapExecutor` discarded on the way out.
  if (revert.kind === "unknown" || revert.kind === "empty") {
    const message = error instanceof BaseError ? error.shortMessage : String(error);
    return `${decoded} (${message})`;
  }

  return decoded;
}
