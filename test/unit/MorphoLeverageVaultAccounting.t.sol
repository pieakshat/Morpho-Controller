// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {MorphoSwapExecutor} from "../../src/morpho/libraries/MorphoSwapExecutor.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Fuzzes MorphoLeverageVault's plain ERC4626 accounting (deposit/withdraw,
///         maxWithdraw/maxRedeem clamping, totalAssets) with no Morpho positions ever
///         opened — MORPHO/BUNDLER3/GENERAL_ADAPTER/SWAP_EXECUTOR are inert placeholders,
///         never called here. Idle balance == totalAssets in this tier by construction,
///         so these tests isolate the vault's own ERC4626 overrides from the leverage
///         engine's real-position behavior (covered separately by the fork suite).
contract MorphoLeverageVaultAccountingTest is Test {
    MorphoLeverageVault vault;
    MockERC20 asset;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);

        vault = new MorphoLeverageVault(
            asset, owner, IMorpho(address(0x1111)), IBundler3(address(0x2222)), IGeneralAdapter1(address(0x3333))
        );
    }

    function _deposit(uint256 amount) internal {
        asset.mint(depositor, amount);
        vm.startPrank(depositor);
        asset.approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_totalAssets_equalsIdleBalance_whenNoPositions(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _deposit(amount);

        assertEq(vault.totalAssets(), amount);
        assertEq(vault.totalMorphoAssets(), 0);
        assertEq(IERC20(address(asset)).balanceOf(address(vault)), amount);
    }

    /// @dev With no Morpho position ever opened, idle balance is the vault's entire value —
    ///      deposit-then-withdraw-in-full should return (almost) exactly what went in. Any
    ///      shortfall is bounded to a few wei of decimals-offset rounding, never a lossy
    ///      or exploitable amount.
    function testFuzz_deposit_thenFullWithdraw_returnsApproxOriginalAmount(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _deposit(amount);

        uint256 maxAssets = vault.maxWithdraw(depositor);
        vm.prank(depositor);
        vault.withdraw(maxAssets, depositor, depositor);

        assertEq(IERC20(address(asset)).balanceOf(address(vault)), amount - maxAssets);
        assertApproxEqAbs(asset.balanceOf(depositor), amount, 2);
    }

    /// @dev Core solvency invariant: with no positions, maxWithdraw can never exceed the
    ///      vault's real token balance — the ERC4626 override's clamp must always bind at
    ///      or below actual liquidity, for any deposit size.
    function testFuzz_maxWithdraw_neverExceedsActualBalance(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _deposit(amount);

        uint256 idle = IERC20(address(asset)).balanceOf(address(vault));
        assertLe(vault.maxWithdraw(depositor), idle);
        assertLe(vault.maxRedeem(depositor), vault.balanceOf(depositor));
    }

    /// @dev Depositing and immediately redeeming the resulting shares should never yield
    ///      more assets than were deposited — no value can be manufactured by round-tripping
    ///      through shares, only lost to rounding (bounded, never more than a few wei).
    function testFuzz_deposit_thenRedeemAllShares_neverExceedsDeposit(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _deposit(amount);

        uint256 shares = vault.balanceOf(depositor);
        vm.prank(depositor);
        uint256 assetsOut = vault.redeem(shares, depositor, depositor);

        assertLe(assetsOut, amount);
        assertApproxEqAbs(assetsOut, amount, 2);
    }

    /// @dev Two independent depositors should each be able to withdraw their own full
    ///      share without one's presence corrupting the other's accounting.
    function testFuzz_twoDepositors_eachWithdrawFullShareIndependently(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, 1, 1e30);
        amountB = bound(amountB, 1, 1e30);

        address depositorB = makeAddr("depositorB");

        _deposit(amountA);
        asset.mint(depositorB, amountB);
        vm.startPrank(depositorB);
        asset.approve(address(vault), amountB);
        vault.deposit(amountB, depositorB);
        vm.stopPrank();

        // Hoisted out of the redeem() call: vm.prank only overrides msg.sender for the
        // literal next call, and vault.balanceOf(...) evaluated inline as an argument
        // would itself be that next call, silently eating the prank.
        uint256 depositorShares = vault.balanceOf(depositor);
        uint256 depositorBShares = vault.balanceOf(depositorB);

        vm.prank(depositor);
        vault.redeem(depositorShares, depositor, depositor);
        vm.prank(depositorB);
        vault.redeem(depositorBShares, depositorB, depositorB);

        assertApproxEqAbs(asset.balanceOf(depositor), amountA, 2);
        assertApproxEqAbs(asset.balanceOf(depositorB), amountB, 2);
        assertLe(IERC20(address(asset)).balanceOf(address(vault)), 4, "at most a few wei of rounding dust left behind");
    }
}
