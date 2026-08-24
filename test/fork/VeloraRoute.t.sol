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
///      Regenerate both by re-running the capture that produced
///      allocator/packages/planner/test/fixtures/velora-arbitrum.json and updating
///      QUOTE_BLOCK to the priceRoute's own blockNumber.
contract VeloraRouteForkTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;

    /// @dev The `blockNumber` inside the recorded priceRoute.
    uint256 constant QUOTE_BLOCK = 494_800_425;

    string fixture;

    address caller; // the vault's swap executor, as userAddress in the quote
    address receiver; // GeneralAdapter1, as receiver in the quote
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

        // Delivered to the receiver named in the quote, not to the caller: the property under
        // test is that Velora honours an arbitrary receiver at all, since the executor is
        // never the transaction sender.
        //
        // NOTE the receiver this fixture names is GeneralAdapter1, which is NOT what a
        // production route should ask for. MorphoSwapExecutor enforces minOut against its OWN
        // balance delta and only then forwards to GeneralAdapter1, so a route paying
        // GeneralAdapter1 directly leaves that delta at zero and the bundle dies on
        // SlippageExceeded(0, minOut) with the tokens already delivered somewhere the check
        // cannot see them. The allocator therefore quotes with the executor as receiver; see
        // the recipient note in allocator/packages/planner/src/quote.ts. Regenerating this
        // fixture is the moment to align it.
        assertGt(delivered, 0, "receiver got nothing");
        assertEq(
            IERC20(WSTETH).balanceOf(caller),
            callerCollateralBefore,
            "output went to the caller instead of the receiver"
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

        assertLt(expectedOut, oracleImplied, "route should be worse than the oracle, not better");
        uint256 shortfallBps = ((oracleImplied - expectedOut) * 10_000) / oracleImplied;

        // 50 is what script/config/42161.json registers for this market. Price impact adds
        // roughly 14bps more by 500k, so the headroom below is what absorbs size.
        uint256 configuredBps = 50;
        assertLt(shortfallBps, configuredBps, "real spread has outgrown the configured maxSlippageBps");
    }
}
