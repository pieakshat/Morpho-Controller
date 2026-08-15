// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";

/// @notice Settable IMorpho stand-in for unit-testing RiskLimits's on-chain-state reads
///         (position/market) without a fork. Every other IMorpho function is left reverting
///         on purpose — RiskLimits never calls them, so a test that reaches one of them
///         is exercising something this mock was never meant to support.
contract MockMorpho is IMorpho {
    struct MockPosition {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct MockMarket {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
    }

    mapping(Id => mapping(address => MockPosition)) internal _positions;
    mapping(Id => MockMarket) internal _markets;

    function setPosition(Id id, address user, uint256 supplyShares, uint128 borrowShares, uint128 collateral) external {
        _positions[id][user] = MockPosition(supplyShares, borrowShares, collateral);
    }

    function setMarket(
        Id id,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares
    ) external {
        _markets[id] = MockMarket(totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares);
    }

    function position(Id id, address user) external view returns (uint256, uint128, uint128) {
        MockPosition memory p = _positions[id][user];
        return (p.supplyShares, p.borrowShares, p.collateral);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        MockMarket memory m = _markets[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, 0, 0);
    }

    function setAuthorization(address, bool) external pure {
        revert("MockMorpho: unused");
    }

    function supply(MarketParams memory, uint256, uint256, address, bytes memory)
        external
        pure
        returns (uint256, uint256)
    {
        revert("MockMorpho: unused");
    }

    function withdraw(MarketParams memory, uint256, uint256, address, address)
        external
        pure
        returns (uint256, uint256)
    {
        revert("MockMorpho: unused");
    }

    function supplyCollateral(MarketParams memory, uint256, address, bytes memory) external pure {
        revert("MockMorpho: unused");
    }

    function withdrawCollateral(MarketParams memory, uint256, address, address) external pure {
        revert("MockMorpho: unused");
    }

    function borrow(MarketParams memory, uint256, uint256, address, address) external pure returns (uint256, uint256) {
        revert("MockMorpho: unused");
    }

    function repay(MarketParams memory, uint256, uint256, address, bytes memory)
        external
        pure
        returns (uint256, uint256)
    {
        revert("MockMorpho: unused");
    }

    function flashLoan(address, uint256, bytes calldata) external pure {
        revert("MockMorpho: unused");
    }

    function accrueInterest(MarketParams memory) external pure {
        revert("MockMorpho: unused");
    }

    function idToMarketParams(Id) external pure returns (MarketParams memory) {
        revert("MockMorpho: unused");
    }
}
