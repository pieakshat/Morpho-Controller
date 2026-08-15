/**
 * Differential test: every vector here is MorphoSharesMath's own output, dumped by
 * test/vectors/MathVectors.t.sol. The mirror must reproduce all of them exactly.
 *
 * This is the defence against silent drift. Change a rounding direction in either the
 * contract or the mirror and these fail, rather than the difference surfacing as an opaque
 * panic from inside Morpho on a real transaction.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { mulDivDown, mulDivUp, ORACLE_PRICE_SCALE } from "../src/math/fixed.js";
import {
  VIRTUAL_ASSETS,
  VIRTUAL_SHARES,
  toAssetsDown,
  toAssetsUp,
  toSharesDown,
  toSharesUp,
} from "../src/math/shares.js";

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, "vectors/shares-math.json"), "utf8")) as {
  VIRTUAL_SHARES: number;
  VIRTUAL_ASSETS: number;
  ORACLE_PRICE_SCALE: string;
  cases: string[];
};

const OPS: Record<string, (a: bigint, b: bigint, c: bigint) => bigint> = {
  toAssetsDown,
  toAssetsUp,
  toSharesDown,
  toSharesUp,
  mulDivDown,
  mulDivUp,
};

describe("constants match the contract", () => {
  it("virtual offsets and oracle scale", () => {
    expect(VIRTUAL_SHARES).toBe(BigInt(vectors.VIRTUAL_SHARES));
    expect(VIRTUAL_ASSETS).toBe(BigInt(vectors.VIRTUAL_ASSETS));
    expect(ORACLE_PRICE_SCALE).toBe(BigInt(vectors.ORACLE_PRICE_SCALE));
  });
});

describe("golden vectors from MorphoSharesMath", () => {
  it("has vectors to check", () => {
    expect(vectors.cases.length).toBeGreaterThan(50);
  });

  for (const [index, line] of vectors.cases.entries()) {
    const [op, a, b, c, expected] = line.split(",");
    if (!op || a === undefined || b === undefined || c === undefined || expected === undefined) {
      throw new Error(`malformed vector at index ${index}: ${line}`);
    }
    const fn = OPS[op];
    if (!fn) throw new Error(`unknown op "${op}" in vector at index ${index}`);

    it(`${op}(${a}, ${b}, ${c}) === ${expected}`, () => {
      expect(fn(BigInt(a), BigInt(b), BigInt(c))).toBe(BigInt(expected));
    });
  }
});

describe("round-trip invariant", () => {
  /**
   * `toSharesDown(toAssetsUp(s)) >= s`. Violating this underflows Morpho's
   * `borrowShares -= shares`, which is exactly the repay-overshoot bug hit twice during the
   * contract build. Fuzzed on the Solidity side too, in MathVectors.t.sol.
   */
  it("converting shares up to assets and back never gains shares", () => {
    const rand = (max: bigint): bigint => {
      const bits = max.toString(2).length;
      let v = 0n;
      for (let i = 0; i < bits; i++) v = (v << 1n) | BigInt(Math.random() < 0.5 ? 0 : 1);
      return v % (max + 1n);
    };

    for (let i = 0; i < 2_000; i++) {
      const shares = rand(10n ** 30n);
      const totalAssets = rand(10n ** 30n);
      const totalShares = rand(10n ** 36n);

      const assets = toAssetsUp(shares, totalAssets, totalShares);
      expect(toSharesDown(assets, totalAssets, totalShares)).toBeGreaterThanOrEqual(shares);
    }
  });
});
