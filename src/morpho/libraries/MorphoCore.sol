// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMorpho} from "../interfaces/IMorpho.sol";
import {IBundler3} from "../interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../interfaces/IGeneralAdapter1.sol";
import {MorphoSwapExecutor} from "./MorphoSwapExecutor.sol";

/// @notice Shared base holding every real external reference this system talks to.
abstract contract MorphoCore {
    IMorpho internal immutable MORPHO;
    IBundler3 internal immutable BUNDLER3;
    IGeneralAdapter1 internal immutable GENERAL_ADAPTER;
    MorphoSwapExecutor internal immutable SWAP_EXECUTOR;

    /// @dev The swap executor is deployed here rather than passed in, which makes it
    ///      structurally impossible for two vaults to share one. The executor reads its
    ///      authorized vault from its deployer, so constructing it here is also what
    ///      binds its access control to this vault.
    constructor(IMorpho morpho_, IBundler3 bundler3_, IGeneralAdapter1 generalAdapter_) {
        MORPHO = morpho_;
        BUNDLER3 = bundler3_;
        GENERAL_ADAPTER = generalAdapter_;
        SWAP_EXECUTOR = new MorphoSwapExecutor(bundler3_);
    }

    /// @notice The dedicated swap executor this vault routes every swap leg through.
    function swapExecutor() external view returns (address) {
        return address(SWAP_EXECUTOR);
    }
}
