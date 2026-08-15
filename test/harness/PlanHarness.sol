// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id} from "../../src/morpho/interfaces/IMorpho.sol";
import {IMorpho} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";

/// @notice TEST ONLY. Exposes the engine's decrease planners so their output can be dumped
///         as golden vectors for the off-chain planner in allocator/packages/planner.
///
/// @dev Never deploy this. It adds two unauthenticated external functions that any caller
///      can use to accrue interest on a market, which is harmless but pointless in
///      production, and it exists solely because the numbers these functions compute have to
///      be reproduced exactly off-chain to build valid calldata.
///
///      Both functions are state-changing, not view: the planners call
///      `MORPHO.accrueInterest` before reading, which is precisely the behaviour the mirror
///      has to account for. Calling one of these twice in the same block returns the same
///      plan, since the second call finds interest already accrued.
contract PlanHarness is MorphoLeverageVault {
    constructor(IERC20 asset_, address owner_, IMorpho morpho_, IBundler3 bundler3_, IGeneralAdapter1 generalAdapter_)
        MorphoLeverageVault(asset_, owner_, morpho_, bundler3_, generalAdapter_)
    {}

    /// @notice `_planDecrease` verbatim. Handles both the proportional branch and the
    ///         full-close branch, selected by `requestedAmount >= collateralRaw`.
    function planDecrease(Id id, uint256 requestedAmount) external returns (DecreasePlan memory) {
        return _planDecrease(id, requestedAmount);
    }

    /// @notice `_planDeleverage` verbatim.
    function planDeleverage(Id id, uint256 targetLeverage) external returns (DecreasePlan memory) {
        return _planDeleverage(id, targetLeverage);
    }
}
