/**
 * @morphoagg/runtime
 *
 * The part that touches the network. `core` mirrors the contract math, `planner` turns intents
 * into calldata, and both are pure; everything with an RPC client in it lives here.
 *
 * The shape worth knowing: state arrives as ONE `eth_call`. A Multicall3 `aggregate3` runs
 * every market's `accrueInterest` first and then every read, so the snapshot is atomic and
 * post-accrual by construction. Building the call list and decoding the response are pure
 * functions in `read/`; only `state.ts` reaches the network.
 */

export {
  DEFAULT_MULTICALL3,
  deploymentPath,
  envSchema,
  loadConfig,
  loadDeployment,
  maxPlanAge,
  type Env,
  type Policy,
  type RuntimeConfig,
} from "./config.js";

export { assertChainMatches, chainFrom, createClients, requireAllocator, type Clients } from "./clients.js";

export {
  buildStateCalls,
  distinctCollateralTokens,
  type MarketLayout,
  type MarketTopology,
  type StateCalls,
  type StateLayout,
  type Topology,
} from "./read/calls.js";

export {
  assertReaderAgreesWithVault,
  checkReaderAgreesWithVault,
  decodeVaultState,
  type ReaderMismatch,
} from "./read/decode.js";

export {
  CallBuilder,
  decodeAggregate3,
  encodeAggregate3,
  erc20Abi,
  multicall3Abi,
  type Multicall3Call,
  type Multicall3Result,
  type Slot,
} from "./read/multicall.js";

export { executeAggregate3, readVaultState, type ReadStateOptions } from "./read/state.js";
export { discoverTopology } from "./read/topology.js";

export {
  assertBatchFresh,
  extractRevertData,
  isTransportFailure,
  simulateExecuteActions,
  StalePlanError,
  type SimulationResult,
} from "./simulate.js";

export {
  ExecutionRevertedError,
  StuckTransactionError,
  submitExecuteActions,
  type SubmitOptions,
  type SubmittedTransaction,
} from "./submit.js";

export {
  prepareBatch,
  runOnce,
  type PipelineDeps,
  type PipelineStage,
  type PreparedBatch,
  type RunOptions,
  type RunResult,
} from "./pipeline.js";

export { backoffFor, startLoop, stopOnSignals, type LoopHandle, type LoopOptions } from "./loop.js";

export {
  describeIntent,
  formatWad,
  intentFileSchema,
  loadIntents,
  parseIntents,
} from "./intentFile.js";
