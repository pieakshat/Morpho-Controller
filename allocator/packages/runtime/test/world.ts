/**
 * A two-market world used by every offline test here.
 *
 * Two markets rather than one, sharing neither collateral nor oracle, because most of what
 * the state reader can get wrong is cross-market: market A's position paired with market B's
 * totals, one collateral cap read twice, or a layout offset that happens to work with a single
 * market and falls apart with two.
 *
 * Numbers are USDC-scaled (6dp) against an 18dp collateral, matching the real deployment. The
 * awkward decimal pairing is deliberate: a bug that cancels out at matching decimals does not.
 */

import type { Id, MarketParams } from "@morphoagg/core";
import { getAddress, type Address } from "viem";

import type { FakeMarket, FakeWorld } from "./fakeChain.js";

const a = (n: number): Address => getAddress(`0x${n.toString(16).padStart(40, "0")}`);
const id = (n: number): Id => `0x${n.toString(16).padStart(64, "0")}`;

export const ADDRESSES = {
  vault: a(0x1001),
  asset: a(0x1002),
  riskLimits: a(0x1003),
  swapExecutor: a(0x1004),
  morpho: a(0x1005),
  generalAdapter1: a(0x1006),
  multicall3: a(0x1007),
  wstETH: a(0x2001),
  wbtc: a(0x2002),
  oracleA: a(0x3001),
  oracleB: a(0x3002),
  irm: a(0x4001),
} as const;

export const MARKET_A = id(0xaaaa);
export const MARKET_B = id(0xbbbb);

function params(collateralToken: Address, oracle: Address, lltv: bigint): MarketParams {
  return { loanToken: ADDRESSES.asset, collateralToken, oracle, irm: ADDRESSES.irm, lltv };
}

/** 1e36-scaled, and for a 6dp loan token against an 18dp collateral. ~4,000 USDC per unit. */
const PRICE_A = 4_000n * 10n ** 24n;
/** ~90,000 USDC per unit. */
const PRICE_B = 90_000n * 10n ** 24n;

function market(overrides: Partial<FakeMarket> & Pick<FakeMarket, "id" | "params">): FakeMarket {
  return {
    collateralDecimals: 18,
    position: { supplyShares: 0n, borrowShares: 0n, collateral: 0n },
    preAccrual: {
      totalSupplyAssets: 10_000_000_000_000n,
      totalSupplyShares: 10_000_000_000_000n * 10n ** 6n,
      totalBorrowAssets: 6_000_000_000_000n,
      totalBorrowShares: 6_000_000_000_000n * 10n ** 6n,
      lastUpdate: 1_800_000_000n,
      fee: 0n,
    },
    pendingInterest: 0n,
    price: PRICE_A,
    config: { maxLeverage: 5n * 10n ** 18n, maxSlippageBps: 50n, enabled: true },
    limits: {
      minHealthFactor: 1_150_000_000_000_000_000n,
      maxPriceDeviationBps: 500n,
      maxExposureChangePerWindow: 2_000_000_000_000n,
      windowStart: 1_799_000_000n,
      windowExposureChange: 0n,
      lastObservedPrice: PRICE_A,
      lastObservedAt: 1_799_900_000n,
    },
    ...overrides,
  };
}

export function makeWorld(overrides: Partial<FakeWorld> = {}): FakeWorld {
  const markets: FakeMarket[] = [
    market({
      id: MARKET_A,
      params: params(ADDRESSES.wstETH, ADDRESSES.oracleA, 860_000_000_000_000_000n),
      // 250 wstETH of collateral against 500k of debt: roughly 2x on a 1M position.
      position: { supplyShares: 0n, borrowShares: 500_000_000_000n * 10n ** 6n, collateral: 250n * 10n ** 18n },
      // A full day of interest at the market's own rate, so post-accrual debt is visibly
      // larger than stored debt and reading in the wrong order cannot pass by luck.
      pendingInterest: 1_200_000_000n,
      price: PRICE_A,
    }),
    market({
      id: MARKET_B,
      params: params(ADDRESSES.wbtc, ADDRESSES.oracleB, 800_000_000_000_000_000n),
      position: { supplyShares: 0n, borrowShares: 200_000_000_000n * 10n ** 6n, collateral: 5n * 10n ** 18n },
      pendingInterest: 400_000_000n,
      price: PRICE_B,
      config: { maxLeverage: 3n * 10n ** 18n, maxSlippageBps: 80n, enabled: false },
      limits: {
        minHealthFactor: 1_200_000_000_000_000_000n,
        maxPriceDeviationBps: 300n,
        maxExposureChangePerWindow: 1_000_000_000_000n,
        windowStart: 1_799_500_000n,
        windowExposureChange: 250_000_000_000n,
        lastObservedPrice: PRICE_B,
        lastObservedAt: 1_799_950_000n,
      },
    }),
  ];

  return {
    ...ADDRESSES,
    blockNumber: 500_000_000n,
    timestamp: 1_800_000_828n,
    idle: 750_000_000_000n,
    actionDropToleranceBps: 100n,
    paused: false,
    maxAggregateDebt: 5_000_000_000_000n,
    maxSlippageBpsCeiling: 100n,
    rateLimitWindowSeconds: 86_400n,
    priceObservationMaxAge: 86_400n,
    maxAssetExposure: new Map<Address, bigint>([
      [ADDRESSES.wstETH, 8_000_000_000_000n],
      [ADDRESSES.wbtc, 3_000_000_000_000n],
    ]),
    markets,
    ...overrides,
  };
}
