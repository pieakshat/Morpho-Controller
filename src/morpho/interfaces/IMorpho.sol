// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Morpho Blue market identifier. Computed as keccak256(abi.encode(MarketParams)).
/// @dev Value type, not redefinable — this must match the real deployed Morpho Blue exactly.
type Id is bytes32;

/// @notice One isolated Morpho Blue market.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Minimal interface to the real, immutable Morpho Blue contract.
/// @dev Verified 2026-08-03 against the deployed contract's own ABI on Arbitrum
///      (0x6c247b1F6182318877311737BaC0844bAa518F5e).
///      Only the functions this project actually calls — Morpho Blue's real surface is larger.
interface IMorpho {
    /// @notice Grants or revokes `authorized` the right to act on this caller's behalf (onBehalf).
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Native flashloan. Morpho calls back into `msg.sender`'s onMorphoFlashLoan(assets, data)
    ///         and expects `assets` of `token` to be returned by the end of that callback.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    function accrueInterest(MarketParams memory marketParams) external;

    /// @dev Auto-generated Solidity mapping getter — returns the Position struct's fields as a
    ///      raw tuple, NOT a struct. Matching this exactly is required for correct decoding.
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    /// @dev Same tuple-unpacking note as position() above.
    function market(Id id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    function idToMarketParams(Id id) external view returns (MarketParams memory);
}
