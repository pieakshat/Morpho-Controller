// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Id, MarketParams} from "../interfaces/IMorpho.sol";

/// @notice A single market this adapter is permitted to hold a position in.
/// @dev Lives in the registry (whitelist), managed by the allocator/owner — not per-action.
///      Leverage is a property of the market strategy, not a one-off instruction.
struct MorphoMarketConfig {
    /// @dev The real Morpho market this config describes. Its Id is derivable from this —
    ///      keccak256(abi.encode(params)) — we don't store the Id redundantly.
    MarketParams params;
    /// @notice 1e18 = plain seeding (no debt). Anything above 1e18 = leveraged via flashloan looping.
    uint256 targetLeverage;
    /// @notice The whitelist gate. Allocator can only act on a market where this is true —
    ///         bounds blast radius if the allocator key is ever compromised.
    bool enabled;
}

/// @notice One instruction within a rebalance call, touching exactly one market.
/// @dev Flat and typed on purpose — we don't have Blend's cross-contract opacity constraint
///      (their StrategyManager doesn't know what their SwapAdapter needs; ours is one
///      self-contained system), so there's no reason to nest abi.encode calls inside bytes.
struct MarketAction {
    /// @notice Must match an enabled MorphoMarketConfig's computed Id.
    Id marketId;
    /// @notice true = increase this market's position, false = decrease it.
    bool isIncrease;
    /// @notice Amount for this leg, in whichever token the operation naturally denominates in.
    uint256 amount;
    /// @notice Our own oracle-independent slippage floor for this leg's swap, if any.
    uint256 minOut;
    /// @notice Swap venue for this leg. address(0) if this leg needs no swap.
    address swapTarget;
    /// @notice Calldata for swapTarget, if swapTarget != address(0).
    bytes swapCalldata;
}
