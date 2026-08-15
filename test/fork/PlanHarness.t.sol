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
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {PlanHarness} from "../harness/PlanHarness.sol";

/// @notice Proves PlanHarness reports the same numbers the real decrease path acts on.
///
/// @dev Without this, the golden vectors it produces would be an untested claim: the harness
///      could report one plan while `_decreasePosition` executed against another, and the
///      off-chain mirror would be held to the wrong target. Every assertion here compares a
///      planned figure against the position delta an actually-executed action produced.
contract PlanHarnessForkTest is Test {
    address constant MORPHO = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address constant BUNDLER3 = 0x1FA4431bC113D308beE1d46B0e98Cb805FB48C13;
    address constant GENERAL_ADAPTER = 0x9954aFB60BB5A222714c478ac86990F221788B88;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;
    address constant IRM = 0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA;
    uint256 constant FORK_BLOCK = 491_260_000;

    PlanHarness vault;
    MockSwapRouter router;
    address owner = makeAddr("owner");

    MarketParams params;
    Id marketId;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);
        router = new MockSwapRouter();

        vault = new PlanHarness(
            IERC20(USDC), owner, IMorpho(MORPHO), IBundler3(BUNDLER3), IGeneralAdapter1(GENERAL_ADAPTER)
        );

        params =
            MarketParams({loanToken: USDC, collateralToken: WSTETH, oracle: WSTETH_ORACLE, irm: IRM, lltv: 0.86e18});
        vm.prank(owner);
        marketId = vault.registerMarket(params, 10e18, 50);

        deal(USDC, address(this), 1_000_000e6);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, address(this));
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

    /// @dev The fill rate differs by mode, and getting this wrong is easy.
    ///
    ///      A proportional decrease or full close withdraws a caller-chosen amount of
    ///      collateral while repaying only that slice of the debt, so the swap must deliver
    ///      the collateral's full ORACLE value, not merely the repay. Anything less trips the
    ///      oracle floor in the swap executor; the surplus over the repay is swept back to
    ///      the vault as idle.
    ///
    ///      A deleverage is different: collateralToWithdraw is derived from the repay via
    ///      mulDivUp, so the two are already oracle-equivalent by construction. There the
    ///      rate is rounded up off the repay instead, because the plan's mulDivUp and a
    ///      price-derived rate round independently and can leave the flashloan a couple of
    ///      wei short.
    function _executeDecrease(uint256 amount, uint256 leverage, uint256 collateralToWithdraw, uint256 repayAmount)
        internal
    {
        uint256 rate = leverage == 0
            ? IOracle(WSTETH_ORACLE).price() / 1e18
            : MorphoSharesMath.mulDivUp(repayAmount, 1e18, collateralToWithdraw);
        router.setRate(rate);
        uint256 expectedOut = (collateralToWithdraw * rate) / 1e18;
        deal(USDC, address(router), expectedOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: marketId,
            isIncrease: false,
            amount: amount,
            leverage: leverage,
            minOut: expectedOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(WSTETH), IERC20(USDC), collateralToWithdraw))
        });
        vm.prank(owner);
        vault.executeActions(actions);
    }

    function _position() internal view returns (uint128 borrowShares, uint128 collateral) {
        (, borrowShares, collateral) = IMorpho(MORPHO).position(marketId, address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                          PROPORTIONAL DECREASE
    //////////////////////////////////////////////////////////////*/

    function test_planDecrease_matchesTheExecutedProportionalDecrease() public {
        _open(100_000e6, 2e18);
        (uint128 sharesBefore, uint128 collateralBefore) = _position();

        uint256 requested = uint256(collateralBefore) / 3;
        MorphoLeverageEngine.DecreasePlan memory plan = vault.planDecrease(marketId, requested);

        assertEq(plan.collateralToWithdraw, requested, "proportional mode withdraws exactly what was asked");
        assertFalse(plan.isFullClose);
        assertGt(plan.repayAssets, 0, "a real decrease must repay something");
        assertEq(plan.repayShares, 0, "proportional mode repays by assets, not shares");
        assertEq(plan.flashloanAmount, plan.repayAssets);

        _executeDecrease(requested, 0, plan.collateralToWithdraw, plan.flashloanAmount);

        (uint128 sharesAfter, uint128 collateralAfter) = _position();
        assertEq(
            uint256(collateralBefore - collateralAfter),
            plan.collateralToWithdraw,
            "collateral moved by exactly the planned amount"
        );
        assertLt(sharesAfter, sharesBefore, "debt was actually reduced");
    }

    /*//////////////////////////////////////////////////////////////
                                FULL CLOSE
    //////////////////////////////////////////////////////////////*/

    function test_planDecrease_fullCloseRepaysByExactShares() public {
        _open(100_000e6, 2e18);
        (uint128 sharesBefore, uint128 collateralBefore) = _position();

        MorphoLeverageEngine.DecreasePlan memory plan = vault.planDecrease(marketId, type(uint256).max);

        assertTrue(plan.isFullClose);
        assertEq(plan.collateralToWithdraw, collateralBefore, "the whole position comes out");
        assertEq(plan.repayShares, sharesBefore, "repays the exact share count, avoiding dust");
        assertEq(plan.repayAssets, 0, "assets side unused on a full close");
        assertGt(plan.flashloanAmount, 0);

        _executeDecrease(type(uint256).max, 0, plan.collateralToWithdraw, plan.flashloanAmount);

        (uint128 sharesAfter, uint128 collateralAfter) = _position();
        assertEq(sharesAfter, 0);
        assertEq(collateralAfter, 0);
        assertEq(vault.activeMarkets().length, 0, "market deactivated");
    }

    /// @dev The sentinel rule is `>=`, not `==`: passing the exact collateral balance must
    ///      take the same exact-shares path, since routing it through the proportional branch
    ///      would compute a repay Morpho converts back to more shares than exist.
    function test_planDecrease_exactCollateralAlsoTakesTheFullClosePath() public {
        _open(100_000e6, 2e18);
        (, uint128 collateralBefore) = _position();

        MorphoLeverageEngine.DecreasePlan memory plan = vault.planDecrease(marketId, uint256(collateralBefore));

        assertTrue(plan.isFullClose, "exact balance is a full close, not a 100% proportional decrease");
        assertGt(plan.repayShares, 0);
        assertEq(plan.repayAssets, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                DELEVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_planDeleverage_matchesTheExecutedDeleverage() public {
        _open(100_000e6, 3e18);
        (uint128 sharesBefore, uint128 collateralBefore) = _position();

        MorphoLeverageEngine.DecreasePlan memory plan = vault.planDeleverage(marketId, 1.5e18);

        assertGt(plan.repayShares, 0, "deleverage repays by shares");
        assertEq(plan.repayAssets, 0);
        assertLe(plan.collateralToWithdraw, collateralBefore);
        assertGt(plan.flashloanAmount, 0);

        _executeDecrease(0, 1.5e18, plan.collateralToWithdraw, plan.flashloanAmount);

        (uint128 sharesAfter, uint128 collateralAfter) = _position();
        assertEq(
            uint256(collateralBefore - collateralAfter),
            plan.collateralToWithdraw,
            "collateral moved by exactly the planned amount"
        );
        assertEq(
            uint256(sharesBefore - sharesAfter), plan.repayShares, "debt shares moved by exactly the planned amount"
        );
    }

    /// @dev Calling a planner accrues interest as a side effect, so a second call in the same
    ///      block must return an identical plan. The off-chain mirror relies on that: it
    ///      reads post-accrual state once and expects the contract to agree at execution.
    function test_planningTwiceInOneBlockIsStable() public {
        _open(100_000e6, 3e18);

        MorphoLeverageEngine.DecreasePlan memory a = vault.planDeleverage(marketId, 1.5e18);
        MorphoLeverageEngine.DecreasePlan memory b = vault.planDeleverage(marketId, 1.5e18);

        assertEq(a.collateralToWithdraw, b.collateralToWithdraw);
        assertEq(a.repayShares, b.repayShares);
        assertEq(a.flashloanAmount, b.flashloanAmount);
    }

    /// @dev And the drift the mirror has to budget for is real: let time pass and the same
    ///      request plans a strictly larger repay, because interest accrued.
    function test_planDrifts_asInterestAccrues() public {
        _open(100_000e6, 3e18);
        MorphoLeverageEngine.DecreasePlan memory before = vault.planDeleverage(marketId, 1.5e18);

        vm.warp(block.timestamp + 30 days);
        MorphoLeverageEngine.DecreasePlan memory later = vault.planDeleverage(marketId, 1.5e18);

        assertGt(later.flashloanAmount, before.flashloanAmount, "accrued interest raises the repay");
        assertGt(
            later.collateralToWithdraw, before.collateralToWithdraw, "and therefore the collateral that must come out"
        );
    }
}
