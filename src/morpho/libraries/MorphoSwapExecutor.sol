// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Executes one arbitrary-target swap and enforces a slippage floor on-chain.
/// @dev This is the piece that makes accepting arbitrary {target, callData} in a
///      MarketAction survivable — without it, minOut would just be a number nobody
///      checks. Expects tokenIn to already be sitting in this contract's own balance,
///      transferred in by a prior Bundler3 step: one Call moves tokens in, a separate
///      Call executes the swap.
contract MorphoSwapExecutor {
    using SafeERC20 for IERC20;

    error SlippageExceeded(uint256 received, uint256 minOut);
    error SwapCallFailed();

    /// @notice Swaps this contract's entire current balance of `tokenIn` through
    ///         `target` using `data`, then sends the resulting `tokenOut` to `recipient`.
    /// @dev `minOut` is trusted from whoever constructs the MarketAction (the allocator) —
    ///      a flat floor, not an oracle-derived check. This assumes the allocator won't
    ///      collude with itself (set minOut low, then swap through a bad venue); revisit
    ///      with an oracle-derived floor if that trust assumption ever changes.
    function executeSwap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 minOut,
        address target,
        bytes calldata data,
        address recipient
    ) external {
        uint256 amountIn = tokenIn.balanceOf(address(this));
        uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

        tokenIn.forceApprove(target, amountIn);
        (bool ok,) = target.call(data);
        if (!ok) revert SwapCallFailed();
        tokenIn.forceApprove(target, 0);

        uint256 received = tokenOut.balanceOf(address(this)) - balanceOutBefore;
        if (received < minOut) revert SlippageExceeded(received, minOut);

        tokenOut.safeTransfer(recipient, received);
    }
}
