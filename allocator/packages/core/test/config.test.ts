/**
 * The chain config schema is validated against the real file the deploy scripts read, not a
 * fixture. If someone edits script/config/42161.json in a way Solidity would choke on, this
 * fails first and names the field.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { parseChainConfig, parseDeployment } from "../src/config.js";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../../..");
const realConfig = JSON.parse(readFileSync(join(repoRoot, "script/config/42161.json"), "utf8")) as unknown;

describe("the committed Arbitrum config", () => {
  it("parses", () => {
    const c = parseChainConfig(realConfig);
    expect(c.chainName).toBe("arbitrum");
    expect(c.markets).toHaveLength(c.marketCount);
  });

  it("keeps large integers exact as bigints", () => {
    const c = parseChainConfig(realConfig);
    const m = c.markets[0]!;
    expect(m.lltv).toBe(860000000000000000n);
    expect(m.maxLeverage).toBe(5000000000000000000n);
    // A JSON number would have lost precision here; the schema requires a decimal string.
    expect(typeof m.maxExposureChangePerWindow).toBe("bigint");
  });
});

describe("refinements catch what Solidity would only fail on later", () => {
  const base = () => JSON.parse(JSON.stringify(realConfig)) as Record<string, unknown>;

  it("rejects marketCount disagreeing with the array", () => {
    const c = base();
    c.marketCount = 2;
    expect(() => parseChainConfig(c)).toThrow(/marketCount must equal/);
  });

  it("rejects a market whose loanToken is not the vault asset", () => {
    const c = base();
    (c.markets as Record<string, unknown>[])[0]!.loanToken = "0x0000000000000000000000000000000000000001";
    expect(() => parseChainConfig(c)).toThrow(/loanToken must equal the vault asset/);
  });

  it("rejects a rate-limit cap with no window, the on-chain footgun", () => {
    const c = base();
    (c.riskLimits as Record<string, unknown>).rateLimitWindowSeconds = 0;
    expect(() => parseChainConfig(c)).toThrow(/rateLimitWindowSeconds must be set/);
  });

  it("allows a zero window when no market sets a cap", () => {
    const c = base();
    (c.riskLimits as Record<string, unknown>).rateLimitWindowSeconds = 0;
    (c.markets as Record<string, unknown>[])[0]!.maxExposureChangePerWindow = "0";
    expect(() => parseChainConfig(c)).not.toThrow();
  });

  it("normalises addresses to checksummed form, whatever case the file uses", () => {
    const c = base();
    const lower = "0xaf88d065e77c8cc2239327c5edb3a432268e5831";
    (c.markets as Record<string, unknown>[])[0]!.loanToken = lower;
    c.asset = lower.toUpperCase().replace("0X", "0x");

    const parsed = parseChainConfig(c);
    // Both sides came in differently cased and still land on the same checksummed value,
    // which is what lets the loanToken refinement use === rather than case-folding.
    expect(parsed.asset).toBe("0xaf88d065e77c8cC2239327C5EDb3A432268e5831");
    expect(parsed.markets[0]!.loanToken).toBe(parsed.asset);
  });

  it("rejects a malformed address", () => {
    const c = base();
    c.asset = "0xaf88d065e77c8cC2239327C5EDb3A432268e583"; // 39 nibbles
    expect(() => parseChainConfig(c)).toThrow(/20-byte address/);
  });

  it("rejects slippage above the registry's own 1000 bps cap", () => {
    const c = base();
    (c.markets as Record<string, unknown>[])[0]!.maxSlippageBps = 1001;
    expect(() => parseChainConfig(c)).toThrow();
  });

  it("rejects a JSON number where a decimal string is required", () => {
    const c = base();
    (c.markets as Record<string, unknown>[])[0]!.lltv = 860000000000000000;
    expect(() => parseChainConfig(c)).toThrow();
  });
});

describe("deployment artifact schema", () => {
  const artifact = {
    chainId: 42161,
    vault: "0x940a6607163C810F05115cC266B20746A411893c",
    swapExecutor: "0xE3Dafc650Ff44A5ed2E7cB9e875145daeE0f4Dbe",
    riskLimits: "0x2E875A03f9417477CB85f78aBa8B72CFbBc61099",
    asset: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    morpho: "0x6c247b1F6182318877311737BaC0844bAa518F5e",
    bundler3: "0x1FA4431bC113D308beE1d46B0e98Cb805FB48C13",
    generalAdapter1: "0x9954aFB60BB5A222714c478ac86990F221788B88",
    allocator: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    markets: {
      "wstETH/USDC 86%": "0x33e0c8ab132390822b07e5dc95033cf250c963153320b7ffca73220664da2ea0",
    },
  };

  it("parses a real Deploy.s.sol artifact", () => {
    const d = parseDeployment(artifact);
    expect(d.vault).toBe(artifact.vault);
    expect(d.markets["wstETH/USDC 86%"]).toHaveLength(66);
  });

  it("rejects a market id that is not 32 bytes", () => {
    expect(() => parseDeployment({ ...artifact, markets: { m: "0xdeadbeef" } })).toThrow();
  });
});
