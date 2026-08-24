/**
 * Multicall3 plumbing, and the typed slot abstraction the state reader is built on.
 *
 * The reason this exists rather than a list of `publicClient.readContract` calls: `VaultState`
 * needs roughly a dozen globals plus seven reads per market, and doing that naively is both
 * thirty-odd round trips and a TORN snapshot, with market A read at one moment and market B at
 * another. Everything here exists to make it one call and one moment.
 *
 * The other half of the trick is that `aggregate3` is not a view function. State changes made
 * by an earlier sub-call ARE visible to later ones inside the same `eth_call`, which is what
 * lets `accrueInterest` run first and every subsequent read see post-accrual totals. Verified
 * empirically against Arbitrum before anything was built on it, because the whole design
 * collapses if it is not true.
 */

import {
  decodeFunctionResult,
  encodeFunctionData,
  type Abi,
  type Address,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type ContractFunctionReturnType,
  type Hex,
} from "viem";

export const multicall3Abi = [
  {
    type: "function",
    name: "aggregate3",
    stateMutability: "payable",
    inputs: [
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "target", type: "address" },
          { name: "allowFailure", type: "bool" },
          { name: "callData", type: "bytes" },
        ],
      },
    ],
    outputs: [
      {
        name: "returnData",
        type: "tuple[]",
        components: [
          { name: "success", type: "bool" },
          { name: "returnData", type: "bytes" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getBlockNumber",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "blockNumber", type: "uint256" }],
  },
  {
    type: "function",
    name: "getCurrentBlockTimestamp",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "timestamp", type: "uint256" }],
  },
] as const;

/** The bits of ERC20 this system reads. Not worth generating an artifact for. */
export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

export interface Multicall3Call {
  target: Address;
  allowFailure: boolean;
  callData: Hex;
}

export interface Multicall3Result {
  success: boolean;
  returnData: Hex;
}

type Mutability = "pure" | "view" | "nonpayable" | "payable";

/**
 * One planned call: the bytes to send, and how to read what comes back.
 *
 * Pairing them is the point. The failure this prevents is a mis-ordered layout, where call
 * `n`'s result is decoded with call `m`'s decoder. With enough same-shaped reads (eleven of
 * the per-market ones return a bare `uint256`) that produces plausible numbers rather than a
 * decode error, and the first symptom would be a plan built on another market's rate limit.
 */
export interface Slot<T> {
  readonly index: number;
  readonly allowFailure: boolean;
  decode(results: readonly Multicall3Result[]): T;
}

/**
 * Accumulates calls and hands back a typed slot for each.
 *
 * `add` is the only way to grow the list, and it returns the only way to read the result, so
 * an index can never be written down by hand.
 */
export class CallBuilder {
  private readonly calls: Multicall3Call[] = [];

  /**
   * @param allowFailure - `true` returns `undefined` from the slot instead of throwing.
   *   Reserved for reads that are genuinely allowed to fail: an oracle that has stopped
   *   answering is a state the planner already models, and must not take the whole tick down.
   */
  add<
    const TAbi extends Abi,
    TName extends ContractFunctionName<TAbi, Mutability>,
    TArgs extends ContractFunctionArgs<TAbi, Mutability, TName>,
  >(
    target: Address,
    abi: TAbi,
    functionName: TName,
    args: TArgs,
    allowFailure = false,
  ): Slot<ContractFunctionReturnType<TAbi, Mutability, TName, TArgs>> {
    type Return = ContractFunctionReturnType<TAbi, Mutability, TName, TArgs>;

    const index = this.calls.length;
    // viem's encode/decode signatures are overloaded across every abi shape and do not narrow
    // through a wrapper's own generics. The casts are at the boundary only: the public
    // signature above is fully typed, and the abi/functionName/args triple is checked there.
    const callData = encodeFunctionData({ abi, functionName, args } as never);
    this.calls.push({ target, allowFailure, callData });

    return {
      index,
      allowFailure,
      decode: (results) => {
        const r = results[index];
        if (!r) {
          throw new Error(`multicall returned ${results.length} results, expected at least ${index + 1}`);
        }
        if (!r.success) {
          if (allowFailure) return undefined as Return;
          throw new Error(`call ${index} to ${target} (${String(functionName)}) reverted: ${r.returnData}`);
        }
        return decodeFunctionResult({ abi, functionName, args, data: r.returnData } as never) as Return;
      },
    };
  }

  /** As above, but the caller has already accepted that this one may come back empty. */
  addOptional<
    const TAbi extends Abi,
    TName extends ContractFunctionName<TAbi, Mutability>,
    TArgs extends ContractFunctionArgs<TAbi, Mutability, TName>,
  >(
    target: Address,
    abi: TAbi,
    functionName: TName,
    args: TArgs,
  ): Slot<ContractFunctionReturnType<TAbi, Mutability, TName, TArgs> | undefined> {
    return this.add(target, abi, functionName, args, true);
  }

  build(): readonly Multicall3Call[] {
    return this.calls;
  }

  get length(): number {
    return this.calls.length;
  }
}

/** Calldata for one `aggregate3`. Pure, so the whole call list is testable without a node. */
export function encodeAggregate3(calls: readonly Multicall3Call[]): Hex {
  return encodeFunctionData({ abi: multicall3Abi, functionName: "aggregate3", args: [calls] });
}

export function decodeAggregate3(data: Hex): readonly Multicall3Result[] {
  return decodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", data }) as readonly Multicall3Result[];
}
