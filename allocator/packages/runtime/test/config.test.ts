import { describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULT_MULTICALL3, deploymentPath, envSchema, loadConfig, maxPlanAge } from "../src/config.js";
import { ADDRESSES, MARKET_A } from "./world.js";

function writeDeployment(chainId: number, name: string): string {
  const dir = mkdtempSync(join(tmpdir(), "morphoagg-"));
  writeFileSync(
    join(dir, name),
    JSON.stringify({
      chainId,
      vault: ADDRESSES.vault,
      swapExecutor: ADDRESSES.swapExecutor,
      riskLimits: ADDRESSES.riskLimits,
      asset: ADDRESSES.asset,
      morpho: ADDRESSES.morpho,
      bundler3: ADDRESSES.generalAdapter1,
      generalAdapter1: ADDRESSES.generalAdapter1,
      allocator: ADDRESSES.vault,
      owner: ADDRESSES.vault,
      markets: { "wstETH/USDC": MARKET_A },
    }),
  );
  return dir;
}

const BASE_ENV = { RPC_URL: "http://127.0.0.1:8545", CHAIN_ID: "42161" };

describe("env schema", () => {
  it("boots without a private key, because reads and simulations do not need one", () => {
    const dir = writeDeployment(42161, "42161.json");
    const config = loadConfig({ ...BASE_ENV, DEPLOYMENTS_DIR: dir }, dir);
    expect(config.allocatorKey).toBeUndefined();
    expect(config.multicall3).toBe(DEFAULT_MULTICALL3);
  });

  it("rejects a private key of the wrong length rather than failing at signing time", () => {
    expect(() => envSchema.parse({ ...BASE_ENV, ALLOCATOR_PRIVATE_KEY: "0xdeadbeef" })).toThrow();
  });

  it("rejects bps above 10000", () => {
    expect(() => envSchema.parse({ ...BASE_ENV, QUOTE_SLIPPAGE_BPS: "10001" })).toThrow();
    expect(envSchema.parse({ ...BASE_ENV, QUOTE_SLIPPAGE_BPS: "10000" }).QUOTE_SLIPPAGE_BPS).toBe(10_000n);
  });
});

describe("deployment records", () => {
  /**
   * The footgun this guards. An anvil fork of Arbitrum still reports chainid 42161, so a local
   * run and a production run compete for the same filename. `Deploy.s.sol` labels the local
   * one; the runtime has to be able to point at the same labelled file, or it reads production
   * addresses while talking to a fork.
   */
  it("resolves a labelled file separately from the unlabelled one", () => {
    expect(deploymentPath("/d", 42161)).toBe("/d/42161.json");
    expect(deploymentPath("/d", 42161, "local")).toBe("/d/42161.local.json");
    expect(deploymentPath("/d", 42161, "")).toBe("/d/42161.json");
  });

  it("loads the labelled file when DEPLOYMENT_LABEL is set", () => {
    const dir = writeDeployment(42161, "42161.local.json");
    const config = loadConfig({ ...BASE_ENV, DEPLOYMENTS_DIR: dir, DEPLOYMENT_LABEL: "local" }, dir);
    expect(config.deployment.vault).toBe(ADDRESSES.vault);
  });

  it("refuses a record whose chainId disagrees with CHAIN_ID", () => {
    const dir = writeDeployment(1, "42161.json");
    expect(() => loadConfig({ ...BASE_ENV, DEPLOYMENTS_DIR: dir }, dir)).toThrow(/records chainId 1/);
  });

  it("names the missing file rather than throwing ENOENT", () => {
    expect(() => loadConfig({ ...BASE_ENV, DEPLOYMENTS_DIR: "/nowhere" }, "/nowhere")).toThrow(
      /no deployment record at/,
    );
  });
});

describe("freshness policy", () => {
  it("holds a drifting plan to a much tighter budget than a stable one", () => {
    const dir = writeDeployment(42161, "42161.json");
    const { policy } = loadConfig({ ...BASE_ENV, DEPLOYMENTS_DIR: dir }, dir);

    // A deleverage's swap amount derives from debt that grows every block, so one block is
    // the honest budget. Widening it would not make the plan more correct.
    expect(maxPlanAge(policy, "drifts")).toBe(1n);
    expect(maxPlanAge(policy, "stable")).toBeGreaterThan(maxPlanAge(policy, "drifts"));
  });
});
