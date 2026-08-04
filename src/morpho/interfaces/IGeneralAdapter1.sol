// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketParams} from "./IMorpho.sol";

/// @notice Minimal interface to Morpho's real, official GeneralAdapter1 (used from within
///         a Bundler3 bundle). These are wrapper calls around Morpho Blue's own functions
///         that add native share-price slippage bounds (E27-scaled) on top.
/// @dev Verified 2026-08-03 against the deployed contract's own ABI on Arbitrum
///      (0x9954aFB60BB5A222714c478ac86990F221788B88). Only the functions this project uses.
interface IGeneralAdapter1 {
    /// @notice Sends `amount` of `token` from this adapter's OWN balance to `receiver`.
    function erc20Transfer(address token, address receiver, uint256 amount) external;

    /// @dev No `from` parameter — pulls from Bundler3.initiator() via a pre-existing
    ///      ERC20 allowance the initiator granted GeneralAdapter1 beforehand.
    function erc20TransferFrom(address token, address receiver, uint256 amount) external;

    /// @notice Triggers Morpho's native flashLoan, then Morpho calls back into this
    ///         adapter's onMorphoFlashLoan, which re-enters Bundler3 with `data`'s bundle.
    function morphoFlashLoan(address token, uint256 assets, bytes calldata data) external;

    function morphoSupplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;

    /// @dev No onBehalf — resolved internally against Bundler3.initiator(). The initiator
    ///      must have called MORPHO.setAuthorization(GeneralAdapter1, true) beforehand.
    function morphoBorrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address receiver
    ) external;

    function morphoRepay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxSharePriceE27,
        address onBehalf,
        bytes calldata data
    ) external;

    /// @dev No onBehalf — same initiator-resolution note as morphoBorrow.
    function morphoWithdrawCollateral(MarketParams calldata marketParams, uint256 assets, address receiver)
        external;
}
