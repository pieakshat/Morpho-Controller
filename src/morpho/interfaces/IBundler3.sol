// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A single call within a Bundler3 bundle.
/// @dev Verified 2026-08-03 against the deployed contract's own ABI on Arbitrum
///      (0x1FA4431bC113D308beE1d46B0e98Cb805FB48C13), field order matters for encoding.
struct Call {
    address to;
    bytes data;
    uint256 value;
    bool skipRevert;
    bytes32 callbackHash;
}

/// @notice Minimal interface to the real, permissionless Bundler3 multicall executor.
/// @dev Bundler3 is Morpho's own official composition infrastructure, not something we're
///      reimplementing — this file just declares the one function we call on it.
interface IBundler3 {
    /// @notice Executes each Call in `bundle` in order. Reverts the whole bundle unless a
    ///         given Call has skipRevert = true.
    function multicall(Call[] calldata bundle) external payable;
}
