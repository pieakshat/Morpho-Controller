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

    constructor(
        IMorpho morpho_,
        IBundler3 bundler3_,
        IGeneralAdapter1 generalAdapter_,
        MorphoSwapExecutor swapExecutor_
    ) {
        MORPHO = morpho_;
        BUNDLER3 = bundler3_;
        GENERAL_ADAPTER = generalAdapter_;
        SWAP_EXECUTOR = swapExecutor_;
    }
}
