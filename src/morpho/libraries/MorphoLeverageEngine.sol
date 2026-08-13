// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Id, MarketParams} from "../interfaces/IMorpho.sol";
import {Call} from "../interfaces/IBundler3.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {MorphoMarketConfig, MarketAction, IncreaseCheckParams} from "../types/MorphoTypes.sol";
import {MorphoSharesMath} from "./MorphoSharesMath.sol";
import {MorphoSwapExecutor} from "./MorphoSwapExecutor.sol";
import {MorphoCore} from "./MorphoCore.sol";
import {MorphoMarketRegistry} from "./MorphoMarketRegistry.sol";

/// @notice Builds and executes flashloan-based leverage entry/exit through Bundler3 +
///         GeneralAdapter1.
abstract contract MorphoLeverageEngine is MorphoCore, MorphoMarketRegistry {
    using SafeERC20 for IERC20;

    error MarketNotEnabled(Id id);
    error LeverageBelowOneX(uint256 requested);
    error LeverageExceedsMax(uint256 requested, uint256 max);
    error InvalidDecreaseAmount(uint256 requested, uint256 available);
    error TargetLeverageNotBelowCurrent(uint256 target, uint256 current);
    error DeleverageAmountTooSmall();
    error DecreaseAmountTooSmall();
    error NoPosition(Id id);
    error PositionHasNoEquity(Id id);

    /// @dev Groups _decreasePosition's derived numbers into one struct, passed by memory
    ///      reference between the planning and bundle-building helpers below.
    struct DecreasePlan {
        uint256 collateralToWithdraw;
        uint256 repayAssets;
        uint256 repayShares;
        uint256 flashloanAmount;
        uint256 minSwapOut;
        bool isFullClose;
    }

    /// @dev Raises the caller's requested minOut to the market oracle's implied output
    ///      less the market's tolerated slippage. The allocator picks both the swap venue
    ///      and its own minOut, so its number alone bounds nothing; this is what actually
    ///      caps how much a swap can under-deliver relative to a price the vault trusts.
    function _effectiveMinOut(uint256 oracleExpectedOut, uint256 maxSlippageBps, uint256 requestedMinOut)
        private
        pure
        returns (uint256)
    {
        uint256 floor = (oracleExpectedOut * (10_000 - maxSlippageBps)) / 10_000;
        return requestedMinOut > floor ? requestedMinOut : floor;
    }

    /*//////////////////////////////////////////////////////////////
                                  INCREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Opens or adds to a position in one flashloan-atomic bundle. `action.leverage`
    ///         picks the leverage for this call, capped by the market's maxLeverage.
    ///         Leverage is optional: a request of exactly 1e18 supplies collateral with no
    ///         borrow at all.
    /// @dev `action.amount` is this adapter's own contribution, not the total position
    ///      size. Total exposure and the borrow amount are derived from it via
    ///      `action.leverage`, chosen by the allocator per call rather than fixed on the
    ///      market's config, so the same market can be entered at different leverage in
    ///      different calls without any owner transaction in between.
    function _increasePosition(MarketAction memory action) internal {
        Id id = action.marketId;
        require(isMarketEnabled(id), MarketNotEnabled(id));

        MorphoMarketConfig memory config = _marketConfigs[id];
        require(action.leverage >= 1e18, LeverageBelowOneX(action.leverage));
        require(action.leverage <= config.maxLeverage, LeverageExceedsMax(action.leverage, config.maxLeverage));

        uint256 totalAmount = (action.amount * action.leverage) / 1e18;
        uint256 price = IOracle(config.params.oracle).price();

        // loanToken -> collateralToken, so the oracle's collateral-per-loan-token rate is
        // the inverse of the price it quotes.
        uint256 minSwapOut = _effectiveMinOut(
            MorphoSharesMath.mulDivDown(totalAmount, MorphoSharesMath.ORACLE_PRICE_SCALE, price),
            config.maxSlippageBps,
            action.minOut
        );

        // Built once and reused for both hook calls below: same memory pointer either way,
        // so passing it twice costs nothing extra and can't let the two checks disagree on
        // what this action actually was.
        IncreaseCheckParams memory checkParams = IncreaseCheckParams({
            marketId: id,
            params: config.params,
            leverage: action.leverage,
            totalAmount: totalAmount,
            price: price,
            slippageBpsUsed: config.maxSlippageBps
        });
        CIRCUIT_BREAKER.checkBeforeIncrease(checkParams);

        // Plain transfer rather than a bundled Call: inside a bundle a Call here would
        // execute as Bundler3, which holds nothing, instead of this adapter.
        IERC20(config.params.loanToken).safeTransfer(address(GENERAL_ADAPTER), action.amount);

        _flashloanAndExecute(
            config.params.loanToken,
            totalAmount,
            _buildIncreaseBundle(config.params, totalAmount, totalAmount - action.amount, minSwapOut, action)
        );
        _markActive(id);

        CIRCUIT_BREAKER.checkAfterIncrease(checkParams);
    }

    /// @dev Builds the nested Call[] for an increase: move the borrowed loanToken to the
    ///      swap executor, swap it for collateral, supply all of it, then borrow against it.
    function _buildIncreaseBundle(
        MarketParams memory params,
        uint256 totalAmount,
        uint256 borrowAmount,
        uint256 minSwapOut,
        MarketAction memory action
    ) private view returns (Call[] memory nested) {
        // Morpho's borrow() reverts if both `assets` and `shares` are zero, so the borrow
        // step is omitted entirely at 1x rather than called with borrowAmount = 0.
        nested = new Call[](borrowAmount > 0 ? 4 : 3);
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
                    minSwapOut,
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
    }

    /*//////////////////////////////////////////////////////////////
                                  DECREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reduces or fully closes a leveraged position, or brings it down to a lower
    ///         leverage in place.
    /// @dev Two mutually exclusive modes, selected by `action.leverage`:
    ///      - `action.leverage == 0`: `action.amount` is collateral to withdraw, or
    ///        type(uint256).max for a full close. A full close repays by exact shares
    ///        instead of a rounded asset estimate, to avoid dust.
    ///      - `action.leverage > 0`: deleverage to that target ratio. `action.amount` is
    ///        ignored. Collateral is unwound and swapped, and the proceeds repay exactly
    ///        enough debt to land the position at the target, holding equity constant —
    ///        this is self-funded, no capital comes from or returns to idle balance beyond
    ///        whatever the swap delivers above `action.minOut`. Never fully closes the
    ///        position: a target of exactly 1e18 pays off all debt but leaves collateral.
    ///
    ///      When there's debt, swap proceeds land on GeneralAdapter1 rather than this
    ///      adapter, because Morpho's flashLoan() reclaims its due amount synchronously
    ///      before any later bundle step runs — the repayment funds must already be
    ///      sitting there. Whatever's left after repayment is swept back here as the
    ///      remaining balance (type(uint256).max), since swap slippage means the exact
    ///      leftover amount can't be known in advance. For a deleverage, `action.minOut`
    ///      is the floor on that same swap: set it below the computed repay amount and a
    ///      bad fill reverts cleanly in the swap executor instead of failing later when
    ///      the flashloan can't be covered.
    function _decreasePosition(MarketAction memory action) internal {
        uint256 unwoundValue = _decreasePositionCore(action);
        CIRCUIT_BREAKER.checkAfterDecrease(action.marketId, unwoundValue);
    }

    /// @dev Same as _decreasePosition but skips CIRCUIT_BREAKER entirely — used only by
    ///      MorphoLeverageVault.emergencyDecrease. checkAfterDecrease can't revert on its
    ///      current happy path, but an emergency exit's whole job is to survive scenarios
    ///      other assumptions have broken in; it must not depend on CircuitBreaker being
    ///      alive and well, not just on its checks passing.
    function _emergencyDecreasePosition(MarketAction memory action) internal {
        _decreasePositionCore(action);
    }

    function _decreasePositionCore(MarketAction memory action) private returns (uint256 unwoundValue) {
        Id id = action.marketId;
        require(_isRegistered[id], MarketNotRegistered(id));
        MarketParams memory params = _marketConfigs[id].params;

        DecreasePlan memory plan =
            action.leverage > 0 ? _planDeleverage(id, action.leverage) : _planDecrease(id, action.amount);

        // collateralToken -> loanToken, the opposite direction from an increase, so here
        // the oracle price applies directly rather than inverted. Also what CircuitBreaker
        // sees as this action's exposure change, via checkAfterDecrease above.
        unwoundValue = MorphoSharesMath.mulDivDown(
            plan.collateralToWithdraw, IOracle(params.oracle).price(), MorphoSharesMath.ORACLE_PRICE_SCALE
        );
        plan.minSwapOut = _effectiveMinOut(unwoundValue, _marketConfigs[id].maxSlippageBps, action.minOut);

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

        // Decided from the resulting on-chain state rather than from the plan's intent. A
        // decrease can empty a position without having been flagged a full close, and a
        // market left in the active set costs an oracle call plus two storage reads on
        // every totalAssets(), which sits on the deposit and withdraw path.
        (, uint128 sharesAfter, uint128 collateralAfter) = MORPHO.position(id, address(this));
        if (sharesAfter == 0 && collateralAfter == 0) {
            _markInactive(id);
        }
    }

    /// @dev Reads live position/market state and derives the numbers needed to decrease
    ///      the position.
    function _planDecrease(Id id, uint256 requestedAmount) private returns (DecreasePlan memory plan) {
        MarketParams memory params = _marketConfigs[id].params;
        MORPHO.accrueInterest(params);
        (, uint128 borrowSharesRaw, uint128 collateralRaw) = MORPHO.position(id, address(this));

        require(collateralRaw > 0, NoPosition(id));

        // Asking for exactly the whole balance is the same intent as the max sentinel, so
        // it takes the same exact-shares path. Routing it through the proportional branch
        // instead would compute a repay of toAssetsUp(borrowShares), which Morpho converts
        // back to at least borrowShares and then underflows on — a full exit expressed the
        // obvious way would revert with nothing explaining why.
        plan.isFullClose = requestedAmount >= collateralRaw;
        plan.collateralToWithdraw = plan.isFullClose ? uint256(collateralRaw) : requestedAmount;
        require(
            requestedAmount == type(uint256).max || requestedAmount <= collateralRaw,
            InvalidDecreaseAmount(requestedAmount, collateralRaw)
        );

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
                // A withdrawal small enough that its share of the debt rounds to zero would
                // otherwise skip the repay leg entirely and pull collateral out for free,
                // nudging leverage up on what is supposed to be a proportional decrease.
                require(plan.repayAssets > 0, DecreaseAmountTooSmall());
                plan.flashloanAmount = plan.repayAssets;
            }
        }
    }

    /// @dev Derives how much collateral to unwind to bring the position to `targetLeverage`,
    ///      holding equity constant: newCollateralValue = targetLeverage * equity, so the
    ///      value withdrawn equals the value repaid, no capital in or out beyond that.
    ///      Never a full close — see _decreasePosition's leverage-mode doc.
    function _planDeleverage(Id id, uint256 targetLeverage) private returns (DecreasePlan memory plan) {
        require(targetLeverage >= 1e18, LeverageBelowOneX(targetLeverage));

        MarketParams memory params = _marketConfigs[id].params;
        MORPHO.accrueInterest(params);
        (, uint128 borrowSharesRaw, uint128 collateralRaw) = MORPHO.position(id, address(this));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);

        uint256 price = IOracle(params.oracle).price();
        uint256 collateralValue = MorphoSharesMath.mulDivDown(collateralRaw, price, MorphoSharesMath.ORACLE_PRICE_SCALE);
        uint256 debtValue = borrowSharesRaw > 0
            ? MorphoSharesMath.toAssetsUp(borrowSharesRaw, totalBorrowAssets, totalBorrowShares)
            : 0;

        // Underflows and reverts if collateral no longer covers debt. This engine's own
        // opens should never produce that state, but a silent floor here would hide it
        // instead of surfacing it as the bug it would be.
        uint256 equity = collateralValue - debtValue;
        // Zero equity means there is no ratio to target: leverage is undefined, and the
        // division below would panic. Say so rather than surfacing a bare arithmetic error.
        require(equity > 0, PositionHasNoEquity(id));
        uint256 currentLeverage = (collateralValue * 1e18) / equity;
        require(targetLeverage < currentLeverage, TargetLeverageNotBelowCurrent(targetLeverage, currentLeverage));

        uint256 newCollateralValue = (targetLeverage * equity) / 1e18;

        // Computed in shares, not value: repaying an asset amount derived independently
        // from a value estimate can convert back to more shares than the position actually
        // has once rounding compounds near the margins (the same dust problem a full close
        // avoids with exact shares, but it turns out not to be unique to the 1x case).
        // Deriving repayShares directly from borrowSharesRaw keeps it commensurable by
        // construction, so it can never exceed what's outstanding.
        uint256 repayShares;
        if (targetLeverage == 1e18) {
            repayShares = borrowSharesRaw;
        } else {
            uint256 newDebtValue = newCollateralValue - equity;
            uint256 targetBorrowShares = MorphoSharesMath.toSharesDown(newDebtValue, totalBorrowAssets, totalBorrowShares);
            // The up/down rounding chain can still overshoot by a share or two at the
            // margins — clamp rather than let the subtraction below underflow.
            if (targetBorrowShares > borrowSharesRaw) targetBorrowShares = borrowSharesRaw;
            repayShares = borrowSharesRaw - targetBorrowShares;
        }
        require(repayShares > 0, DeleverageAmountTooSmall());

        // Both the flashloan size and the collateral to withdraw are derived from
        // repayShares, not from a separately-rounded value estimate, so the flashloan is
        // always exactly enough to cover what Morpho will actually charge for this many
        // shares — no cross-computation mismatch possible.
        plan.repayShares = repayShares;
        plan.flashloanAmount = MorphoSharesMath.toAssetsUp(repayShares, totalBorrowAssets, totalBorrowShares);
        plan.collateralToWithdraw =
            MorphoSharesMath.mulDivUp(plan.flashloanAmount, MorphoSharesMath.ORACLE_PRICE_SCALE, price);
        require(plan.collateralToWithdraw <= collateralRaw, InvalidDecreaseAmount(plan.collateralToWithdraw, collateralRaw));
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
                    plan.minSwapOut,
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
