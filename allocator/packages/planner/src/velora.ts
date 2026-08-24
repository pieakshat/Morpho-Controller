import type { Address, Hex } from "viem";

import type { Quote, QuoteProvider, QuoteRequest } from "./quote.js";

/**
 * Velora (formerly ParaSwap) quote provider.
 *
 * Chosen because Morpho's own Multiply feature routes through it, so it is known to work with
 * this bundle shape. Two of its parameters matter more here than they would elsewhere, and
 * both were confirmed against the live API rather than inferred:
 *
 * `txOrigin`. Velora requires it whenever `msg.sender` differs from the transaction sender.
 * For this system they always differ: the allocator EOA sends to the vault, and four hops
 * later `MorphoSwapExecutor` is what calls the router. Omitting it produces calldata that
 * reverts at execution.
 *
 * `ignoreChecks`. At quote time the executor holds nothing and has approved nothing, because
 * tokens only reach it mid-bundle. Velora's balance, allowance and simulation checks would
 * therefore all fail on a route that is perfectly valid. This is not a way of silencing a
 * real warning; it is the only way to price a swap that has not been funded yet.
 */

const DEFAULTS = {
  baseUrl: "https://api.paraswap.io",
  version: "6.2",
  slippageBps: 100,
  timeoutMs: 10_000,
  maxAttempts: 4,
  partner: "anon",
} as const;

/** Transient by nature: worth another attempt. Anything else is a real answer. */
const RETRYABLE_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);

export interface VeloraOptions {
  /**
   * Overridable because of the ParaSwap to Velora rebrand: `api.paraswap.io` is what
   * currently answers, and the host may move.
   */
  baseUrl?: string;
  /**
   * Slippage in bps sent to Velora, used only for its own internal bound inside the calldata.
   * Distinct from the `minOut` this system enforces, which `encode` derives and the vault
   * checks on-chain. Kept loose here on purpose: the binding constraint should be ours.
   */
  slippageBps?: number;
  /**
   * Partner tag. The default "anon" charges 1 bps, already reflected in `destAmountAfterFee`
   * and therefore in the `expectedOut` returned below.
   */
  partner?: string;
  timeoutMs?: number;
  maxAttempts?: number;
  /** Injected so tests can replay recorded payloads instead of reaching the network. */
  fetchImpl?: typeof fetch;
}

export class VeloraError extends Error {
  constructor(
    readonly stage: "prices" | "transactions",
    readonly status: number | null,
    message: string,
  ) {
    super(`velora ${stage}: ${message}`);
    this.name = "VeloraError";
  }
}

export function createVeloraQuoteProvider(options: VeloraOptions = {}): QuoteProvider {
  const baseUrl = (options.baseUrl ?? DEFAULTS.baseUrl).replace(/\/$/, "");
  const slippageBps = options.slippageBps ?? DEFAULTS.slippageBps;
  const partner = options.partner ?? DEFAULTS.partner;
  const timeoutMs = options.timeoutMs ?? DEFAULTS.timeoutMs;
  const maxAttempts = options.maxAttempts ?? DEFAULTS.maxAttempts;
  const doFetch = options.fetchImpl ?? globalThis.fetch;

  async function request(stage: "prices" | "transactions", url: string, init?: RequestInit): Promise<unknown> {
    let lastError = "";

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        // 300ms, 900ms, 2700ms, each jittered +/-30% so retries from parallel legs do not
        // land in lockstep.
        const base = 300 * 3 ** (attempt - 1);
        await sleep(base * (0.7 + Math.random() * 0.6));
      }

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const res = await doFetch(url, { ...init, signal: controller.signal });
        if (res.ok) return await res.json();

        const body = await res.text().catch(() => "");
        lastError = `HTTP ${res.status} ${body.slice(0, 200)}`;
        if (!RETRYABLE_STATUS.has(res.status)) throw new VeloraError(stage, res.status, lastError);
      } catch (e) {
        if (e instanceof VeloraError) throw e;
        lastError = e instanceof Error ? e.message : String(e);
      } finally {
        clearTimeout(timer);
      }
    }

    throw new VeloraError(stage, null, `gave up after ${maxAttempts} attempts: ${lastError}`);
  }

  return {
    name: "velora",

    async quote(req: QuoteRequest): Promise<Quote> {
      const priceQuery = new URLSearchParams({
        srcToken: req.tokenIn,
        destToken: req.tokenOut,
        amount: req.amountIn.toString(),
        srcDecimals: String(req.srcDecimals),
        destDecimals: String(req.destDecimals),
        // Always SELL: the plan fixes amountIn exactly, and BUY would let the router choose
        // an input amount that no longer matches what the bundle transfers.
        side: "SELL",
        network: String(req.chainId),
        version: DEFAULTS.version,
        userAddress: req.caller,
        receiver: req.recipient,
        partner,
      });

      const priced = (await request("prices", `${baseUrl}/prices?${priceQuery}`)) as {
        priceRoute?: Record<string, unknown>;
      };
      const priceRoute = priced.priceRoute;
      if (!priceRoute) throw new VeloraError("prices", null, "response had no priceRoute");

      // The route is HMAC-signed and must be echoed back verbatim, so it is never rebuilt or
      // trimmed here.
      const srcAmount = readAmount("prices", priceRoute, "srcAmount");
      if (srcAmount !== req.amountIn) {
        throw new VeloraError("prices", null, `route is for srcAmount ${srcAmount}, requested ${req.amountIn}`);
      }

      // destAmountAfterFee, NOT destAmount. The partner fee (1 bps on the default "anon" tag)
      // is deducted from what actually arrives, so pricing off destAmount overstates the
      // output and can push minOut above anything the route can deliver.
      const expectedOut = readAmount("prices", priceRoute, "destAmountAfterFee", "destAmount");

      const built = (await request(
        "transactions",
        `${baseUrl}/transactions/${req.chainId}?ignoreChecks=true&ignoreGasEstimate=true`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            srcToken: req.tokenIn,
            destToken: req.tokenOut,
            srcAmount: req.amountIn.toString(),
            srcDecimals: req.srcDecimals,
            destDecimals: req.destDecimals,
            slippage: slippageBps,
            userAddress: req.caller,
            txOrigin: req.txOrigin,
            receiver: req.recipient,
            partner,
            priceRoute,
          }),
        },
      )) as { to?: string; data?: string; value?: string };

      if (!built.to || !built.data) {
        throw new VeloraError("transactions", null, "response had no to/data");
      }
      // The executor cannot forward value: it only ever moves ERC20s. A non-zero requirement
      // means the route is not usable here.
      if (built.value && built.value !== "0") {
        throw new VeloraError("transactions", null, `route requires ${built.value} native value`);
      }

      return {
        to: built.to as Address,
        data: built.data as Hex,
        amountIn: req.amountIn,
        expectedOut,
        source: "velora",
      };
    },
  };
}

/**
 * Amounts must arrive as strings.
 *
 * A JSON number has already lost precision by the time it is parsed, so accepting one would
 * silently corrupt a wei value rather than fail. Velora returns strings; this asserts it
 * rather than assuming it.
 */
function readAmount(
  stage: "prices" | "transactions",
  obj: Record<string, unknown>,
  key: string,
  fallbackKey?: string,
): bigint {
  const raw = obj[key] ?? (fallbackKey ? obj[fallbackKey] : undefined);
  if (typeof raw !== "string" || !/^\d+$/.test(raw)) {
    throw new VeloraError(stage, null, `expected ${key} as a decimal string, got ${JSON.stringify(raw)}`);
  }
  return BigInt(raw);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
