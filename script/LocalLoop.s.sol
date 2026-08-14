// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Id, MarketParams} from "../src/morpho/interfaces/IMorpho.sol";
import {IOracle} from "../src/morpho/interfaces/IOracle.sol";
import {MarketAction} from "../src/morpho/types/MorphoTypes.sol";
import {MorphoLeverageVault} from "../src/morpho/MorphoLeverageVault.sol";
import {MorphoSharesMath} from "../src/morpho/libraries/MorphoSharesMath.sol";
import {MockSwapRouter} from "../test/mocks/MockSwapRouter.sol";
import {ChainConfig, MarketEntry, ConfigLoader} from "./Config.sol";

/// @notice LOCAL DEVELOPMENT ONLY. Drives one full increase/decrease cycle against a
///         deployed vault using a mock swap venue.
///
/// @dev Never run this against a real network. It deploys MockSwapRouter, which fills at
///      whatever rate you tell it and holds no real liquidity. Real routing is the
///      allocator service's problem, not the deploy scripts'.
///
///      Split into separate entry points because the router has to be funded with the
///      output token between steps, and funding on a fork means writing storage from
///      outside the script. See the runbook in README.
contract LocalLoop is ConfigLoader {
    function _vault() internal view returns (MorphoLeverageVault) {
        return MorphoLeverageVault(vm.parseJsonAddress(vm.readFile(_deploymentPath()), ".vault"));
    }

    /// @notice Step 1. Deploy the mock venue and put real depositor capital in the vault.
    function setup() external {
        ChainConfig memory c = _loadChain(_readConfig());
        MorphoLeverageVault vault = _vault();
        uint256 depositAmount = vm.envUint("DEPOSIT_AMOUNT");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        MockSwapRouter router = new MockSwapRouter();
        IERC20(c.asset).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY")));
        vm.stopBroadcast();

        console2.log("router      ", address(router));
        console2.log("totalAssets ", vault.totalAssets());
    }

    /// @notice Step 2. Open a leveraged position. Requires the router to already hold
    ///         enough collateral token to fill at the oracle rate.
    function openPosition() external {
        string memory json = _readConfig();
        MarketEntry memory m = _loadMarket(json, 0);
        MorphoLeverageVault vault = _vault();

        address router = vm.envAddress("ROUTER_ADDRESS");
        uint256 ownAmount = vm.envUint("OWN_AMOUNT");
        uint256 leverage = vm.envUint("LEVERAGE");
        uint256 totalAmount = (ownAmount * leverage) / 1e18;

        // Fill at exactly the oracle rate so the swap does not distort collateral valuation
        // or Morpho's LLTV check. Same rate the fork tests use.
        uint256 rate = 1e54 / IOracle(m.params.oracle).price();
        uint256 expectedOut = (totalAmount * rate) / 1e18;

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: _marketId(m.params),
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: expectedOut,
            swapTarget: router,
            swapCalldata: abi.encodeCall(
                MockSwapRouter.swap, (IERC20(m.params.loanToken), IERC20(m.params.collateralToken), totalAmount)
            )
        });

        vm.startBroadcast(vm.envUint("ALLOCATOR_PRIVATE_KEY"));
        MockSwapRouter(router).setRate(rate);
        vault.executeActions(actions);
        vm.stopBroadcast();

        _report(vault, m, "opened");
    }

    /// @notice Step 3. Full close. Requires the router to hold enough loan token to fill.
    function closePosition() external {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);
        MarketEntry memory m = _loadMarket(json, 0);
        MorphoLeverageVault vault = _vault();
        Id id = _marketId(m.params);

        address router = vm.envAddress("ROUTER_ADDRESS");

        // Mirrors _planDecrease's full-close branch: the whole collateral balance comes out,
        // and the swap is sized to exactly that. This is the computation the off-chain
        // allocator will have to reproduce.
        (,, uint128 collateral) = IMorpho(c.morpho).position(id, address(vault));
        uint256 rate = IOracle(m.params.oracle).price() / 1e18;
        uint256 expectedOut = (uint256(collateral) * rate) / 1e18;

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: id,
            isIncrease: false,
            amount: type(uint256).max, // full close sentinel
            leverage: 0,
            minOut: expectedOut,
            swapTarget: router,
            swapCalldata: abi.encodeCall(
                MockSwapRouter.swap,
                (IERC20(m.params.collateralToken), IERC20(m.params.loanToken), uint256(collateral))
            )
        });

        vm.startBroadcast(vm.envUint("ALLOCATOR_PRIVATE_KEY"));
        MockSwapRouter(router).setRate(rate);
        vault.executeActions(actions);
        vm.stopBroadcast();

        _report(vault, m, "closed");
    }

    /// @notice Read-only helper: what the router needs to be funded with for each leg.
    function quote() external view {
        string memory json = _readConfig();
        ChainConfig memory c = _loadChain(json);
        MarketEntry memory m = _loadMarket(json, 0);
        MorphoLeverageVault vault = _vault();

        uint256 price = IOracle(m.params.oracle).price();
        uint256 totalAmount = (vm.envUint("OWN_AMOUNT") * vm.envUint("LEVERAGE")) / 1e18;

        console2.log("oracle price      ", price);
        console2.log("collateral needed ", (totalAmount * (1e54 / price)) / 1e18);

        (,, uint128 collateral) = IMorpho(c.morpho).position(_marketId(m.params), address(vault));
        if (collateral > 0) {
            console2.log("loan token needed ", (uint256(collateral) * (price / 1e18)) / 1e18);
        }
    }

    function _report(MorphoLeverageVault vault, MarketEntry memory m, string memory label) internal view {
        ChainConfig memory c = _loadChain(_readConfig());
        (, uint128 borrowShares, uint128 collateral) = IMorpho(c.morpho).position(_marketId(m.params), address(vault));

        console2.log("");
        console2.log("=== position", label, "===");
        console2.log("collateral   ", collateral);
        console2.log("borrowShares ", borrowShares);
        console2.log("totalAssets  ", vault.totalAssets());
        console2.log("idle         ", IERC20(c.asset).balanceOf(address(vault)));
        console2.log("activeMarkets", vault.activeMarkets().length);
    }
}
