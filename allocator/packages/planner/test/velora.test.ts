/**
 * Tests the Velora adapter against a payload captured live from api.paraswap.io, using the
 * exact caller topology this system has: userAddress = the swap executor, txOrigin = the
 * allocator EOA, receiver = GeneralAdapter1.
 *
 * Recorded rather than invented, because the two things most likely to be wrong here are
 * assumptions about the response shape. Fetch is injected, so the suite stays offline.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import type { QuoteRequest } from "../src/quote.js";
import { createVeloraQuoteProvider, VeloraError } from "../src/velora.js";

const here = dirname(fileURLToPath(import.meta.url));
const fx = JSON.parse(readFileSync(join(here, "fixtures/velora-arbitrum.json"), "utf8")) as {
  request: Record<string, string | number>;
  prices: { priceRoute: Record<string, unknown> };
  transaction: { to: string; data: string; value: string };
};

const REQUEST: QuoteRequest = {
  chainId: 42161,
  tokenIn: fx.request.srcToken as Address,
  tokenOut: fx.request.destToken as Address,
  amountIn: BigInt(fx.request.amountIn as string),
  srcDecimals: fx.request.srcDecimals as number,
  destDecimals: fx.request.destDecimals as number,
  caller: fx.request.caller as Address,
  txOrigin: fx.request.txOrigin as Address,
  recipient: fx.request.recipient as Address,
};

interface Captured {
  priceUrl?: URL;
  txBody?: Record<string, unknown>;
  txUrl?: URL;
}

function replay(overrides: { prices?: unknown; transaction?: unknown; status?: number } = {}) {
  const captured: Captured = {};

  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const isPrices = url.pathname.endsWith("/prices");

    if (overrides.status && overrides.status >= 400) {
      return new Response("upstream said no", { status: overrides.status });
    }

    if (isPrices) {
      captured.priceUrl = url;
      return new Response(JSON.stringify(overrides.prices ?? fx.prices), { status: 200 });
    }
    captured.txUrl = url;
    captured.txBody = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
    return new Response(JSON.stringify(overrides.transaction ?? fx.transaction), { status: 200 });
  }) as unknown as typeof fetch;

  return { captured, provider: createVeloraQuoteProvider({ fetchImpl, maxAttempts: 2, timeoutMs: 500 }) };
}

describe("quoting against the recorded payload", () => {
  it("returns the venue, calldata and amountIn from the real response", async () => {
    const { provider } = replay();
    const q = await provider.quote(REQUEST);

    expect(q.to.toLowerCase()).toBe(fx.transaction.to.toLowerCase());
    expect(q.data).toBe(fx.transaction.data);
    expect(q.amountIn).toBe(REQUEST.amountIn);
    expect(q.source).toBe("velora");
  });

  it("prices off destAmountAfterFee, not destAmount", async () => {
    // The default "anon" partner takes 1 bps, deducted from what actually arrives. Using
    // destAmount would overstate the output and let encode set a minOut the route cannot
    // possibly fill.
    const { provider } = replay();
    const q = await provider.quote(REQUEST);

    const gross = BigInt(fx.prices.priceRoute.destAmount as string);
    const net = BigInt(fx.prices.priceRoute.destAmountAfterFee as string);
    expect(net).toBeLessThan(gross);
    expect(q.expectedOut).toBe(net);
    expect(q.expectedOut).not.toBe(gross);
  });
});

describe("the parameters that are easy to get wrong", () => {
  it("sends txOrigin, because msg.sender is never the transaction sender here", async () => {
    const { captured, provider } = replay();
    await provider.quote(REQUEST);

    expect(captured.txBody?.txOrigin).toBe(REQUEST.txOrigin);
    expect(captured.txBody?.userAddress).toBe(REQUEST.caller);
    expect(captured.txBody?.txOrigin).not.toBe(captured.txBody?.userAddress);
  });

  it("routes output to the recipient, not the caller", async () => {
    // On a decrease with debt this must be GeneralAdapter1: Morpho reclaims the flashloan
    // inside the same call, so proceeds arriving anywhere else are too late.
    const { captured, provider } = replay();
    await provider.quote(REQUEST);

    expect(captured.txBody?.receiver).toBe(REQUEST.recipient);
    expect(captured.priceUrl?.searchParams.get("receiver")).toBe(REQUEST.recipient);
  });

  it("sets ignoreChecks, since the executor holds nothing at quote time", async () => {
    const { captured, provider } = replay();
    await provider.quote(REQUEST);

    expect(captured.txUrl?.searchParams.get("ignoreChecks")).toBe("true");
  });

  it("always quotes SELL side against the exact planned amountIn", async () => {
    const { captured, provider } = replay();
    await provider.quote(REQUEST);

    expect(captured.priceUrl?.searchParams.get("side")).toBe("SELL");
    expect(captured.priceUrl?.searchParams.get("amount")).toBe(REQUEST.amountIn.toString());
    expect(captured.priceUrl?.searchParams.get("version")).toBe("6.2");
    expect(captured.priceUrl?.searchParams.get("network")).toBe("42161");
  });

  it("passes the priceRoute back verbatim, since it is HMAC-signed", async () => {
    const { captured, provider } = replay();
    await provider.quote(REQUEST);

    expect(captured.txBody?.priceRoute).toEqual(fx.prices.priceRoute);
    expect((captured.txBody?.priceRoute as Record<string, unknown>).hmac).toBeDefined();
  });
});

describe("refusals", () => {
  it("rejects a route priced for a different amount than requested", async () => {
    const tampered = { priceRoute: { ...fx.prices.priceRoute, srcAmount: "999" } };
    const { provider } = replay({ prices: tampered });
    await expect(provider.quote(REQUEST)).rejects.toThrow(/route is for srcAmount 999/);
  });

  it("rejects an amount that arrives as a JSON number", async () => {
    // A number has already lost precision by the time it parses, so accepting one would
    // silently corrupt a wei value instead of failing.
    const lossy = {
      priceRoute: { ...fx.prices.priceRoute, destAmountAfterFee: 42877861410430953918, destAmount: undefined },
    };
    const { provider } = replay({ prices: lossy });
    await expect(provider.quote(REQUEST)).rejects.toThrow(/decimal string/);
  });

  it("rejects a route that needs native value, which the executor cannot forward", async () => {
    const { provider } = replay({ transaction: { ...fx.transaction, value: "1000" } });
    await expect(provider.quote(REQUEST)).rejects.toThrow(/native value/);
  });

  it("rejects a response with no priceRoute", async () => {
    const { provider } = replay({ prices: {} });
    await expect(provider.quote(REQUEST)).rejects.toThrow(/no priceRoute/);
  });

  it("gives up after the retry budget on a persistent 503", async () => {
    const { provider } = replay({ status: 503 });
    await expect(provider.quote(REQUEST)).rejects.toThrow(/gave up after 2 attempts/);
  });

  it("does not retry a 400, which is a real answer rather than a blip", async () => {
    let calls = 0;
    const fetchImpl = (async () => {
      calls++;
      return new Response("bad request", { status: 400 });
    }) as unknown as typeof fetch;

    const provider = createVeloraQuoteProvider({ fetchImpl, maxAttempts: 4 });
    await expect(provider.quote(REQUEST)).rejects.toThrow(VeloraError);
    expect(calls).toBe(1);
  });
});
