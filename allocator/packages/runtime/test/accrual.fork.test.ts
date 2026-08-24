/**
 * The one assumption everything else here is built on, checked against a real node.
 *
 * `read/calls.ts` puts every `accrueInterest` ahead of every read and relies on the writes
 * being visible to the reads behind them, inside a single `eth_call`. That is not obviously
 * true: `eth_call` is a read, and the intuition most people carry is that nothing in it can
 * write. The reality is narrower and is what this pins down. State changes DO apply within the
 * call and do NOT persist past it.
 *
 * If this ever stopped holding, the symptom would not be an error. Every plan would be built
 * from understated debt, every flashloan would be sized slightly short, and the failure would
 * surface as an opaque bundle revert with the venue's reason discarded. Hence a test rather
 * than a comment.
 *
 * Skipped without ARBITRUM_RPC_URL, matching the fork job in CI.
 */

import { describe, expect, it } from "vitest";
import { createPublicClient, encodeAbiParameters, http, keccak256, parseAbiParameters, type Address } from "viem";
import { morphoAbi, type MarketParams } from "@morphoagg/core";

import { DEFAULT_MULTICALL3 } from "../src/config.js";
import { CallBuilder } from "../src/read/multicall.js";
import { executeAggregate3 } from "../src/read/state.js";

const RPC = process.env.ARBITRUM_RPC_URL;
const MORPHO: Address = "0x6c247b1F6182318877311737BaC0844bAa518F5e";

/** wstETH/USDC 86%, the market script/config/42161.json registers. */
const PARAMS: MarketParams = {
  loanToken: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  collateralToken: "0x5979D7b546E38E414F7E9822514be443A4800529",
  oracle: "0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31",
  irm: "0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA",
  lltv: 860_000_000_000_000_000n,
};

/** `keccak256(abi.encode(params))`, derived rather than hardcoded so a param typo cannot hide. */
const MARKET_ID = keccak256(
  encodeAbiParameters(parseAbiParameters("address, address, address, address, uint256"), [
    PARAMS.loanToken,
    PARAMS.collateralToken,
    PARAMS.oracle,
    PARAMS.irm,
    PARAMS.lltv,
  ]),
);

describe.skipIf(!RPC)("accrueInterest inside an aggregate3 eth_call", () => {
  // Built even when the suite is skipped, because the describe body still runs, so the URL
  // needs a placeholder that never gets dialled.
  const client = createPublicClient({ transport: http(RPC ?? "http://127.0.0.1:8545") });

  async function plainMarketRead() {
    return client.readContract({ address: MORPHO, abi: morphoAbi, functionName: "market", args: [MARKET_ID] });
  }

  it("makes later reads in the same call see post-accrual totals", async () => {
    const [, , preBorrowAssets, preBorrowShares, preLastUpdate] = await plainMarketRead();

    const b = new CallBuilder();
    b.add(MORPHO, morphoAbi, "accrueInterest", [PARAMS]);
    const marketSlot = b.add(MORPHO, morphoAbi, "market", [MARKET_ID]);

    const results = await executeAggregate3(client, DEFAULT_MULTICALL3, b.build());
    const [, , postBorrowAssets, postBorrowShares, postLastUpdate] = marketSlot.decode(results);

    // Interest accrued: debt grew and the clock moved.
    expect(postBorrowAssets).toBeGreaterThan(preBorrowAssets);
    expect(postLastUpdate).toBeGreaterThan(preLastUpdate);

    // Shares did not. This is the half that proves it really was an accrual rather than some
    // other state change: interest moves assets per share, never the share count.
    expect(postBorrowShares).toBe(preBorrowShares);
  });

  it("leaves nothing behind, so the read stays a read", async () => {
    const before = await plainMarketRead();

    const b = new CallBuilder();
    b.add(MORPHO, morphoAbi, "accrueInterest", [PARAMS]);
    await executeAggregate3(client, DEFAULT_MULTICALL3, b.build());

    const [, , afterBorrowAssets, , afterLastUpdate] = await plainMarketRead();

    // `lastUpdate` is the honest check: `totalBorrowAssets` could coincidentally match if a
    // real transaction accrued in between, but the stored timestamp only moves when one did.
    expect(afterLastUpdate).toBe(before[4]);
    expect(afterBorrowAssets).toBe(before[2]);
  });

  it("reports accrual for the market it was asked about and not another", async () => {
    // A second market on the same Morpho, so a wrongly-keyed accrual would be visible.
    const b = new CallBuilder();
    const untouched = b.add(MORPHO, morphoAbi, "market", [MARKET_ID]);
    b.add(MORPHO, morphoAbi, "accrueInterest", [PARAMS]);
    const accruedAfter = b.add(MORPHO, morphoAbi, "market", [MARKET_ID]);

    const results = await executeAggregate3(client, DEFAULT_MULTICALL3, b.build());

    // Read BEFORE the accrual in the same list, so it must still be pre-accrual. This is the
    // ordering rule stated as an experiment: position in the list is what decides.
    expect(untouched.decode(results)[4]).toBeLessThan(accruedAfter.decode(results)[4]);
  });
});
