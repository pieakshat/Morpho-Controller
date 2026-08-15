// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMorpho} from "../interfaces/IMorpho.sol";
import {IBundler3} from "../interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../interfaces/IGeneralAdapter1.sol";
import {MorphoSwapExecutor} from "./MorphoSwapExecutor.sol";
import {RiskLimits} from "./RiskLimits.sol";

/// @notice Shared base holding every real external reference this system talks to.
abstract contract MorphoCore {
    IMorpho internal immutable MORPHO;
    IBundler3 internal immutable BUNDLER3;
    IGeneralAdapter1 internal immutable GENERAL_ADAPTER;
    MorphoSwapExecutor internal immutable SWAP_EXECUTOR;
    RiskLimits internal immutable RISK_LIMITS;

    /// @dev The swap executor and risk-limit gate are both deployed here rather than passed
    ///      in, which makes it structurally impossible for two vaults to share either one.
    ///      Each reads its authorized vault from its own deployer, so constructing them here
    ///      is also what binds their access control to this vault.
    constructor(IMorpho morpho_, IBundler3 bundler3_, IGeneralAdapter1 generalAdapter_) {
        MORPHO = morpho_;
        BUNDLER3 = bundler3_;
        GENERAL_ADAPTER = generalAdapter_;
        SWAP_EXECUTOR = new MorphoSwapExecutor(bundler3_);
        RISK_LIMITS = new RiskLimits(morpho_);
    }

    /// @notice The dedicated swap executor this vault routes every swap leg through.
    function swapExecutor() external view returns (address) {
        return address(SWAP_EXECUTOR);
    }

    /// @notice The risk-limit gate every allocator action is checked against.
    function riskLimits() external view returns (address) {
        return address(RISK_LIMITS);
    }
}
