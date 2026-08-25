import { describe, expect, it } from "vitest";
import { encodeErrorResult, encodeFunctionResult, decodeFunctionData, getAddress, type Hex } from "viem";
import { ORACLE_PRICE_SCALE, mulDivDown, vaultAbi } from "@morphoagg/core";
import type { Quote, QuoteProvider, QuoteRequest } from "@morphoagg/planner";

import { multicall3Abi } from "../src/read/multicall.js";
import { runOnce, type PipelineDeps } from "../src/pipeline.js";
import type { Clients } from "../src/clients.js";
import type { Policy, RuntimeConfig } from "../src/config.js";
import { runAggregate3, topologyOf, type FakeWorld } from "./fakeChain.js";
import { ADDRESSES, MARKET_A, MARKET_B, makeWorld } from "./world.js";

/** Checksummed, because viem refuses to encode an address that is not. */
const FAKE_ROUTER = getAddress("0x000000000000000000000000000000000000a000");

const POLICY: Policy = {
  simulateBlockTag: "pending",
  maxPlanAgeSeconds: 45,
  maxPlanAgeBlocks: 600n,
  quoteSlippageBps: 50n,
  accrualBufferBps: 25n,
};

/**
 * A quote at a configurable distance below the oracle.
 *
 * 8 bps is the default because that is the real measured shortfall for an honest 100k
 * USDC -> wstETH route on Arbitrum at a matched block. Using a round number here would make
 * the test agree with a system tuned for a spread that does not exist.
 */
function fakeQuotes(shortfallBps: bigint, world: FakeWorld): QuoteProvider {
  return {
    name: "fake",
    async quote(request: QuoteRequest): Promise<Quote> {
      const market = world.markets.find(
        (m) =>
          getAddress(m.params.collateralToken) === getAddress(request.tokenOut) ||
          getAddress(m.params.collateralToken) === getAddress(request.tokenIn),
      );
      if (!market || market.price === null) throw new Error("no price for this pair");

      const isIncrease = getAddress(request.tokenIn) === getAddress(world.asset);
      const atOracle = isIncrease
        ? mulDivDown(request.amountIn, ORACLE_PRICE_SCALE, market.price)
        : mulDivDown(request.amountIn, market.price, ORACLE_PRICE_SCALE);

      return {
        to: FAKE_ROUTER,
        data: "0xdeadbeef",
        amountIn: request.amountIn,
        expectedOut: (atOracle * (10_000n - shortfallBps)) / 10_000n,
        source: "fake",
      };
    },
  };
}

interface StubOptions {
  /** Revert data for the `executeActions` simulation. Undefined means it passes. */
  simulationRevert?: Hex;
  /** Seconds to advance the head past the snapshot, to age plans past their budget. */
  ageSeconds?: bigint;
}

function stubClients(world: FakeWorld, options: StubOptions = {}): Clients {
  const publicClient = {
    async call({ to, data }: { to: `0x${string}`; data: Hex }) {
      if (getAddress(to) === getAddress(world.multicall3)) {
        const calls = decodeFunctionData({ abi: multicall3Abi, data }).args?.[0] as never;
        const results = runAggregate3(world, calls);
        return {
          data: encodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", result: results as never }),
        };
      }
      if (getAddress(to) === getAddress(world.vault)) {
        if (options.simulationRevert) {
          const error = new Error("execution reverted") as Error & { data: Hex };
          error.data = options.simulationRevert;
          throw error;
        }
        return { data: "0x" as Hex };
      }
      throw new Error(`stub has no contract at ${to}`);
    },
    async getBlock() {
      const age = options.ageSeconds ?? 0n;
      return { number: world.blockNumber + age, timestamp: world.timestamp + age };
    },
  };

  return { publicClient: publicClient as never, walletClient: undefined, account: undefined };
}

