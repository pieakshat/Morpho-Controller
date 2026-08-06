// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Id, MarketParams} from "../interfaces/IMorpho.sol";

/// @notice A single market this adapter is permitted to hold a position in.
/// @dev Lives in the registry (whitelist), managed by the allocator/owner — not per-action.
///      The actual leverage used for a given increase is chosen by the allocator per call
///      (see MarketAction.leverage) and only capped here.
struct MorphoMarketConfig {
    /// @dev The real Morpho market this config describes. Its Id is derivable from this —
    ///      keccak256(abi.encode(params)) — we don't store the Id redundantly.
    MarketParams params;
    /// @notice Ceiling on the leverage any single increase into this market may request.
    ///         1e18 = no leverage above 1x is ever allowed here.
    uint256 maxLeverage;
    /// @notice The whitelist gate — the allocator can only act on a market where this is true.
    bool enabled;
}

/// @notice One instruction within a rebalance call, touching exactly one market.
/// @dev Flat and typed on purpose — this is one self-contained system, so there's no
///      reason to nest abi.encode calls inside opaque bytes just to cross a module boundary.
struct MarketAction {
    /// @notice Must match an enabled MorphoMarketConfig's computed Id.
    Id marketId;
    /// @notice true = increase this market's position, false = decrease it.
    bool isIncrease;
    /// @notice Amount for this leg, in whichever token the operation naturally denominates in.
    uint256 amount;
    /// @notice For increases: the leverage this specific action targets, in WAD (1e18 =
    ///         1x, no borrow). Must fall between 1e18 and the market's maxLeverage.
    ///         Ignored for decreases.
    uint256 leverage;
    /// @notice Our own oracle-independent slippage floor for this leg's swap, if any.
    uint256 minOut;
    /// @notice Swap venue for this leg. address(0) if this leg needs no swap.
    address swapTarget;
    /// @notice Calldata for swapTarget, if swapTarget != address(0).
    bytes swapCalldata;
}
