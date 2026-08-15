/**
 * @morphoagg/planner
 *
 * Turns a strategy's intent into calldata the vault will accept.
 *
 * The pipeline is `plan -> quote -> encode`, and that ordering is forced rather than chosen:
 * `MorphoSwapExecutor` swaps its entire balance while `swapCalldata` hardcodes an amount, so
 * the plan has to compute the exact `amountIn` before anything asks an aggregator for a
 * route. Encode less and the residual is swept to idle; encode more and the router's
 * `transferFrom` fails as an opaque `SwapCallFailed`.
 *
 * `plan` and `encode` are pure. Only the quote step performs I/O.
 *
 * This module currently holds the shared vocabulary: intents, state, and errors. The plan
 * functions themselves land next.
 */

export {
  isRiskIncreasing,
  type CloseFullyIntent,
  type DecreaseByCollateralIntent,
  type DeleverageToIntent,
  type IncreaseIntent,
  type Intent,
} from "./intents.js";

export {
  marketOrThrow,
  type MarketRiskLimits,
  type MarketSnapshot,
  type RiskLimitsSnapshot,
  type VaultState,
} from "./state.js";

export {
  assertPlanFresh,
  encode,
  encodeExecuteActions,
  type EncodeOptions,
} from "./encode.js";

export type { Quote, QuoteProvider, QuoteRequest } from "./quote.js";

export {
  checkBeforeIncrease,
  isIncreasePlan,
  oracleFloor,
  plan,
  planDecrease,
  planDeleverage,
  planIncrease,
  type DecreasePlan,
  type DriftClass,
  type IncreasePlan,
  type Plan,
  type SwapLeg,
} from "./plan/index.js";

export {
  PlannerError,
  decodeVaultError,
  describeFailure,
  describeRevert,
  fail,
  type DecodedRevert,
  type PlannerFailure,
  type PlannerFailureCode,
} from "./errors.js";
