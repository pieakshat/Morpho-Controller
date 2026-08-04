// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interface oracles used by Morpho markets must implement.
/// @dev Verified 2026-08-03 against Morpho Labs' real IOracle.sol (GPL-2.0-or-later).
///      It is the caller's responsibility to trust the specific oracle a market uses —
///      Morpho itself does not vet oracles.
interface IOracle {
    /// @notice Price of 1 unit of collateral token quoted in loan token, scaled by 1e36.
    /// @dev Precision is `36 + loanTokenDecimals - collateralTokenDecimals`. Getting this
    ///      decimal adjustment wrong silently corrupts valuation by a power of 10 — always
    ///      divide out decimals explicitly rather than assuming both tokens match.
    function price() external view returns (uint256);
}
