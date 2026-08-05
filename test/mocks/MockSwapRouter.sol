// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Swap venue stand-in for MorphoSwapExecutor tests. Pulls tokenIn from whoever
///         calls swap() (mirrors a real router being called mid-bundle by the executor,
///         where msg.sender is the executor's own address), pays out tokenOut at a
///         configurable rate. Must be pre-funded with tokenOut via MockERC20.mint.
/// @dev Not testing real DEX behavior anywhere this is used — the swap venue itself is
///      never what's under test, only that callers correctly handle whatever it returns.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    /// @dev amountOut = amountIn * rate / 1e18, then reduced by underDeliverBps if set.
    uint256 public rate = 1e18;
    uint256 public underDeliverBps;

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    /// @dev e.g. 500 = deliver 5% less than the configured rate would produce, to trigger
    ///      a caller's slippage floor.
    function setUnderDeliverBps(uint256 bps) external {
        underDeliverBps = bps;
    }

    function swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = (amountIn * rate) / 1e18;
        if (underDeliverBps > 0) {
            amountOut = amountOut - (amountOut * underDeliverBps) / 10_000;
        }

        tokenOut.safeTransfer(msg.sender, amountOut);
    }
}
