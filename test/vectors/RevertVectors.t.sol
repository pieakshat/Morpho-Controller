// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {IMorpho} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {MarketAction} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";
import {RiskLimits} from "../../src/morpho/libraries/RiskLimits.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Only exists to produce genuine Panic revert data through an external call boundary.
contract PanicSource {
    function overflow() external pure returns (uint256) {
        return MorphoSharesMath.mulDivDown(1 << 200, 1 << 200, 1);
    }

    function divByZero() external pure returns (uint256) {
        return MorphoSharesMath.mulDivDown(1, 1, 0);
    }
}

/// @notice Captures REAL revert data from the contracts and dumps it for the off-chain
///         decoder in allocator/packages/planner to parse.
///
/// @dev The point is that these bytes are ABI-encoded by solc from the actual error
///      definitions, not hand-assembled in a test. A decoder checked only against
///      hand-written fixtures proves the fixtures match the decoder, which is circular; this
///      proves it matches the contracts.
///
///      Offline, so the TypeScript suite needs no RPC. Regenerate with:
///        forge test --match-path 'test/vectors/RevertVectors.t.sol'
///
///      Each line is `label,0x<revert data>`.
contract RevertVectorsTest is Test {
    MorphoLeverageVault vault;
    RiskLimits limits;
    MockERC20 asset;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    string[] private lines;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        vault = new MorphoLeverageVault(
            asset, owner, IMorpho(address(0x1111)), IBundler3(address(0x2222)), IGeneralAdapter1(address(0x3333))
        );
        limits = RiskLimits(vault.riskLimits());
    }

    /// @dev Captures returndata from a call that must fail. Reverting here rather than
    ///      recording a success keeps a silently-passing call from producing an empty vector.
    function _capture(string memory label, address target, bytes memory callData) internal {
        (bool ok, bytes memory data) = target.call(callData);
        require(!ok, string.concat("expected a revert for ", label));
        lines.push(string.concat(label, ",", vm.toString(data)));
    }

    function _params() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(asset),
            collateralToken: address(0xC01),
            oracle: address(0x0AC1E),
            irm: address(0x1417),
            lltv: 0.86e18
        });
    }

    function _action(Id id, uint256 leverage) internal pure returns (MarketAction[] memory actions) {
        actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: id,
            isIncrease: true,
            amount: 1e6,
            leverage: leverage,
            minOut: 0,
            swapTarget: address(0),
            swapCalldata: ""
        });
    }

    function test_writeRevertVectors() public {
        MarketParams memory p = _params();
        Id id = Id.wrap(keccak256(abi.encode(p)));

        // --- vault access control and admin ---
        vm.prank(stranger);
        _capture("NotAllocator", address(vault), abi.encodeCall(vault.executeActions, (_action(id, 2e18))));

        vm.prank(owner);
        _capture("InvalidDropToleranceBps", address(vault), abi.encodeCall(vault.setActionDropToleranceBps, (1001)));

        vm.prank(stranger);
        _capture("OwnableUnauthorizedAccount", address(vault), abi.encodeCall(vault.setAllocator, (stranger, true)));

        // --- engine guards, all of which fire before any Morpho call ---
        vm.prank(owner);
        _capture("MarketNotEnabled", address(vault), abi.encodeCall(vault.executeActions, (_action(id, 2e18))));

        vm.prank(owner);
        vault.registerMarket(p, 5e18, 50);

        vm.prank(owner);
        _capture("LeverageBelowOneX", address(vault), abi.encodeCall(vault.executeActions, (_action(id, 5e17))));

        vm.prank(owner);
        _capture("LeverageExceedsMax", address(vault), abi.encodeCall(vault.executeActions, (_action(id, 9e18))));

        // --- registry ---
        vm.prank(owner);
        _capture("MarketAlreadyRegistered", address(vault), abi.encodeCall(vault.registerMarket, (p, 5e18, 50)));

        vm.prank(owner);
        _capture("InvalidSlippageBps", address(vault), abi.encodeCall(vault.setMaxSlippageBps, (id, 1001)));

        MarketParams memory wrongLoan = p;
        wrongLoan.loanToken = address(0xBAD);
        vm.prank(owner);
        _capture("LoanTokenMismatch", address(vault), abi.encodeCall(vault.registerMarket, (wrongLoan, 5e18, 50)));

        // --- RiskLimits ---
        vm.prank(stranger);
        _capture("NotVaultOwner", address(limits), abi.encodeCall(limits.setPaused, (true)));

        _capture("NotVault", address(limits), abi.encodeCall(limits.checkAfterDecrease, (id, 1, 1e36)));

        vm.prank(owner);
        _capture(
            "RateLimitWindowNotSet", address(limits), abi.encodeCall(limits.setMaxExposureChangePerWindow, (id, 100e6))
        );

        vm.prank(owner);
        _capture(
            "InvalidPriceDeviationBps", address(limits), abi.encodeCall(limits.setMaxPriceDeviationBps, (id, 10_001))
        );

        vm.prank(owner);
        _capture("InvalidSlippageBpsCeiling", address(limits), abi.encodeCall(limits.setMaxSlippageBpsCeiling, (1001)));

        // --- solc-generated panics, which carry no name at all ---
        PanicSource panics = new PanicSource();
        _capture("Panic_0x11", address(panics), abi.encodeCall(panics.overflow, ()));
        _capture("Panic_0x12", address(panics), abi.encodeCall(panics.divByZero, ()));

        string memory obj = "reverts";
        string memory out = vm.serializeString(obj, "cases", lines);
        vm.writeJson(out, "./allocator/packages/planner/test/vectors/reverts.json");
    }
}
