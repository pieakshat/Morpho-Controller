/**
 * Startup discovery: the facts that do not change while the process runs.
 *
 * Two round trips, sequentially, and they cannot be merged: the second needs the collateral
 * token addresses that the first returns. Both happen once at boot, so the cost is
 * irrelevant; the per-tick read in `state.ts` stays a single call, which is the one that
 * matters.
 *
 * Market registration is owner-only and decimals are immutable, so nothing here is worth
 * re-reading in the loop. The accepted consequence: a market registered while the process is
 * running stays invisible until restart. For something holding a hot key that is the right
 * default, since it means the set of markets the allocator can touch is fixed at a moment an
 * operator chose.
 */

import { morphoAbi, vaultAbi, type Id, type MarketParams } from "@morphoagg/core";
import { type Address, type PublicClient } from "viem";

import type { RuntimeConfig } from "../config.js";
import type { MarketTopology, Topology } from "./calls.js";
import { CallBuilder, erc20Abi } from "./multicall.js";
import { executeAggregate3 } from "./state.js";

export async function discoverTopology(
  publicClient: PublicClient,
  config: RuntimeConfig,
): Promise<Topology> {
  const { vault, asset, riskLimits, swapExecutor, morpho, generalAdapter1 } = config.deployment;

  // Pass 1: which markets exist, and what their params are.
  //
  // `registeredMarkets()` rather than `activeMarkets()`. Active means "currently holds a
  // position", which is exactly the set that changes underneath a long-running process.
  // Registered is the owner-controlled whitelist, and it is also the set a strategy may want
  // to OPEN into, which by definition is not active yet.
  const ids = (await publicClient.readContract({
    address: vault,
    abi: vaultAbi,
    functionName: "registeredMarkets",
  })) as readonly Id[];

  if (ids.length === 0) {
    throw new Error(`vault ${vault} has no registered markets; run script/RegisterMarket.s.sol first`);
  }

  const paramsCalls = new CallBuilder();
  const paramsSlots = ids.map((id) => paramsCalls.add(morpho, morphoAbi, "idToMarketParams", [id]));
  const assetDecimalsSlot = paramsCalls.add(asset, erc20Abi, "decimals", []);

  const pass1 = await executeAggregate3(publicClient, config.multicall3, paramsCalls.build());
  const params = paramsSlots.map((s) => s.decode(pass1) as MarketParams);
  const assetDecimals = assetDecimalsSlot.decode(pass1);

  // A registered id whose Morpho entry is empty means the id was computed from params that do
  // not describe a real market. That cannot happen through `registerMarket`, which checks
  // `lastUpdate != 0`, but it is cheap to notice here rather than as an inscrutable revert.
  params.forEach((p, i) => {
    if (p.loanToken === ZERO_ADDRESS) {
      throw new Error(`market ${ids[i]} is registered on the vault but unknown to Morpho at ${morpho}`);
    }
    if (p.loanToken !== asset) {
      throw new Error(
        `market ${ids[i]} has loanToken ${p.loanToken}, but the vault's asset is ${asset}; ` +
          `the deployment record and the chain disagree`,
      );
    }
  });

  // Pass 2: decimals for each distinct collateral token, needed by the quote layer.
  const collaterals = [...new Set(params.map((p) => p.collateralToken))];
  const decCalls = new CallBuilder();
  const decSlots = collaterals.map((t) => ({ token: t, slot: decCalls.add(t, erc20Abi, "decimals", []) }));
  const pass2 = await executeAggregate3(publicClient, config.multicall3, decCalls.build());

  const decimalsByToken = new Map<Address, number>();
  for (const { token, slot } of decSlots) decimalsByToken.set(token, slot.decode(pass2));

  const markets: MarketTopology[] = ids.map((id, i) => {
    const p = params[i];
    if (!p) throw new Error(`missing params for market ${id}`);
    const collateralDecimals = decimalsByToken.get(p.collateralToken);
    if (collateralDecimals === undefined) throw new Error(`missing decimals for ${p.collateralToken}`);
    return { id, params: p, collateralDecimals };
  });

  return { vault, asset, assetDecimals, riskLimits, swapExecutor, morpho, generalAdapter1, markets };
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
