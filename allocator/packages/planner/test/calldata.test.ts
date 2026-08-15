/**
 * Byte-for-byte differential test against solc's own encoding.
 *
 * The round-trip test in encode.test.ts decodes our output through the ABI, which only proves
 * we are self-consistent: a wrong field order or a mis-typed member would encode and decode
 * happily on this side and still be rejected on-chain. These vectors are calldata solc
 * produced from `abi.encodeCall(MorphoLeverageVault.executeActions, ...)`, so matching them
 * is the real check.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";

import { FULL_CLOSE, type MarketAction } from "@morphoagg/core";
import { encodeExecuteActions } from "../src/encode.js";

const here = dirname(fileURLToPath(import.meta.url));
const raw = JSON.parse(readFileSync(join(here, "vectors/calldata.json"), "utf8")) as { cases: string[] };

const FIELDS_PER_ACTION = 7;

interface Vector {
  label: string;
  actions: MarketAction[];
  expected: Hex;
}

const vectors: Vector[] = raw.cases.map((line) => {
  const f = line.split(",");
  const label = f[0]!;
  const expected = f[f.length - 1] as Hex;
  const body = f.slice(1, -1);

  const actions: MarketAction[] = [];
  for (let i = 0; i < body.length; i += FIELDS_PER_ACTION) {
    actions.push({
      marketId: body[i] as Hex,
      isIncrease: body[i + 1] === "1",
      amount: BigInt(body[i + 2]!),
      leverage: BigInt(body[i + 3]!),
      minOut: BigInt(body[i + 4]!),
      swapTarget: body[i + 5] as Address,
      swapCalldata: body[i + 6] as Hex,
    });
  }
  return { label, actions, expected };
});

describe("executeActions calldata matches solc exactly", () => {
  it("covers every action shape", () => {
    const labels = vectors.map((v) => v.label);
    expect(labels).toEqual(
      expect.arrayContaining(["increase", "increase_1x", "decrease_proportional", "close_fully", "deleverage", "batch"]),
    );
  });

  for (const v of vectors) {
    it(`${v.label} (${v.actions.length} action${v.actions.length > 1 ? "s" : ""})`, () => {
      expect(encodeExecuteActions(v.actions).toLowerCase()).toBe(v.expected.toLowerCase());
    });
  }
});

describe("the values most likely to be mangled at a language boundary", () => {
  it("the full-close sentinel survives as max uint256", () => {
    const v = vectors.find((x) => x.label === "close_fully")!;
    expect(v.actions[0]!.amount).toBe(FULL_CLOSE);
    // And still matches solc's bytes, which is what proves it was not silently truncated.
    expect(encodeExecuteActions(v.actions).toLowerCase()).toBe(v.expected.toLowerCase());
  });

  it("empty swapCalldata encodes the same as solc's hex\"\"", () => {
    const v = vectors.find((x) => x.label === "close_fully")!;
    expect(v.actions[0]!.swapCalldata).toBe("0x");
  });

  it("a two-action batch preserves order and dynamic offsets", () => {
    // Dynamic `bytes` members in an array of structs are where offset arithmetic goes wrong.
    const v = vectors.find((x) => x.label === "batch")!;
    expect(v.actions).toHaveLength(2);
    expect(v.actions[0]!.isIncrease).toBe(false);
    expect(v.actions[1]!.isIncrease).toBe(true);
    expect(v.actions[0]!.swapCalldata).not.toBe(v.actions[1]!.swapCalldata);
    expect(encodeExecuteActions(v.actions).toLowerCase()).toBe(v.expected.toLowerCase());
  });

  it("reordering the batch changes the calldata, so order is really encoded", () => {
    const v = vectors.find((x) => x.label === "batch")!;
    const reversed = [...v.actions].reverse();
    expect(encodeExecuteActions(reversed).toLowerCase()).not.toBe(v.expected.toLowerCase());
  });
});
