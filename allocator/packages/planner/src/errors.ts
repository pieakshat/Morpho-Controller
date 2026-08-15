/**
 * Two halves, and they serve opposite directions.
 *
 * `PlannerFailure` is the predict-the-revert layer: conditions the planner detects BEFORE
 * emitting an action, so a bad intent fails locally in a millisecond instead of burning gas
 * to learn the same thing. Most of these mirror a contract error one-for-one; a few are
 * quote-validation checks with no on-chain counterpart, marked below.
 *
 * `decodeVaultError` is the other direction: turning revert bytes that came back from a
 * simulation or a failed transaction into something with a name and arguments.
 */

import { riskLimitsAbi, swapExecutorAbi, vaultAbi, type Id } from "@morphoagg/core";
import { decodeErrorResult, type Hex } from "viem";

/*//////////////////////////////////////////////////////////////
                        PREDICTED FAILURES
//////////////////////////////////////////////////////////////*/

export type PlannerFailure =
  // --- planner-only: the snapshot cannot support planning at all ---
  | { code: "MarketNotInSnapshot"; marketId: Id }
  | { code: "OracleUnavailable"; marketId: Id }
  | { code: "InsufficientIdle"; required: bigint; available: bigint }

  // --- mirrors of MorphoLeverageEngine / MorphoMarketRegistry ---
  | { code: "MarketNotEnabled"; marketId: Id }
  | { code: "LeverageBelowOneX"; requested: bigint }
  | { code: "LeverageExceedsMax"; requested: bigint; max: bigint }
  | { code: "NoPosition"; marketId: Id }
  | { code: "InvalidDecreaseAmount"; requested: bigint; available: bigint }
  | { code: "DecreaseAmountTooSmall" }
  | { code: "DeleverageAmountTooSmall" }
  | { code: "PositionHasNoEquity"; marketId: Id }
  | { code: "TargetLeverageNotBelowCurrent"; target: bigint; current: bigint }

  // --- mirrors of RiskLimits ---
  | { code: "RiskLimitsPaused" }
  | { code: "RateLimitExceeded"; marketId: Id; attempted: bigint; cap: bigint }
  | { code: "PriceDeviationExceeded"; marketId: Id; newPrice: bigint; lastPrice: bigint; maxBps: bigint }

  // --- mirror of MorphoLeverageVault's batch guard ---
  | { code: "TotalAssetsDropBelowFloor"; before: bigint; projected: bigint; floor: bigint }

  // --- planner-only: the quote does not fit the plan ---
  | { code: "QuoteAmountMismatch"; planned: bigint; quoted: bigint }
  | { code: "QuoteBelowOracleFloor"; expectedOut: bigint; floor: bigint }
  | { code: "QuoteCannotCoverFlashloan"; expectedOut: bigint; required: bigint }
  | { code: "OracleDivergesFromQuote"; oracleImplied: bigint; quoted: bigint; maxSlippageBps: bigint };

export type PlannerFailureCode = PlannerFailure["code"];

export class PlannerError extends Error {
  constructor(readonly failure: PlannerFailure) {
    super(describeFailure(failure));
    this.name = "PlannerError";
  }
}

export function fail(failure: PlannerFailure): never {
  throw new PlannerError(failure);
}

export function describeFailure(f: PlannerFailure): string {
  switch (f.code) {
    case "MarketNotInSnapshot":
      return `${f.code}: ${f.marketId} is not in the state snapshot`;
    case "OracleUnavailable":
      return `${f.code}: ${f.marketId}'s oracle is not answering, so no swap floor can be derived`;
    case "InsufficientIdle":
      return `${f.code}: needs ${f.required} idle, vault holds ${f.available}`;
    case "MarketNotEnabled":
      return `${f.code}: ${f.marketId} is registered but disabled, so increases are blocked`;
    case "LeverageBelowOneX":
      return `${f.code}: ${f.requested} is below 1e18`;
    case "LeverageExceedsMax":
      return `${f.code}: ${f.requested} exceeds the market ceiling of ${f.max}`;
    case "NoPosition":
      return `${f.code}: ${f.marketId} holds no collateral`;
    case "InvalidDecreaseAmount":
      return `${f.code}: ${f.requested} against ${f.available} of collateral`;
    case "DecreaseAmountTooSmall":
      return `${f.code}: the repay this implies rounds to zero, which would withdraw collateral for free`;
    case "DeleverageAmountTooSmall":
      return `${f.code}: the target implies repaying zero shares`;
    case "PositionHasNoEquity":
      return `${f.code}: ${f.marketId} has no equity, so leverage is undefined`;
    case "TargetLeverageNotBelowCurrent":
      return `${f.code}: target ${f.target} is not below current ${f.current}`;
    case "RiskLimitsPaused":
      return `${f.code}: increases are paused (decreases are unaffected)`;
    case "RateLimitExceeded":
      return `${f.code}: ${f.marketId} would reach ${f.attempted} against a cap of ${f.cap}`;
    case "PriceDeviationExceeded":
      return `${f.code}: ${f.marketId} moved from ${f.lastPrice} to ${f.newPrice}, past ${f.maxBps}bps`;
    case "TotalAssetsDropBelowFloor":
      return `${f.code}: ${f.before} would become ${f.projected}, below the floor of ${f.floor}`;
    case "QuoteAmountMismatch":
      return `${f.code}: plan needs amountIn ${f.planned}, quote is for ${f.quoted}`;
    case "QuoteBelowOracleFloor":
      return `${f.code}: quote returns ${f.expectedOut}, floor is ${f.floor}`;
    case "QuoteCannotCoverFlashloan":
      return `${f.code}: quote returns ${f.expectedOut}, flashloan needs ${f.required}`;
    case "OracleDivergesFromQuote":
      return `${f.code}: oracle implies ${f.oracleImplied}, quote is ${f.quoted}, past ${f.maxSlippageBps}bps`;
  }
}

