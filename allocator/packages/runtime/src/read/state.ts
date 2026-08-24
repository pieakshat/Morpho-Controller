/**
 * The one `eth_call` per tick.
 *
 * Everything expensive about reading vault state was pushed into `calls.ts` and `decode.ts`,
 * both pure. What is left here is the network boundary and nothing else, which is the same
 * split that made the math and plan layers testable offline.
 */

import type { VaultState } from "@morphoagg/planner";
import type { Address, Hex, PublicClient } from "viem";

import type { StateCalls, Topology } from "./calls.js";
import { buildStateCalls } from "./calls.js";
import { assertReaderAgreesWithVault, decodeVaultState } from "./decode.js";
import { decodeAggregate3, encodeAggregate3, type Multicall3Call, type Multicall3Result } from "./multicall.js";

/**
 * Sends one `aggregate3` as an `eth_call`.
 *
 * `call` rather than `readContract`, deliberately. `aggregate3` is payable, not view, because
 * the sub-calls may write, and that is load-bearing here: the `accrueInterest` calls at the
 * head of the list have to actually mutate for the reads behind them to see post-accrual
 * totals. Nothing persists past the call, so this stays a read as far as the chain is
 * concerned, but the ABI mutability has to be honest about it.
 */
export async function executeAggregate3(
  publicClient: PublicClient,
  multicall3: Address,
  calls: readonly Multicall3Call[],
  blockNumber?: bigint,
): Promise<readonly Multicall3Result[]> {
  const { data } = await publicClient.call({
    to: multicall3,
    data: encodeAggregate3(calls),
    ...(blockNumber === undefined ? {} : { blockNumber }),
  });

  if (!data || data === "0x") {
    throw new Error(
      `aggregate3 at ${multicall3} returned no data. ` +
        `Most likely there is no Multicall3 deployed there on this chain; set MULTICALL3_ADDRESS.`,
    );
  }

  const results = decodeAggregate3(data as Hex);
  if (results.length !== calls.length) {
    throw new Error(`aggregate3 returned ${results.length} results for ${calls.length} calls`);
  }
  return results;
}

export interface ReadStateOptions {
  /** Pin the read to a block. Used by tests and by the drift check; unset means latest. */
  blockNumber?: bigint;
  /**
   * Skip the mirror-vs-vault equality check.
   *
   * Exists for one narrow case: reproducing a disagreement in a test. Anything that plans
   * against the result must leave it on. A snapshot that fails the check is not "slightly
   * off", it is assembled wrong, and every number derived from it is suspect.
   */
  skipSelfCheck?: boolean;
}

export async function readVaultState(
  publicClient: PublicClient,
  topology: Topology,
  multicall3: Address,
  options: ReadStateOptions = {},
): Promise<VaultState> {
  const built: StateCalls = buildStateCalls(topology, multicall3);
  const results = await executeAggregate3(publicClient, multicall3, built.calls, options.blockNumber);
  const state = decodeVaultState(topology, built.layout, results);

  if (!options.skipSelfCheck) assertReaderAgreesWithVault(state);

  return state;
}
