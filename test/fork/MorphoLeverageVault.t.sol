// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {IOracle} from "../../src/morpho/interfaces/IOracle.sol";
import {MarketAction} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";
import {MorphoSwapExecutor} from "../../src/morpho/libraries/MorphoSwapExecutor.sol";
import {RiskLimits} from "../../src/morpho/libraries/RiskLimits.sol";
import {MorphoLeverageEngine} from "../../src/morpho/libraries/MorphoLeverageEngine.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice Fork-integration tests for the leverage engine's actual flashloan mechanics —
///         real Morpho Blue, real Bundler3, real GeneralAdapter1 on Arbitrum, pinned to a
///         fixed block for reproducibility. Only the swap leg is mocked (MockSwapRouter);
///         everything else touches live deployed contracts, because Bundler3's reenter/
///         callbackHash verification and GeneralAdapter1's internal behavior are real,
///         audited logic this project didn't write and shouldn't pretend to reimplement.
/// @dev Requires ARBITRUM_RPC_URL to be an archive-capable endpoint (Alchemy/Infura/
///      QuickNode) — the public https://arb1.arbitrum.io/rpc only retains ~30 minutes of
///      state and cannot serve a pinned historical block. See .env.example.
contract MorphoLeverageVaultForkTest is Test {
    address constant MORPHO = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address constant BUNDLER3 = 0x1FA4431bC113D308beE1d46B0e98Cb805FB48C13;
    address constant GENERAL_ADAPTER = 0x9954aFB60BB5A222714c478ac86990F221788B88;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WETH_ORACLE = 0x282FEB10549fde52bD61A6979424Ddf18A4971A2;
    address constant IRM = 0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA;
    uint256 constant LLTV_86 = 0.86e18;

    // Pinned behind the chain tip so an archive RPC can always serve it, regardless of
    // when these tests run.
    uint256 constant FORK_BLOCK = 491_260_000;

    uint256 constant LEVERAGE_2X = 2e18;
    // Registered as each market's ceiling in setUp, comfortably above every leverage used
    // in this file (up to 5x in the fuzz tests) — actions pick their own leverage per call,
    // this only bounds how high they're allowed to go without the owner raising it.
    uint256 constant MAX_LEVERAGE_CEILING = 10e18;
    // The mock router fills at exactly the oracle rate, so any non-zero tolerance clears
    // the engine's oracle floor; 50bps leaves room for the rounding in either direction.
    uint256 constant SLIPPAGE_BPS = 50;
    uint256 constant DEPOSIT_AMOUNT = 1_000_000e6;

    MorphoLeverageVault vault;
    MorphoSwapExecutor swapExecutor;
    MockSwapRouter router;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");
    address stranger = makeAddr("stranger");

    MarketParams wstEthParams;
    MarketParams wethParams;
    Id wstEthMarketId;
    Id wethMarketId;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);

        router = new MockSwapRouter();

        vault = new MorphoLeverageVault(
            IERC20(USDC), owner, IMorpho(MORPHO), IBundler3(BUNDLER3), IGeneralAdapter1(GENERAL_ADAPTER)
        );
        // The vault deploys its own executor now, so it can bind that executor's access
        // control to itself. Read it back rather than constructing one here.
        swapExecutor = MorphoSwapExecutor(vault.swapExecutor());

        wstEthParams =
            MarketParams({loanToken: USDC, collateralToken: WSTETH, oracle: WSTETH_ORACLE, irm: IRM, lltv: LLTV_86});
        wethParams =
            MarketParams({loanToken: USDC, collateralToken: WETH, oracle: WETH_ORACLE, irm: IRM, lltv: LLTV_86});

        vm.startPrank(owner);
        wstEthMarketId = vault.registerMarket(wstEthParams, MAX_LEVERAGE_CEILING, SLIPPAGE_BPS);
        wethMarketId = vault.registerMarket(wethParams, MAX_LEVERAGE_CEILING, SLIPPAGE_BPS);
        vm.stopPrank();

        // Real ERC4626 deposit, not a raw deal() into the vault — gives us an actual
        // shareholder to exercise maxWithdraw/maxRedeem against later.
        deal(USDC, depositor, DEPOSIT_AMOUNT);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, depositor);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirrors the oracle-implied exchange rate exactly, so the mock swap doesn't
    ///      distort collateral valuation or Morpho's real LLTV health check. Funds the
    ///      router with exactly what it needs to deliver.
    ///
    ///      Takes an explicit router rather than always reaching for the shared `router`
    ///      field: MockSwapRouter's rate is mutable contract state, so two swap legs built
    ///      back-to-back in the same test (e.g. a decrease and an increase composed into
    ///      one executeActions call) would silently clobber each other's rate if they
    ///      shared one instance — the second setRate() call would win for both, since both
    ///      legs' calldata get built before either actually executes. Single-leg tests just
    ///      pass the shared `router`; multi-leg tests must use one instance per leg.
    function _buildIncreaseSwap(MockSwapRouter targetRouter, address collateralToken, address oracle, uint256 totalAmountUsdc)
        internal
        returns (bytes memory data, uint256 expectedOut)
    {
        uint256 price = IOracle(oracle).price();
        uint256 rate = 1e54 / price; // collateralRaw out per usdcRaw in, scaled by 1e18
        targetRouter.setRate(rate);
        expectedOut = (totalAmountUsdc * rate) / 1e18;
        deal(collateralToken, address(targetRouter), expectedOut);
        data = abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(collateralToken), totalAmountUsdc));
    }

    function _buildIncreaseSwap(address collateralToken, address oracle, uint256 totalAmountUsdc)
        internal
        returns (bytes memory data, uint256 expectedOut)
    {
        return _buildIncreaseSwap(router, collateralToken, oracle, totalAmountUsdc);
    }

    function _buildDecreaseSwap(MockSwapRouter targetRouter, address collateralToken, address oracle, uint256 collateralAmount)
        internal
        returns (bytes memory data, uint256 expectedOut)
    {
        uint256 price = IOracle(oracle).price();
        uint256 rate = price / 1e18; // usdcRaw out per collateralRaw in, scaled by 1e18
        targetRouter.setRate(rate);
        expectedOut = (collateralAmount * rate) / 1e18;
        deal(USDC, address(targetRouter), expectedOut);
        data = abi.encodeCall(MockSwapRouter.swap, (IERC20(collateralToken), IERC20(USDC), collateralAmount));
    }

    function _buildDecreaseSwap(address collateralToken, address oracle, uint256 collateralAmount)
        internal
        returns (bytes memory data, uint256 expectedOut)
    {
        return _buildDecreaseSwap(router, collateralToken, oracle, collateralAmount);
    }

    /// @dev Opens a leveraged position via executeActions, returning the collateral
    ///      actually delivered by the mock swap (== the position's collateral, since the
    ///      engine supplies GeneralAdapter1's full post-swap balance).
    function _openPosition(Id id, MarketParams memory params, address oracle, uint256 ownAmount)
        internal
        returns (uint256 collateralDelivered)
    {
        return _openPositionWithLeverage(id, params, oracle, ownAmount, LEVERAGE_2X);
    }

    /// @dev Same as _openPosition, but with leverage as an explicit parameter, passed
    ///      straight through in the action itself rather than configured on the market —
    ///      used by the fuzz tests below to vary leverage per run with no owner call
    ///      needed, only the registered ceiling in setUp bounds what's allowed.
    function _openPositionWithLeverage(
        Id id,
        MarketParams memory params,
        address oracle,
        uint256 ownAmount,
        uint256 leverage
    ) internal returns (uint256 collateralDelivered) {
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        (bytes memory data, uint256 expectedOut) = _buildIncreaseSwap(params.collateralToken, oracle, totalAmount);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: id,
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: expectedOut,
            swapTarget: address(router),
            swapCalldata: data
        });

        vm.prank(owner);
        vault.executeActions(actions);
        return expectedOut;
    }

    /// @dev Mirrors _planDecrease's own math exactly — this is precisely the computation a
    ///      real off-chain allocator must do ahead of time to build correct calldata, not a
    ///      testing shortcut.
    function _planDecrease(Id id, MarketParams memory params, uint256 requestedAmount)
        internal
        returns (uint256 collateralToWithdraw, uint256 flashloanAmount)
    {
        IMorpho(MORPHO).accrueInterest(params);
        (, uint128 borrowSharesRaw, uint128 collateralRaw) = IMorpho(MORPHO).position(id, address(vault));

        bool isFullClose = requestedAmount == type(uint256).max;
        collateralToWithdraw = isFullClose ? uint256(collateralRaw) : requestedAmount;

        if (borrowSharesRaw > 0) {
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(id);
            uint256 totalDebt = MorphoSharesMath.toAssetsUp(borrowSharesRaw, totalBorrowAssets, totalBorrowShares);
            flashloanAmount =
                isFullClose ? totalDebt : (totalDebt * collateralToWithdraw) / uint256(collateralRaw);
        }
    }

    function _decreasePosition(Id id, MarketParams memory params, uint256 requestedAmount) internal {
        (uint256 collateralToWithdraw,) = _planDecrease(id, params, requestedAmount);
        (bytes memory data, uint256 expectedOut) =
            _buildDecreaseSwap(params.collateralToken, params.oracle, collateralToWithdraw);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: id,
            isIncrease: false,
            amount: requestedAmount,
            leverage: 0, // ignored for decreases
            minOut: expectedOut,
            swapTarget: address(router),
            swapCalldata: data
        });

        vm.prank(owner);
        vault.executeActions(actions);
    }

    /// @dev Mirrors _planDeleverage's own math exactly, share-based repay amount included:
    ///      computing the repay in Morpho's own share unit (not a separately-rounded value
    ///      estimate) is what keeps it safely bounded by what's actually outstanding, so
    ///      this mirrors that precisely rather than approximating it.
    function _planDeleverage(Id id, MarketParams memory params, uint256 targetLeverage)
        internal
        returns (uint256 collateralToWithdraw, uint256 repayAmount)
    {
        IMorpho(MORPHO).accrueInterest(params);
        (, uint128 borrowSharesRaw, uint128 collateralRaw) = IMorpho(MORPHO).position(id, address(vault));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(id);

        uint256 price = IOracle(params.oracle).price();
        uint256 collateralValue = MorphoSharesMath.mulDivDown(collateralRaw, price, MorphoSharesMath.ORACLE_PRICE_SCALE);
        uint256 debtValue = borrowSharesRaw > 0
            ? MorphoSharesMath.toAssetsUp(borrowSharesRaw, totalBorrowAssets, totalBorrowShares)
            : 0;

        uint256 equity = collateralValue - debtValue;
        uint256 newCollateralValue = (targetLeverage * equity) / 1e18;

        uint256 repayShares;
        if (targetLeverage == 1e18) {
            repayShares = borrowSharesRaw;
        } else {
            uint256 newDebtValue = newCollateralValue - equity;
            uint256 targetBorrowShares = MorphoSharesMath.toSharesDown(newDebtValue, totalBorrowAssets, totalBorrowShares);
            if (targetBorrowShares > borrowSharesRaw) targetBorrowShares = borrowSharesRaw;
            repayShares = borrowSharesRaw - targetBorrowShares;
        }

        repayAmount = MorphoSharesMath.toAssetsUp(repayShares, totalBorrowAssets, totalBorrowShares);
        collateralToWithdraw = MorphoSharesMath.mulDivUp(repayAmount, MorphoSharesMath.ORACLE_PRICE_SCALE, price);
    }

    /// @dev Shared live-state reader for the deleverage assertions below — pulled out
    ///      purely to keep the test functions under Solidity's stack-depth limit.
    function _readEquityAndLeverage(Id id, address oracle) internal view returns (uint256 equity, uint256 leverage) {
        (, uint128 borrowSharesRaw, uint128 collateralRaw) = IMorpho(MORPHO).position(id, address(vault));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(id);
        uint256 price = IOracle(oracle).price();
        uint256 collateralValue = MorphoSharesMath.mulDivDown(collateralRaw, price, MorphoSharesMath.ORACLE_PRICE_SCALE);
        uint256 debtValue = borrowSharesRaw > 0
            ? MorphoSharesMath.toAssetsUp(borrowSharesRaw, totalBorrowAssets, totalBorrowShares)
            : 0;
        equity = collateralValue - debtValue;
        leverage = (collateralValue * 1e18) / equity;
    }

    function _deleveragePosition(Id id, MarketParams memory params, uint256 targetLeverage) internal {
        (uint256 collateralToWithdraw, uint256 repayAmount) = _planDeleverage(id, params, targetLeverage);

        // Rate rounded up so collateralToWithdraw*rate/1e18 is guaranteed >= repayAmount —
        // _buildDecreaseSwap's own price-based rate rounds independently of this plan's
        // own math and can leave the flashloan a couple wei short.
        uint256 rate = MorphoSharesMath.mulDivUp(repayAmount, 1e18, collateralToWithdraw);
        uint256 expectedOut = (collateralToWithdraw * rate) / 1e18;
        router.setRate(rate);
        deal(USDC, address(router), expectedOut);
        bytes memory data =
            abi.encodeCall(MockSwapRouter.swap, (IERC20(params.collateralToken), IERC20(USDC), collateralToWithdraw));

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: id,
            isIncrease: false,
            amount: 0, // ignored when leverage > 0
            leverage: targetLeverage,
            minOut: repayAmount,
            swapTarget: address(router),
            swapCalldata: data
        });

        vm.prank(owner);
        vault.executeActions(actions);
    }

    /*//////////////////////////////////////////////////////////////
                                 INCREASE
    //////////////////////////////////////////////////////////////*/

    function test_increasePosition_opensLeveragedPosition() public {
        uint256 ownAmount = 100_000e6;
        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WSTETH).balanceOf(GENERAL_ADAPTER);

        uint256 collateralDelivered = _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, ownAmount);

        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(uint256(collateral), collateralDelivered, "all delivered collateral should be supplied");
        assertGt(borrowShares, 0, "position should have real debt");

        // The whole point of the flashloan-atomic design: nothing should be left behind on
        // the shared real adapter or on our own dedicated swap executor.
        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WSTETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), 0);
        assertEq(IERC20(WSTETH).balanceOf(address(swapExecutor)), 0);

        Id[] memory active = vault.activeMarkets();
        assertEq(active.length, 1);
        assertEq(Id.unwrap(active[0]), Id.unwrap(wstEthMarketId));
    }

    function test_increasePosition_revertsIfMarketNotEnabled() public {
        vm.prank(owner);
        vault.setMarketEnabled(wstEthMarketId, false);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: 1_000e6,
            leverage: LEVERAGE_2X,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MorphoLeverageEngine.MarketNotEnabled.selector, wstEthMarketId));
        vault.executeActions(actions);
    }

    function test_increasePosition_revertsIfLeverageBelowOneX() public {
        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: 1_000e6,
            leverage: 1e18 - 1,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MorphoLeverageEngine.LeverageBelowOneX.selector, 1e18 - 1));
        vault.executeActions(actions);
    }

    function test_increasePosition_revertsIfLeverageExceedsMax() public {
        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: 1_000e6,
            leverage: MAX_LEVERAGE_CEILING + 1,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoLeverageEngine.LeverageExceedsMax.selector, MAX_LEVERAGE_CEILING + 1, MAX_LEVERAGE_CEILING
            )
        );
        vault.executeActions(actions);
    }

    function testFuzz_increasePosition_revertsIfLeverageBelowOneX(uint256 leverage) public {
        leverage = bound(leverage, 0, 1e18 - 1);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: 1_000e6,
            leverage: leverage,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MorphoLeverageEngine.LeverageBelowOneX.selector, leverage));
        vault.executeActions(actions);
    }

    function testFuzz_increasePosition_revertsIfLeverageExceedsMax(uint256 leverage) public {
        leverage = bound(leverage, MAX_LEVERAGE_CEILING + 1, type(uint128).max);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: 1_000e6,
            leverage: leverage,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoLeverageEngine.LeverageExceedsMax.selector, leverage, MAX_LEVERAGE_CEILING)
        );
        vault.executeActions(actions);
    }

    /// @dev An action requesting exactly 1e18 leverage should supply collateral with zero
    ///      borrow, not revert — the flashloan's borrow leg is simply omitted. No owner
    ///      call needed: 1e18 is always within any market's ceiling.
    function test_increasePosition_atOneXLeverage_suppliesWithNoDebt() public {
        uint256 ownAmount = 50_000e6;
        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WETH).balanceOf(GENERAL_ADAPTER);

        uint256 collateralDelivered =
            _openPositionWithLeverage(wethMarketId, wethParams, WETH_ORACLE, ownAmount, 1e18);

        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(wethMarketId, address(vault));
        assertEq(uint256(collateral), collateralDelivered, "all delivered collateral should be supplied");
        assertEq(borrowShares, 0, "1x should never open any debt");

        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), 0);
        assertEq(IERC20(WETH).balanceOf(address(swapExecutor)), 0);

        Id[] memory active = vault.activeMarkets();
        assertEq(active.length, 1);
        assertEq(Id.unwrap(active[0]), Id.unwrap(wethMarketId));
    }

    /*//////////////////////////////////////////////////////////////
                                 DECREASE
    //////////////////////////////////////////////////////////////*/

    /// @dev Closing a 1x (zero-debt) position takes _decreasePosition's no-flashloan
    ///      branch — the only existing coverage of that branch used a position that never
    ///      had debt to begin with, not one opened for real through the increase path.
    function test_decreasePosition_atOneXLeverage_withdrawsWithoutFlashloan() public {
        _openPositionWithLeverage(wethMarketId, wethParams, WETH_ORACLE, 50_000e6, 1e18);

        uint256 idleBefore = IERC20(USDC).balanceOf(address(vault));
        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WETH).balanceOf(GENERAL_ADAPTER);

        _decreasePosition(wethMarketId, wethParams, type(uint256).max);

        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(wethMarketId, address(vault));
        assertEq(collateral, 0, "full close should leave zero collateral");
        assertEq(borrowShares, 0);

        assertGt(IERC20(USDC).balanceOf(address(vault)), idleBefore, "proceeds should land back on the vault");
        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), 0);
        assertEq(IERC20(WETH).balanceOf(address(swapExecutor)), 0);

        assertEq(vault.activeMarkets().length, 0, "full close should deactivate the market");
    }

    function test_decreasePosition_partialReducesProportionally() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        (,, uint128 collateralBefore) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 withdrawAmount = uint256(collateralBefore) / 2;

        _decreasePosition(wstEthMarketId, wstEthParams, withdrawAmount);

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateralAfter, collateralBefore - withdrawAmount);
        assertGt(borrowSharesAfter, 0, "partial decrease should leave some debt");

        Id[] memory active = vault.activeMarkets();
        assertEq(active.length, 1, "partial decrease should not deactivate the market");
    }

    function test_decreasePosition_fullCloseRepaysByExactShares() public {
        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WSTETH).balanceOf(GENERAL_ADAPTER);

        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);
        _decreasePosition(wstEthMarketId, wstEthParams, type(uint256).max);

        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateral, 0, "full close should leave zero collateral");
        assertEq(borrowShares, 0, "full close should leave zero debt");

        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WSTETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), 0);
        assertEq(IERC20(WSTETH).balanceOf(address(swapExecutor)), 0);

        assertEq(vault.activeMarkets().length, 0, "full close should deactivate the market");
    }

    /// @dev Self-funded deleverage: withdraw collateral, swap it, repay debt with the
    ///      proceeds, holding equity roughly constant while leverage drops.
    function test_decreasePosition_deleveragesToTargetRatio() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        (, uint128 borrowSharesBefore, uint128 collateralBefore) =
            IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        (uint256 equityBefore,) = _readEquityAndLeverage(wstEthMarketId, WSTETH_ORACLE);

        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WSTETH).balanceOf(GENERAL_ADAPTER);

        _deleveragePosition(wstEthMarketId, wstEthParams, 1.5e18);

        (, uint128 borrowSharesAfter, uint128 collateralAfter) =
            IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertLt(collateralAfter, collateralBefore, "collateral should shrink");
        assertLt(borrowSharesAfter, borrowSharesBefore, "debt should shrink");
        assertGt(borrowSharesAfter, 0, "1.5x should still leave some debt");

        (uint256 equityAfter, uint256 realizedLeverage) = _readEquityAndLeverage(wstEthMarketId, WSTETH_ORACLE);

        // Rounding in collateralToWithdraw always rounds up (withdraws slightly more than
        // the bare minimum), so realized leverage should land at or just under the target.
        assertLe(realizedLeverage, 1.5e18, "should never overshoot past the target leverage");
        assertApproxEqAbs(realizedLeverage, 1.5e18, 0.001e18, "realized leverage should land close to target");
        assertApproxEqRel(equityAfter, equityBefore, 0.001e18, "equity should stay roughly constant, self-funded");

        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WSTETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), 0);
        assertEq(IERC20(WSTETH).balanceOf(address(swapExecutor)), 0);

        assertEq(vault.activeMarkets().length, 1, "deleverage should never deactivate the market");
    }

    /// @dev Deleveraging all the way to 1x should pay off every last bit of debt (via
    ///      exact-shares repay, not a rounded value) while still leaving collateral behind
    ///      rather than closing the position outright.
    function test_decreasePosition_deleverageToOneX_paysOffDebtButKeepsCollateral() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        _deleveragePosition(wstEthMarketId, wstEthParams, 1e18);

        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(borrowShares, 0, "1x should pay off all debt");
        assertGt(collateral, 0, "1x should still leave collateral behind, unlike a full close");

        assertEq(vault.activeMarkets().length, 1, "deleverage to 1x should never deactivate the market");
    }

    function test_decreasePosition_revertsIfDeleverageTargetBelowOneX() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: 0,
            leverage: 1e18 - 1,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MorphoLeverageEngine.LeverageBelowOneX.selector, 1e18 - 1));
        vault.executeActions(actions);
    }

    function test_decreasePosition_revertsIfDeleverageTargetNotBelowCurrent() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        (, uint256 currentLeverage) = _readEquityAndLeverage(wstEthMarketId, WSTETH_ORACLE);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: 0,
            leverage: currentLeverage,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoLeverageEngine.TargetLeverageNotBelowCurrent.selector, currentLeverage, currentLeverage
            )
        );
        vault.executeActions(actions);
    }

    /// @dev Fuzzes both the starting leverage and how far below it the target sits,
    ///      confirming the realized leverage always lands at or under the target and
    ///      equity stays roughly flat regardless of the specific starting point.
    function testFuzz_decreasePosition_deleveragesToAnyValidTarget(uint256 startLeverage, uint256 targetFraction)
        public
    {
        startLeverage = bound(startLeverage, 1.1e18, 5e18);
        // Target somewhere between 1x and just under the starting leverage.
        targetFraction = bound(targetFraction, 0, 0.999e18);
        uint256 targetLeverage = 1e18 + ((startLeverage - 1e18) * targetFraction) / 1e18;

        _openPositionWithLeverage(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6, startLeverage);
        (uint256 equityBefore,) = _readEquityAndLeverage(wstEthMarketId, WSTETH_ORACLE);

        _deleveragePosition(wstEthMarketId, wstEthParams, targetLeverage);

        (, uint128 borrowSharesAfter, uint128 collateralAfter) =
            IMorpho(MORPHO).position(wstEthMarketId, address(vault));

        // Not asserting "some debt remains" for target > 1x: the conservative rounding in
        // _planDeleverage (never leave the position above target) means a target very
        // close to 1x can legitimately round down to a full payoff too, same as target
        // == 1x exactly. Only exact 1x is asserted precisely; collateral surviving is the
        // one invariant that holds unconditionally.
        if (targetLeverage == 1e18) {
            assertEq(borrowSharesAfter, 0);
        }
        assertGt(collateralAfter, 0, "deleverage should never fully close the position");

        (uint256 equityAfter, uint256 realizedLeverage) = _readEquityAndLeverage(wstEthMarketId, WSTETH_ORACLE);
        if (targetLeverage > 1e18) {
            assertLe(realizedLeverage, targetLeverage, "should never overshoot past the target leverage");
        }
        assertApproxEqRel(equityAfter, equityBefore, 0.001e18, "equity should stay roughly constant, self-funded");
    }

    /*//////////////////////////////////////////////////////////////
                            MULTI-MARKET REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_executeActions_rebalanceAcrossTwoMarkets() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        (uint256 collateralToWithdraw,) = _planDecrease(wstEthMarketId, wstEthParams, type(uint256).max);
        (bytes memory decreaseData, uint256 decreaseExpectedOut) =
            _buildDecreaseSwap(router, WSTETH, WSTETH_ORACLE, collateralToWithdraw);

        // A second, independent router for the increase leg — both legs' calldata are
        // built upfront, before executeActions runs either of them, so a single shared
        // router's mutable rate would be left holding whichever leg configured it last.
        MockSwapRouter router2 = new MockSwapRouter();
        uint256 wethOwnAmount = 50_000e6;
        uint256 wethTotalAmount = (wethOwnAmount * LEVERAGE_2X) / 1e18;
        (bytes memory increaseData, uint256 increaseExpectedOut) =
            _buildIncreaseSwap(router2, WETH, WETH_ORACLE, wethTotalAmount);

        MarketAction[] memory actions = new MarketAction[](2);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: type(uint256).max,
            leverage: 0, // ignored for decreases
            minOut: decreaseExpectedOut,
            swapTarget: address(router),
            swapCalldata: decreaseData
        });
        actions[1] = MarketAction({
            marketId: wethMarketId,
            isIncrease: true,
            amount: wethOwnAmount,
            leverage: LEVERAGE_2X,
            minOut: increaseExpectedOut,
            swapTarget: address(router2),
            swapCalldata: increaseData
        });

        vm.prank(owner);
        vault.executeActions(actions);

        (, uint128 wstEthBorrowShares, uint128 wstEthCollateral) =
            IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(wstEthCollateral, 0);
        assertEq(wstEthBorrowShares, 0);

        (, uint128 wethBorrowShares, uint128 wethCollateral) = IMorpho(MORPHO).position(wethMarketId, address(vault));
        assertEq(wethCollateral, increaseExpectedOut);
        assertGt(wethBorrowShares, 0);

        Id[] memory active = vault.activeMarkets();
        assertEq(active.length, 1);
        assertEq(Id.unwrap(active[0]), Id.unwrap(wethMarketId));
    }

    /*//////////////////////////////////////////////////////////////
                              ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_executeActions_revertsForNonAllocator() public {
        MarketAction[] memory actions = new MarketAction[](0);

        vm.prank(stranger);
        vm.expectRevert(MorphoLeverageVault.NotAllocator.selector);
        vault.executeActions(actions);
    }

    /*//////////////////////////////////////////////////////////////
                                VALUATION
    //////////////////////////////////////////////////////////////*/

    function test_totalAssets_and_totalMorphoAssets_trackRealState() public {
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.totalMorphoAssets(), 0);

        uint256 ownAmount = 100_000e6;
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, ownAmount);

        uint256 idle = IERC20(USDC).balanceOf(address(vault));
        assertEq(idle, DEPOSIT_AMOUNT - ownAmount);

        uint256 morphoAssets = vault.totalMorphoAssets();
        assertGt(morphoAssets, 0);
        // The mock swap's rate is derived from the same oracle price used for valuation, so
        // the freshly opened position's net value should track our own contribution closely
        // (small deviation only from the borrow-side toAssetsUp rounding).
        assertApproxEqAbs(morphoAssets, ownAmount, 10);

        assertEq(vault.totalAssets(), idle + morphoAssets);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW/REDEEM CLAMP
    //////////////////////////////////////////////////////////////*/

    function test_maxWithdraw_and_maxRedeem_clampToIdleBalanceOnly() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        uint256 idle = IERC20(USDC).balanceOf(address(vault));
        uint256 trueOwnerAssets = vault.convertToAssets(vault.balanceOf(depositor));

        // The position has real value, so the depositor's true share of assets exceeds idle
        // balance — proving the clamp below is actually binding, not vacuously true.
        assertGt(trueOwnerAssets, idle);

        // maxWithdraw = previewRedeem(maxRedeem(owner)) per OZ's base ERC4626, and since
        // maxRedeem is itself overridden to clamp to idle, this round-trips idle through
        // shares and back (Floor both ways) — losing at most a wei or two, never exceeding
        // idle. That's the actual guarantee worth asserting, not bit-for-bit equality.
        assertLe(vault.maxWithdraw(depositor), idle);
        assertApproxEqAbs(vault.maxWithdraw(depositor), idle, 2);
        assertEq(vault.maxRedeem(depositor), vault.convertToShares(idle));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Bounds keep the borrow leg comfortably under the wstETH/USDC market's real
    ///      available liquidity at the pinned block (~$796k) and leverage under a level
    ///      that would breach the real 86% LLTV — Morpho's own health check would revert
    ///      first if these were wrong, but the point is to fuzz realistic, passing
    ///      scenarios, not to fuzz-discover the liquidity/LLTV ceiling itself.
    function testFuzz_increasePosition_forAnyValidOwnAmountAndLeverage(uint256 ownAmount, uint256 leverage) public {
        ownAmount = bound(ownAmount, 1e6, 100_000e6);
        leverage = bound(leverage, 1.01e18, 5e18);

        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WSTETH).balanceOf(GENERAL_ADAPTER);

        uint256 collateralDelivered =
            _openPositionWithLeverage(wstEthMarketId, wstEthParams, WSTETH_ORACLE, ownAmount, leverage);

        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(uint256(collateral), collateralDelivered, "all delivered collateral should be supplied");
        assertGt(borrowShares, 0, "position should have real debt for any leverage > 1x");

        // Independent re-derivation of the health check, using the same real oracle price
        // Morpho itself uses — not just trusting that the real borrow() call didn't revert.
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 borrowAmount = totalAmount - ownAmount;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 collateralValue =
            MorphoSharesMath.mulDivDown(collateralDelivered, price, MorphoSharesMath.ORACLE_PRICE_SCALE);
        assertLe(borrowAmount, (collateralValue * LLTV_86) / 1e18, "position must stay within the real 86% LLTV");

        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WSTETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), 0);
        assertEq(IERC20(WSTETH).balanceOf(address(swapExecutor)), 0);
    }

    function testFuzz_decreasePosition_forAnyValidPartialAmount(uint256 ownAmount, uint256 leverage, uint256 withdrawPct)
        public
    {
        ownAmount = bound(ownAmount, 1e6, 100_000e6);
        leverage = bound(leverage, 1.01e18, 5e18);
        withdrawPct = bound(withdrawPct, 1, 99); // strictly partial — full close is covered separately

        _openPositionWithLeverage(wstEthMarketId, wstEthParams, WSTETH_ORACLE, ownAmount, leverage);

        (, uint128 borrowSharesBefore, uint128 collateralBefore) =
            IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 withdrawAmount = (uint256(collateralBefore) * withdrawPct) / 100;
        vm.assume(withdrawAmount > 0);

        uint256 adapterUsdcBefore = IERC20(USDC).balanceOf(GENERAL_ADAPTER);
        uint256 adapterCollateralBefore = IERC20(WSTETH).balanceOf(GENERAL_ADAPTER);

        _decreasePosition(wstEthMarketId, wstEthParams, withdrawAmount);

        (, uint128 borrowSharesAfter, uint128 collateralAfter) =
            IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateralAfter, collateralBefore - withdrawAmount, "collateral must drop by exactly the requested amount");
        assertLe(borrowSharesAfter, borrowSharesBefore, "debt must never increase from a decrease");
        assertGt(borrowSharesAfter, 0, "a <100% withdraw of collateral must never fully clear debt");

        assertEq(IERC20(USDC).balanceOf(GENERAL_ADAPTER), adapterUsdcBefore, "GeneralAdapter1 USDC dust");
        assertEq(
            IERC20(WSTETH).balanceOf(GENERAL_ADAPTER), adapterCollateralBefore, "GeneralAdapter1 collateral dust"
        );
        assertEq(vault.activeMarkets().length, 1, "partial decrease should never deactivate the market");
    }

    /*//////////////////////////////////////////////////////////////
                              CIRCUIT BREAKER
    //////////////////////////////////////////////////////////////*/

    /// @dev emergencyDecrease must survive exactly the scenario it exists for: RiskLimits
    ///      paused and a market's rate limit already exhausted, both of which would block a
    ///      normal allocator action -- see MorphoLeverageEngine._emergencyDecreasePosition.
    function test_emergencyDecrease_worksWhilePausedAndRateLimited() public {
        _openPosition(wstEthMarketId, wstEthParams, WSTETH_ORACLE, 100_000e6);

        RiskLimits limits = RiskLimits(vault.riskLimits());
        vm.startPrank(owner);
        limits.setPaused(true);
        limits.setRateLimitWindowSeconds(1 days);
        limits.setMaxExposureChangePerWindow(wstEthMarketId, 1); // exhausted by anything real
        vm.stopPrank();

        // Confirm a normal allocator increase is actually blocked, not just theoretically.
        uint256 ownAmount = 1_000e6;
        (bytes memory increaseData, uint256 increaseOut) =
            _buildIncreaseSwap(WSTETH, WSTETH_ORACLE, (ownAmount * LEVERAGE_2X) / 1e18);
        MarketAction[] memory increaseActions = new MarketAction[](1);
        increaseActions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: LEVERAGE_2X,
            minOut: increaseOut,
            swapTarget: address(router),
            swapCalldata: increaseData
        });
        vm.prank(owner);
        vm.expectRevert(RiskLimits.Paused.selector);
        vault.executeActions(increaseActions);

        // The owner's emergency exit still works, bypassing RiskLimits entirely.
        (,, uint128 collateralBefore) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 withdrawAmount = uint256(collateralBefore) / 2;
        (bytes memory decreaseData, uint256 decreaseOut) = _buildDecreaseSwap(WSTETH, WSTETH_ORACLE, withdrawAmount);

        MarketAction memory emergencyAction = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: withdrawAmount,
            leverage: 0,
            minOut: decreaseOut,
            swapTarget: address(router),
            swapCalldata: decreaseData
        });

        vm.prank(owner);
        vault.emergencyDecrease(emergencyAction);

        (,, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(
            collateralAfter, collateralBefore - withdrawAmount, "emergency decrease succeeded despite pause + rate limit"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        REALIZED SLIPPAGE CEILING
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds an increase swap that deliberately under-delivers by `shortfallBps`
    ///      against the oracle rate, so the trade's realized slippage is a known quantity.
    function _buildLossyIncreaseSwap(address collateralToken, address oracle, uint256 totalAmountUsdc, uint256 shortfallBps)
        internal
        returns (bytes memory data, uint256 delivered)
    {
        uint256 rate = ((1e54 / IOracle(oracle).price()) * (10_000 - shortfallBps)) / 10_000;
        router.setRate(rate);
        delivered = (totalAmountUsdc * rate) / 1e18;
        deal(collateralToken, address(router), delivered);
        data = abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(collateralToken), totalAmountUsdc));
    }

    function _increaseWithSwap(uint256 ownAmount, bytes memory data, uint256 minOut) internal {
        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: LEVERAGE_2X,
            minOut: minOut,
            swapTarget: address(router),
            swapCalldata: data
        });
        vm.prank(owner);
        vault.executeActions(actions);
    }

    /// @dev The ceiling measures what a trade actually cost, not what the market's config
    ///      would have permitted. A clean fill has to pass a ceiling tighter than the
    ///      market's own maxSlippageBps, which is the whole distinction: previously the
    ///      engine reported the static config value here, so any ceiling below
    ///      SLIPPAGE_BPS rejected every trade including a perfect one.
    function test_slippageCeiling_cleanFillPassesCeilingBelowMarketMax() public {
        RiskLimits limits = RiskLimits(vault.riskLimits());
        vm.prank(owner);
        limits.setMaxSlippageBpsCeiling(40); // below the market's SLIPPAGE_BPS of 50

        uint256 ownAmount = 10_000e6;
        (bytes memory data, uint256 expectedOut) =
            _buildIncreaseSwap(WSTETH, WSTETH_ORACLE, (ownAmount * LEVERAGE_2X) / 1e18);

        _increaseWithSwap(ownAmount, data, expectedOut);

        (,, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertGt(collateral, 0, "a zero-slippage fill must clear a 40bps ceiling");
    }

    /// @dev And a fill that really does lose more than the ceiling is rejected, even though
    ///      it clears the market's own oracle floor and would have executed fine before.
    function test_slippageCeiling_lossyFillIsRejectedAfterTheFact() public {
        RiskLimits limits = RiskLimits(vault.riskLimits());
        vm.prank(owner);
        limits.setMaxSlippageBpsCeiling(20);

        uint256 ownAmount = 10_000e6;
        // 45bps of real loss: inside the market's 50bps oracle floor, so minOut passes and
        // the swap executes, but past the 20bps ceiling once measured.
        (bytes memory data,) = _buildLossyIncreaseSwap(WSTETH, WSTETH_ORACLE, (ownAmount * LEVERAGE_2X) / 1e18, 45);

        // Asserts the measured figure, not just that it reverted: 45 in, 45 reported back.
        vm.expectRevert(abi.encodeWithSelector(RiskLimits.SlippageCeilingExceeded.selector, 45, 20));
        _increaseWithSwap(ownAmount, data, 0); // minOut 0 -> defers to the oracle floor
    }
}
