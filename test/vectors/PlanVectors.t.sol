// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {IOracle} from "../../src/morpho/interfaces/IOracle.sol";
import {MarketAction} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoLeverageEngine} from "../../src/morpho/libraries/MorphoLeverageEngine.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {PlanHarness} from "../harness/PlanHarness.sol";

/// @notice Dumps `_planDecrease` and `_planDeleverage` output for the off-chain planner in
///         allocator/packages/planner to assert against.
///
/// @dev The mirror has to reproduce every field exactly, including rounding direction and the
///      targetBorrowShares clamp, or the calldata it builds is rejected. Nothing short of the
///      contract's own numbers establishes that.
///
///      Inputs are read AFTER the plan call, deliberately: the planners accrue interest as a
///      side effect, so reading first would record pre-accrual totals the plan never saw. A
///      second call in the same block is stable, which PlanHarness.t.sol pins separately.
///
///      Needs a fork to regenerate; the output is committed so the TypeScript runs offline.
///        forge test --match-path 'test/vectors/PlanVectors.t.sol'
///
///      Line formats, both with inputs first and the contract's answer after:
///        dec,<collateral>,<borrowShares>,<tba>,<tbs>,<price>,<requested>,
///            <collateralToWithdraw>,<repayAssets>,<repayShares>,<flashloan>,<isFullClose>
///        del,<collateral>,<borrowShares>,<tba>,<tbs>,<price>,<targetLeverage>,
///            <collateralToWithdraw>,<repayAssets>,<repayShares>,<flashloan>
contract PlanVectorsTest is Test {
    address constant MORPHO = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address constant BUNDLER3 = 0x1FA4431bC113D308beE1d46B0e98Cb805FB48C13;
    address constant GENERAL_ADAPTER = 0x9954aFB60BB5A222714c478ac86990F221788B88;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;
    address constant IRM = 0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA;
    uint256 constant FORK_BLOCK = 491_260_000;
    uint256 constant SLIPPAGE_BPS = 50;

    PlanHarness vault;
    MockSwapRouter router;
    address owner = makeAddr("owner");

    MarketParams params;
    Id marketId;

    string[] private lines;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);
        router = new MockSwapRouter();

        vault = new PlanHarness(
            IERC20(USDC), owner, IMorpho(MORPHO), IBundler3(BUNDLER3), IGeneralAdapter1(GENERAL_ADAPTER)
        );
        params =
            MarketParams({loanToken: USDC, collateralToken: WSTETH, oracle: WSTETH_ORACLE, irm: IRM, lltv: 0.86e18});

        vm.prank(owner);
        marketId = vault.registerMarket(params, 10e18, SLIPPAGE_BPS);

        deal(USDC, address(this), 2_000_000e6);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.deposit(2_000_000e6, address(this));
    }

    function _open(uint256 ownAmount, uint256 leverage) internal {
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 rate = 1e54 / IOracle(WSTETH_ORACLE).price();
        router.setRate(rate);
        uint256 expectedOut = (totalAmount * rate) / 1e18;
        deal(WSTETH, address(router), expectedOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: marketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: expectedOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });
        vm.prank(owner);
        vault.executeActions(actions);
    }

    /// @dev Reads the state the plan actually used, which is only correct post-accrual.
    function _inputs(uint256 request) internal view returns (string memory) {
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, address(vault));
        (,, uint128 tba, uint128 tbs,,) = IMorpho(MORPHO).market(marketId);
        return string.concat(
            vm.toString(uint256(collateral)),
            ",",
            vm.toString(uint256(borrowShares)),
            ",",
            vm.toString(uint256(tba)),
            ",",
            vm.toString(uint256(tbs)),
            ",",
            vm.toString(IOracle(WSTETH_ORACLE).price()),
            ",",
            vm.toString(request)
        );
    }

    function _outputs(MorphoLeverageEngine.DecreasePlan memory p) internal pure returns (string memory) {
        return string.concat(
            vm.toString(p.collateralToWithdraw),
            ",",
            vm.toString(p.repayAssets),
            ",",
            vm.toString(p.repayShares),
            ",",
            vm.toString(p.flashloanAmount)
        );
    }

    function _recordDecrease(uint256 requested) internal {
        MorphoLeverageEngine.DecreasePlan memory p = vault.planDecrease(marketId, requested);
        lines.push(string.concat("dec,", _inputs(requested), ",", _outputs(p), ",", p.isFullClose ? "1" : "0"));
    }

    function _recordDeleverage(uint256 target) internal {
        MorphoLeverageEngine.DecreasePlan memory p = vault.planDeleverage(marketId, target);
        lines.push(string.concat("del,", _inputs(target), ",", _outputs(p)));
    }

    function test_writePlanVectors() public {
        (,, uint128 c0) = IMorpho(MORPHO).position(marketId, address(vault));
        c0; // silence: position is empty until the first open below

        // Sized well inside the market's real ~796k of available liquidity at this block.
        // Borrowing close to all of it pins utilisation near 100%, where the AdaptiveCurveIRM
        // rate spikes hard enough to put the position underwater within a month, and a
        // deleverage of an underwater position correctly panics rather than planning.
        _open(50_000e6, 2e18);
        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, address(vault));

        // Proportional decreases across the range, including the awkward fractions where
        // the floor division in repayAssets actually bites.
        _recordDecrease(uint256(collateral) / 100);
        _recordDecrease(uint256(collateral) / 3);
        _recordDecrease(uint256(collateral) / 2);
        _recordDecrease((uint256(collateral) * 99) / 100);

        // Both full-close spellings. The exact-balance one is the case that used to underflow.
        _recordDecrease(type(uint256).max);
        _recordDecrease(uint256(collateral));

        // Same position a week later: same requests, larger debt.
        vm.warp(block.timestamp + 7 days);
        _recordDecrease(uint256(collateral) / 3);
        _recordDecrease(type(uint256).max);

        // A second open ADDS to the position rather than replacing it. Combined with the 2x
        // already in place this lands near 2.5x, not the 3x requested here, so every target
        // below is chosen under that rather than under 3x.
        _open(50_000e6, 3e18);
        _recordDeleverage(2e18);
        _recordDeleverage(1.5e18);
        _recordDeleverage(1.0001e18);
        _recordDeleverage(1e18); // exactly 1x repays every share

        // And after more accrual, where collateralToWithdraw visibly drifts upward.
        vm.warp(block.timestamp + 7 days);
        _recordDeleverage(1.5e18);

        string memory obj = "plans";
        vm.serializeUint(obj, "maxSlippageBps", SLIPPAGE_BPS);
        string memory out = vm.serializeString(obj, "cases", lines);
        vm.writeJson(out, "./allocator/packages/planner/test/vectors/plans.json");
    }
}
