// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {Id} from "../src/morpho/interfaces/IMorpho.sol";
import {MorphoLeverageVault} from "../src/morpho/MorphoLeverageVault.sol";
import {CircuitBreaker} from "../src/morpho/libraries/CircuitBreaker.sol";
import {ChainConfig, MarketEntry, ConfigLoader} from "./Config.sol";

/// @notice Registers one additional market on an already-deployed vault, and applies that
///         market's breaker thresholds in the same transaction batch.
///
/// @dev Separate from Deploy because markets get added over the vault's life, and the
///      registration path should not only exist inside a one-shot deploy script. Reads the
///      market from the same chain config, so a new market is added by appending to
///      `markets`, bumping `marketCount`, and running this with MARKET_INDEX pointed at it.
///
///      Broadcasts with a single OWNER_PRIVATE_KEY, so it stops working the moment the
///      vault's owner moves to a multisig — there's no key left to sign with. Unlike
///      ConfigureBreaker, there's no printCalldata() mode here yet; registering a market
///      after handover means building the registerMarket and breaker calls by hand.
///
/// Usage:
///   MARKET_INDEX=1 forge script script/RegisterMarket.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast
contract RegisterMarket is ConfigLoader {
    function run() external {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);

        uint256 index = vm.envUint("MARKET_INDEX");
        require(index < c.marketCount, "MARKET_INDEX out of range for this config");
        MarketEntry memory m = _loadMarket(json, index);

        address vaultAddr = vm.parseJsonAddress(vm.readFile(_deploymentPath()), ".vault");
        MorphoLeverageVault vault = MorphoLeverageVault(vaultAddr);
        CircuitBreaker breaker = CircuitBreaker(vault.circuitBreaker());

        _requireLiveOnMorpho(c.morpho, m, c.asset);
        require(!vault.isMarketEnabled(_marketId(m.params)), "market already registered on this vault");

        // A per-market cap cannot be set while the global window is still zero. On a vault
        // deployed by Deploy.s.sol it already is set, but this script can also run against a
        // vault configured by hand, so check rather than assume.
        require(
            m.maxExposureChangePerWindow == 0 || breaker.rateLimitWindowSeconds() != 0,
            "set breaker rateLimitWindowSeconds before registering a market with a rate limit"
        );

        vm.startBroadcast(vm.envUint("OWNER_PRIVATE_KEY"));

        Id id = vault.registerMarket(m.params, m.maxLeverage, m.maxSlippageBps);
        breaker.setMinHealthFactor(id, m.minHealthFactor);
        breaker.setMaxPriceDeviationBps(id, m.maxPriceDeviationBps);
        breaker.setMaxExposureChangePerWindow(id, m.maxExposureChangePerWindow);
        breaker.setMaxAssetExposure(m.params.collateralToken, m.assetExposureCap);

        vm.stopBroadcast();

        console2.log("registered", m.name);
        console2.log("  vault   ", vaultAddr);
        console2.log("  marketId", vm.toString(Id.unwrap(id)));
    }
}
