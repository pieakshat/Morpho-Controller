import type { Address } from "viem";

import type { Intent } from "../intents.js";
import type { VaultState } from "../state.js";
import { planDecrease } from "./decrease.js";
import { planDeleverage } from "./deleverage.js";
import { planIncrease } from "./increase.js";
import type { Plan } from "./types.js";

/**
 * Turns one intent into a fully determined Plan, or throws a `PlannerError` naming exactly
 * why the contract would have rejected it.
 *
 * Pure. The `generalAdapter` argument is deployment configuration rather than live state,
 * which is why it is passed rather than read.
 */
export function plan(state: VaultState, intent: Intent, generalAdapter: Address): Plan {
  switch (intent.kind) {
    case "increase":
      return planIncrease(state, intent, generalAdapter);
    case "decreaseByCollateral":
    case "closeFully":
      return planDecrease(state, intent, generalAdapter);
    case "deleverageTo":
      return planDeleverage(state, intent, generalAdapter);
  }
}

export { planDecrease } from "./decrease.js";
export { planDeleverage } from "./deleverage.js";
export { planIncrease } from "./increase.js";
export { checkBeforeIncrease } from "./riskLimits.js";
export { oracleFloor } from "./shared.js";
export { isIncreasePlan, type DecreasePlan, type DriftClass, type IncreasePlan, type Plan, type SwapLeg } from "./types.js";