/*//////////////////////////////////////////////////////////////
                        DECODING REVERTS
//////////////////////////////////////////////////////////////*/

export type DecodedRevert =
  | { kind: "custom"; name: string; args: readonly unknown[] }
  | { kind: "string"; reason: string }
  | { kind: "panic"; code: number; reason: string }
  | { kind: "empty" }
  | { kind: "unknown"; data: Hex };

const ERROR_STRING_SELECTOR = "0x08c379a0";
const PANIC_SELECTOR = "0x4e487b71";

/**
 * The panics that actually show up here.
 *
 * 0x11 is the one to recognise on sight: it is what Morpho's `borrowShares -= shares`
 * produces when a repay converts back to more shares than the position holds. That was the
 * repay-overshoot bug, and off-chain it means the planner's arithmetic disagreed with the
 * contract's.
 */
const PANIC_REASONS: Record<number, string> = {
  0x01: "assertion failed",
  0x11: "arithmetic overflow or underflow",
  0x12: "division or modulo by zero",
  0x21: "invalid enum conversion",
  0x31: "pop on empty array",
  0x32: "array index out of bounds",
  0x41: "out of memory",
  0x51: "call to an uninitialised function pointer",
};

/**
 * Every error the vault can surface, in one list.
 *
 * The vault's own ABI already carries the engine's and the registry's errors through
 * inheritance, so this only has to add the two satellite contracts. Anything bubbling up from
 * Morpho itself is a plain string revert and lands in the `string` branch.
 */
const ERROR_ABI = [...vaultAbi, ...riskLimitsAbi, ...swapExecutorAbi] as const;

export function decodeVaultError(data: Hex | undefined | null): DecodedRevert {
  if (!data || data === "0x") return { kind: "empty" };

  const selector = data.slice(0, 10).toLowerCase();

  if (selector === ERROR_STRING_SELECTOR) {
    try {
      const decoded = decodeErrorResult({ abi: ERROR_ABI, data });
      return { kind: "string", reason: String(decoded.args?.[0] ?? "") };
    } catch {
      return { kind: "unknown", data };
    }
  }

  if (selector === PANIC_SELECTOR) {
    try {
      const decoded = decodeErrorResult({ abi: ERROR_ABI, data });
      const code = Number(decoded.args?.[0] ?? 0n);
      return { kind: "panic", code, reason: PANIC_REASONS[code] ?? `unrecognised panic 0x${code.toString(16)}` };
    } catch {
      return { kind: "unknown", data };
    }
  }

  try {
    const decoded = decodeErrorResult({ abi: ERROR_ABI, data });
    return { kind: "custom", name: decoded.errorName, args: decoded.args ?? [] };
  } catch {
    // A swap venue's own revert reaches here: MorphoSwapExecutor discards the target's
    // revert data and throws a bare SwapCallFailed, so the underlying cause is unrecoverable
    // by design. Worth knowing when debugging a failed route.
    return { kind: "unknown", data };
  }
}

export function describeRevert(r: DecodedRevert): string {
  switch (r.kind) {
    case "custom":
      return r.args.length > 0 ? `${r.name}(${r.args.map(String).join(", ")})` : `${r.name}()`;
    case "string":
      return `revert: ${r.reason}`;
    case "panic":
      return `panic 0x${r.code.toString(16)}: ${r.reason}`;
    case "empty":
      return "reverted with no data";
    case "unknown":
      return `unrecognised revert data: ${r.data}`;
  }
}
