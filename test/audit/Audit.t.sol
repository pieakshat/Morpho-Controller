// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {IOracle} from "../../src/morpho/interfaces/IOracle.sol";
import {MarketAction} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";
import {MorphoSwapExecutor} from "../../src/morpho/libraries/MorphoSwapExecutor.sol";
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
    function test_H1_proportionalDecreaseBreaksNearFullWithdrawal() public {
        _openPosition(100_000e6, 2e18);
        (,, uint128 collateral) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        uint256 snap = vm.snapshotState();

        uint256[8] memory bps = [uint256(9000), 9500, 9900, 9990, 9999, 10000, 10000, 10000];
        for (uint256 i = 0; i < 6; ++i) {
            bool ok = _tryDecrease((uint256(collateral) * bps[i]) / 10_000);
            console2.log("withdraw bps / succeeded:", bps[i], ok);
            vm.revertToState(snap);
        }

        // The exact-100% case is the one a naive allocator would reach for to fully exit
        // without knowing about the type(uint256).max sentinel.
        bool fullOk = _tryDecrease(uint256(collateral));
        console2.log("exact 100% via amount succeeded:", fullOk);
        assertFalse(fullOk, "exact-100% proportional decrease should be shown to fail");
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

    /// @dev equity is zero when there is no position, so currentLeverage divides by zero.
    ///      Reverts either way, but with a bare panic rather than a named error.
    function test_H4_deleverageOnEmptyPositionDividesByZero() public {
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
        vm.expectRevert(stdError.divisionError);
        vault.executeActions(actions);
    }

    /*//////////////////////////////////////////////////////////////
        H5: oracle failure bricks the whole vault
    //////////////////////////////////////////////////////////////*/

    /// @dev totalAssets() reads every active market's oracle. If one reverts, share
    ///      conversion reverts, which takes down deposits AND withdrawals of purely idle
    ///      funds that have nothing to do with that market.
    function test_H5_revertingOracleBricksDepositsAndWithdrawals() public {
        _openPosition(100_000e6, 2e18);

        uint256 idle = IERC20(USDC).balanceOf(address(vault));
        assertGt(idle, 0, "vault holds idle USDC unrelated to the position");

        vm.mockCallRevert(WSTETH_ORACLE, abi.encodeWithSelector(IOracle.price.selector), "ORACLE_DOWN");

        vm.expectRevert();
        vault.totalAssets();

        deal(USDC, attacker, 1_000e6);
        vm.startPrank(attacker);
        IERC20(USDC).approve(address(vault), 1_000e6);
        vm.expectRevert();
        vault.deposit(1_000e6, attacker);
        vm.stopPrank();

        // Even withdrawing idle funds is impossible.
        vm.prank(depositor);
        vm.expectRevert();
        vault.withdraw(1_000e6, depositor, depositor);

        console2.log("oracle down: idle USDC frozen:", idle);
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

    /// @dev repayAssets = totalDebt * ctw / collateralRaw truncates to zero for small ctw.
    ///      flashloanAmount then reads as zero, so the whole repay leg is skipped and
    ///      collateral leaves the position with debt untouched, nudging leverage UP on
    ///      what is nominally a decrease.
    function test_H9_dustDecreaseWithdrawsCollateralWithoutRepaying() public {
        _openPosition(100_000e6, 2e18);

        (, uint128 sharesBefore, uint128 collateralBefore) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));

        // Largest ctw for which totalDebt * ctw / collateralRaw still floors to zero.
        (,, uint128 tba, uint128 tbs,,) = IMorpho(MORPHO).market(wstEthMarketId);
        uint256 totalDebt = MorphoSharesMath.toAssetsUp(sharesBefore, tba, tbs);
        uint256 freeWithdraw = uint256(collateralBefore) / totalDebt;
        console2.log("collateral withdrawable with zero repayment:", freeWithdraw);

        _decreaseByAmount(freeWithdraw);

        (, uint128 sharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(wstEthMarketId, address(vault));
        console2.log("collateral removed:", uint256(collateralBefore) - uint256(collateralAfter));
        console2.log("borrow shares before:", uint256(sharesBefore));
        console2.log("borrow shares after: ", uint256(sharesAfter));

        assertLt(collateralAfter, collateralBefore, "collateral did leave the position");
        assertEq(sharesAfter, sharesBefore, "but no debt was repaid at all");
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
}
