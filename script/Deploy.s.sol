// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Id} from "../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../src/morpho/interfaces/IGeneralAdapter1.sol";
import {MorphoLeverageVault} from "../src/morpho/MorphoLeverageVault.sol";
import {RiskLimits} from "../src/morpho/libraries/RiskLimits.sol";
import {ChainConfig, MarketEntry, ConfigLoader} from "./Config.sol";

/// @notice Deploys and fully configures a MorphoLeverageVault from script/config/<chainid>.json.
///
/// @dev Ownership sequencing is the thing to understand here. RiskLimits resolves its
///      admin as IOwnableView(VAULT).owner() at call time, and Ownable sets the owner in the
///      vault's constructor. Deploying straight to a multisig would therefore lock this
///      script out of registerMarket, setAllocator, and every limits setter. So the vault
///      is always deployed owned by the deployer, configured, and only then handed over.
///
///      The handover cannot complete here either: Ownable2Step requires the incoming owner
///      to call acceptOwnership() themselves. This script leaves it pending and says so
///      loudly rather than pretending the transfer is done.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast
contract Deploy is ConfigLoader {
    function run() external {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address allocator = vm.envAddress("ALLOCATOR_ADDRESS");
        // Optional. Unset means the deployer stays the permanent owner
        address finalOwner = vm.envOr("VAULT_OWNER", address(0));

        for (uint256 i = 0; i < c.marketCount; ++i) {
            _requireLiveOnMorpho(c.morpho, _loadMarket(json, i), c.asset);
        }
        if (c.seedAmount > 0) {
            require(
                IERC20(c.asset).balanceOf(deployer) >= c.seedAmount,
                "deployer does not hold enough asset for the seed deposit"
            );
        }

        vm.startBroadcast(deployerPk);

        MorphoLeverageVault vault = new MorphoLeverageVault(
            IERC20(c.asset), deployer, IMorpho(c.morpho), IBundler3(c.bundler3), IGeneralAdapter1(c.generalAdapter1)
        );
        RiskLimits limits = RiskLimits(vault.riskLimits());

        vault.setAllocator(allocator, true);
        vault.setActionDropToleranceBps(c.actionDropToleranceBps);

        // Global limits settings first. The rate-limit window in particular must land
        // before any per-market cap: setMaxExposureChangePerWindow reverts
        // RateLimitWindowNotSet while the window is still zero, because a zero window makes
        // every call look like a fresh period and silently turns a per-window budget into a
        // per-action one.
        limits.setRateLimitWindowSeconds(c.riskLimits.rateLimitWindowSeconds);
        limits.setPriceObservationMaxAge(c.riskLimits.priceObservationMaxAge);
        limits.setMaxAggregateDebt(c.riskLimits.maxAggregateDebt);
        limits.setMaxSlippageBpsCeiling(c.riskLimits.maxSlippageBpsCeiling);

        for (uint256 i = 0; i < c.marketCount; ++i) {
            _registerAndLimit(vault, limits, _loadMarket(json, i));
        }

        if (c.riskLimits.paused) limits.setPaused(true);

        _seed(vault, c);

        if (finalOwner != address(0) && finalOwner != deployer) {
            vault.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        _writeArtifact(json, vault, limits, c, allocator);
        _report(json, vault, limits, c, deployer, allocator, finalOwner);
    }

    function _registerAndLimit(MorphoLeverageVault vault, RiskLimits limits, MarketEntry memory m) internal {
        Id id = vault.registerMarket(m.params, m.maxLeverage, m.maxSlippageBps);

        limits.setMinHealthFactor(id, m.minHealthFactor);
        limits.setMaxPriceDeviationBps(id, m.maxPriceDeviationBps);
        limits.setMaxExposureChangePerWindow(id, m.maxExposureChangePerWindow);
        // Keyed by collateral token, not by market: the cap is the total across every active
        // market sharing that collateral, so two markets on the same asset write the same
        // slot and the last value in the config wins. Intentional, but worth knowing.
        limits.setMaxAssetExposure(m.params.collateralToken, m.assetExposureCap);
    }

    /// @dev Shares go to a burn address, never to the deployer. Seeding is what closes the
    ///      first-depositor inflation window, and that window reopens the moment those
    ///      shares can be redeemed, so they must be unredeemable by construction rather than
    ///      by policy. address(0) is not an option: OZ's _mint reverts ERC20InvalidReceiver.
    function _seed(MorphoLeverageVault vault, ChainConfig memory c) internal {
        if (c.seedAmount == 0) return;
        IERC20(c.asset).approve(address(vault), c.seedAmount);
        vault.deposit(c.seedAmount, c.seedBurnAddress);
    }

    /// @dev The allocator service reads this file for its addresses, so it is the handoff
    ///      point between this repo's Solidity and the off-chain side.
    function _writeArtifact(
        string memory json,
        MorphoLeverageVault vault,
        RiskLimits limits,
        ChainConfig memory c,
        address allocator
    ) internal {
        string memory marketsObj = "markets";
        string memory marketsOut = "";
        for (uint256 i = 0; i < c.marketCount; ++i) {
            MarketEntry memory m = _loadMarket(json, i);
            marketsOut = vm.serializeBytes32(marketsObj, m.name, Id.unwrap(_marketId(m.params)));
        }

        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "vault", address(vault));
        vm.serializeAddress(obj, "swapExecutor", vault.swapExecutor());
        vm.serializeAddress(obj, "riskLimits", address(limits));
        vm.serializeAddress(obj, "asset", c.asset);
        vm.serializeAddress(obj, "morpho", c.morpho);
        vm.serializeAddress(obj, "bundler3", c.bundler3);
        vm.serializeAddress(obj, "generalAdapter1", c.generalAdapter1);
        vm.serializeAddress(obj, "allocator", allocator);
        vm.serializeAddress(obj, "owner", vault.owner());
        string memory out = vm.serializeString(obj, "markets", marketsOut);

        vm.writeJson(out, _deploymentPath());
    }

    function _report(
        string memory json,
        MorphoLeverageVault vault,
        RiskLimits limits,
        ChainConfig memory c,
        address deployer,
        address allocator,
        address finalOwner
    ) internal view {
        console2.log("");
        console2.log("=== deployed ===");
        console2.log("vault          ", address(vault));
        console2.log("swapExecutor   ", vault.swapExecutor());
        console2.log("riskLimits ", address(limits));
        console2.log("allocator      ", allocator);
        console2.log("owner          ", vault.owner());
        console2.log("artifact       ", _deploymentPath());

        for (uint256 i = 0; i < c.marketCount; ++i) {
            MarketEntry memory m = _loadMarket(json, i);
            console2.log("market         ", m.name, vm.toString(Id.unwrap(_marketId(m.params))));
        }
        if (c.seedAmount > 0) {
            console2.log("seeded         ", c.seedAmount, "->", c.seedBurnAddress);
        }

        if (finalOwner != address(0) && finalOwner != deployer) {
            console2.log("");
            console2.log("!!! OWNERSHIP TRANSFER IS PENDING, NOT COMPLETE !!!");
            console2.log("Ownable2Step needs the incoming owner to accept before it takes effect.");
            console2.log("Until then the deployer still owns the vault AND RiskLimits.");
            console2.log("  new owner must call vault.acceptOwnership()");
            console2.log("  new owner:", finalOwner);
        }
    }
}
