import { ORACLE_PRICE_SCALE, dropToleranceFloor, mulDivDown, type Id, type MarketAction } from "@morphoagg/core";
import type { Address } from "viem";

import { fail } from "./errors.js";
import type { Intent } from "./intents.js";
import { plan } from "./plan/index.js";
import type { Plan } from "./plan/types.js";
import { requireMarket } from "./plan/shared.js";
import type { VaultState } from "./state.js";

/**
 * Planning a batch is not planning each action and concatenating the results.
 *
 * `executeActions` runs its array in order against shared state, and the vault documents the
 * pattern it exists for: a decrease on one market funding an increase on another inside one
 * transaction. That only works if the later increase can see the idle balance the earlier
 * decrease produced, so idle has to be threaded through the sequence rather than read once.
 *
 * The value guard is batch-wide for the same reason. `actionDropToleranceBps` is measured
 * across the whole call, so several legs that each clear their own oracle floor can still
 * add up to a breach that no per-action check would catch.
 */

export interface BatchOptions {
  /**
   * Whether a decrease's proceeds count toward funding a later increase.
   *
   * On by default, because that is the composition the contract exists to support. Turning
   * it off plans every action against the starting idle balance, which is stricter than
   * reality and occasionally what you want when the batch may be split.
   */
  creditDecreaseProceeds?: boolean;
}

export interface BatchProjection {
  assetsBefore: bigint;
  /**
   * Value destroyed if EVERY leg fills exactly at its oracle floor.
   *
   * Deliberately pessimistic. Real quotes are better than the floor, so a batch that clears
   * this is safe under any fill the contract will accept, and one that does not is merely
   * unproven rather than doomed.
   */
  worstCaseLoss: bigint;
  worstCaseAssetsAfter: bigint;
  /** `assetsBefore * (10_000 - dropToleranceBps) / 10_000`, as the contract computes it. */
  floor: bigint;
  clearsWorstCase: boolean;
}

export interface BatchPlan {
  plans: Plan[];
  projection: BatchProjection;
  /** Idle remaining once every leg has settled, on the conservative accounting below. */
  projectedIdle: bigint;
}

/**
 * Plans a sequence of intents against one state snapshot.
 *
 * Throws a `PlannerError` for anything the contract would reject. Does NOT throw when only
 * the worst-case projection breaches the drop tolerance: that figure assumes every swap fills
 * at its floor, which real quotes beat. Check `projection.clearsWorstCase`, and re-check with
 * `projectEncodedBatch` once actions carry real minOuts.
 */
export function planBatch(
  state: VaultState,
  intents: readonly Intent[],
  generalAdapter: Address,
  options: BatchOptions = {},
): BatchPlan {
  const creditProceeds = options.creditDecreaseProceeds ?? true;

  // Two actions on one market would need the position itself threaded, not just idle: the
  // second would have to see the collateral and debt the first left behind, which means
  // mirroring how Morpho converts a repay into shares mid-batch. Refusing is honest; silently
  // planning the second against stale position state would not be.
  const seen = new Set<Id>();
  for (const intent of intents) {
    if (seen.has(intent.marketId)) fail({ code: "DuplicateMarketInBatch", marketId: intent.marketId });
    seen.add(intent.marketId);
  }

  const plans: Plan[] = [];
  let idle = state.idle;
  let worstCaseLoss = 0n;

  for (const intent of intents) {
    // Only idle moves between steps. Positions and market totals cannot, given the
    // one-action-per-market rule above.
    const stepState: VaultState = { ...state, idle };
    const p = plan(stepState, intent, generalAdapter);
    plans.push(p);

    idle += idleDelta(p, creditProceeds);
    worstCaseLoss += worstCaseLegLoss(state, p);
  }

  const assetsBefore = state.totalAssets;
  const worstCaseAssetsAfter = assetsBefore > worstCaseLoss ? assetsBefore - worstCaseLoss : 0n;
  const floor = dropToleranceFloor(assetsBefore, state.actionDropToleranceBps);

  return {
    plans,
    projectedIdle: idle,
    projection: {
      assetsBefore,
      worstCaseLoss,
      worstCaseAssetsAfter,
      floor,
      clearsWorstCase: worstCaseAssetsAfter >= floor,
    },
  };
}

