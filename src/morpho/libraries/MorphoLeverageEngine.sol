// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Id, MarketParams} from "../interfaces/IMorpho.sol";
import {Call} from "../interfaces/IBundler3.sol";
import {MorphoMarketConfig, MarketAction} from "../types/MorphoTypes.sol";
import {MorphoSharesMath} from "./MorphoSharesMath.sol";
import {MorphoSwapExecutor} from "./MorphoSwapExecutor.sol";
import {MorphoCore} from "./MorphoCore.sol";
import {MorphoMarketRegistry} from "./MorphoMarketRegistry.sol";

/// @notice Builds and executes flashloan-based leverage entry/exit through Bundler3 +
///         GeneralAdapter1. This is the piece that actually moves Morpho positions.
/// @dev All balance math below was worked through by hand and must net to exactly zero —
///      that's the real correctness bar for a flashloan bundle, not just "it compiles."
abstract contract MorphoLeverageEngine is MorphoCore, MorphoMarketRegistry {
    using SafeERC20 for IERC20;

    error MarketNotEnabled(Id id);
    error NotLeveredMarket(Id id);
    error InvalidDecreaseAmount(uint256 requested, uint256 available);

    /// @dev Groups _decreasePosition's derived numbers into one struct, passed by memory
    ///      reference between the planning and bundle-building helpers below. Splitting
    ///      the original single function this way — not for style, but because the
    ///      combined MorphoLeverageVault contract hit a genuine "stack too deep" compile
    ///      error with everything living as separate locals in one function.
    struct DecreasePlan {
        uint256 collateralToWithdraw;
        uint256 repayAssets;
        uint256 repayShares;
        uint256 flashloanAmount;
        bool isFullClose;
    }

    /*//////////////////////////////////////////////////////////////
                                  INCREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Opens or adds to a leveraged position in one flashloan-atomic bundle.
    /// @dev `action.amount` is OUR OWN contribution (already sitting in this adapter's
    ///      balance) — not the total position size. Total exposure and the borrow amount
    ///      are derived from it via the market's configured targetLeverage. This is the
    ///      opposite convention from Blend's RebalanceData.amount (which is total position
    ///      size, with own-contribution derived from it) — chosen because an allocator
    ///      splitting one deposit across several markets naturally thinks in terms of "how
    ///      much of my capital goes here," not "what's the total leveraged exposure."
    ///
    ///      Balance trace through GeneralAdapter1 (this must net to zero for correctness):
    ///        before flashloan:      ownAmount                          (our pre-transfer)
    ///        after flashloan:       ownAmount + totalAmount
    ///        after transfer-out:    ownAmount                          (totalAmount sent to swap)
    ///        after swap-in:         ownAmount (ASSET) + collateral
    ///        after supply:          ownAmount (ASSET), 0 collateral    (all supplied to Morpho)
    ///        after borrow:          ownAmount + borrowAmount = totalAmount
    ///      GeneralAdapter1 now holds exactly totalAmount to repay the flashloan.
    function _increasePosition(MarketAction memory action) internal {
        Id id = action.marketId;
        require(isMarketEnabled(id), MarketNotEnabled(id));

        MorphoMarketConfig memory config = _marketConfigs[id];
        MarketParams memory params = config.params;
        require(config.targetLeverage > 1e18, NotLeveredMarket(id));

        uint256 ownAmount = action.amount;
        uint256 totalAmount = (ownAmount * config.targetLeverage) / 1e18;
        uint256 borrowAmount = totalAmount - ownAmount;

        // Plain, direct transfer — deliberately NOT a Bundler3 Call. A raw ERC20.transfer
        // inside a bundle would execute with Bundler3 as msg.sender (it holds nothing),
        // not this adapter — doing it here, before the bundle starts, avoids that entirely.
        IERC20(params.loanToken).safeTransfer(address(GENERAL_ADAPTER), ownAmount);

        Call[] memory nested = new Call[](4);
        nested[0] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(GENERAL_ADAPTER.erc20Transfer, (params.loanToken, address(SWAP_EXECUTOR), totalAmount)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        nested[1] = Call({
            to: address(SWAP_EXECUTOR),
            data: abi.encodeCall(
                MorphoSwapExecutor.executeSwap,
                (
                    IERC20(params.loanToken),
                    IERC20(params.collateralToken),
                    action.minOut,
                    action.swapTarget,
                    action.swapCalldata,
                    address(GENERAL_ADAPTER)
                )
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        nested[2] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(GENERAL_ADAPTER.morphoSupplyCollateral, (params, type(uint256).max, address(this), hex"")),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        nested[3] = Call({
            to: address(GENERAL_ADAPTER),
            // minSharePriceE27 = 0: no protection on the borrow leg itself. Deliberate for
            // v0 — the real risk surface is the swap (external, arbitrary venue), not this
            // deterministic protocol-native call. Revisit if that assumption stops holding.
            data: abi.encodeCall(GENERAL_ADAPTER.morphoBorrow, (params, borrowAmount, 0, 0, address(GENERAL_ADAPTER))),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        _flashloanAndExecute(params.loanToken, totalAmount, nested);
        _markActive(id);
    }

    /*//////////////////////////////////////////////////////////////
                                  DECREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reduces or fully closes a leveraged position.
    /// @dev `action.amount` is collateral to withdraw, in collateral-token units, or
    ///      type(uint256).max for a full close. Debt is repaid proportionally to how much
    ///      collateral is being pulled — full close repays by exact shares (not our
    ///      rounded-up asset estimate) to avoid any dust mismatch from toAssetsUp rounding.
    ///      Swap proceeds land on THIS adapter directly, not GeneralAdapter1 — GeneralAdapter1
    ///      then pulls only exactly what it needs to repay the flashloan via a pre-approved
    ///      erc20TransferFrom. Whatever's left over (profit, or excess from partial closes)
    ///      simply stays here — no separate "sweep" step needed.
    function _decreasePosition(MarketAction memory action) internal {
        Id id = action.marketId;
        require(_isRegistered[id], MarketNotRegistered(id));
        MarketParams memory params = _marketConfigs[id].params;

        DecreasePlan memory plan = _planDecrease(id, action.amount);

        if (plan.flashloanAmount > 0) {
            // GeneralAdapter1 will pull exactly this much back from us mid-bundle, once
            // swap proceeds have landed — approved up front since Bundler3 executes as
            // itself, not as this adapter, mid-bundle.
            IERC20(params.loanToken).forceApprove(address(GENERAL_ADAPTER), plan.flashloanAmount);
        }

        Call[] memory nested = _buildDecreaseBundle(params, plan, action);

        if (plan.flashloanAmount > 0) {
            Call[] memory pullRepayment = new Call[](1);
            pullRepayment[0] = Call({
                to: address(GENERAL_ADAPTER),
                data: abi.encodeCall(
                    GENERAL_ADAPTER.erc20TransferFrom, (params.loanToken, address(GENERAL_ADAPTER), plan.flashloanAmount)
                ),
                value: 0,
                skipRevert: false,
                callbackHash: bytes32(0)
            });
            // Flashloan case: the repay/withdraw/swap sequence runs inside the callback
            // (nested), then the pull-repayment happens after — see _flashloanAndExecute.
            _flashloanAndExecuteThenPull(params.loanToken, plan.flashloanAmount, nested, pullRepayment);
            IERC20(params.loanToken).forceApprove(address(GENERAL_ADAPTER), 0);
        } else {
            // No debt at all — nothing to flashloan, just run the withdraw/swap directly.
            BUNDLER3.multicall(nested);
        }

        if (plan.isFullClose) {
            _markInactive(id);
        }
    }

    /// @dev Reads live position/market state and derives every number _decreasePosition
    ///      needs, isolated in its own function so those locals don't stay live for the
    ///      rest of the operation.
    function _planDecrease(Id id, uint256 requestedAmount) private returns (DecreasePlan memory plan) {
        MarketParams memory params = _marketConfigs[id].params;
        MORPHO.accrueInterest(params);
        (, uint128 borrowSharesRaw, uint128 collateralRaw) = MORPHO.position(id, address(this));

        plan.isFullClose = requestedAmount == type(uint256).max;
        plan.collateralToWithdraw = plan.isFullClose ? uint256(collateralRaw) : requestedAmount;
        require(plan.collateralToWithdraw <= collateralRaw, InvalidDecreaseAmount(plan.collateralToWithdraw, collateralRaw));

        if (borrowSharesRaw > 0) {
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
            if (plan.isFullClose) {
                // Repay by exact shares — avoids any dust mismatch from toAssetsUp's
                // rounding, since Morpho computes the precise asset cost itself.
                plan.repayShares = borrowSharesRaw;
                plan.flashloanAmount = MorphoSharesMath.toAssetsUp(borrowSharesRaw, totalBorrowAssets, totalBorrowShares);
            } else {
                uint256 totalDebt = MorphoSharesMath.toAssetsUp(borrowSharesRaw, totalBorrowAssets, totalBorrowShares);
                plan.repayAssets = (totalDebt * plan.collateralToWithdraw) / collateralRaw;
                plan.flashloanAmount = plan.repayAssets;
            }
        }
    }

    /// @dev Builds the nested Call[] for a decrease — repay (if any debt), withdraw
    ///      collateral, transfer to the swap executor, swap back to loanToken. Isolated
    ///      from _decreasePosition for the same stack-depth reason as _planDecrease.
    function _buildDecreaseBundle(MarketParams memory params, DecreasePlan memory plan, MarketAction memory action)
        private
        view
        returns (Call[] memory nested)
    {
        nested = new Call[](plan.flashloanAmount > 0 ? 4 : 3);
        uint256 i;
        if (plan.flashloanAmount > 0) {
            nested[i++] = Call({
                to: address(GENERAL_ADAPTER),
                data: abi.encodeCall(
                    GENERAL_ADAPTER.morphoRepay,
                    (params, plan.repayAssets, plan.repayShares, type(uint256).max, address(this), hex"")
                ),
                value: 0,
                skipRevert: false,
                callbackHash: bytes32(0)
            });
        }
        nested[i++] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(
                GENERAL_ADAPTER.morphoWithdrawCollateral, (params, plan.collateralToWithdraw, address(GENERAL_ADAPTER))
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        nested[i++] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(
                GENERAL_ADAPTER.erc20Transfer, (params.collateralToken, address(SWAP_EXECUTOR), plan.collateralToWithdraw)
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        nested[i++] = Call({
            to: address(SWAP_EXECUTOR),
            data: abi.encodeCall(
                MorphoSwapExecutor.executeSwap,
                (
                    IERC20(params.collateralToken),
                    IERC20(params.loanToken),
                    action.minOut,
                    action.swapTarget,
                    action.swapCalldata,
                    address(this)
                )
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
    }

    /*//////////////////////////////////////////////////////////////
                                  INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Wraps `nested` in a flashloan for `amount` of `token`, with the authorization
    ///      grant/revoke scoped tightly around the call — GeneralAdapter1 never holds
    ///      standing power over this adapter's Morpho position between operations.
    function _flashloanAndExecute(address token, uint256 amount, Call[] memory nested) private {
        bytes32 callbackHash = keccak256(abi.encode(nested));
        Call[] memory outer = new Call[](1);
        outer[0] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(GENERAL_ADAPTER.morphoFlashLoan, (token, amount, abi.encode(nested))),
            value: 0,
            skipRevert: false,
            callbackHash: callbackHash
        });

        MORPHO.setAuthorization(address(GENERAL_ADAPTER), true);
        BUNDLER3.multicall(outer);
        MORPHO.setAuthorization(address(GENERAL_ADAPTER), false);
    }

    /// @dev Same as above, but with an extra top-level Call appended after the flashloan
    ///      resolves — used by the decrease path to pull the flashloan repayment back from
    ///      this adapter once swap proceeds have landed here rather than on GeneralAdapter1.
    function _flashloanAndExecuteThenPull(address token, uint256 amount, Call[] memory nested, Call[] memory pull)
        private
    {
        bytes32 callbackHash = keccak256(abi.encode(nested));
        Call[] memory outer = new Call[](2);
        outer[0] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(GENERAL_ADAPTER.morphoFlashLoan, (token, amount, abi.encode(nested))),
            value: 0,
            skipRevert: false,
            callbackHash: callbackHash
        });
        outer[1] = pull[0];

        MORPHO.setAuthorization(address(GENERAL_ADAPTER), true);
        BUNDLER3.multicall(outer);
        MORPHO.setAuthorization(address(GENERAL_ADAPTER), false);
    }
}
