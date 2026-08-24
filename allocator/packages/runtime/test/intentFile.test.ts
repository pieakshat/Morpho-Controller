import { describe, expect, it } from "vitest";
import { FULL_CLOSE } from "@morphoagg/core";

import { describeIntent, formatWad, parseIntents } from "../src/intentFile.js";
import { MARKET_A } from "./world.js";

describe("intent files", () => {
  it("parses all four kinds", () => {
    const intents = parseIntents({
      intents: [
        { kind: "increase", marketId: MARKET_A, ownAmount: "500000000000", leverage: "2000000000000000000" },
        { kind: "decreaseByCollateral", marketId: MARKET_A, collateralAmount: "1000000000000000000" },
        { kind: "closeFully", marketId: MARKET_A },
        { kind: "deleverageTo", marketId: MARKET_A, targetLeverage: "1500000000000000000" },
      ],
    });

    expect(intents).toHaveLength(4);
    expect(intents[0]).toEqual({
      kind: "increase",
      marketId: MARKET_A,
      ownAmount: 500_000_000_000n,
      leverage: 2n * 10n ** 18n,
    });
  });

  /**
   * The one rule worth enforcing in the file rather than at the contract. `ownAmount` is in
   * the asset's own units and `leverage` is 1e18-scaled; both exceed what a double holds
   * exactly, and the precision loss is silent.
   */
  it("refuses JSON numbers for on-chain integers", () => {
    expect(() =>
      parseIntents({ intents: [{ kind: "increase", marketId: MARKET_A, ownAmount: 500000000000, leverage: "2000000000000000000" }] }),
    ).toThrow();
  });

  it("refuses a leverage below 1x, which the contract rejects as LeverageBelowOneX", () => {
    expect(() =>
      parseIntents({ intents: [{ kind: "increase", marketId: MARKET_A, ownAmount: "1", leverage: "999999999999999999" }] }),
    ).toThrow(/at least 1e18/);
  });

  it("refuses a wrong-length market id instead of failing on-chain as unregistered", () => {
    expect(() => parseIntents({ intents: [{ kind: "closeFully", marketId: "0xabcd" }] })).toThrow(/32-byte/);
  });

  it("rejects an unknown kind rather than skipping it", () => {
    expect(() => parseIntents({ intents: [{ kind: "yolo", marketId: MARKET_A }] })).toThrow();
  });
});

describe("display", () => {
  it("shows a full close as the sentinel it encodes", () => {
    expect(describeIntent({ kind: "closeFully", marketId: MARKET_A })).toContain(String(FULL_CLOSE));
  });

  it("formats WAD leverage readably", () => {
    expect(formatWad(2n * 10n ** 18n)).toBe("2");
    expect(formatWad(1_500_000_000_000_000_000n)).toBe("1.5");
    expect(formatWad(1_150_000_000_000_000_000n)).toBe("1.15");
  });
});
