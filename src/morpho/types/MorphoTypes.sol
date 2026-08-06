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
    /// @notice For increases: this adapter's own contribution to the position. For
    ///         decreases with leverage == 0: collateral to withdraw, or type(uint256).max
    ///         for a full close. Ignored for decreases with leverage > 0.
    uint256 amount;
    /// @notice For increases: the leverage this specific action targets, in WAD (1e18 =
    ///         1x, no borrow). Must fall between 1e18 and the market's maxLeverage.
    ///         For decreases: 0 means use `amount` as an explicit collateral withdrawal;
    ///         any value >= 1e18 instead deleverages the position down to that ratio,
    ///         ignoring `amount`. Must be below the position's current leverage.
    uint256 leverage;
    /// @notice Our own oracle-independent slippage floor for this leg's swap, if any.
    uint256 minOut;
    /// @notice Swap venue for this leg. address(0) if this leg needs no swap.
    address swapTarget;
    /// @notice Calldata for swapTarget, if swapTarget != address(0).
    bytes swapCalldata;
}
