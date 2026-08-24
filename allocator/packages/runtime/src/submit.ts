/**
 * Estimate, send, wait. Nothing clever, on purpose.
 *
 * The decision worth recording: a transaction that does not confirm is SURFACED, never
 * automatically replaced. Auto-bumping the fee is the obvious feature and the wrong default
 * here. The allocator's transactions are not idempotent, so the failure mode of a replacement
 * race is not a wasted fee, it is two batches landing: the original confirming from the
 * mempool while the replacement is also in flight, and the vault taking the same leverage
 * increase twice. Better to stop, name the stuck hash and nonce, and let an operator decide.
 */

import { type Account, type Address, type Hex, type PublicClient, type TransactionReceipt, type WalletClient } from "viem";

import { extractRevertData } from "./simulate.js";
import { decodeVaultError, describeRevert } from "@morphoagg/planner";

export interface SubmitOptions {
  /**
   * Multiplier applied to the estimate, in bps of 10_000.
   *
   * Not paranoia padding. The estimate runs against pending state and the transaction executes
   * against the next block's, so a swap that touches one more pool tick, or a Morpho storage
   * slot that goes from zero to non-zero in between, costs real extra gas. 15% is enough for
   * both and cheap when unused, since unused gas is refunded.
   */
  gasBufferBps?: bigint;
  /** How long to wait for inclusion before declaring the transaction stuck. */
  confirmTimeoutMs?: number;
  confirmations?: number;
}

const DEFAULTS = {
  gasBufferBps: 1_500n,
  confirmTimeoutMs: 120_000,
  confirmations: 1,
} as const;

export interface SubmittedTransaction {
  hash: Hex;
  nonce: number;
  gasLimit: bigint;
  receipt: TransactionReceipt;
}

export class StuckTransactionError extends Error {
  constructor(
    readonly hash: Hex,
    readonly nonce: number,
    readonly waitedMs: number,
  ) {
    super(
      `transaction ${hash} (nonce ${nonce}) did not confirm within ${waitedMs}ms.\n` +
        `It is NOT being replaced automatically: a replacement racing the original risks both ` +
        `landing, and these batches are not idempotent. Check the mempool, then either wait or ` +
        `send a deliberate replacement at nonce ${nonce} yourself.`,
    );
    this.name = "StuckTransactionError";
  }
}

export class ExecutionRevertedError extends Error {
  constructor(
    readonly hash: Hex,
    readonly reason: string,
  ) {
    super(
      `transaction ${hash} was mined but reverted: ${reason}.\n` +
        `Simulation passed beforehand, so state moved between the two. Re-read, re-plan and re-quote.`,
    );
    this.name = "ExecutionRevertedError";
  }
}

export async function submitExecuteActions(
  publicClient: PublicClient,
  walletClient: WalletClient,
  account: Account,
  args: { vault: Address; data: Hex },
  options: SubmitOptions = {},
): Promise<SubmittedTransaction> {
  const gasBufferBps = options.gasBufferBps ?? DEFAULTS.gasBufferBps;
  const confirmTimeoutMs = options.confirmTimeoutMs ?? DEFAULTS.confirmTimeoutMs;
  const confirmations = options.confirmations ?? DEFAULTS.confirmations;

  const estimate = await publicClient.estimateGas({
    account,
    to: args.vault,
    data: args.data,
  });
  const gas = (estimate * (10_000n + gasBufferBps)) / 10_000n;

  // Read the nonce explicitly rather than letting viem fill it. It has to appear in the stuck
  // message, and the whole point of that message is that an operator can act on it.
  const nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" });

  const hash = await walletClient.sendTransaction({
    account,
    chain: walletClient.chain ?? null,
    to: args.vault,
    data: args.data,
    gas,
    nonce,
  });

  let receipt: TransactionReceipt;
  try {
    receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations, timeout: confirmTimeoutMs });
  } catch {
    throw new StuckTransactionError(hash, nonce, confirmTimeoutMs);
  }

  if (receipt.status === "reverted") {
    throw new ExecutionRevertedError(hash, await reasonForMinedRevert(publicClient, receipt, args));
  }

  return { hash, nonce, gasLimit: gas, receipt };
}

/**
 * Replays a mined-but-reverted transaction as an `eth_call` at its own block to recover the
 * reason.
 *
 * A receipt carries `status` and nothing else: the revert data is not in it. Re-calling at
 * `blockNumber - 1` reproduces the state the transaction actually executed against, which is
 * the only way to get a named error back rather than "reverted".
 *
 * Best-effort by design. An archive-less node cannot answer, and failing to explain a failure
 * must not itself become a second failure.
 */
async function reasonForMinedRevert(
  publicClient: PublicClient,
  receipt: TransactionReceipt,
  args: { vault: Address; data: Hex },
): Promise<string> {
  try {
    await publicClient.call({
      account: receipt.from,
      to: args.vault,
      data: args.data,
      blockNumber: receipt.blockNumber - 1n,
    });
    // The replay succeeded, so the revert depended on something the replay does not reproduce:
    // most often another transaction in the same block moving the pool the route priced
    // against, or the debt this batch was sized to.
    return "not reproducible at the preceding block; state within the block changed under it";
  } catch (error) {
    return describeRevert(decodeVaultError(extractRevertData(error)));
  }
}
