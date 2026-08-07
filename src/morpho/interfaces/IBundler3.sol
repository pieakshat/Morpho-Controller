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

    /// @notice Whoever called multicall() for the bundle currently in flight, or the zero
    ///         address when no bundle is executing.
    /// @dev Transient storage on the real deployment, so it is only non-zero for the
    ///      duration of one transaction's bundle. This is how a callee invoked by Bundler3
    ///      identifies who actually initiated the bundle, since msg.sender is Bundler3.
    function initiator() external view returns (address);
}
