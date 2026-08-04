// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Id, MarketParams} from "../interfaces/IMorpho.sol";
import {MorphoMarketConfig} from "../types/MorphoTypes.sol";

/// @notice Owner-managed whitelist of Morpho markets this adapter may hold positions in,
///         plus tracking of which markets currently have a non-zero position.
/// @dev Two separate lists, two separate jobs:
///      - the whitelist bounds blast radius if the allocator key is ever compromised
///      - the active set exists purely for gas: totalAssets() should iterate only markets
///        with real exposure, not the entire whitelist every single call.
///      Meant to be inherited by MorphoAdapter, not deployed standalone.
abstract contract MorphoMarketRegistry {
    error MarketAlreadyRegistered(Id id);
    error MarketNotRegistered(Id id);
    error InvalidLeverage();
    error LoanTokenMismatch(address expected, address actual);

    event MarketRegistered(Id indexed id, uint256 targetLeverage);
    event MarketEnabledSet(Id indexed id, bool enabled);
    event MarketLeverageUpdated(Id indexed id, uint256 targetLeverage);
    event MarketActivated(Id indexed id);
    event MarketDeactivated(Id indexed id);

    /// @notice The asset this adapter (and its owning vault) is denominated in. Every
    ///         registered market's loanToken must equal this — see _registerMarket.
    /// @dev Collateral token is unconstrained (handled via swap in MarketAction); loan
    ///      token is constrained on purpose, since a mismatch there would need a second
    ///      swap leg just to reconcile debt back to the vault's asset, and would make
    ///      valuation ambiguous about which token a position's debt is actually in.
    address internal immutable ASSET;

    mapping(Id => MorphoMarketConfig) internal _marketConfigs;
    mapping(Id => bool) internal _isRegistered;
    Id[] internal _registeredMarkets;

    mapping(Id => bool) internal _isActive;
    Id[] internal _activeMarkets;

    modifier onlyRegistered(Id id) {
        require(_isRegistered[id], MarketNotRegistered(id));
        _;
    }

    constructor(address asset_) {
        ASSET = asset_;
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST ADMIN (governance-facing)
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds a new market to the whitelist, enabled by default.
    /// @dev Id is derived from params, not passed in — can't register a mismatched pair.
    function _registerMarket(MarketParams memory params, uint256 targetLeverage) internal returns (Id id) {
        require(params.loanToken == ASSET, LoanTokenMismatch(ASSET, params.loanToken));
        require(targetLeverage >= 1e18, InvalidLeverage());
        id = _computeId(params);
        require(!_isRegistered[id], MarketAlreadyRegistered(id));

        _isRegistered[id] = true;
        _marketConfigs[id] = MorphoMarketConfig({params: params, targetLeverage: targetLeverage, enabled: true});
        _registeredMarkets.push(id);

        emit MarketRegistered(id, targetLeverage);
    }

    /// @notice Enables or disables new increases into a market. Does NOT touch existing
    ///         positions — disabling a market should stop new exposure, not force an exit.
    function _setMarketEnabled(Id id, bool enabled) internal onlyRegistered(id) {
        _marketConfigs[id].enabled = enabled;
        emit MarketEnabledSet(id, enabled);
    }

    function _setMarketLeverage(Id id, uint256 targetLeverage) internal onlyRegistered(id) {
        require(targetLeverage >= 1e18, InvalidLeverage());
        _marketConfigs[id].targetLeverage = targetLeverage;
        emit MarketLeverageUpdated(id, targetLeverage);
    }

    /*//////////////////////////////////////////////////////////////
                 ACTIVE-SET BOOKKEEPING (called by execution logic)
    //////////////////////////////////////////////////////////////*/

    /// @dev Called after an increase actually lands a non-zero position. Idempotent.
    function _markActive(Id id) internal {
        if (!_isActive[id]) {
            _isActive[id] = true;
            _activeMarkets.push(id);
            emit MarketActivated(id);
        }
    }

    /// @dev Called after a decrease fully closes a position. Idempotent.
    function _markInactive(Id id) internal {
        if (_isActive[id]) {
            _isActive[id] = false;
            _removeFromActiveArray(id);
            emit MarketDeactivated(id);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                    VIEWS
    //////////////////////////////////////////////////////////////*/

    function marketConfig(Id id) public view returns (MorphoMarketConfig memory) {
        return _marketConfigs[id];
    }

    function isMarketEnabled(Id id) public view returns (bool) {
        return _isRegistered[id] && _marketConfigs[id].enabled;
    }

    function registeredMarkets() external view returns (Id[] memory) {
        return _registeredMarkets;
    }

    function activeMarkets() external view returns (Id[] memory) {
        return _activeMarkets;
    }

    /*//////////////////////////////////////////////////////////////
                                  INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _computeId(MarketParams memory params) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(params)));
    }

    function _removeFromActiveArray(Id target) internal {
        uint256 length = _activeMarkets.length;
        for (uint256 i = 0; i < length; ++i) {
            if (Id.unwrap(_activeMarkets[i]) == Id.unwrap(target)) {
                _activeMarkets[i] = _activeMarkets[length - 1];
                _activeMarkets.pop();
                return;
            }
        }
    }
}
