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
///         GeneralAdapter1.
abstract contract MorphoLeverageEngine is MorphoCore, MorphoMarketRegistry {
    using SafeERC20 for IERC20;

    error MarketNotEnabled(Id id);
    error InvalidDecreaseAmount(uint256 requested, uint256 available);

    /// @dev Groups _decreasePosition's derived numbers into one struct, passed by memory
    ///      reference between the planning and bundle-building helpers below.
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

    /// @notice Opens or adds to a position in one flashloan-atomic bundle. Leverage is
    ///         optional: a market registered at exactly 1e18 (see MorphoMarketConfig)
    ///         supplies collateral with no borrow at all.
    /// @dev `action.amount` is this adapter's own contribution, not the total position
    ///      size. Total exposure and the borrow amount are derived from it via the
    ///      market's configured targetLeverage.
    function _increasePosition(MarketAction memory action) internal {
        Id id = action.marketId;
        require(isMarketEnabled(id), MarketNotEnabled(id));

        MorphoMarketConfig memory config = _marketConfigs[id];
        MarketParams memory params = config.params;

        uint256 ownAmount = action.amount;
        uint256 totalAmount = (ownAmount * config.targetLeverage) / 1e18;
        uint256 borrowAmount = totalAmount - ownAmount;

        // Plain transfer rather than a bundled Call: inside a bundle a Call here would
        // execute as Bundler3, which holds nothing, instead of this adapter.
        IERC20(params.loanToken).safeTransfer(address(GENERAL_ADAPTER), ownAmount);

        // Morpho's borrow() reverts if both `assets` and `shares` are zero, so the borrow
        // step is omitted entirely at 1x rather than called with borrowAmount = 0.
        Call[] memory nested = new Call[](borrowAmount > 0 ? 4 : 3);
        uint256 i;
        nested[i++] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(GENERAL_ADAPTER.erc20Transfer, (params.loanToken, address(SWAP_EXECUTOR), totalAmount)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        nested[i++] = Call({
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
        nested[i++] = Call({
            to: address(GENERAL_ADAPTER),
            data: abi.encodeCall(GENERAL_ADAPTER.morphoSupplyCollateral, (params, type(uint256).max, address(this), hex"")),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        if (borrowAmount > 0) {
            nested[i++] = Call({
                to: address(GENERAL_ADAPTER),
                // minSharePriceE27 = 0: the borrow is a deterministic native call with no
                // slippage risk of its own — the real risk lives in the swap leg above.
                data: abi.encodeCall(GENERAL_ADAPTER.morphoBorrow, (params, borrowAmount, 0, 0, address(GENERAL_ADAPTER))),
                value: 0,
                skipRevert: false,
                callbackHash: bytes32(0)
            });
        }

        _flashloanAndExecute(params.loanToken, totalAmount, nested);
        _markActive(id);
    }

    /*//////////////////////////////////////////////////////////////
                                  DECREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reduces or fully closes a leveraged position.
    /// @dev `action.amount` is collateral to withdraw, or type(uint256).max for a full
    ///      close. A full close repays by exact shares instead of a rounded asset
    ///      estimate, to avoid dust.
    ///
    ///      When there's debt, swap proceeds land on GeneralAdapter1 rather than this
    ///      adapter, because Morpho's flashLoan() reclaims its due amount synchronously
    ///      before any later bundle step runs — the repayment funds must already be
    ///      sitting there. Whatever's left after repayment is swept back here as the
    ///      remaining balance (type(uint256).max), since swap slippage means the exact
    ///      leftover amount can't be known in advance.
    function _decreasePosition(MarketAction memory action) internal {
        Id id = action.marketId;
        require(_isRegistered[id], MarketNotRegistered(id));
        MarketParams memory params = _marketConfigs[id].params;

        DecreasePlan memory plan = _planDecrease(id, action.amount);
        Call[] memory nested = _buildDecreaseBundle(params, plan, action);

        if (plan.flashloanAmount > 0) {
            Call[] memory sweep = new Call[](1);
            sweep[0] = Call({
                to: address(GENERAL_ADAPTER),
                data: abi.encodeCall(GENERAL_ADAPTER.erc20Transfer, (params.loanToken, address(this), type(uint256).max)),
                value: 0,
                skipRevert: false,
                callbackHash: bytes32(0)
            });
            _flashloanAndExecuteThenSweep(params.loanToken, plan.flashloanAmount, nested, sweep);
        } else {
            // No debt — nothing to flashloan, run the withdraw/swap directly. Still needs
            // authorization: morphoWithdrawCollateral resolves onBehalf via
            // Bundler3.initiator() and requires it, same as in the flashloan path.
            MORPHO.setAuthorization(address(GENERAL_ADAPTER), true);
            BUNDLER3.multicall(nested);
            MORPHO.setAuthorization(address(GENERAL_ADAPTER), false);
        }

        if (plan.isFullClose) {
            _markInactive(id);
        }
    }

    /// @dev Reads live position/market state and derives the numbers needed to decrease
    ///      the position.
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
                // Repay by exact shares avoids any dust mismatch from toAssetsUp's
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

    /// @dev Builds the nested Call[] for a decrease: repay (if any debt), withdraw
    ///      collateral, transfer to the swap executor, then swap back to loanToken.
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
        // Proceeds go to GeneralAdapter1 when there's a flashloan to cover (see the sweep
        // in _decreasePosition); otherwise straight to this adapter.
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
                    plan.flashloanAmount > 0 ? address(GENERAL_ADAPTER) : address(this)
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
    ///      grant/revoke scoped tightly around the call. GeneralAdapter1 never holds
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

    /// @dev Same as _flashloanAndExecute, but appends one more Call after the flashloan —
    ///      sweeps GeneralAdapter1's leftover balance back to this adapter. Must run after
    ///      the flashloan Call, not inside it: Morpho reclaims its loan synchronously
    ///      within that call, so there's nothing to sweep until it returns.
    function _flashloanAndExecuteThenSweep(address token, uint256 amount, Call[] memory nested, Call[] memory sweep)
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
        outer[1] = sweep[0];

        MORPHO.setAuthorization(address(GENERAL_ADAPTER), true);
        BUNDLER3.multicall(outer);
        MORPHO.setAuthorization(address(GENERAL_ADAPTER), false);
    }
}
