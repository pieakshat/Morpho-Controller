// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {MorphoMarketConfig, IncreaseCheckParams} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";
import {CircuitBreaker} from "../../src/morpho/libraries/CircuitBreaker.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Stands in for MorphoLeverageVault: deploys its own CircuitBreaker exactly like
///      MorphoCore does, exposes Ownable2Step so ownership-transfer behavior is real, and
///      exposes the IVaultMarketsView surface (activeMarkets/marketConfig) the breaker reads
///      back. Relay functions mirror the exact calls MorphoLeverageEngine makes, so
///      msg.sender inside CircuitBreaker is this contract, same as in production.
contract MockVault is Ownable2Step {
    CircuitBreaker public immutable BREAKER;

    mapping(Id => MorphoMarketConfig) internal _configs;
    Id[] internal _active;

    constructor(IMorpho morpho_, address owner_) Ownable(owner_) {
        BREAKER = new CircuitBreaker(morpho_);
    }

    function setMarketConfig(Id id, MorphoMarketConfig calldata cfg) external {
        _configs[id] = cfg;
    }

    function setActiveMarkets(Id[] calldata ids) external {
        delete _active;
        for (uint256 i = 0; i < ids.length; ++i) {
            _active.push(ids[i]);
        }
    }

    function activeMarkets() external view returns (Id[] memory) {
        return _active;
    }

    function marketConfig(Id id) external view returns (MorphoMarketConfig memory) {
        return _configs[id];
    }

    function callCheckBeforeIncrease(IncreaseCheckParams calldata p) external {
        BREAKER.checkBeforeIncrease(p);
    }

    function callCheckAfterIncrease(IncreaseCheckParams calldata p) external view {
        BREAKER.checkAfterIncrease(p);
    }

    function callCheckAfterDecrease(Id id, uint256 unwoundValue) external {
        BREAKER.checkAfterDecrease(id, unwoundValue);
    }
}

