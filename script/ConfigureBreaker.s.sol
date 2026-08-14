// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {Id} from "../src/morpho/interfaces/IMorpho.sol";
import {MorphoLeverageVault} from "../src/morpho/MorphoLeverageVault.sol";
import {CircuitBreaker} from "../src/morpho/libraries/CircuitBreaker.sol";
import {ChainConfig, MarketEntry, ConfigLoader} from "./Config.sol";

/// @notice Re-applies every circuit breaker threshold from the chain config to a deployed
///         vault's breaker.
///
/// @dev Split out of Deploy for one reason: once ownership moves to a multisig, nobody can
///      run this as a transaction. `printCalldata` exists for exactly that case, emitting
///      the encoded calls to hand to the multisig instead. Risk policy stays as data in the
///      config file either way, so both paths apply the same numbers.
///
///      Ordering is load-bearing throughout: the global rate-limit window must be set before
///      any per-market cap, or setMaxExposureChangePerWindow reverts RateLimitWindowNotSet.
///      Both entry points below emit the calls in that order.
///
/// Usage:
///   forge script script/ConfigureBreaker.s.sol --rpc-url $RPC --broadcast
///   forge script script/ConfigureBreaker.s.sol --sig "printCalldata()" --rpc-url $RPC
contract ConfigureBreaker is ConfigLoader {
    function run() external {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);
        CircuitBreaker breaker = _breaker();

        vm.startBroadcast(vm.envUint("OWNER_PRIVATE_KEY"));

        breaker.setRateLimitWindowSeconds(c.breaker.rateLimitWindowSeconds);
        breaker.setPriceObservationMaxAge(c.breaker.priceObservationMaxAge);
        breaker.setMaxAggregateDebt(c.breaker.maxAggregateDebt);
        breaker.setMaxSlippageBpsCeiling(c.breaker.maxSlippageBpsCeiling);

        for (uint256 i = 0; i < c.marketCount; ++i) {
            MarketEntry memory m = _loadMarket(json, i);
            Id id = _marketId(m.params);
            breaker.setMinHealthFactor(id, m.minHealthFactor);
            breaker.setMaxPriceDeviationBps(id, m.maxPriceDeviationBps);
            breaker.setMaxExposureChangePerWindow(id, m.maxExposureChangePerWindow);
            breaker.setMaxAssetExposure(m.params.collateralToken, m.assetExposureCap);
        }

        breaker.setPaused(c.breaker.paused);

        vm.stopBroadcast();

        console2.log("breaker reconfigured:", address(breaker));
    }

    /// @notice Emits the same calls as `run`, encoded, for execution by a multisig owner.
    function printCalldata() external view {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);
        address breaker = address(_breaker());

        console2.log("target (CircuitBreaker):", breaker);
        console2.log("execute in this order; the window must precede any per-market cap");
        console2.log("");

        _log("setRateLimitWindowSeconds", abi.encodeCall(CircuitBreaker.setRateLimitWindowSeconds, (c.breaker.rateLimitWindowSeconds)));
        _log("setPriceObservationMaxAge", abi.encodeCall(CircuitBreaker.setPriceObservationMaxAge, (c.breaker.priceObservationMaxAge)));
        _log("setMaxAggregateDebt", abi.encodeCall(CircuitBreaker.setMaxAggregateDebt, (c.breaker.maxAggregateDebt)));
        _log("setMaxSlippageBpsCeiling", abi.encodeCall(CircuitBreaker.setMaxSlippageBpsCeiling, (c.breaker.maxSlippageBpsCeiling)));

        for (uint256 i = 0; i < c.marketCount; ++i) {
            MarketEntry memory m = _loadMarket(json, i);
            Id id = _marketId(m.params);
            console2.log("-- market:", m.name);
            _log("setMinHealthFactor", abi.encodeCall(CircuitBreaker.setMinHealthFactor, (id, m.minHealthFactor)));
            _log("setMaxPriceDeviationBps", abi.encodeCall(CircuitBreaker.setMaxPriceDeviationBps, (id, m.maxPriceDeviationBps)));
            _log(
                "setMaxExposureChangePerWindow",
                abi.encodeCall(CircuitBreaker.setMaxExposureChangePerWindow, (id, m.maxExposureChangePerWindow))
            );
            _log(
                "setMaxAssetExposure",
                abi.encodeCall(CircuitBreaker.setMaxAssetExposure, (m.params.collateralToken, m.assetExposureCap))
            );
        }

        _log("setPaused", abi.encodeCall(CircuitBreaker.setPaused, (c.breaker.paused)));
    }

    function _breaker() internal view returns (CircuitBreaker) {
        address vaultAddr = vm.parseJsonAddress(vm.readFile(_deploymentPath()), ".vault");
        return CircuitBreaker(MorphoLeverageVault(vaultAddr).circuitBreaker());
    }

    function _log(string memory name, bytes memory data) internal pure {
        console2.log(name, vm.toString(data));
    }
}