function deps(world: FakeWorld, options: StubOptions = {}, shortfallBps = 8n): PipelineDeps {
  const config = {
    rpcUrl: "http://stub",
    chainId: 42161,
    allocatorKey: undefined,
    multicall3: world.multicall3,
    deployment: { allocator: ADDRESSES.vault } as never,
    policy: POLICY,
    velora: { baseUrl: undefined, partner: undefined, slippageBps: undefined },
  } satisfies Partial<RuntimeConfig> as RuntimeConfig;

  return { clients: stubClients(world, options), config, topology: topologyOf(world), quotes: fakeQuotes(shortfallBps, world) };
}

const INCREASE = {
  kind: "increase" as const,
  marketId: MARKET_A,
  ownAmount: 100_000_000_000n,
  leverage: 2n * 10n ** 18n,
};

const DELEVERAGE = {
  kind: "deleverageTo" as const,
  marketId: MARKET_A,
  targetLeverage: 1_500_000_000_000_000_000n,
};

describe("deleverage", () => {
  /**
   * This mode was unexecutable until the engine was fixed, and the reason is worth keeping.
   *
   * `_planDeleverage` used to set `collateralToWithdraw` to the flashloan's own oracle value,
   * so the collateral sold was worth the debt only AT THE ORACLE. Every real route fills below
   * the oracle, and nothing could make up the difference: the flashloan is taken by
   * GeneralAdapter1 and Morpho reclaims from GeneralAdapter1 synchronously inside the callback,
   * while the sweep of the vault's own balance runs after the flashloan returns. Confirmed on
   * an Arbitrum fork, where seeding GeneralAdapter1 with 1,000 USDC was enough to make an
   * otherwise identical deleverage go through.
   *
   * The engine now grosses the withdrawal up by the market's slippage tolerance and solves for
   * the debt that still lands the position on target once the surplus has left it.
   */
  it("plans, encodes and simulates a 2x -> 1.5x deleverage", async () => {
    const result = await runOnce(deps(makeWorld()), [DELEVERAGE]);
    if (result.outcome === "rejected") throw new Error(`${result.stage}: ${result.reason}`);
    expect(result.outcome).toBe("simulated");
  });

  it("sells more collateral than the repay is worth, by the slippage allowance", async () => {
    const result = await runOnce(deps(makeWorld()), [DELEVERAGE]);
    if (result.outcome !== "simulated") throw new Error(`unexpected ${result.outcome}`);

    const plan = result.batch.plans[0]!;
    if (plan.kind === "increase") throw new Error("expected a decrease plan");

    // Worth strictly more than the reclaim at the oracle, which is the whole point: at the
    // worst fill this market permits the swap still repays.
    const soldAtOracle = plan.swap.oracleExpectedOut;
    expect(soldAtOracle).toBeGreaterThan(plan.flashloanAmount);

    // And the floor the contract will enforce is itself at or above the reclaim.
    expect(plan.swap.minOutFloor).toBeGreaterThanOrEqual(plan.flashloanAmount);
  });
});

