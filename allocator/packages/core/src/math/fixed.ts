/**
 * Fixed-point primitives mirroring `MorphoSharesMath`'s `_mulDivDown` / `_mulDivUp`.
 *
 * The contract deliberately uses plain `(x * y) / d` rather than an overflow-safe 512-bit
 * mulDiv, to match Morpho Blue's own overflow bounds. Its header says so explicitly. That
 * choice is the reason this file is not a one-line port.
 *
 * In Solidity 0.8, `x * y` REVERTS when the product exceeds uint256. In TypeScript, bigint
 * is arbitrary precision and happily returns a number no chain could ever produce. Mirroring
 * the arithmetic without mirroring the revert would mean the planner cheerfully builds
 * calldata for a transaction that always fails, and the failure would surface as an opaque
 * panic from inside Morpho rather than as something traceable to here.
 *
 * So every primitive below reproduces the *failure* behaviour as well as the arithmetic:
 * each intermediate that Solidity would check is checked here, and throws instead.
 */

/** 2**256 - 1. Anything above this reverts on-chain. */
export const MAX_UINT256 = (1n << 256n) - 1n;

export const WAD = 10n ** 18n;

/** Matches Morpho Blue's ConstantsLib.ORACLE_PRICE_SCALE. */
export const ORACLE_PRICE_SCALE = 10n ** 36n;

/**
 * Thrown where Solidity 0.8 would revert with an arithmetic panic (0x11) or a division by
 * zero (0x12). Carries the operands so a caller can report which input was out of range
 * rather than just that something overflowed.
 */
export class SolidityArithmeticError extends Error {
  constructor(
    readonly op: string,
    readonly operands: Record<string, bigint>,
    reason: string,
  ) {
    const detail = Object.entries(operands)
      .map(([k, v]) => `${k}=${v}`)
      .join(", ");
    super(`${op}: ${reason} (${detail})`);
    this.name = "SolidityArithmeticError";
  }
}

function requireUint256(op: string, operands: Record<string, bigint>, value: bigint): bigint {
  if (value < 0n) {
    throw new SolidityArithmeticError(op, operands, "negative intermediate, would underflow uint256");
  }
  if (value > MAX_UINT256) {
    throw new SolidityArithmeticError(op, operands, "intermediate exceeds uint256");
  }
  return value;
}

/** `(x * y) / d`, rounding down. Mirrors `MorphoSharesMath.mulDivDown`. */
export function mulDivDown(x: bigint, y: bigint, d: bigint): bigint {
  const operands = { x, y, d };
  if (d === 0n) throw new SolidityArithmeticError("mulDivDown", operands, "division by zero");
  const product = requireUint256("mulDivDown", operands, x * y);
  return product / d;
}

/**
 * `(x * y + (d - 1)) / d`, rounding up. Mirrors `MorphoSharesMath.mulDivUp`.
 *
 * Two separate overflow points, not one: the product, and then the product plus `d - 1`.
 * Solidity checks both, so both are checked here.
 */
export function mulDivUp(x: bigint, y: bigint, d: bigint): bigint {
  const operands = { x, y, d };
  if (d === 0n) throw new SolidityArithmeticError("mulDivUp", operands, "division by zero");
  const product = requireUint256("mulDivUp", operands, x * y);
  const numerator = requireUint256("mulDivUp", operands, product + (d - 1n));
  return numerator / d;
}

/** Guards an addition Solidity would check, e.g. `totalAssets + VIRTUAL_ASSETS`. */
export function addUint256(op: string, a: bigint, b: bigint): bigint {
  return requireUint256(op, { a, b }, a + b);
}
