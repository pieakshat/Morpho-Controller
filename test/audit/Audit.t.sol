// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

/// @dev Swap target that delivers an exact, caller-chosen amount of tokenOut and keeps the
///      rest of tokenIn. Models a compromised allocator routing through a venue it controls.
contract SkimmingRouter {
    address public immutable thief;
    uint256 public deliverAmount;

    constructor(address thief_) {
        thief = thief_;
    }

    function setDeliver(uint256 amount) external {
        deliverAmount = amount;
    }

    function swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn) external {
        tokenIn.transferFrom(msg.sender, thief, amountIn);
        tokenOut.transfer(msg.sender, deliverAmount);
    }
}

/// @dev Swap target that simply spends the allowance the executor granted it. Used to show
///      that any balance sitting in MorphoSwapExecutor is permissionlessly extractable.
contract ApprovalDrainer {
    function drain(IERC20 token, address victim, address to, uint256 amount) external {
        token.transferFrom(victim, to, amount);
    }
}

/// @dev Swap target that attempts to reenter the vault mid-bundle.
contract Reenterer {
    MorphoLeverageVault public immutable vault;
    bool public attempted;
    bool public succeeded;

    constructor(MorphoLeverageVault vault_) {
        vault = vault_;
    }

    function swap(IERC20, IERC20 tokenOut, uint256) external {
        attempted = true;
        try vault.deposit(1, address(this)) {
            succeeded = true;
        } catch {
            succeeded = false;
        }
        tokenOut.transfer(msg.sender, tokenOut.balanceOf(address(this)));
    }
}

