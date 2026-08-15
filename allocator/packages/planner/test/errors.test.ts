/**
 * Differential test for the revert decoder.
 *
 * Every vector here is revert data solc actually produced from the contracts' own error
 * definitions, captured by test/vectors/RevertVectors.t.sol. Checking a decoder against
 * hand-written fixtures only proves the fixtures agree with the decoder, which is circular.
 * These prove it agrees with the contracts.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { encodeErrorResult, type Hex } from "viem";

import { decodeVaultError, describeFailure, describeRevert, PlannerError, type PlannerFailure } from "../src/errors.js";

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, "vectors/reverts.json"), "utf8")) as { cases: string[] };

const parsed = vectors.cases.map((line) => {
  const i = line.indexOf(",");
  return { label: line.slice(0, i), data: line.slice(i + 1) as Hex };
});

describe("decoding real revert data", () => {
  it("captured a meaningful spread", () => {
    expect(parsed.length).toBeGreaterThanOrEqual(15);
  });

  for (const { label, data } of parsed) {
    if (label.startsWith("Panic_")) {
      const expectedCode = Number(label.split("_")[1]);
      it(`${label} decodes as a panic`, () => {
        const r = decodeVaultError(data);
        expect(r.kind).toBe("panic");
        if (r.kind !== "panic") return;
        expect(r.code).toBe(expectedCode);
        expect(r.reason).not.toContain("unrecognised");
      });
      continue;
    }

    it(`${label} decodes by name`, () => {
      const r = decodeVaultError(data);
      expect(r.kind).toBe("custom");
      if (r.kind !== "custom") return;
      expect(r.name).toBe(label);
    });
  }
});

describe("decoded arguments are usable, not just present", () => {
  const find = (label: string) => parsed.find((c) => c.label === label)!.data;

  it("LeverageExceedsMax carries the requested value and the ceiling", () => {
    const r = decodeVaultError(find("LeverageExceedsMax"));
    expect(r.kind).toBe("custom");
    if (r.kind !== "custom") return;
    // The generator asks for 9e18 against a registered ceiling of 5e18.
    expect(r.args[0]).toBe(9_000_000_000_000_000_000n);
    expect(r.args[1]).toBe(5_000_000_000_000_000_000n);
  });

  it("MarketNotEnabled carries the market id", () => {
    const r = decodeVaultError(find("MarketNotEnabled"));
    expect(r.kind).toBe("custom");
    if (r.kind !== "custom") return;
    expect(String(r.args[0])).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("0x11 is the panic that means the arithmetic disagreed with the contract", () => {
    const r = decodeVaultError(find("Panic_0x11"));
    expect(r.kind).toBe("panic");
    if (r.kind !== "panic") return;
    expect(r.reason).toBe("arithmetic overflow or underflow");
  });
});

describe("the branches real vectors cannot cover", () => {
  it("empty revert data", () => {
    expect(decodeVaultError("0x").kind).toBe("empty");
    expect(decodeVaultError(undefined).kind).toBe("empty");
    expect(decodeVaultError(null).kind).toBe("empty");
  });

  it("a plain string revert, as Morpho Blue itself produces", () => {
    // Morpho Blue reverts with strings, not custom errors, so anything bubbling up from the
    // protocol lands here rather than in the `custom` branch.
    const data = encodeErrorResult({
      abi: [{ type: "error", name: "Error", inputs: [{ type: "string" }] }],
      errorName: "Error",
      args: ["insufficient collateral"],
    });
    const r = decodeVaultError(data);
    expect(r.kind).toBe("string");
    if (r.kind !== "string") return;
    expect(r.reason).toBe("insufficient collateral");
  });

  it("an unrecognised selector falls through rather than throwing", () => {
    const r = decodeVaultError("0xdeadbeef");
    expect(r.kind).toBe("unknown");
  });

  it("a swap venue's own revert is unrecoverable by design", () => {
    // MorphoSwapExecutor discards the target's revert data and throws a bare SwapCallFailed,
    // so the underlying cause never reaches the decoder. Worth pinning as expected behaviour.
    const swapCallFailed = parsed.find((c) => c.label === "SwapCallFailed");
    expect(swapCallFailed).toBeUndefined();
  });
});

describe("describeRevert", () => {
  it("formats each kind readably", () => {
    expect(describeRevert({ kind: "custom", name: "NotAllocator", args: [] })).toBe("NotAllocator()");
    expect(describeRevert({ kind: "custom", name: "LeverageBelowOneX", args: [5n] })).toBe("LeverageBelowOneX(5)");
    expect(describeRevert({ kind: "string", reason: "nope" })).toBe("revert: nope");
    expect(describeRevert({ kind: "panic", code: 0x11, reason: "arithmetic overflow or underflow" })).toContain(
      "panic 0x11",
    );
    expect(describeRevert({ kind: "empty" })).toBe("reverted with no data");
  });
});

describe("PlannerError", () => {
  const samples: PlannerFailure[] = [
    { code: "MarketNotInSnapshot", marketId: "0x00" as Hex },
    { code: "OracleUnavailable", marketId: "0x00" as Hex },
    { code: "InsufficientIdle", required: 10n, available: 5n },
    { code: "MarketNotEnabled", marketId: "0x00" as Hex },
    { code: "LeverageBelowOneX", requested: 1n },
    { code: "LeverageExceedsMax", requested: 9n, max: 5n },
    { code: "NoPosition", marketId: "0x00" as Hex },
    { code: "InvalidDecreaseAmount", requested: 9n, available: 5n },
    { code: "DecreaseAmountTooSmall" },
    { code: "DeleverageAmountTooSmall" },
    { code: "PositionHasNoEquity", marketId: "0x00" as Hex },
    { code: "TargetLeverageNotBelowCurrent", target: 3n, current: 2n },
    { code: "RiskLimitsPaused" },
    { code: "RateLimitExceeded", marketId: "0x00" as Hex, attempted: 9n, cap: 5n },
    { code: "PriceDeviationExceeded", marketId: "0x00" as Hex, newPrice: 2n, lastPrice: 1n, maxBps: 100n },
    { code: "TotalAssetsDropBelowFloor", before: 100n, projected: 50n, floor: 99n },
    { code: "QuoteAmountMismatch", planned: 10n, quoted: 11n },
    { code: "QuoteBelowOracleFloor", expectedOut: 1n, floor: 2n },
    { code: "QuoteCannotCoverFlashloan", expectedOut: 1n, required: 2n },
    { code: "OracleDivergesFromQuote", oracleImplied: 100n, quoted: 50n, maxSlippageBps: 50n },
  ];

  it("every failure code has a message that names it", () => {
    for (const f of samples) {
      const msg = describeFailure(f);
      expect(msg).toContain(f.code);
      expect(msg.length).toBeGreaterThan(f.code.length + 2);
    }
  });

  it("carries the structured failure, not just a string", () => {
    const e = new PlannerError({ code: "InsufficientIdle", required: 100n, available: 40n });
    expect(e).toBeInstanceOf(Error);
    expect(e.failure.code).toBe("InsufficientIdle");
    if (e.failure.code === "InsufficientIdle") expect(e.failure.required).toBe(100n);
    expect(e.message).toContain("100");
  });
});