contract CircuitBreakerTest is Test {
    MockMorpho morpho;
    MockVault vault;
    CircuitBreaker breaker;
    MockOracle oracle;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    Id marketId = Id.wrap(bytes32(uint256(1)));
    address collateralToken = address(0xC01);

    function setUp() public {
        morpho = new MockMorpho();
        vault = new MockVault(IMorpho(address(morpho)), owner);
        breaker = vault.BREAKER();
        oracle = new MockOracle();
        oracle.setPrice(1e36);
    }

    function _marketParams(uint256 lltv) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(0),
            collateralToken: collateralToken,
            oracle: address(oracle),
            irm: address(0),
            lltv: lltv
        });
    }

    function _params() internal view returns (IncreaseCheckParams memory) {
        return IncreaseCheckParams({
            marketId: marketId,
            params: _marketParams(0.8e18),
            leverage: 2e18,
            totalAmount: 100e6,
            price: 1e36,
            slippageBpsUsed: 50
        });
    }

    function _setConfig(Id id, MarketParams memory params) internal {
        vault.setMarketConfig(id, MorphoMarketConfig({params: params, maxLeverage: 0, maxSlippageBps: 0, enabled: true}));
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsVaultAndMorpho() public view {
        assertEq(breaker.VAULT(), address(vault));
        assertEq(address(breaker.MORPHO()), address(morpho));
    }

    /*//////////////////////////////////////////////////////////////
                                ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_onlyOwner_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(CircuitBreaker.NotVaultOwner.selector);
        breaker.setPaused(true);
    }

    function test_onlyOwner_acceptsDirectOwnerCall() public {
        vm.prank(owner);
        breaker.setPaused(true);
        assertTrue(breaker.paused());
    }

    function test_onlyOwner_acceptsVaultForwardedCall() public {
        // Mirrors MorphoLeverageVault.setBreakerPaused: msg.sender at the breaker is the
        // vault contract itself, not the EOA owner -- must be accepted too.
        vm.prank(address(vault));
        breaker.setPaused(true);
        assertTrue(breaker.paused());
    }

    function test_ownershipTransfer_carriesBreakerAdminWithNoBreakerSideStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(CircuitBreaker.NotVaultOwner.selector);
        breaker.setPaused(true);

        vm.prank(newOwner);
        breaker.setPaused(true);
        assertTrue(breaker.paused());
    }

    function test_onlyVault_revertsForNonVaultCaller() public {
        IncreaseCheckParams memory p = _params();

        vm.expectRevert(CircuitBreaker.NotVault.selector);
        breaker.checkBeforeIncrease(p);

        vm.expectRevert(CircuitBreaker.NotVault.selector);
        breaker.checkAfterIncrease(p);

        vm.expectRevert(CircuitBreaker.NotVault.selector);
        breaker.checkAfterDecrease(marketId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @dev No per-market setup at all: a market the breaker has never heard of is usable by
    ///      default, since MorphoMarketRegistry -- not this contract -- decides which
    ///      markets and leverage are allowed at all. Everything here is opt-in risk limits
    ///      layered on top of that, not a second gate to unlock first.
    function test_checkBeforeIncrease_succeedsWithNoConfiguration() public {
        vault.callCheckBeforeIncrease(_params());
    }

    function test_paused_blocksCheckBeforeIncrease() public {
        vm.prank(owner);
        breaker.setPaused(true);

        vm.expectRevert(CircuitBreaker.Paused.selector);
        vault.callCheckBeforeIncrease(_params());
    }

    function test_paused_doesNotBlockCheckAfterDecrease() public {
        vm.prank(owner);
        breaker.setPaused(true);

        // Must not revert -- decreases are never blockable by the breaker.
        vault.callCheckAfterDecrease(marketId, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE DEVIATION
    //////////////////////////////////////////////////////////////*/

    function test_priceDeviation_firstObservationAlwaysPasses() public {
        vm.prank(owner);
        breaker.setMaxPriceDeviationBps(marketId, 100); // 1%

        vault.callCheckBeforeIncrease(_params());
        assertEq(breaker.lastObservedPrice(marketId), 1e36);
    }

    function test_priceDeviation_atBoundaryPasses() public {
        vm.prank(owner);
        breaker.setMaxPriceDeviationBps(marketId, 100); // 1%

        vault.callCheckBeforeIncrease(_params()); // seeds lastObservedPrice = 1e36

        IncreaseCheckParams memory p = _params();
        p.price = 1e36 + (1e36 / 100); // exactly +1%, boundary passes
        vault.callCheckBeforeIncrease(p);
    }

    function test_priceDeviation_beyondBoundaryReverts() public {
        vm.prank(owner);
        breaker.setMaxPriceDeviationBps(marketId, 100); // 1%

        vault.callCheckBeforeIncrease(_params()); // seeds lastObservedPrice = 1e36

        // One wei over 1% relative to the seeded baseline above -- checked from a fresh
        // baseline, not chained after a passing call, since a passing checkBeforeIncrease
        // itself updates lastObservedPrice and would move the goalposts.
        IncreaseCheckParams memory p = _params();
        p.price = 1e36 + (1e36 / 100) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.PriceDeviationExceeded.selector, marketId, p.price, 1e36, 100)
        );
        vault.callCheckBeforeIncrease(p);
    }

    function test_priceDeviation_disabledWhenBpsZero() public {
        vault.callCheckBeforeIncrease(_params());

        IncreaseCheckParams memory p = _params();
        p.price = 1e36 * 100; // wildly different, but maxPriceDeviationBps defaults to 0
        vault.callCheckBeforeIncrease(p);
    }

    function test_setMaxPriceDeviationBps_revertsAboveLimit() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidPriceDeviationBps.selector, 10_001, 10_000));
        breaker.setMaxPriceDeviationBps(marketId, 10_001);
    }

    /*//////////////////////////////////////////////////////////////
                                RATE LIMIT
    //////////////////////////////////////////////////////////////*/

    function test_rateLimit_accumulatesWithinWindowAndReverts() public {
        vm.startPrank(owner);
        breaker.setRateLimitWindowSeconds(1 hours);
        breaker.setMaxExposureChangePerWindow(marketId, 150e6);
        vm.stopPrank();

        IncreaseCheckParams memory p = _params();
        p.totalAmount = 100e6;
        vault.callCheckBeforeIncrease(p); // window now at 100e6

        p.totalAmount = 50e6;
        vault.callCheckBeforeIncrease(p); // window now at 150e6, exactly the cap

        p.totalAmount = 1;
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.RateLimitExceeded.selector, marketId, 150e6 + 1, 150e6));
        vault.callCheckBeforeIncrease(p);
    }

    function test_rateLimit_windowResetsAfterWarp() public {
        vm.startPrank(owner);
        breaker.setRateLimitWindowSeconds(1 hours);
        breaker.setMaxExposureChangePerWindow(marketId, 100e6);
        vm.stopPrank();

        IncreaseCheckParams memory p = _params();
        p.totalAmount = 100e6;
        vault.callCheckBeforeIncrease(p);

        vm.warp(block.timestamp + 1 hours);
        vault.callCheckBeforeIncrease(p); // new window, must not revert
    }

    /// @dev Documents the known fixed-window tradeoff: acting right at a window's end and
    ///      again right after the next one starts can admit close to 2x the nominal cap.
    function test_rateLimit_boundaryBurstIsPossibleByDesign() public {
        vm.startPrank(owner);
        breaker.setRateLimitWindowSeconds(1 hours);
        breaker.setMaxExposureChangePerWindow(marketId, 100e6);
        vm.stopPrank();

        IncreaseCheckParams memory p = _params();
        p.totalAmount = 100e6;

        vault.callCheckBeforeIncrease(p); // fills window 1 fully, at t

        vm.warp(block.timestamp + 1 hours); // window 2 begins
        vault.callCheckBeforeIncrease(p); // fills window 2 fully too -- 200e6 in ~1 hour
    }

    function test_rateLimit_disabledWhenCapZero() public {
        IncreaseCheckParams memory p = _params();
        p.totalAmount = type(uint128).max;
        vault.callCheckBeforeIncrease(p); // maxExposureChangePerWindow defaults to 0 = off
    }

    /*//////////////////////////////////////////////////////////////
                              AFTER DECREASE
    //////////////////////////////////////////////////////////////*/

    function test_checkAfterDecrease_neverRevertsEvenForHugeValue() public {
        vault.callCheckAfterDecrease(marketId, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    function _seedPosition(Id id, uint128 borrowShares, uint128 collateral, uint128 totalBorrowAssets, uint128 totalBorrowShares)
        internal
    {
        morpho.setPosition(id, address(vault), 0, borrowShares, collateral);
        morpho.setMarket(id, 0, 0, totalBorrowAssets, totalBorrowShares);
    }

    function test_healthFactor_view_isMaxWhenNoDebt() public {
        _seedPosition(marketId, 0, 100e18, 0, 0);
        _setConfig(marketId, _marketParams(0.8e18));

        assertEq(breaker.healthFactor(marketId), type(uint256).max);
    }

    function test_healthFactor_view_matchesFormula() public {
        uint128 borrowShares = 100e6;
        uint128 totalBorrowAssets = 1_000_000e6;
        uint128 totalBorrowShares = 1_000_000e6;
        uint128 collateral = 150e18;
        uint256 lltv = 0.8e18;

        oracle.setPrice(1e24); // collateralValue lands in the same ~1e6 scale as debtValue
        _seedPosition(marketId, borrowShares, collateral, totalBorrowAssets, totalBorrowShares);
        _setConfig(marketId, _marketParams(lltv));

        uint256 debtValue = MorphoSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = MorphoSharesMath.mulDivDown(collateral, 1e24, MorphoSharesMath.ORACLE_PRICE_SCALE);
        uint256 expected = (collateralValue * lltv) / debtValue;

        assertEq(breaker.healthFactor(marketId), expected);
    }

    function test_checkAfterIncrease_healthFactor_passesAtFloor_revertsOneWeiAbove() public {
        uint128 borrowShares = 100e6;
        uint128 totalBorrowAssets = 1_000_000e6;
        uint128 totalBorrowShares = 1_000_000e6;
        uint128 collateral = 150e18;
        uint256 lltv = 0.8e18;

        oracle.setPrice(1e24);
        _seedPosition(marketId, borrowShares, collateral, totalBorrowAssets, totalBorrowShares);
        _setConfig(marketId, _marketParams(lltv));

        uint256 debtValue = MorphoSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = MorphoSharesMath.mulDivDown(collateral, 1e24, MorphoSharesMath.ORACLE_PRICE_SCALE);
        uint256 hf = (collateralValue * lltv) / debtValue;

        IncreaseCheckParams memory p = _params();
        p.params = _marketParams(lltv);

        vm.prank(owner);
        breaker.setMinHealthFactor(marketId, hf); // exactly at the floor, must pass
        vault.callCheckAfterIncrease(p);

        vm.prank(owner);
        breaker.setMinHealthFactor(marketId, hf + 1); // one wei above actual HF, must revert
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.HealthFactorTooLow.selector, marketId, hf, hf + 1));
        vault.callCheckAfterIncrease(p);
    }

    function test_checkAfterIncrease_healthFactor_skippedWhenFloorUnset() public {
        _seedPosition(marketId, 100e6, 1, 1_000_000e6, 1_000_000e6); // deeply underwater if checked
        _setConfig(marketId, _marketParams(0.8e18));

        IncreaseCheckParams memory p = _params();
        p.params = _marketParams(0.8e18);
        vault.callCheckAfterIncrease(p); // minHealthFactor defaults to 0 = unset, must not revert
    }

    /*//////////////////////////////////////////////////////////////
                    AGGREGATE DEBT + PER-ASSET EXPOSURE
    //////////////////////////////////////////////////////////////*/

    function test_checkAfterIncrease_aggregateDebt_sumsAcrossActiveMarketsAndReverts() public {
        Id marketA = Id.wrap(bytes32(uint256(10)));
        Id marketB = Id.wrap(bytes32(uint256(11)));

        _seedPosition(marketA, 50e6, 0, 1_000_000e6, 1_000_000e6);
        _seedPosition(marketB, 50e6, 0, 1_000_000e6, 1_000_000e6);
        _setConfig(marketA, _marketParams(0.8e18));
        _setConfig(marketB, _marketParams(0.8e18));

        Id[] memory active = new Id[](2);
        active[0] = marketA;
        active[1] = marketB;
        vault.setActiveMarkets(active);

        uint256 debtEach = MorphoSharesMath.toAssetsUp(50e6, 1_000_000e6, 1_000_000e6);
        uint256 totalDebt = debtEach * 2;

        IncreaseCheckParams memory p = _params();
        p.marketId = marketA;
        p.params = _marketParams(0.8e18);

        vm.prank(owner);
        breaker.setMaxAggregateDebt(totalDebt); // exactly at the cap, must pass
        vault.callCheckAfterIncrease(p);

        vm.prank(owner);
        breaker.setMaxAggregateDebt(totalDebt - 1); // one unit under, must revert
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.MaxAggregateDebtExceeded.selector, totalDebt, totalDebt - 1)
        );
        vault.callCheckAfterIncrease(p);
    }

    function test_checkAfterIncrease_assetExposure_groupsBySharedTokenExcludesOthers() public {
        Id sameTokenMarket = Id.wrap(bytes32(uint256(20)));
        Id otherTokenMarket = Id.wrap(bytes32(uint256(21)));
        address otherToken = address(0xC02);
        MockOracle otherOracle = new MockOracle();
        otherOracle.setPrice(1e36);

        _seedPosition(marketId, 0, 100e18, 0, 0);
        _seedPosition(sameTokenMarket, 0, 100e18, 0, 0);
        _seedPosition(otherTokenMarket, 0, 999e18, 0, 0);

        _setConfig(marketId, _marketParams(0.8e18));
        _setConfig(sameTokenMarket, _marketParams(0.8e18));
        vault.setMarketConfig(
            otherTokenMarket,
            MorphoMarketConfig({
                params: MarketParams({
                    loanToken: address(0),
                    collateralToken: otherToken,
                    oracle: address(otherOracle),
                    irm: address(0),
                    lltv: 0.8e18
                }),
                maxLeverage: 0,
                maxSlippageBps: 0,
                enabled: true
            })
        );

        Id[] memory active = new Id[](3);
        active[0] = marketId;
        active[1] = sameTokenMarket;
        active[2] = otherTokenMarket;
        vault.setActiveMarkets(active);

        // price = 1e36 => collateralValue == collateral 1:1
        uint256 exposure = 100e18 + 100e18; // only the two markets sharing collateralToken

        IncreaseCheckParams memory p = _params();

        vm.prank(owner);
        breaker.setMaxAssetExposure(collateralToken, exposure); // exactly at the cap, passes
        vault.callCheckAfterIncrease(p);

        vm.prank(owner);
        breaker.setMaxAssetExposure(collateralToken, exposure - 1);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.MaxAssetExposureExceeded.selector, collateralToken, exposure, exposure - 1)
        );
        vault.callCheckAfterIncrease(p);
    }

    function test_checkAfterIncrease_brokenOracleOnUnrelatedMarketDegradesToZero() public {
        Id healthyMarket = Id.wrap(bytes32(uint256(30)));
        Id brokenOracleMarket = Id.wrap(bytes32(uint256(31)));
        MockOracle brokenOracle = new MockOracle();
        brokenOracle.setBroken();

        _seedPosition(healthyMarket, 0, 100e18, 0, 0);
        _seedPosition(brokenOracleMarket, 0, 100e18, 0, 0);

        _setConfig(healthyMarket, _marketParams(0.8e18));
        vault.setMarketConfig(
            brokenOracleMarket,
            MorphoMarketConfig({
                params: MarketParams({
                    loanToken: address(0),
                    collateralToken: collateralToken,
                    oracle: address(brokenOracle),
                    irm: address(0),
                    lltv: 0.8e18
                }),
                maxLeverage: 0,
                maxSlippageBps: 0,
                enabled: true
            })
        );

        Id[] memory active = new Id[](2);
        active[0] = healthyMarket;
        active[1] = brokenOracleMarket;
        vault.setActiveMarkets(active);

        IncreaseCheckParams memory p = _params();
        p.marketId = healthyMarket;

        vm.prank(owner);
        breaker.setMaxAssetExposure(collateralToken, 100e18); // only the healthy market's 100e18 should count

        vault.callCheckAfterIncrease(p); // must not revert: broken oracle degrades to zero
    }

    /*//////////////////////////////////////////////////////////////
                              SLIPPAGE CEILING
    //////////////////////////////////////////////////////////////*/

    function test_checkAfterIncrease_slippageCeiling_passAndFail() public {
        _setConfig(marketId, _marketParams(0.8e18));

        IncreaseCheckParams memory p = _params();
        p.slippageBpsUsed = 100;

        vm.prank(owner);
        breaker.setMaxSlippageBpsCeiling(100);
        vault.callCheckAfterIncrease(p); // exactly at the ceiling, passes

        vm.prank(owner);
        breaker.setMaxSlippageBpsCeiling(99);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.SlippageCeilingExceeded.selector, 100, 99));
        vault.callCheckAfterIncrease(p);
    }

    function test_setMaxSlippageBpsCeiling_revertsAboveLimit() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidSlippageBpsCeiling.selector, 1_001, 1_000));
        breaker.setMaxSlippageBpsCeiling(1_001);
    }

    /*//////////////////////////////////////////////////////////////
                                PREVIEW
    //////////////////////////////////////////////////////////////*/

    function test_previewBeforeIncrease_matchesRealCheck() public {
        vm.prank(owner);
        breaker.setPaused(true);

        (bool okPaused, bytes4 selPaused) = breaker.previewBeforeIncrease(_params());
        assertFalse(okPaused);
        assertEq(selPaused, CircuitBreaker.Paused.selector);

        vm.prank(owner);
        breaker.setPaused(false);

        (bool okAfter, bytes4 selAfter) = breaker.previewBeforeIncrease(_params());
        assertTrue(okAfter);
        assertEq(selAfter, bytes4(0));

        // Real check must agree once the preview says it will pass.
        vault.callCheckBeforeIncrease(_params());
    }

    function test_previewBeforeIncrease_neverMutatesState() public {
        vm.prank(owner);
        breaker.setMaxPriceDeviationBps(marketId, 100);

        breaker.previewBeforeIncrease(_params());
        breaker.previewBeforeIncrease(_params());

        assertEq(breaker.lastObservedPrice(marketId), 0);
        assertEq(breaker.windowExposureChange(marketId), 0);
    }
}
