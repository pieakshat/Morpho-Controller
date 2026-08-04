// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMorpho} from "../interfaces/IMorpho.sol";
import {IBundler3} from "../interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../interfaces/IGeneralAdapter1.sol";
import {MorphoSwapExecutor} from "./MorphoSwapExecutor.sol";

/// @notice Shared base holding every real external reference this system talks to.
/// @dev Declared exactly once here so every other piece (valuation, the leverage/
///      bundle-builder logic) inherits these immutables instead of each redeclaring its
///      own — Solidity would reject two base contracts declaring an immutable of the same
///      name in one inheritance graph.
///      SWAP_EXECUTOR is dedicated to this adapter instance, not a shared singleton — a
///      shared executor would need to reason about balance cross-contamination if two
///      unrelated bundles ever touched it; dedicated avoids that class of bug entirely.
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