describe("runOnce", () => {
  it("plans, quotes, encodes and simulates a 2x increase without submitting", async () => {
    const world = makeWorld();
    const result = await runOnce(deps(world), [INCREASE]);

    if (result.outcome === "rejected") throw new Error(`${result.stage}: ${result.reason}`);
    expect(result.outcome).toBe("simulated");
    if (result.outcome !== "simulated") return;

    const [action] = result.batch.actions;
    expect(result.batch.actions).toHaveLength(1);
    expect(action!.marketId).toBe(MARKET_A);
    expect(action!.isIncrease).toBe(true);
    // The action's amount is the vault's OWN contribution, not the levered total. Getting this
    // backwards would open a 4x position and pass every other check here.
    expect(action!.amount).toBe(INCREASE.ownAmount);
    expect(action!.leverage).toBe(INCREASE.leverage);

    // The route was priced for the levered total, because the executor swaps its whole balance.
    const plan = result.batch.plans[0]!;
    expect(plan.swap.amountIn).toBe(200_000_000_000n);
    expect(result.batch.quotes[0]!.amountIn).toBe(plan.swap.amountIn);

    // minOut never drops below the oracle floor the contract would raise it to anyway.
    expect(action!.minOut).toBeGreaterThanOrEqual(plan.swap.minOutFloor);
    expect(result.batch.projection.worstCaseAssetsAfter).toBeGreaterThanOrEqual(result.batch.projection.floor);
  });

  it("produces calldata that decodes back to the same actions", async () => {
    const world = makeWorld();
    const result = await runOnce(deps(world), [INCREASE]);
    if (result.outcome !== "simulated") throw new Error(`unexpected ${result.outcome}`);

    const decoded = decodeFunctionData({ abi: vaultAbi, data: result.batch.calldata });
    expect(decoded.functionName).toBe("executeActions");
    expect(decoded.args?.[0]).toEqual(result.batch.actions);
  });

  it("reports nothing to do for an empty intent list, having still read state", async () => {
    const result = await runOnce(deps(makeWorld()), []);
    expect(result.outcome).toBe("nothing-to-do");
    expect(result.state.markets.size).toBe(2);
  });

  it("names the plan stage when the market is disabled", async () => {
    const result = await runOnce(deps(makeWorld()), [{ ...INCREASE, marketId: MARKET_B }]);

    expect(result.outcome).toBe("rejected");
    if (result.outcome !== "rejected") return;
    expect(result.stage).toBe("plan");
    expect(result.reason).toMatch(/MarketNotEnabled/);
  });

  it("names the quote stage when the route cannot clear the oracle floor", async () => {
    // The market allows 50 bps. A route 300 bps below the oracle cannot be rescued by sending
    // a lower minOut, because the contract raises whatever we submit up to its own floor.
    const result = await runOnce(deps(makeWorld(), {}, 300n), [INCREASE]);

    expect(result.outcome).toBe("rejected");
    if (result.outcome !== "rejected") return;
    expect(result.stage).toBe("encode");
    expect(result.reason).toMatch(/QuoteBelowOracleFloor/);
  });

  it("names the freshness stage when the clock has moved past the budget", async () => {
    const world = makeWorld();
    const result = await runOnce(deps(world, { ageSeconds: 500n }), [INCREASE]);

    expect(result.outcome).toBe("rejected");
    if (result.outcome !== "rejected") return;
    expect(result.stage).toBe("freshness");
    expect(result.reason).toMatch(/500 seconds old/);
  });

  it("does not reject a plan merely for taking a few seconds to quote", async () => {
    const world = makeWorld();
    const result = await runOnce(deps(world, { ageSeconds: 3n }), [INCREASE]);
    expect(result.outcome).toBe("simulated");
  });

  it("decodes a simulation revert to a named error rather than raw bytes", async () => {
    const world = makeWorld();
    const revert = encodeErrorResult({
      abi: vaultAbi,
      errorName: "TotalAssetsDropped",
      args: [1_000n, 900n, 990n],
    });
    const result = await runOnce(deps(world, { simulationRevert: revert }), [INCREASE]);

    expect(result.outcome).toBe("rejected");
    if (result.outcome !== "rejected") return;
    expect(result.stage).toBe("simulate");
    expect(result.reason).toContain("TotalAssetsDropped");
  });

  it("refuses to plan against a snapshot the reader cannot vouch for", async () => {
    const world = makeWorld();

    // A topology that has fallen behind the chain: it knows about one market, the vault holds
    // two. Every individual read succeeds, so nothing else here would notice; the reader would
    // simply derive a total that silently omits a position.
    const stale = deps(world);
    stale.topology = { ...stale.topology, markets: stale.topology.markets.slice(0, 1) };

    await expect(runOnce(stale, [])).rejects.toThrow(/disagrees with the vault/);
  });
});
