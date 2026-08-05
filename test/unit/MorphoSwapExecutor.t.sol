// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MorphoSwapExecutor} from "../../src/morpho/libraries/MorphoSwapExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice MorphoSwapExecutor tests using a hand-rolled swap venue — no flashloan/Bundler3
///         mechanics are involved here, so no fork is needed.
contract MorphoSwapExecutorTest is Test {
    MorphoSwapExecutor executor;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockSwapRouter router;

    address recipient = makeAddr("recipient");

    function setUp() public {
        executor = new MorphoSwapExecutor();
        tokenIn = new MockERC20("TokenIn", "IN", 18);
        tokenOut = new MockERC20("TokenOut", "OUT", 18);
        router = new MockSwapRouter();
    }

    function test_executeSwap_transfersOutputToRecipient() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn); // router rate defaults to 1:1

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        executor.executeSwap(tokenIn, tokenOut, amountIn, address(router), data, recipient);

        assertEq(tokenOut.balanceOf(recipient), amountIn);
        assertEq(tokenIn.balanceOf(address(executor)), 0);
        assertEq(tokenOut.balanceOf(address(executor)), 0);
    }

    function test_executeSwap_revertsOnSlippageExceeded() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn);
        router.setUnderDeliverBps(500); // delivers 5% less than the configured rate

        uint256 expectedOut = amountIn - (amountIn * 500) / 10_000; // 950e18
        uint256 minOut = amountIn;

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        vm.expectRevert(abi.encodeWithSelector(MorphoSwapExecutor.SlippageExceeded.selector, expectedOut, minOut));
        executor.executeSwap(tokenIn, tokenOut, minOut, address(router), data, recipient);
    }

    function test_executeSwap_revertsOnSwapCallFailed() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);

        // Router has no fallback, so an unmatched selector reverts the low-level call.
        bytes memory data = abi.encodeWithSignature("nonexistentFunction()");
        vm.expectRevert(MorphoSwapExecutor.SwapCallFailed.selector);
        executor.executeSwap(tokenIn, tokenOut, 0, address(router), data, recipient);
    }

    function test_executeSwap_resetsApprovalToZero() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn);

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        executor.executeSwap(tokenIn, tokenOut, amountIn, address(router), data, recipient);

        assertEq(tokenIn.allowance(address(executor), address(router)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_executeSwap_transfersExactOutputAtConfiguredRate(uint256 amountIn, uint256 rate) public {
        amountIn = bound(amountIn, 1, 1e24);
        rate = bound(rate, 0, 100e18);

        tokenIn.mint(address(executor), amountIn);
        router.setRate(rate);
        uint256 expectedOut = (amountIn * rate) / 1e18;
        tokenOut.mint(address(router), expectedOut);

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        executor.executeSwap(tokenIn, tokenOut, expectedOut, address(router), data, recipient);

        assertEq(tokenOut.balanceOf(recipient), expectedOut);
        assertEq(tokenIn.balanceOf(address(executor)), 0);
        assertEq(tokenOut.balanceOf(address(executor)), 0);
        assertEq(tokenIn.allowance(address(executor), address(router)), 0);
    }

    /// @dev Bounds amountIn so that a shortfall of at least 1 unit is guaranteed whenever
    ///      underDeliverBps >= 1 — otherwise floor(amountIn * bps / 10_000) could round back
    ///      down to zero and the swap would (correctly) not revert, defeating the test.
    function testFuzz_executeSwap_revertsWhenUnderDelivered(uint256 amountIn, uint256 underDeliverBps) public {
        amountIn = bound(amountIn, 10_000, 1e24);
        underDeliverBps = bound(underDeliverBps, 1, 10_000);

        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn); // rate defaults to 1:1
        router.setUnderDeliverBps(underDeliverBps);

        uint256 received = amountIn - (amountIn * underDeliverBps) / 10_000;
        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));

        vm.expectRevert(abi.encodeWithSelector(MorphoSwapExecutor.SlippageExceeded.selector, received, amountIn));
        executor.executeSwap(tokenIn, tokenOut, amountIn, address(router), data, recipient);
    }
}
