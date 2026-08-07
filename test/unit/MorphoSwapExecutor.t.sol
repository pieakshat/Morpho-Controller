// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {MorphoSwapExecutor} from "../../src/morpho/libraries/MorphoSwapExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice MorphoSwapExecutor tests using a hand-rolled swap venue — no flashloan/Bundler3
///         mechanics are involved here, so no fork is needed.
/// @dev The executor authorizes on "Bundler3 is calling AND the bundle's initiator is my
///      vault", so every call here is staged to look like that: deployed from `vault`,
///      invoked as `bundler3`, with initiator() mocked to `vault`.
contract MorphoSwapExecutorTest is Test {
    MorphoSwapExecutor executor;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockSwapRouter router;

    address recipient = makeAddr("recipient");
    address vault = makeAddr("vault");
    address bundler3 = makeAddr("bundler3");

    function setUp() public {
        vm.prank(vault);
        executor = new MorphoSwapExecutor(IBundler3(bundler3));

        tokenIn = new MockERC20("TokenIn", "IN", 18);
        tokenOut = new MockERC20("TokenOut", "OUT", 18);
        router = new MockSwapRouter();

        _setInitiator(vault);
    }

    function _setInitiator(address who) internal {
        vm.mockCall(bundler3, abi.encodeWithSelector(IBundler3.initiator.selector), abi.encode(who));
    }

    /// @dev Every legitimate call arrives from Bundler3 mid-bundle.
    function _asBundle() internal {
        vm.prank(bundler3);
    }

    function test_executeSwap_transfersOutputToRecipient() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn); // router rate defaults to 1:1

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        _asBundle();
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
        _asBundle();
        vm.expectRevert(abi.encodeWithSelector(MorphoSwapExecutor.SlippageExceeded.selector, expectedOut, minOut));
        executor.executeSwap(tokenIn, tokenOut, minOut, address(router), data, recipient);
    }

    function test_executeSwap_revertsOnSwapCallFailed() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);

        // Router has no fallback, so an unmatched selector reverts the low-level call.
        bytes memory data = abi.encodeWithSignature("nonexistentFunction()");
        _asBundle();
        vm.expectRevert(MorphoSwapExecutor.SwapCallFailed.selector);
        executor.executeSwap(tokenIn, tokenOut, 0, address(router), data, recipient);
    }

    function test_executeSwap_resetsApprovalToZero() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn);

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        _asBundle();
        executor.executeSwap(tokenIn, tokenOut, amountIn, address(router), data, recipient);

        assertEq(tokenIn.allowance(address(executor), address(router)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @dev Direct calls have no bundle in flight, so initiator() is the zero address.
    function test_executeSwap_revertsForDirectCaller() public {
        tokenIn.mint(address(executor), 1000e18);
        _setInitiator(address(0));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MorphoSwapExecutor.UnauthorizedCaller.selector);
        executor.executeSwap(tokenIn, tokenOut, 0, address(router), "", recipient);
    }

    /// @dev Bundler3 is permissionless, so the real attack is routing a call to this
    ///      executor through an attacker's own bundle. Then msg.sender is legitimately
    ///      Bundler3, but the initiator is the attacker rather than the vault.
    function test_executeSwap_revertsWhenBundleInitiatorIsNotVault() public {
        tokenIn.mint(address(executor), 1000e18);
        _setInitiator(makeAddr("attacker"));

        _asBundle();
        vm.expectRevert(MorphoSwapExecutor.UnauthorizedCaller.selector);
        executor.executeSwap(tokenIn, tokenOut, 0, address(router), "", recipient);
    }

    /*//////////////////////////////////////////////////////////////
                              RESIDUAL SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @dev A router that consumes less than the full approval is normal behavior. The
    ///      leftover must not stay in the executor, where it would be strandable value.
    function test_executeSwap_sweepsUnconsumedTokenInToVault() public {
        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn);

        uint256 consumed = 600e18;
        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, consumed));
        _asBundle();
        executor.executeSwap(tokenIn, tokenOut, 0, address(router), data, recipient);

        assertEq(tokenIn.balanceOf(address(executor)), 0, "no tokenIn left to steal");
        assertEq(tokenIn.balanceOf(vault), amountIn - consumed, "leftover returned to the vault");
        assertEq(tokenOut.balanceOf(recipient), consumed);
    }

    /// @dev A pre-existing tokenOut balance is excluded from `received` by design, so
    ///      without an explicit sweep it would accumulate in the executor indefinitely.
    function test_executeSwap_sweepsPreExistingTokenOutToVault() public {
        uint256 stray = 7e18;
        tokenOut.mint(address(executor), stray);

        uint256 amountIn = 1000e18;
        tokenIn.mint(address(executor), amountIn);
        tokenOut.mint(address(router), amountIn);

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn));
        _asBundle();
        executor.executeSwap(tokenIn, tokenOut, amountIn, address(router), data, recipient);

        assertEq(tokenOut.balanceOf(recipient), amountIn, "recipient still gets exactly the swap output");
        assertEq(tokenOut.balanceOf(address(executor)), 0, "stray balance no longer lingers");
        assertEq(tokenOut.balanceOf(vault), stray, "stray balance recovered to the vault");
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
        _asBundle();
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

        _asBundle();
        vm.expectRevert(abi.encodeWithSelector(MorphoSwapExecutor.SlippageExceeded.selector, received, amountIn));
        executor.executeSwap(tokenIn, tokenOut, amountIn, address(router), data, recipient);
    }
}
