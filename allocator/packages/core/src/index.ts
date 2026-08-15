/**
 * @morphoagg/core
 *
 * Pure mirrors of the on-chain math, plus the schemas and types shared by every other
 * package. Nothing here performs I/O: every function takes chain state as an argument.
 * That is what lets the golden-vector tests assert the mirror against the contracts'
 * own output, and it keeps every RPC concern in the runtime package.
 */

/**
 * Generated from this repo's own `forge build` artifacts by scripts/gen-abi.ts, and
 * gitignored. If this import fails, run `pnpm --filter @morphoagg/core gen` first: the ABIs
 * are deliberately never committed, so a stale copy cannot drift from the deployed contracts.
 */
export { morphoAbi, oracleAbi, riskLimitsAbi, swapExecutorAbi, vaultAbi } from "./abi/generated/index.js";

export {
  MAX_UINT256,
  ORACLE_PRICE_SCALE,
  SolidityArithmeticError,
  WAD,
  addUint256,
  mulDivDown,
  mulDivUp,
} from "./math/fixed.js";

export {
  VIRTUAL_ASSETS,
  VIRTUAL_SHARES,
  toAssetsDown,
  toAssetsUp,
  toSharesDown,
  toSharesUp,
} from "./math/shares.js";

export {
  dropToleranceFloor,
  healthFactor,
  positionValue,
  surplusAndShortfall,
  totalAssets,
  totalMorphoAssets,
  type PositionInputs,
  type PositionValue,
} from "./valuation.js";

export {
  chainConfigSchema,
  deploymentSchema,
  parseChainConfig,
  parseDeployment,
  type ChainConfig,
  type Deployment,
} from "./config.js";

export {
  FULL_CLOSE,
  type Id,
  type MarketAction,
  type MarketParams,
  type MarketState,
  type Position,
} from "./types.js";
