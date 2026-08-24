import type { Address, Hex } from "viem";

/**
 * A swap route request. Built from a Plan, never from an intent.
 *
 * `amountIn` is not negotiable and not a hint. `MorphoSwapExecutor` swaps its entire balance
 * while the calldata hardcodes an amount, so a route built for a different figure is wrong in
 * one of two ways: too small leaves a residual swept back to idle as undeployed capital, too
 * large makes the router's `transferFrom` fail as an opaque `SwapCallFailed` with the
 * underlying reason discarded. `encode` refuses a quote whose `amountIn` does not match.
 */
export interface QuoteRequest {
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;

  /**
   * Who receives the output. Must be the plan's `swap.recipient`, which is GeneralAdapter1
   * for anything involving a flashloan, not the vault. Aggregators that cannot target an
   * arbitrary receiver are unusable here.
   */
  recipient: Address;

  /**
   * The address that will hold the tokens and call the venue: the vault's swap executor.
   * This is `msg.sender` at the router, and aggregators encode against it.
   */
  caller: Address;

  /**
   * The EOA that will actually send the transaction, i.e. the allocator key.
   *
   * Distinct from `caller` here, and aggregators care. Velora requires `txOrigin` whenever
   * `msg.sender` differs from the transaction sender, which is always true for this system:
   * the allocator sends to the vault, and the swap executor is what reaches the router four
   * hops later.
   */
  txOrigin: Address;

  /** Required because tokens are identified by address rather than symbol. */
  srcDecimals: number;
  destDecimals: number;
}

export interface Quote {
  /** Becomes `MarketAction.swapTarget`. */
  to: Address;
  /** Becomes `MarketAction.swapCalldata`, forwarded to `to` unmodified. */
  data: Hex;
  /** The amount this route was built for. Checked against the plan, not trusted. */
  amountIn: bigint;
  /** What the venue expects to deliver. The basis for the submitted `minOut`. */
  expectedOut: bigint;
  /** Optional, for logging and staleness decisions. */
  source?: string;
}

/**
 * The only part of the pipeline that performs I/O.
 *
 * Kept behind an interface so `plan` and `encode` stay pure and testable offline, and so the
 * aggregator can be swapped without touching either.
 */
export interface QuoteProvider {
  readonly name: string;
  quote(request: QuoteRequest): Promise<Quote>;
}
