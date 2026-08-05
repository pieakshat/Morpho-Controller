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
    /// @notice Net value (collateral value minus debt) of one market's position, in ASSET
    ///         terms. Zero if this market currently has no position at all.
    /// @dev loanToken == ASSET is enforced at registration (MorphoMarketRegistry), so debt
    ///      (denominated in loanToken) is already in ASSET terms — no extra conversion.
    ///      Collateral is priced into loan-token terms via the market's own oracle, exactly
    ///      matching Morpho Blue's own internal health-check formula.
    function _positionValue(Id id) internal view returns (uint256) {
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

        // A position can be transiently "underwater" only between a price move and the
        // next rebalance/liquidation touching it — never let that revert a valuation read.
        return collateralValue > debtValue ? collateralValue - debtValue : 0;
    }

    /// @notice Sum of every currently active market's net position value, in ASSET terms.
    /// @dev Called by MorphoLeverageVault.totalAssets() to fold live Morpho exposure into
    ///      the vault's share price, alongside idle balance.
    function totalMorphoAssets() public view returns (uint256 total) {
        uint256 length = _activeMarkets.length;
        for (uint256 i = 0; i < length; ++i) {
            total += _positionValue(_activeMarkets[i]);
        }
    }
}
