/**
 * Captures a live Velora payload into test/fixtures/velora-arbitrum.json.
 *
 * The fixture backs two tests that cannot both be satisfied by an invented payload:
 * `test/velora.test.ts` replays it offline to pin the adapter against the real response shape,
 * and `test/fork/VeloraRoute.t.sol` executes the recorded calldata against the real Augustus
 * router on a fork.
 *
 * The second one is why the block matters. A DEX route encodes specific pools and is only
 * valid against the state it was priced on, so the payload and its block travel together:
 * after running this, set QUOTE_BLOCK in VeloraRoute.t.sol to the priceRoute's own
 * blockNumber, which is printed at the end.
 *
 * RECEIVER IS THE SWAP EXECUTOR, not GeneralAdapter1, and that is the whole reason this script
 * exists. `MorphoSwapExecutor.executeSwap` enforces minOut against its OWN balance delta and
 * only then forwards to the recipient the engine hardcodes. A route paying GeneralAdapter1
 * directly leaves that delta at zero, so the bundle reverts SlippageExceeded(0, minOut) with
 * the tokens already delivered somewhere the check cannot see them. The previous fixture named
 * GeneralAdapter1 and therefore recorded a topology the vault rejects.
 *
 *   pnpm --filter @morphoagg/planner capture:velora
 */

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const BASE_URL = process.env.VELORA_BASE_URL ?? "https://api.paraswap.io";
const PARTNER = process.env.VELORA_PARTNER ?? "anon";
const VERSION = "6.2";
const SLIPPAGE_BPS = 100;

const CHAIN_ID = 42161;
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const WSTETH = "0x5979D7b546E38E414F7E9822514be443A4800529";
const AMOUNT_IN = "100000000000"; // 100,000 USDC

/**
 * The vault's own swap executor, as deployed by an anvil run of script/Deploy.s.sol, and the
 * allocator anvil key. Nothing here has to be a live deployment: the fork test deals tokens to
 * `caller` and pranks as it. What matters is that caller and receiver are the SAME address,
 * because that is the topology the engine actually produces.
 */
const SWAP_EXECUTOR = "0xE3Dafc650Ff44A5ed2E7cB9e875145daeE0f4Dbe";
const ALLOCATOR = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

async function main(): Promise<void> {
  const priceQuery = new URLSearchParams({
    srcToken: USDC,
    destToken: WSTETH,
    amount: AMOUNT_IN,
    srcDecimals: "6",
    destDecimals: "18",
    side: "SELL",
    network: String(CHAIN_ID),
    version: VERSION,
    userAddress: SWAP_EXECUTOR,
    receiver: SWAP_EXECUTOR,
    partner: PARTNER,
  });

  console.log("GET /prices ...");
  const pricesRes = await fetch(`${BASE_URL}/prices?${priceQuery}`);
  if (!pricesRes.ok) throw new Error(`prices: HTTP ${pricesRes.status} ${await pricesRes.text()}`);
  const prices = (await pricesRes.json()) as { priceRoute?: Record<string, unknown> };
  if (!prices.priceRoute) throw new Error("prices response had no priceRoute");

  // ignoreChecks because at quote time the executor holds nothing and has approved nothing:
  // tokens only reach it mid-bundle. Velora's balance and allowance checks would reject a
  // route that is perfectly valid. Not silencing a real warning, it is the only way to price
  // a swap that has not been funded yet.
  console.log("POST /transactions ...");
  const txRes = await fetch(`${BASE_URL}/transactions/${CHAIN_ID}?ignoreChecks=true&ignoreGasEstimate=true`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      srcToken: USDC,
      destToken: WSTETH,
      srcAmount: AMOUNT_IN,
      srcDecimals: 6,
      destDecimals: 18,
      slippage: SLIPPAGE_BPS,
      userAddress: SWAP_EXECUTOR,
      txOrigin: ALLOCATOR,
      receiver: SWAP_EXECUTOR,
      partner: PARTNER,
      priceRoute: prices.priceRoute,
    }),
  });
  if (!txRes.ok) throw new Error(`transactions: HTTP ${txRes.status} ${await txRes.text()}`);
  const transaction = (await txRes.json()) as Record<string, unknown>;

  const fixture = {
    _comment:
      "Captured live from api.paraswap.io on Arbitrum for 100,000 USDC -> wstETH by " +
      "scripts/capture-velora.ts. receiver == caller == the vault's swap executor, which is " +
      "the topology the engine produces: executeSwap enforces minOut against its own balance " +
      "delta and only then forwards to GeneralAdapter1. Regenerate with " +
      "`pnpm --filter @morphoagg/planner capture:velora`, then set QUOTE_BLOCK in " +
      "test/fork/VeloraRoute.t.sol to prices.priceRoute.blockNumber below.",
    request: {
      chainId: CHAIN_ID,
      srcToken: USDC,
      destToken: WSTETH,
      amountIn: AMOUNT_IN,
      srcDecimals: 6,
      destDecimals: 18,
      caller: SWAP_EXECUTOR,
      txOrigin: ALLOCATOR,
      recipient: SWAP_EXECUTOR,
    },
    prices,
    transaction,
  };

  const out = join(dirname(fileURLToPath(import.meta.url)), "../test/fixtures/velora-arbitrum.json");
  writeFileSync(out, `${JSON.stringify(fixture, null, 2)}\n`);

  const route = prices.priceRoute;
  console.log(`\nwrote ${out}`);
  console.log(`  blockNumber          ${String(route.blockNumber)}   <- set QUOTE_BLOCK to this`);
  console.log(`  destAmount           ${String(route.destAmount)}`);
  console.log(`  destAmountAfterFee   ${String(route.destAmountAfterFee)}`);
  console.log(`  receiver             ${SWAP_EXECUTOR} (== caller)`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