/**
 * Re-projects a batch using the minOuts real quotes produced, and refuses one that would trip
 * the contract's guard.
 *
 * This is the check worth gating on. `planBatch`'s worst case is a lower bound on quality;
 * this is what the transaction will actually be judged against.
 */
export function projectEncodedBatch(
  state: VaultState,
  plans: readonly Plan[],
  actions: readonly MarketAction[],
): BatchProjection {
  if (plans.length !== actions.length) {
    throw new Error(`projectEncodedBatch: ${plans.length} plans against ${actions.length} actions`);
  }

  let loss = 0n;
  for (let i = 0; i < plans.length; i++) {
    loss += legLoss(state, plans[i]!, actions[i]!.minOut);
  }

  const assetsBefore = state.totalAssets;
  const projected = assetsBefore > loss ? assetsBefore - loss : 0n;
  const floor = dropToleranceFloor(assetsBefore, state.actionDropToleranceBps);

  if (projected < floor) fail({ code: "TotalAssetsDropBelowFloor", before: assetsBefore, projected, floor });

  return {
    assetsBefore,
    worstCaseLoss: loss,
    worstCaseAssetsAfter: projected,
    floor,
    clearsWorstCase: true,
  };
}

/*//////////////////////////////////////////////////////////////
                            INTERNALS
//////////////////////////////////////////////////////////////*/

/**
 * How the vault's idle balance moves across one leg.
 *
 * Increase: the own contribution is transferred out to GeneralAdapter1 before the flashloan.
 * The borrowed portion never touches idle.
 *
 * Decrease: the swap proceeds land on GeneralAdapter1, Morpho reclaims the flashloan, and the
 * outer sweep returns the remainder to the vault. So idle gains output minus repay. Valued at
 * the oracle FLOOR rather than the expected output, because over-estimating idle here would
 * let a later increase be planned against money that may not arrive.
 */
function idleDelta(p: Plan, creditProceeds: boolean): bigint {
  if (p.kind === "increase") return -p.ownAmount;
  if (!creditProceeds) return 0n;

  const returned = p.swap.minOutFloor > p.flashloanAmount ? p.swap.minOutFloor - p.flashloanAmount : 0n;
  return returned;
}

/** Worst case: the leg fills exactly at the oracle floor the contract would enforce. */
function worstCaseLegLoss(state: VaultState, p: Plan): bigint {
  return legLoss(state, p, p.swap.minOutFloor);
}

/**
 * Value destroyed by one leg, in ASSET terms, if the swap delivers exactly `minOut`.
 *
 * Both directions reduce to the same thing, which is worth seeing: an action is value-neutral
 * apart from what the swap gives up against the oracle.
 *
 * Increase — spends `totalAmount` of loan token and receives collateral worth
 * `minOut * price / 1e36`, so the loss is the difference. The borrow cancels: it adds debt and
 * an equal amount of purchasing power.
 *
 * Decrease — gives up collateral worth `oracleExpectedOut` and receives `minOut` of loan
 * token, both already in ASSET terms, so the loss is again the difference.
 */
function legLoss(state: VaultState, p: Plan, minOut: bigint): bigint {
  if (p.kind === "increase") {
    const price = requireMarket(state, p.marketId).price;
    // Unreachable in practice: planIncrease refuses a market with no price.
    if (price === null) return p.totalAmount;
    const received = mulDivDown(minOut, price, ORACLE_PRICE_SCALE);
    return p.totalAmount > received ? p.totalAmount - received : 0n;
  }

  return p.swap.oracleExpectedOut > minOut ? p.swap.oracleExpectedOut - minOut : 0n;
}
