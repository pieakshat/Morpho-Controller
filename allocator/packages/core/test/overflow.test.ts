/**
 * The mirror has to reproduce the contract's FAILURES, not just its arithmetic.
 *
 * `MorphoSharesMath` uses plain `(x * y) / d` on purpose, to match Morpho Blue's own
 * overflow bounds. In Solidity 0.8 that reverts when the product exceeds uint256. bigint is
 * arbitrary precision and would silently return a number no chain could produce, so the
 * planner would build calldata for a transaction that always reverts.
 *
 * Every case below is paired with a Solidity assertion in test/vectors/MathVectors.t.sol
 * that the same input really does revert on-chain.
 */

import { describe, expect, it } from "vitest";

import { MAX_UINT256, SolidityArithmeticError, mulDivDown, mulDivUp } from "../src/math/fixed.js";
import { toAssetsUp } from "../src/math/shares.js";

describe("overflow parity with Solidity", () => {
  it("throws where the product exceeds uint256", () => {
    const big = 1n << 200n; // 2**200 squared is 2**400, far past the ceiling
    expect(() => mulDivDown(big, big, 1n)).toThrow(SolidityArithmeticError);
    expect(() => mulDivUp(big, big, 1n)).toThrow(SolidityArithmeticError);
  });

  it("throws on mulDivUp's SECOND overflow point, where the product alone still fits", () => {
    // x*y == MAX_UINT256 is fine on its own. Adding (d - 1) is what tips it over, and that
    // addition is a separate checked operation in Solidity. A mirror that only guarded the
    // product would wrongly succeed here.
    expect(() => mulDivDown(MAX_UINT256, 1n, 2n)).not.toThrow();
    expect(() => mulDivUp(MAX_UINT256, 1n, 2n)).toThrow(SolidityArithmeticError);
  });

  it("throws on division by zero", () => {
    expect(() => mulDivDown(1n, 1n, 0n)).toThrow(/division by zero/);
    expect(() => mulDivUp(1n, 1n, 0n)).toThrow(/division by zero/);
  });

  it("throws when the virtual-offset addition itself overflows", () => {
    // totalShares + VIRTUAL_SHARES is a checked add in the contract too.
    expect(() => toAssetsUp(1n, 0n, MAX_UINT256)).toThrow(SolidityArithmeticError);
  });

  it("carries the operands so a caller can report which input was out of range", () => {
    try {
      mulDivDown(1n << 200n, 1n << 200n, 1n);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(SolidityArithmeticError);
      const err = e as SolidityArithmeticError;
      expect(err.op).toBe("mulDivDown");
      expect(err.operands.x).toBe(1n << 200n);
      expect(err.message).toContain("exceeds uint256");
    }
  });

  it("leaves realistic production values well clear of the ceiling", () => {
    // The largest intermediate in normal operation: borrowShares * (totalBorrowAssets + 1).
    // Real values from the pinned fork block put this around 1e29 against a 1.16e77 ceiling.
    const borrowShares = 96_180_260_577_753_035n;
    const totalBorrowAssets = 2_301_561_495_701n;
    const product = borrowShares * (totalBorrowAssets + 1n);

    expect(product).toBeLessThan(MAX_UINT256);
    expect(() => toAssetsUp(borrowShares, totalBorrowAssets, 2_213_647_843_922_413_810n)).not.toThrow();
  });
});
