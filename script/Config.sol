// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMorpho, Id, MarketParams} from "../src/morpho/interfaces/IMorpho.sol";

/// @notice One market entry from the chain config: the Morpho market itself, the registry
///         limits it is registered with, and the breaker thresholds scoped to it.
struct MarketEntry {
    string name;
    MarketParams params;
    uint256 maxLeverage;
    uint256 maxSlippageBps;
    uint256 minHealthFactor;
    uint256 maxPriceDeviationBps;
    uint256 maxExposureChangePerWindow;
    uint256 assetExposureCap;
}

/// @notice Breaker thresholds that are not scoped to a single market.
struct GlobalBreakerConfig {
    bool paused;
    uint256 priceObservationMaxAge;
    uint256 rateLimitWindowSeconds;
    uint256 maxAggregateDebt;
    uint256 maxSlippageBpsCeiling;
}

struct ChainConfig {
    address morpho;
    address bundler3;
    address generalAdapter1;
    address asset;
    uint256 marketCount;
    uint256 seedAmount;
    address seedBurnAddress;
    uint256 actionDropToleranceBps;
    GlobalBreakerConfig breaker;
}

/// @notice Shared loader for script/config/<chainid>.json.
/// @dev Addresses and risk policy live in JSON rather than in Solidity so that adding a
///      chain is a new file, not a new branch, and changing a threshold is not a code
///      change. Every script reads the same file, which is what keeps a deploy and a later
///      reconfiguration from disagreeing about what the policy is.
abstract contract ConfigLoader is Script {
    function _configPath() internal view returns (string memory) {
        return string.concat("script/config/", vm.toString(block.chainid), ".json");
    }

    /// @dev DEPLOYMENT_LABEL exists because a fork reports the forked chain's id: an anvil
    ///      fork of Arbitrum is chain 42161, so a local run would otherwise overwrite the
    ///      real deployment record with a throwaway vault address and nothing about the file
    ///      would show it. Set DEPLOYMENT_LABEL=local for fork work; leave it unset for real
    ///      deployments.
    function _deploymentPath() internal view returns (string memory) {
        string memory label = vm.envOr("DEPLOYMENT_LABEL", string(""));
        string memory suffix = bytes(label).length == 0 ? ".json" : string.concat(".", label, ".json");
        return string.concat("deployments/", vm.toString(block.chainid), suffix);
    }

    function _readConfig() internal view returns (string memory) {
        return vm.readFile(_configPath());
    }

    function _loadChain(string memory json) internal pure returns (ChainConfig memory c) {
        c.morpho = vm.parseJsonAddress(json, ".core.morpho");
        c.bundler3 = vm.parseJsonAddress(json, ".core.bundler3");
        c.generalAdapter1 = vm.parseJsonAddress(json, ".core.generalAdapter1");
        c.asset = vm.parseJsonAddress(json, ".asset");
        c.marketCount = vm.parseJsonUint(json, ".marketCount");

        c.seedAmount = vm.parseJsonUint(json, ".seed.amount");
        c.seedBurnAddress = vm.parseJsonAddress(json, ".seed.burnAddress");
        c.actionDropToleranceBps = vm.parseJsonUint(json, ".vault.actionDropToleranceBps");

        c.breaker = GlobalBreakerConfig({
            paused: vm.parseJsonBool(json, ".breaker.paused"),
            priceObservationMaxAge: vm.parseJsonUint(json, ".breaker.priceObservationMaxAge"),
            rateLimitWindowSeconds: vm.parseJsonUint(json, ".breaker.rateLimitWindowSeconds"),
            maxAggregateDebt: vm.parseJsonUint(json, ".breaker.maxAggregateDebt"),
            maxSlippageBpsCeiling: vm.parseJsonUint(json, ".breaker.maxSlippageBpsCeiling")
        });
    }

    /// @dev Indexed field-by-field rather than abi.decode'd as a struct array. Struct
    ///      decoding from JSON depends on alphabetical field ordering, which breaks silently
    ///      and confusingly when a field is renamed; explicit paths fail loudly instead.
    function _loadMarket(string memory json, uint256 i) internal pure returns (MarketEntry memory m) {
        string memory p = string.concat(".markets[", vm.toString(i), "]");

        m.name = vm.parseJsonString(json, string.concat(p, ".name"));
        m.params = MarketParams({
            loanToken: vm.parseJsonAddress(json, string.concat(p, ".loanToken")),
            collateralToken: vm.parseJsonAddress(json, string.concat(p, ".collateralToken")),
            oracle: vm.parseJsonAddress(json, string.concat(p, ".oracle")),
            irm: vm.parseJsonAddress(json, string.concat(p, ".irm")),
            lltv: vm.parseJsonUint(json, string.concat(p, ".lltv"))
        });
        m.maxLeverage = vm.parseJsonUint(json, string.concat(p, ".maxLeverage"));
        m.maxSlippageBps = vm.parseJsonUint(json, string.concat(p, ".maxSlippageBps"));
        m.minHealthFactor = vm.parseJsonUint(json, string.concat(p, ".minHealthFactor"));
        m.maxPriceDeviationBps = vm.parseJsonUint(json, string.concat(p, ".maxPriceDeviationBps"));
        m.maxExposureChangePerWindow = vm.parseJsonUint(json, string.concat(p, ".maxExposureChangePerWindow"));
        m.assetExposureCap = vm.parseJsonUint(json, string.concat(p, ".assetExposureCap"));
    }

    function _marketId(MarketParams memory params) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(params)));
    }

    /// @dev registerMarket computes the Id from params and stores it without ever asking
    ///      Morpho whether that market exists. One wrong byte in oracle, irm, or lltv
    ///      registers a valid-looking Id for a market that was never created, and the
    ///      failure surfaces much later as an opaque revert inside Morpho on the first
    ///      increase. A live market always has a non-zero lastUpdate.
    function _requireLiveOnMorpho(address morpho, MarketEntry memory m, address asset) internal view {
        (,,,, uint128 lastUpdate,) = IMorpho(morpho).market(_marketId(m.params));
        require(lastUpdate != 0, string.concat("market not live on Morpho: ", m.name));
        require(m.params.loanToken == asset, string.concat("loanToken != vault asset: ", m.name));
    }
}
