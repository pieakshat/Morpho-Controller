// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Id, MarketParams} from "../interfaces/IMorpho.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {MorphoMarketConfig} from "../types/MorphoTypes.sol";
import {MorphoSharesMath} from "./MorphoSharesMath.sol";
import {MorphoCore} from "./MorphoCore.sol";
import {MorphoMarketRegistry} from "./MorphoMarketRegistry.sol";

/// @notice Reads live Morpho state and values this adapter's positions in ASSET terms.
/// @dev Iterates only the registry's active set. That set exists precisely so this stays
///      cheap regardless of how many markets are whitelisted in total.
abstract contract MorphoPositionValuation is MorphoCore, MorphoMarketRegistry {
    /// @notice One market's position split into whichever side it lands on: `surplus` when
    ///         collateral covers debt, `shortfall` when it does not. Exactly one is ever
    ///         non-zero.
    /// @dev loanToken == ASSET is enforced at registration (MorphoMarketRegistry), so debt
    ///      (denominated in loanToken) is already in ASSET terms — no extra conversion.
    ///      Collateral is priced into loan-token terms via the market's own oracle, exactly
    ///      matching Morpho Blue's own internal health-check formula.
    ///
    ///      Returned as a pair instead of a single clamped number: a uint can't express the
    ///      negative value of an underwater position, and losing that sign would let the
    ///      vault report more value than it actually has. MorphoLeverageVault.totalAssets()
    ///      is what nets the two sides back together against idle balance.
    function _positionValue(Id id) internal view returns (uint256 surplus, uint256 shortfall) {
        MarketParams memory params = _marketConfigs[id].params;

        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));

        uint256 debtValue;
        if (borrowShares > 0) {
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
            // Rounds up — never under-report what this position owes.
            debtValue = MorphoSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
        }

        uint256 collateralValue;
        if (collateral > 0) {
            uint256 price = IOracle(params.oracle).price();
            collateralValue = MorphoSharesMath.mulDivDown(collateral, price, MorphoSharesMath.ORACLE_PRICE_SCALE);
        }

        // A position can be transiently underwater between a price move and the rebalance
        // or liquidation that resolves it — never let that revert a valuation read.
        if (collateralValue >= debtValue) {
            surplus = collateralValue - debtValue;
        } else {
            shortfall = debtValue - collateralValue;
        }
    }

    /// @notice Totals across every active market, kept separate so the caller decides how
    ///         to net them.
    /// @dev Sums each market's surplus and shortfall independently rather than clamping per
    ///      position first — see _positionValue for why that distinction matters.
    function _morphoSurplusAndShortfall() internal view returns (uint256 surplus, uint256 shortfall) {
        uint256 length = _activeMarkets.length;
        for (uint256 i = 0; i < length; ++i) {
            (uint256 positionSurplus, uint256 positionShortfall) = _positionValue(_activeMarkets[i]);
            surplus += positionSurplus;
            shortfall += positionShortfall;
        }
    }

    /// @notice Net value of every active Morpho position, in ASSET terms, floored at zero.
    /// @dev Informational only — flooring early throws away whether a shortfall should have
    ///      eaten into idle balance, so MorphoLeverageVault.totalAssets() computes its own
    ///      total from _morphoSurplusAndShortfall() rather than calling this.
    function totalMorphoAssets() public view returns (uint256) {
        (uint256 surplus, uint256 shortfall) = _morphoSurplusAndShortfall();
        return surplus > shortfall ? surplus - shortfall : 0;
    }
}
