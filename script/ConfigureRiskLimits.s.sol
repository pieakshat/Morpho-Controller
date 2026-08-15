// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {Id} from "../src/morpho/interfaces/IMorpho.sol";
import {MorphoLeverageVault} from "../src/morpho/MorphoLeverageVault.sol";
import {RiskLimits} from "../src/morpho/libraries/RiskLimits.sol";
import {ChainConfig, MarketEntry, ConfigLoader} from "./Config.sol";

/// @notice Re-applies every risk limits threshold from the chain config to a deployed
///         vault's limits.
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
///   forge script script/ConfigureRiskLimits.s.sol --rpc-url $RPC --broadcast
///   forge script script/ConfigureRiskLimits.s.sol --sig "printCalldata()" --rpc-url $RPC
contract ConfigureRiskLimits is ConfigLoader {
    function run() external {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);
        RiskLimits limits = _limits();

        vm.startBroadcast(vm.envUint("OWNER_PRIVATE_KEY"));

        limits.setRateLimitWindowSeconds(c.riskLimits.rateLimitWindowSeconds);
        limits.setPriceObservationMaxAge(c.riskLimits.priceObservationMaxAge);
        limits.setMaxAggregateDebt(c.riskLimits.maxAggregateDebt);
        limits.setMaxSlippageBpsCeiling(c.riskLimits.maxSlippageBpsCeiling);

        for (uint256 i = 0; i < c.marketCount; ++i) {
            MarketEntry memory m = _loadMarket(json, i);
            Id id = _marketId(m.params);
            limits.setMinHealthFactor(id, m.minHealthFactor);
            limits.setMaxPriceDeviationBps(id, m.maxPriceDeviationBps);
            limits.setMaxExposureChangePerWindow(id, m.maxExposureChangePerWindow);
            limits.setMaxAssetExposure(m.params.collateralToken, m.assetExposureCap);
        }

        limits.setPaused(c.riskLimits.paused);

        vm.stopBroadcast();

        console2.log("RiskLimits reconfigured:", address(limits));
    }

    /// @notice Emits the same calls as `run`, encoded, for execution by a multisig owner.
    function printCalldata() external view {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);
        address limits = address(_limits());

        console2.log("target (RiskLimits):", limits);
        console2.log("execute in this order; the window must precede any per-market cap");
        console2.log("");

        _log("setRateLimitWindowSeconds", abi.encodeCall(RiskLimits.setRateLimitWindowSeconds, (c.riskLimits.rateLimitWindowSeconds)));
        _log("setPriceObservationMaxAge", abi.encodeCall(RiskLimits.setPriceObservationMaxAge, (c.riskLimits.priceObservationMaxAge)));
        _log("setMaxAggregateDebt", abi.encodeCall(RiskLimits.setMaxAggregateDebt, (c.riskLimits.maxAggregateDebt)));
        _log("setMaxSlippageBpsCeiling", abi.encodeCall(RiskLimits.setMaxSlippageBpsCeiling, (c.riskLimits.maxSlippageBpsCeiling)));

        for (uint256 i = 0; i < c.marketCount; ++i) {
            MarketEntry memory m = _loadMarket(json, i);
            Id id = _marketId(m.params);
            console2.log("-- market:", m.name);
            _log("setMinHealthFactor", abi.encodeCall(RiskLimits.setMinHealthFactor, (id, m.minHealthFactor)));
            _log("setMaxPriceDeviationBps", abi.encodeCall(RiskLimits.setMaxPriceDeviationBps, (id, m.maxPriceDeviationBps)));
            _log(
                "setMaxExposureChangePerWindow",
                abi.encodeCall(RiskLimits.setMaxExposureChangePerWindow, (id, m.maxExposureChangePerWindow))
            );
            _log(
                "setMaxAssetExposure",
                abi.encodeCall(RiskLimits.setMaxAssetExposure, (m.params.collateralToken, m.assetExposureCap))
            );
        }

        _log("setPaused", abi.encodeCall(RiskLimits.setPaused, (c.riskLimits.paused)));
    }

    function _limits() internal view returns (RiskLimits) {
        address vaultAddr = vm.parseJsonAddress(vm.readFile(_deploymentPath()), ".vault");
        return RiskLimits(MorphoLeverageVault(vaultAddr).riskLimits());
    }

    function _log(string memory name, bytes memory data) internal pure {
        console2.log(name, vm.toString(data));
    }
}