/// @notice Adversarial audit suite. Each test states a hypothesis about a flaw and either
///         confirms it against real Arbitrum state or refutes it.
contract AuditTest is Test {
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
    uint256 constant FORK_BLOCK = 491_260_000;

    uint256 constant MAX_LEVERAGE_CEILING = 10e18;
    uint256 constant SLIPPAGE_BPS = 50;
    uint256 constant DEPOSIT_AMOUNT = 1_000_000e6;

    MorphoLeverageVault vault;
    MorphoSwapExecutor swapExecutor;
    MockSwapRouter router;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");
    address attacker = makeAddr("attacker");

    MarketParams wstEthParams;
    Id wstEthMarketId;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);

        router = new MockSwapRouter();

        vault = new MorphoLeverageVault(
            IERC20(USDC), owner, IMorpho(MORPHO), IBundler3(BUNDLER3), IGeneralAdapter1(GENERAL_ADAPTER)
        );
        swapExecutor = MorphoSwapExecutor(vault.swapExecutor());

        wstEthParams =
            MarketParams({loanToken: USDC, collateralToken: WSTETH, oracle: WSTETH_ORACLE, irm: IRM, lltv: LLTV_86});

        vm.prank(owner);
        wstEthMarketId = vault.registerMarket(wstEthParams, MAX_LEVERAGE_CEILING, SLIPPAGE_BPS);

        deal(USDC, depositor, DEPOSIT_AMOUNT);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, depositor);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  HELPERS
    //////////////////////////////////////////////////////////////*/

    function _openPosition(uint256 ownAmount, uint256 leverage) internal returns (uint256 collateralOut) {
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 rate = 1e54 / price;
        router.setRate(rate);
        collateralOut = (totalAmount * rate) / 1e18;
        deal(WSTETH, address(router), collateralOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: collateralOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        vm.prank(owner);
        vault.executeActions(actions);
    }

    /// @dev Splits preparation from execution so vm.expectRevert can target the vault call
    ///      itself rather than an incidental setup call.
    function _prepDecrease(uint256 collateralAmount) internal returns (MarketAction[] memory actions) {
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 rate = price / 1e18;
        router.setRate(rate);

        // The max sentinel means "all of it" to the vault, but the mock router still needs
        // a concrete amount to price and fund the swap leg with.
        (,, uint128 collateralRaw) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 swapAmount = collateralAmount == type(uint256).max ? uint256(collateralRaw) : collateralAmount;
        deal(USDC, address(router), (swapAmount * rate) / 1e18);

        actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: collateralAmount,
            leverage: 0,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(WSTETH), IERC20(USDC), swapAmount))
        });
    }

    function _decreaseByAmount(uint256 collateralAmount) internal {
        MarketAction[] memory actions = _prepDecrease(collateralAmount);
        vm.prank(owner);
        vault.executeActions(actions);
    }

    /// @dev Returns true if a proportional decrease of this size succeeds, without
    ///      propagating the revert, so a boundary can be searched for.
    function _tryDecrease(uint256 collateralAmount) internal returns (bool ok) {
        MarketAction[] memory actions = _prepDecrease(collateralAmount);
        vm.prank(owner);
        try vault.executeActions(actions) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /*//////////////////////////////////////////////////////////////
        H1: decrease with amount == exact full collateral reverts
    //////////////////////////////////////////////////////////////*/

    /// @dev The existing fuzz test bounds withdrawPct to 1..99, never touching the top of
    ///      the range. Scan where the proportional decrease actually stops working.
    /// @dev FIXED. Every size up to and including exactly 100% now works. The 100% case
    ///      used to revert with a bare arithmetic underflow from inside Morpho, because the
    ///      proportional repay resolved to more borrow shares than the position held.
    ///      _planDecrease now routes a full-balance request through the exact-shares path.
    function test_H1_proportionalDecreaseWorksAtEverySizeIncludingFull() public {
        _openPosition(100_000e6, 2e18);
        (,, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 snap = vm.snapshotState();

        uint256[6] memory bps = [uint256(9000), 9500, 9900, 9990, 9999, 10000];
        for (uint256 i = 0; i < 6; ++i) {
            bool ok = _tryDecrease((uint256(collateral) * bps[i]) / 10_000);
            console2.log("withdraw bps / succeeded:", bps[i], ok);
            assertTrue(ok, "every withdrawal size should settle");
            vm.revertToState(snap);
        }

        // The exact-100% case is what an allocator naturally reaches for to fully exit
        // without knowing about the type(uint256).max sentinel. It now behaves identically.
        _decreaseByAmount(uint256(collateral));

        (, uint128 sharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateralAfter, 0, "position fully closed");
        assertEq(sharesAfter, 0, "no dust debt left behind");
        assertEq(vault.activeMarkets().length, 0, "and the market leaves the active set");
    }

    /// @dev The documented full-close path (type(uint256).max) does work, so the failure
    ///      above is specific to expressing the same intent as an explicit amount.
    function test_H1b_fullCloseViaSentinelWorks() public {
        _openPosition(100_000e6, 2e18);
        _decreaseByAmount(type(uint256).max);

        (, uint128 sharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateralAfter, 0);
        assertEq(sharesAfter, 0);
        assertEq(vault.activeMarkets().length, 0, "sentinel path also clears the active set");
    }

    /*//////////////////////////////////////////////////////////////
        H2: MorphoSwapExecutor is permissionless
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXED. executeSwap used to have no access control, so any address could point
    ///      it at a target that spends the approval the executor grants, draining anything
    ///      sitting there. It is now gated on the caller being Bundler3 with this vault as
    ///      the bundle initiator, which no outside caller can forge.
    function test_H2_swapExecutorDrainIsBlocked() public {
        uint256 stranded = 5_000e6;
        deal(USDC, address(swapExecutor), stranded);

        ApprovalDrainer drainer = new ApprovalDrainer();

        vm.prank(attacker);
        vm.expectRevert(MorphoSwapExecutor.UnauthorizedCaller.selector);
        swapExecutor.executeSwap(
            IERC20(USDC),
            IERC20(WSTETH),
            0,
            address(drainer),
            abi.encodeCall(ApprovalDrainer.drain, (IERC20(USDC), address(swapExecutor), attacker, stranded)),
            attacker
        );

        assertEq(IERC20(USDC).balanceOf(attacker), 0, "attacker got nothing");
        assertEq(IERC20(USDC).balanceOf(address(swapExecutor)), stranded, "balance untouched");
    }

    /// @dev A router that consumes less than the full approval leaves the remainder behind,
    ///      which is what makes H2 reachable in normal operation rather than only via a
    ///      stray transfer.
    function test_H2b_partialFillStrandsTokenInInExecutor() public {
        uint256 ownAmount = 100_000e6;
        uint256 totalAmount = 200_000e6;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 rate = 1e54 / price;
        router.setRate(rate);

        // Swap calldata only consumes half of what was transferred in.
        uint256 consumed = totalAmount / 2;
        uint256 out = (consumed * rate) / 1e18;
        deal(WSTETH, address(router), out);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: 2e18,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WSTETH), consumed))
        });

        vm.prank(owner);
        try vault.executeActions(actions) {
            console2.log("partial fill accepted; USDC stranded in executor:", IERC20(USDC).balanceOf(address(swapExecutor)));
        } catch {
            console2.log("partial fill reverted (flashloan could not be covered)");
        }
    }

    /*//////////////////////////////////////////////////////////////
        H3: allocator with a low minOut extracts depositor capital
    //////////////////////////////////////////////////////////////*/

    /// @dev minOut is chosen by the same party that chooses swapTarget, so the on-chain
    ///      slippage floor constrains nothing. Quantify how much a single increase leaks.
    function test_H3_maliciousAllocatorDrainBlockedByOracleFloor() public {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 ownAmount = 100_000e6;
        uint256 totalAmount = 200_000e6;

        SkimmingRouter skimmer = new SkimmingRouter(attacker);
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 fairOut = (totalAmount * (1e54 / price)) / 1e18;

        // Deliver only enough collateral to satisfy the 86% LLTV on the borrow leg, and
        // pocket the rest. 65% clears 100k of debt against 130k of collateral.
        uint256 delivered = (fairOut * 65) / 100;
        skimmer.setDeliver(delivered);
        deal(WSTETH, address(skimmer), delivered);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: 2e18,
            minOut: 0, // allocator sets its own floor
            swapTarget: address(skimmer),
            swapCalldata: abi.encodeCall(SkimmingRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        // FIXED. Before the oracle floor existed this extracted 200,000 USDC and cost
        // depositors 70,000 in value. The engine now raises minOut to the oracle's implied
        // output less the market's tolerance, so a 65% fill can no longer settle.
        vm.prank(owner);
        vm.expectPartialRevert(MorphoSwapExecutor.SlippageExceeded.selector);
        vault.executeActions(actions);

        assertEq(IERC20(USDC).balanceOf(attacker), 0, "nothing extracted");
        assertEq(vault.totalAssets(), totalAssetsBefore, "vault value untouched");
    }

    /*//////////////////////////////////////////////////////////////
        H4: deleverage against an empty position panics
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXED. Zero equity used to panic with a bare division error. It now names the
    ///      actual condition, which matters because an allocator seeing this in a batch has
    ///      no other way to tell it apart from a genuine arithmetic bug.
    function test_H4_deleverageOnEmptyPositionRevertsWithNamedError() public {
        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: 0,
            leverage: 1.5e18,
            minOut: 0,
            swapTarget: address(router),
            swapCalldata: ""
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MorphoLeverageEngine.PositionHasNoEquity.selector, wstEthMarketId));
        vault.executeActions(actions);
    }

    /*//////////////////////////////////////////////////////////////
        H5: oracle failure bricks the whole vault
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXED. A reverting oracle used to propagate out of totalAssets(), which froze
    ///      deposits and withdrawals for the whole vault, including 900,000 of idle USDC
    ///      unrelated to that market. Valuation now degrades to a conservative number
    ///      instead of reverting.
    function test_H5_revertingOracleDegradesConservativelyInsteadOfFreezing() public {
        _openPosition(100_000e6, 2e18);

        uint256 idle = IERC20(USDC).balanceOf(address(vault));
        (, uint128 shares,) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        (,, uint128 tba, uint128 tbs,,) = IMorpho(MORPHO).market(wstEthMarketId);
        uint256 debt = MorphoSharesMath.toAssetsUp(shares, tba, tbs);

        vm.mockCallRevert(WSTETH_ORACLE, abi.encodeWithSelector(IOracle.price.selector), "ORACLE_DOWN");

        assertFalse(vault.isMarketPriceable(wstEthMarketId), "operator can see the market is unpriceable");

        // Collateral counts for nothing while unpriceable, but the debt still does, so the
        // report can only be too low, never too high.
        uint256 reported = vault.totalAssets();
        console2.log("idle:                  ", idle);
        console2.log("debt still counted:    ", debt);
        console2.log("totalAssets() reports: ", reported);
        assertEq(reported, idle - debt, "collateral valued at zero, debt still subtracted");

        // Both sides of the vault keep working against that conservative price.
        deal(USDC, attacker, 1_000e6);
        vm.startPrank(attacker);
        IERC20(USDC).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, attacker);
        vm.stopPrank();

        vm.prank(depositor);
        vault.withdraw(1_000e6, depositor, depositor);

        assertEq(IERC20(USDC).balanceOf(depositor), 1_000e6, "idle funds remain accessible");
    }

    /*//////////////////////////////////////////////////////////////
        H6: reentrancy from the swap target
    //////////////////////////////////////////////////////////////*/

    /// @dev The swap target is arbitrary and gets control mid-bundle while the position is
    ///      in an inconsistent state. Confirm the shared ReentrancyGuard actually blocks it.
    function test_H6_swapTargetCannotReenterVault() public {
        Reenterer reenterer = new Reenterer(vault);
        uint256 ownAmount = 10_000e6;
        uint256 totalAmount = 20_000e6;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 out = (totalAmount * (1e54 / price)) / 1e18;
        deal(WSTETH, address(reenterer), out);
        deal(USDC, address(reenterer), 1_000e6);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: 2e18,
            minOut: 0,
            swapTarget: address(reenterer),
            swapCalldata: abi.encodeCall(Reenterer.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        vm.prank(owner);
        vault.executeActions(actions);

        assertTrue(reenterer.attempted(), "reentrancy was attempted");
        assertFalse(reenterer.succeeded(), "reentrancy must be blocked");
    }

    /*//////////////////////////////////////////////////////////////
        H7: no post-condition on executeActions
    //////////////////////////////////////////////////////////////*/

    /// @dev There is no invariant check that a rebalance did not destroy value, so the
    ///      share price can drop arbitrarily within one allocator transaction.
    function test_H7_sharePriceCollapseBlockedByOracleFloor() public {
        uint256 sharesHeld = vault.balanceOf(depositor);
        uint256 valueBefore = vault.convertToAssets(sharesHeld);

        SkimmingRouter skimmer = new SkimmingRouter(attacker);
        // Sized to stay under the market's real ~796k USDC of available liquidity at the
        // pinned block: 350k own at 2x borrows 350k.
        uint256 ownAmount = 350_000e6;
        uint256 totalAmount = 700_000e6;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 fairOut = (totalAmount * (1e54 / price)) / 1e18;
        uint256 delivered = (fairOut * 65) / 100;
        skimmer.setDeliver(delivered);
        deal(WSTETH, address(skimmer), delivered);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: 2e18,
            minOut: 0,
            swapTarget: address(skimmer),
            swapCalldata: abi.encodeCall(SkimmingRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        // FIXED. This previously cut depositor share value by 24.5% in a single call.
        vm.prank(owner);
        vm.expectPartialRevert(MorphoSwapExecutor.SlippageExceeded.selector);
        vault.executeActions(actions);

        assertEq(vault.convertToAssets(sharesHeld), valueBefore, "share value preserved");
    }

    /*//////////////////////////////////////////////////////////////
        H12: totalAssets backstop behind the per-swap floor
    //////////////////////////////////////////////////////////////*/

    /// @dev The oracle floor caps each individual swap, but the owner can set a market's
    ///      tolerance as loose as 10%. The per-call totalAssets check is the second layer
    ///      that still catches a loss which slips under a permissive per-swap floor.
    function test_H12_totalAssetsBackstopCatchesLossUnderALooseSwapFloor() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(wstEthMarketId, 1_000); // the maximum the owner may set

        SkimmingRouter skimmer = new SkimmingRouter(attacker);
        uint256 totalAmount = 200_000e6;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 fairOut = (totalAmount * (1e54 / price)) / 1e18;

        // 91% clears the 10% per-swap floor, but still destroys ~1.8% of a 1,000,000 vault,
        // which is above the 1% default per-call tolerance.
        uint256 delivered = (fairOut * 91) / 100;
        skimmer.setDeliver(delivered);
        deal(WSTETH, address(skimmer), delivered);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: 100_000e6,
            leverage: 2e18,
            minOut: 0,
            swapTarget: address(skimmer),
            swapCalldata: abi.encodeCall(SkimmingRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        vm.prank(owner);
        vm.expectPartialRevert(MorphoLeverageVault.TotalAssetsDropped.selector);
        vault.executeActions(actions);
    }

    /// @dev The floors must not block honest operation: a fill at the oracle rate, which is
    ///      what a real venue delivers, still goes through untouched.
    function test_H12b_honestActionStillSucceeds() public {
        uint256 before = vault.totalAssets();
        _openPosition(100_000e6, 2e18);

        assertEq(vault.activeMarkets().length, 1, "position opened normally");
        assertApproxEqRel(vault.totalAssets(), before, 0.001e18, "value preserved through an honest action");
    }

    /*//////////////////////////////////////////////////////////////
        H8: idle-only withdrawal clamp under an open position
    //////////////////////////////////////////////////////////////*/

    /// @dev Confirms depositors are structurally illiquid while capital is deployed: the
    ///      clamp is correct, but nothing on-chain forces the allocator to keep a buffer.
    function test_H8_depositorCannotExitBeyondIdleBuffer() public {
        // Low leverage keeps the borrow inside the market's real liquidity while still
        // deploying nearly the whole vault, which is what makes the clamp bite.
        _openPosition(900_000e6, 1.1e18);

        uint256 idle = IERC20(USDC).balanceOf(address(vault));
        uint256 trueValue = vault.convertToAssets(vault.balanceOf(depositor));

        console2.log("depositor's true share value:", trueValue);
        console2.log("actually withdrawable:       ", vault.maxWithdraw(depositor));
        console2.log("idle buffer:                 ", idle);

        assertLt(vault.maxWithdraw(depositor), trueValue / 5, "over 80% of depositor value is locked");
    }

    /*//////////////////////////////////////////////////////////////
        H9: dust decreases skip debt repayment entirely
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXED. repayAssets = totalDebt * ctw / collateralRaw truncates to zero for small
    ///      ctw, which used to skip the repay leg entirely and let collateral leave the
    ///      position with debt untouched, nudging leverage UP on a nominal decrease. A
    ///      decrease that would repay nothing is now rejected outright.
    function test_H9_dustDecreaseIsRejected() public {
        _openPosition(100_000e6, 2e18);

        (, uint128 sharesBefore, uint128 collateralBefore) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));

        // Largest ctw for which totalDebt * ctw / collateralRaw still floors to zero.
        (,, uint128 tba, uint128 tbs,,) = IMorpho(MORPHO).market(wstEthMarketId);
        uint256 totalDebt = MorphoSharesMath.toAssetsUp(sharesBefore, tba, tbs);
        uint256 freeWithdraw = uint256(collateralBefore) / totalDebt;
        console2.log("collateral that was previously free to withdraw:", freeWithdraw);

        MarketAction[] memory actions = _prepDecrease(freeWithdraw);
        vm.prank(owner);
        vm.expectRevert(MorphoLeverageEngine.DecreaseAmountTooSmall.selector);
        vault.executeActions(actions);

        (, uint128 sharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateralAfter, collateralBefore, "no collateral left the position");
        assertEq(sharesAfter, sharesBefore, "and the debt is untouched");
    }

    /// @dev The rejection must be scoped to genuinely-zero-repay dust, not to small but
    ///      legitimate decreases.
    function test_H9b_smallButRealDecreaseStillWorks() public {
        _openPosition(100_000e6, 2e18);
        (, uint128 sharesBefore, uint128 collateralBefore) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));

        _decreaseByAmount(uint256(collateralBefore) / 1_000); // 0.1%

        (, uint128 sharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertLt(collateralAfter, collateralBefore, "collateral reduced");
        assertLt(sharesAfter, sharesBefore, "and debt was actually repaid alongside it");
    }

    /*//////////////////////////////////////////////////////////////
        H13: active-set bookkeeping follows real state
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXED. Deactivation used to key off the plan's isFullClose intent, so a
    ///      decrease that emptied a position by explicit amount left the market in the
    ///      active set forever, costing an oracle call and two storage reads on every
    ///      totalAssets(). It now keys off the resulting on-chain position.
    function test_H13_emptiedPositionLeavesActiveSetRegardlessOfHowItWasClosed() public {
        _openPosition(100_000e6, 2e18);
        assertEq(vault.activeMarkets().length, 1);

        (,, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        _decreaseByAmount(uint256(collateral)); // explicit amount, not the max sentinel

        assertEq(vault.activeMarkets().length, 0, "no stale entry left behind");
        assertEq(vault.totalMorphoAssets(), 0);
    }

    /// @dev And a position that still exists must stay in the set.
    function test_H13b_partiallyClosedPositionStaysActive() public {
        _openPosition(100_000e6, 2e18);
        (,, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));

        _decreaseByAmount(uint256(collateral) / 2);

        assertEq(vault.activeMarkets().length, 1, "still holding a position, still tracked");
        assertGt(vault.totalMorphoAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        H10: donation / first-depositor share inflation
    //////////////////////////////////////////////////////////////*/

    /// @dev totalAssets counts raw balanceOf, so anyone can donate into the vault. Check
    ///      whether the 10**3 decimals offset makes the classic inflation grief unprofitable.
    function test_H10_donationInflationIsUnprofitableButShiftsValue() public {
        MorphoLeverageVault fresh = new MorphoLeverageVault(
            IERC20(USDC), owner, IMorpho(MORPHO), IBundler3(BUNDLER3), IGeneralAdapter1(GENERAL_ADAPTER)
        );

        deal(USDC, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC).approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker);
        IERC20(USDC).transfer(address(fresh), 500_000e6); // donation, not a deposit
        vm.stopPrank();

        address victim = makeAddr("victim");
        deal(USDC, victim, 500_000e6);
        vm.startPrank(victim);
        IERC20(USDC).approve(address(fresh), type(uint256).max);
        uint256 victimShares = fresh.deposit(500_000e6, victim);
        vm.stopPrank();

        uint256 attackerFinal = fresh.convertToAssets(fresh.balanceOf(attacker));
        uint256 victimFinal = fresh.convertToAssets(victimShares);
        console2.log("attacker spent:   ", uint256(500_000e6 + 1));
        console2.log("attacker recovers:", attackerFinal);
        console2.log("victim spent:     ", uint256(500_000e6));
        console2.log("victim recovers:  ", victimFinal);

        assertLt(attackerFinal, 500_000e6 + 1, "inflation grief costs the attacker more than it gains");
    }

    /*//////////////////////////////////////////////////////////////
        H11: underwater positions are valued at zero, not negative
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXED. The shortfall used to vanish from totalAssets, overstating the share
    ///      price by 20,000 in exactly this scenario and letting the first redeemer of the
    ///      idle buffer exit at that stale price. It is now netted against idle balance.
    function test_H11_underwaterPositionShortfallIsNettedAgainstIdle() public {
        _openPosition(100_000e6, 2e18);

        uint256 idle = IERC20(USDC).balanceOf(address(vault));
        (, uint128 shares, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        (,, uint128 tba, uint128 tbs,,) = IMorpho(MORPHO).market(wstEthMarketId);
        uint256 debt = MorphoSharesMath.toAssetsUp(shares, tba, tbs);

        // Crash the collateral price so the position is deeply underwater.
        uint256 crashedPrice = IOracle(WSTETH_ORACLE).price() * 40 / 100;
        vm.mockCall(WSTETH_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(crashedPrice));

        uint256 crashedCollateralValue =
            MorphoSharesMath.mulDivDown(collateral, crashedPrice, MorphoSharesMath.ORACLE_PRICE_SCALE);
        uint256 reported = vault.totalAssets();
        uint256 trueValue = idle + crashedCollateralValue - debt; // shortfall is real

        console2.log("idle:                      ", idle);
        console2.log("collateral value (crashed):", crashedCollateralValue);
        console2.log("debt:                      ", debt);
        console2.log("totalAssets() reports:     ", reported);
        console2.log("economically true value:   ", trueValue);

        assertEq(reported, trueValue, "shortfall is subtracted from the vault's reported value");

        // The first redeemer no longer gets out whole: what the idle buffer is worth in
        // share terms has fallen by the shortfall along with everyone else's.
        assertLt(vault.maxWithdraw(depositor), idle, "idle is no longer redeemable at the pre-crash price");
    }

    /// @dev A shortfall bigger than everything the vault holds floors the report at zero
    ///      rather than underflowing. Sized so the debt (550k) exceeds the idle buffer it
    ///      would be netted against (450k), while staying inside the market's liquidity.
    function test_H11b_shortfallExceedingTotalValueFloorsAtZero() public {
        _openPosition(550_000e6, 2e18);
        assertGt(IERC20(USDC).balanceOf(address(vault)), 0, "vault still holds idle USDC");

        // Collateral priced to effectively nothing, so the whole borrow becomes shortfall.
        vm.mockCall(WSTETH_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(uint256(1)));

        assertEq(vault.totalAssets(), 0, "insolvent vault reports zero, not a revert");
        assertEq(vault.totalMorphoAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        H14: allocator cannot exceed the RiskLimits' aggregate debt cap
    //////////////////////////////////////////////////////////////*/

    /// @dev maxAggregateDebt caps total debt across every active market in ASSET terms,
    ///      independent of any single market's own leverage ceiling.
    function test_H14_allocatorCannotExceedAggregateDebtCap() public {
        uint256 ownAmount = 100_000e6;
        uint256 leverage = 2e18;
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 rate = 1e54 / price;
        router.setRate(rate);
        uint256 collateralOut = (totalAmount * rate) / 1e18;
        deal(WSTETH, address(router), collateralOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: collateralOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        // Built manually rather than via _openPosition: that helper's own oracle staticcall
        // (to size the swap) would otherwise be "the next call" vm.expectRevert() catches,
        // since it runs before _openPosition ever reaches vault.executeActions.
        RiskLimits limits = RiskLimits(vault.riskLimits());
        vm.prank(owner);
        limits.setMaxAggregateDebt(ownAmount / 2); // half of what this action's borrow will be

        vm.prank(owner);
        vm.expectRevert(); // MaxAggregateDebtExceeded
        vault.executeActions(actions);
    }

    /*//////////////////////////////////////////////////////////////
        H15: pausing RiskLimits blocks increases, leaves decreases working
    //////////////////////////////////////////////////////////////*/

    function test_H15_pauseBlocksIncreasesLeavesDecreasesWorking() public {
        _openPosition(100_000e6, 2e18);

        RiskLimits limits = RiskLimits(vault.riskLimits());
        vm.prank(owner);
        limits.setPaused(true);

        _decreaseByAmount(1_000e6); // unaffected by pause

        // Built manually rather than via _openPosition -- see the comment in H14 above.
        uint256 ownAmount = 10_000e6;
        uint256 leverage = 2e18;
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 rate = 1e54 / price;
        router.setRate(rate);
        uint256 collateralOut = (totalAmount * rate) / 1e18;
        deal(WSTETH, address(router), collateralOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: collateralOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        vm.prank(owner);
        vm.expectRevert(RiskLimits.Paused.selector);
        vault.executeActions(actions);
    }

    /*//////////////////////////////////////////////////////////////
        H16: only the owner can trigger emergencyDecrease
    //////////////////////////////////////////////////////////////*/

    /// @dev emergencyDecrease bypasses the allocator role and the risk limits entirely,
    ///      so it must be reachable by the owner alone -- not the allocator, not anyone else.
    function test_H16_emergencyDecreaseIsOwnerOnly() public {
        _openPosition(100_000e6, 2e18);
        (,, uint128 collateralRaw) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 withdrawAmount = uint256(collateralRaw) / 2;

        uint256 price = IOracle(WSTETH_ORACLE).price();
        uint256 rate = price / 1e18;
        router.setRate(rate);
        uint256 expectedOut = (withdrawAmount * rate) / 1e18;
        deal(USDC, address(router), expectedOut);

        MarketAction memory action = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: false,
            amount: withdrawAmount,
            leverage: 0,
            minOut: expectedOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(WSTETH), IERC20(USDC), withdrawAmount))
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.emergencyDecrease(action);

        vm.prank(owner);
        vault.emergencyDecrease(action);

        (,, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        assertEq(collateralAfter, collateralRaw - withdrawAmount, "owner's emergency decrease succeeded");
    }

    /*//////////////////////////////////////////////////////////////
        H17: a broken oracle on one active market must not brick increases into another
    //////////////////////////////////////////////////////////////*/

    /// @dev Regression test for RiskLimits._checkAggregateAndAssetExposure's try/catch:
    ///      without it, one bad oracle on any active market would block every future
    ///      increase into every market, not just the affected one.
    function test_H17_brokenOracleOnUnrelatedMarketDoesNotBrickHealthyIncrease() public {
        MarketParams memory wethParams =
            MarketParams({loanToken: USDC, collateralToken: WETH, oracle: WETH_ORACLE, irm: IRM, lltv: LLTV_86});

        vm.startPrank(owner);
        Id wethMarketId = vault.registerMarket(wethParams, MAX_LEVERAGE_CEILING, SLIPPAGE_BPS);
        // Nonzero so the aggregate loop actually inspects wethMarketId's oracle below,
        // rather than short-circuiting because no exposure cap is configured at all.
        RiskLimits(vault.riskLimits()).setMaxAssetExposure(WETH, type(uint256).max);
        vm.stopPrank();

        uint256 wethOwn = 10_000e6;
        uint256 wethTotal = wethOwn * 2;
        uint256 wethPrice = IOracle(WETH_ORACLE).price();
        uint256 wethRate = 1e54 / wethPrice;
        router.setRate(wethRate);
        uint256 wethOut = (wethTotal * wethRate) / 1e18;
        deal(WETH, address(router), wethOut);

        MarketAction[] memory wethActions = new MarketAction[](1);
        wethActions[0] = MarketAction({
            marketId: wethMarketId,
            isIncrease: true,
            amount: wethOwn,
            leverage: 2e18,
            minOut: wethOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WETH), wethTotal))
        });
        vm.prank(owner);
        vault.executeActions(wethActions);

        vm.mockCallRevert(WETH_ORACLE, abi.encodeWithSelector(IOracle.price.selector), "ORACLE_DOWN");

        _openPosition(50_000e6, 2e18); // must not revert despite WETH's oracle being down
        assertEq(vault.activeMarkets().length, 2, "both positions remain active");
    }

    /*//////////////////////////////////////////////////////////////
        H18: ownership transfer carries limits admin with no separate step
    //////////////////////////////////////////////////////////////*/

    function test_H18_ownershipTransferCarriesRiskLimitsAdminWithNoSeparateStep() public {
        address newOwner = makeAddr("newOwner");
        RiskLimits limits = RiskLimits(vault.riskLimits());

        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(RiskLimits.NotVaultOwner.selector);
        limits.setPaused(true);

        vm.prank(newOwner);
        limits.setPaused(true);
        assertTrue(limits.paused());
    }

    /*//////////////////////////////////////////////////////////////
        H19: price-deviation is a spot-price sanity check, not a manipulation-proof defense
    //////////////////////////////////////////////////////////////*/

    /// @dev Confirms the check does what it claims (catch a gross same-block price jump).
    ///      What it does NOT claim: an attacker moving the spot price by less than the
    ///      configured bps, or across several separate calls, is not caught by this check
    ///      alone -- see MorphoPositionValuation for how the vault handles a price that
    ///      later turns out to have been wrong (nets the shortfall, doesn't prevent it).
    function test_H19_priceDeviationCatchesAGrossSpikeButIsOnlyASanityCheck() public {
        RiskLimits limits = RiskLimits(vault.riskLimits());
        vm.prank(owner);
        limits.setMaxPriceDeviationBps(wstEthMarketId, 500); // 5%

        _openPosition(1_000e6, 1.5e18); // seeds a baseline observation
        uint256 baseline = limits.lastObservedPrice(wstEthMarketId);
        console2.log("baseline observed price:", baseline);

        uint256 spiked = baseline * 2;
        vm.mockCall(WSTETH_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(spiked));

        // Built manually rather than via _openPosition -- see the comment in H14 above.
        uint256 ownAmount = 1_000e6;
        uint256 leverage = 1.5e18;
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 rate = 1e54 / spiked;
        router.setRate(rate);
        uint256 collateralOut = (totalAmount * rate) / 1e18;
        deal(WSTETH, address(router), collateralOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: wstEthMarketId,
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: collateralOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(WSTETH), totalAmount))
        });

        vm.prank(owner);
        vm.expectRevert(); // PriceDeviationExceeded
        vault.executeActions(actions);
    }
}
