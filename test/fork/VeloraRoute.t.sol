// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOracle} from "../../src/morpho/interfaces/IOracle.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";

/// @notice Executes REAL Velora calldata against the REAL Augustus router on a fork.
///
/// @dev Every other fork test in this repo swaps through MockSwapRouter, which fills at
///      whatever rate it is told. That is the right call when the swap venue is not what is
///      under test. But it means nothing here had ever verified that calldata produced by the
///      aggregator adapter actually executes, delivers to the receiver we asked for, or
///      returns what the quote promised. This does.
///
///      Pinned to the block the quote was priced at, not the suite's usual FORK_BLOCK. A DEX
///      route encodes specific pools and is only valid against the state it was built on;
///      replaying it 3.5M blocks earlier would fail on pool balances that had not happened
///      yet. The payload and the block have to travel together.
///
///      Regenerate both by running the planner package's `capture:velora` script, then set
///      QUOTE_BLOCK to the priceRoute's own blockNumber, which the script prints.
contract VeloraRouteForkTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;

    /// @dev The `blockNumber` inside the recorded priceRoute.
    uint256 constant QUOTE_BLOCK = 498_219_507;

    string fixture;

    address caller; // the vault's swap executor, as userAddress in the quote
    address receiver; // also the swap executor: see the note on the delivery test below
    address router; // Augustus v6.2
    uint256 amountIn;
    uint256 expectedOut;
    bytes swapCalldata;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), QUOTE_BLOCK);

        fixture = vm.readFile("./allocator/packages/planner/test/fixtures/velora-arbitrum.json");

        caller = vm.parseJsonAddress(fixture, ".request.caller");
        receiver = vm.parseJsonAddress(fixture, ".request.recipient");
        router = vm.parseJsonAddress(fixture, ".transaction.to");
        amountIn = vm.parseJsonUint(fixture, ".request.amountIn");
        expectedOut = vm.parseJsonUint(fixture, ".prices.priceRoute.destAmountAfterFee");
        swapCalldata = vm.parseJsonBytes(fixture, ".transaction.data");
    }

    /// @dev The fixture is only meaningful if it really was priced here.
    function test_fixtureMatchesThePinnedBlock() public view {
        assertEq(vm.parseJsonUint(fixture, ".prices.priceRoute.blockNumber"), QUOTE_BLOCK);
        assertEq(vm.parseJsonUint(fixture, ".prices.priceRoute.srcAmount"), amountIn);
    }

    /// @dev The whole point: real calldata, real router, real pools.
    function test_recordedRouteExecutesAndPaysTheReceiver() public {
        deal(USDC, caller, amountIn);

        uint256 receiverBefore = IERC20(WSTETH).balanceOf(receiver);
        uint256 callerCollateralBefore = IERC20(WSTETH).balanceOf(caller);

        // Exactly what MorphoSwapExecutor does: approve the target for the amount it holds,
        // then forward the opaque calldata to it.
        vm.startPrank(caller);
        IERC20(USDC).approve(router, amountIn);
        (bool ok,) = router.call(swapCalldata);
        vm.stopPrank();

        assertTrue(ok, "recorded Velora calldata reverted against the real router");

        uint256 delivered = IERC20(WSTETH).balanceOf(receiver) - receiverBefore;

        // The output must land on the EXECUTOR, and this is the property the whole bundle
        // depends on rather than a detail of the fixture.
        //
        // MorphoSwapExecutor measures its own balance delta to enforce minOut, and only then
        // forwards to GeneralAdapter1. A route paying GeneralAdapter1 directly leaves that
        // delta at zero, so the bundle reverts SlippageExceeded(0, minOut) with the tokens
        // already delivered somewhere the check cannot see them. An earlier version of this
        // fixture named GeneralAdapter1 as receiver and so recorded a topology the vault
        // rejects; see the recipient note in allocator/packages/planner/src/quote.ts.
        assertEq(receiver, caller, "fixture must quote the executor as its own receiver");
        assertGt(delivered, 0, "executor received nothing, so minOut would be enforced against zero");
        assertEq(
            IERC20(WSTETH).balanceOf(caller) - callerCollateralBefore,
            delivered,
            "the executor's own balance must be what moved"
        );

        // And the input really was consumed.
        assertEq(IERC20(USDC).balanceOf(caller), 0, "router did not take the full input");

        // Within 10bps of what the quote promised. Not exact: the route's own internal
        // slippage bound and pool rounding both move the final wei.
        assertApproxEqRel(delivered, expectedOut, 0.001e18, "delivered far from the quoted amount");
    }

    /// @dev The number the adapter reports as `expectedOut` is the one `encode` prices the
    ///      minOut from, so it has to be the amount that actually arrives. Using the gross
    ///      `destAmount` instead would overstate it by the partner fee and let encode set a
    ///      floor the route cannot fill.
    function test_destAmountAfterFeeIsTheAmountThatActuallyArrives() public {
        uint256 gross = vm.parseJsonUint(fixture, ".prices.priceRoute.destAmount");
        assertGt(gross, expectedOut, "fixture should have a non-zero partner fee");

        deal(USDC, caller, amountIn);
        uint256 before = IERC20(WSTETH).balanceOf(receiver);

        vm.startPrank(caller);
        IERC20(USDC).approve(router, amountIn);
        (bool ok,) = router.call(swapCalldata);
        vm.stopPrank();
        assertTrue(ok);

        uint256 delivered = IERC20(WSTETH).balanceOf(receiver) - before;

        // Closer to the net figure than to the gross one.
        uint256 distToNet = delivered > expectedOut ? delivered - expectedOut : expectedOut - delivered;
        uint256 distToGross = gross > delivered ? gross - delivered : delivered - gross;
        assertLt(distToNet, distToGross, "delivered amount tracks destAmount, not destAmountAfterFee");
    }

    /// @dev Checks that an honest route actually clears the market's configured slippage
    ///      floor, which is the property `maxSlippageBps` exists to permit. If the real
    ///      spread ever widens past the config, every increase on this pair starts reverting
    ///      `SlippageExceeded` and this test says so first.
    ///
    ///      Measured at a MATCHED block, which is the whole trick. Comparing a quote priced
    ///      at one block against an oracle read at another measures the price drift between
    ///      them, not the spread. Doing exactly that produced a bogus 40bps reading here and
    ///      nearly drove a needless config change; the oracle had moved 32bps between the two
    ///      blocks and the "spread" was almost entirely that.
    function test_anHonestRouteClearsTheConfiguredSlippageFloor() public view {
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 oracleImplied = MorphoSharesMath.mulDivDown(amountIn, MorphoSharesMath.ORACLE_PRICE_SCALE, price);

        // 50 is what script/config/42161.json registers for this market, and the floor the
        // engine will raise any submitted minOut to.
        uint256 configuredBps = 50;

        // The route being BETTER than the oracle is normal and clears trivially. An earlier
        // version of this test asserted the opposite and was simply wrong: measured across
        // sizes on Arbitrum, an honest USDC -> wstETH fill runs anywhere from a couple of bps
        // above the oracle to a couple below, because the oracle is a reference price and not
        // a quote. Only a shortfall can breach the floor.
        if (expectedOut >= oracleImplied) return;

        uint256 shortfallBps = ((oracleImplied - expectedOut) * 10_000) / oracleImplied;
        assertLt(shortfallBps, configuredBps, "real spread has outgrown the configured maxSlippageBps");
    }
}
