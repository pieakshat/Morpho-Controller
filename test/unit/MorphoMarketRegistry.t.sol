// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {MorphoSwapExecutor} from "../../src/morpho/libraries/MorphoSwapExecutor.sol";
import {MorphoMarketRegistry} from "../../src/morpho/libraries/MorphoMarketRegistry.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Registry behavior exercised through MorphoLeverageVault's real owner-gated
///         entry points (registerMarket/setMarketEnabled/setMaxLeverage), not a
///         standalone internal-function harness — this is the actual surface a real
///         deployment uses. MORPHO/BUNDLER3/GENERAL_ADAPTER/SWAP_EXECUTOR are inert
///         placeholder addresses here: nothing in this tier calls out to them.
contract MorphoMarketRegistryTest is Test {
    MorphoLeverageVault vault;
    MockERC20 asset;
    MockERC20 otherAsset;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        otherAsset = new MockERC20("Other", "OTH", 18);

        vault = new MorphoLeverageVault(
            asset,
            owner,
            IMorpho(address(0x1111)),
            IBundler3(address(0x2222)),
            IGeneralAdapter1(address(0x3333)),
            MorphoSwapExecutor(address(0x4444))
        );
    }

    function _params(address collateralToken) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(asset),
            collateralToken: collateralToken,
            oracle: address(0x5555),
            irm: address(0x6666),
            lltv: 0.86e18
        });
    }

    /*//////////////////////////////////////////////////////////////
                              REGISTER MARKET
    //////////////////////////////////////////////////////////////*/

    function test_registerMarket_succeedsAndReturnsId() public {
        MarketParams memory params = _params(address(0xC01));

        vm.prank(owner);
        Id id = vault.registerMarket(params, 2e18);

        assertTrue(vault.isMarketEnabled(id));
        assertEq(vault.marketConfig(id).maxLeverage, 2e18);
    }

    function test_registerMarket_revertsOnDuplicate() public {
        MarketParams memory params = _params(address(0xC01));

        vm.startPrank(owner);
        Id id = vault.registerMarket(params, 2e18);

        vm.expectRevert(abi.encodeWithSelector(MorphoMarketRegistry.MarketAlreadyRegistered.selector, id));
        vault.registerMarket(params, 2e18);
        vm.stopPrank();
    }

    function test_registerMarket_revertsOnInvalidLeverage() public {
        MarketParams memory params = _params(address(0xC01));

        vm.prank(owner);
        vm.expectRevert(MorphoMarketRegistry.InvalidLeverage.selector);
        vault.registerMarket(params, 1e18 - 1);
    }

    function test_registerMarket_revertsOnLoanTokenMismatch() public {
        MarketParams memory params = _params(address(0xC01));
        params.loanToken = address(otherAsset);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoMarketRegistry.LoanTokenMismatch.selector, address(asset), address(otherAsset))
        );
        vault.registerMarket(params, 2e18);
    }

    function test_registerMarket_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.registerMarket(_params(address(0xC01)), 2e18);
    }

    /*//////////////////////////////////////////////////////////////
                              SET MARKET ENABLED
    //////////////////////////////////////////////////////////////*/

    function test_setMarketEnabled_togglesAndReverts_onUnregistered() public {
        vm.startPrank(owner);
        Id id = vault.registerMarket(_params(address(0xC01)), 2e18);
        assertTrue(vault.isMarketEnabled(id));

        vault.setMarketEnabled(id, false);
        assertFalse(vault.isMarketEnabled(id));

        vault.setMarketEnabled(id, true);
        assertTrue(vault.isMarketEnabled(id));
        vm.stopPrank();

        Id unregistered = Id.wrap(bytes32(uint256(0xdead)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MorphoMarketRegistry.MarketNotRegistered.selector, unregistered));
        vault.setMarketEnabled(unregistered, true);
    }

    function test_setMarketEnabled_onlyOwner() public {
        vm.prank(owner);
        Id id = vault.registerMarket(_params(address(0xC01)), 2e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setMarketEnabled(id, false);
    }

    /*//////////////////////////////////////////////////////////////
                               SET MAX LEVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_setMaxLeverage_updatesAndRevertsOnInvalid() public {
        vm.startPrank(owner);
        Id id = vault.registerMarket(_params(address(0xC01)), 2e18);

        vault.setMaxLeverage(id, 3e18);
        assertEq(vault.marketConfig(id).maxLeverage, 3e18);

        vm.expectRevert(MorphoMarketRegistry.InvalidLeverage.selector);
        vault.setMaxLeverage(id, 1e18 - 1);
        vm.stopPrank();
    }

    function test_setMaxLeverage_onlyOwner() public {
        vm.prank(owner);
        Id id = vault.registerMarket(_params(address(0xC01)), 2e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setMaxLeverage(id, 3e18);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_registeredMarkets_and_activeMarkets_returnCorrectArrays() public {
        vm.startPrank(owner);
        Id id1 = vault.registerMarket(_params(address(0xC01)), 2e18);
        Id id2 = vault.registerMarket(_params(address(0xC02)), 3e18);
        vm.stopPrank();

        Id[] memory registered = vault.registeredMarkets();
        assertEq(registered.length, 2);
        assertEq(Id.unwrap(registered[0]), Id.unwrap(id1));
        assertEq(Id.unwrap(registered[1]), Id.unwrap(id2));

        // Nothing in this tier ever calls executeActions, so the active set — populated
        // only by the leverage engine on a real increase — must stay empty.
        assertEq(vault.activeMarkets().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    function test_setAllocator_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setAllocator(stranger, true);

        vm.prank(owner);
        vault.setAllocator(stranger, true);
        assertTrue(vault.isAllocator(stranger));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_registerMarket_succeedsForAnyValidLeverage(
        uint256 leverage,
        address collateralToken,
        address oracle,
        address irm,
        uint256 lltv
    ) public {
        leverage = bound(leverage, 1e18, 1_000e18);
        lltv = bound(lltv, 0, 1e18);

        MarketParams memory params =
            MarketParams({loanToken: address(asset), collateralToken: collateralToken, oracle: oracle, irm: irm, lltv: lltv});

        vm.prank(owner);
        Id id = vault.registerMarket(params, leverage);

        assertTrue(vault.isMarketEnabled(id));
        assertEq(vault.marketConfig(id).maxLeverage, leverage);
    }

    function testFuzz_registerMarket_revertsForAnyInvalidLeverage(uint256 leverage) public {
        leverage = bound(leverage, 0, 1e18 - 1);

        vm.prank(owner);
        vm.expectRevert(MorphoMarketRegistry.InvalidLeverage.selector);
        vault.registerMarket(_params(address(0xC01)), leverage);
    }

    function testFuzz_setMaxLeverage_revertsForAnyInvalidLeverage(uint256 newLeverage) public {
        newLeverage = bound(newLeverage, 0, 1e18 - 1);

        vm.startPrank(owner);
        Id id = vault.registerMarket(_params(address(0xC01)), 2e18);

        vm.expectRevert(MorphoMarketRegistry.InvalidLeverage.selector);
        vault.setMaxLeverage(id, newLeverage);
        vm.stopPrank();
    }

    /// @dev Every owner-gated entry point must reject an arbitrary non-owner caller.
    function testFuzz_ownerGatedFunctions_revertForAnyNonOwnerCaller(address caller) public {
        vm.assume(caller != owner);

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vault.registerMarket(_params(address(0xC01)), 2e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vault.setAllocator(caller, true);
        vm.stopPrank();

        vm.prank(owner);
        Id id = vault.registerMarket(_params(address(0xC01)), 2e18);

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vault.setMarketEnabled(id, false);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vault.setMaxLeverage(id, 3e18);
        vm.stopPrank();
    }
}
