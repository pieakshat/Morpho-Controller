// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Id} from "../../src/morpho/interfaces/IMorpho.sol";
import {MarketAction} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";

/// @notice Emits `executeActions` calldata that solc itself produced, for the off-chain
///         encoder in allocator/packages/planner to match byte for byte.
///
/// @dev Decoding TypeScript's own output through the ABI only proves it is self-consistent.
///      A wrong field order or a mis-typed member would encode and decode happily on the
///      TypeScript side and still be rejected on-chain. Comparing against solc's bytes is
///      what actually rules that out.
///
///      Offline. Regenerate with:
///        forge test --match-path 'test/vectors/CalldataVectors.t.sol'
///
///      Each line is:
///        label,<marketId>,<isIncrease 1|0>,<amount>,<leverage>,<minOut>,<swapTarget>,
///        <swapCalldata>,<full executeActions calldata>
contract CalldataVectorsTest is Test {
    string[] private lines;

    Id constant MARKET_A = Id.wrap(0x33e0c8ab132390822b07e5dc95033cf250c963153320b7ffca73220664da2ea0);
    Id constant MARKET_B = Id.wrap(0xca83d02be579485cc10945c9597a6141e772f1cf0e0aa28d09a327b6cbd8642c);
    address constant VENUE = 0x1111111254EEB25477B68fb85Ed929f73A960582;

    function _one(string memory label, MarketAction memory a) internal {
        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = a;
        _record(label, actions);
    }

    function _record(string memory label, MarketAction[] memory actions) internal {
        bytes memory calldata_ = abi.encodeCall(MorphoLeverageVault.executeActions, (actions));

        string memory head = label;
        for (uint256 i = 0; i < actions.length; ++i) {
            head = string.concat(
                head,
                ",",
                vm.toString(Id.unwrap(actions[i].marketId)),
                ",",
                actions[i].isIncrease ? "1" : "0",
                ",",
                vm.toString(actions[i].amount),
                ",",
                vm.toString(actions[i].leverage),
                ",",
                vm.toString(actions[i].minOut),
                ",",
                vm.toString(actions[i].swapTarget),
                ",",
                vm.toString(actions[i].swapCalldata)
            );
        }
        lines.push(string.concat(head, ",", vm.toString(calldata_)));
    }

    function test_writeCalldataVectors() public {
        // A plain increase: own contribution in `amount`, real leverage.
        _one(
            "increase",
            MarketAction({
                marketId: MARKET_A,
                isIncrease: true,
                amount: 50_000_000000,
                leverage: 2e18,
                minOut: 42_834_021_334_116_990_659,
                swapTarget: VENUE,
                swapCalldata: hex"deadbeef"
            })
        );

        // 1x: no borrow leg at all, but still a real increase.
        _one(
            "increase_1x",
            MarketAction({
                marketId: MARKET_A,
                isIncrease: true,
                amount: 25_000_000000,
                leverage: 1e18,
                minOut: 10_708_505_333_529_247_664,
                swapTarget: VENUE,
                swapCalldata: hex"c0ffee"
            })
        );

        // Proportional decrease: collateral in `amount`, leverage zero.
        _one(
            "decrease_proportional",
            MarketAction({
                marketId: MARKET_A,
                isIncrease: false,
                amount: 14_349_755_890_826_462_532,
                leverage: 0,
                minOut: 16_583_333_333,
                swapTarget: VENUE,
                swapCalldata: hex"01"
            })
        );

        // Full close via the sentinel. The max-uint round-trip is worth pinning on its own:
        // it is the value most likely to be mangled by a language boundary.
        _one(
            "close_fully",
            MarketAction({
                marketId: MARKET_A,
                isIncrease: false,
                amount: type(uint256).max,
                leverage: 0,
                minOut: 49_750_000_000,
                swapTarget: VENUE,
                swapCalldata: hex""
            })
        );

        // Deleverage: `amount` ignored and set to zero, target ratio in `leverage`.
        _one(
            "deleverage",
            MarketAction({
                marketId: MARKET_A,
                isIncrease: false,
                amount: 0,
                leverage: 1.5e18,
                minOut: 50_053_721_983,
                swapTarget: VENUE,
                swapCalldata: hex"ffffffffffffffffffffffffffffffffffffffff"
            })
        );

        // A two-market batch, where a decrease funds an increase in the same call. Also
        // exercises dynamic-offset encoding for the second element's bytes member.
        MarketAction[] memory batch = new MarketAction[](2);
        batch[0] = MarketAction({
            marketId: MARKET_A,
            isIncrease: false,
            amount: 21_524_633_836_239_693_798,
            leverage: 0,
            minOut: 24_875_000_000,
            swapTarget: VENUE,
            swapCalldata: hex"aabbcc"
        });
        batch[1] = MarketAction({
            marketId: MARKET_B,
            isIncrease: true,
            amount: 20_000_000000,
            leverage: 3e18,
            minOut: 19_900_000_000_000_000_000,
            swapTarget: VENUE,
            swapCalldata: hex"ddeeff0011"
        });
        _record("batch", batch);

        string memory obj = "calldata";
        string memory out = vm.serializeString(obj, "cases", lines);
        vm.writeJson(out, "./allocator/packages/planner/test/vectors/calldata.json");
    }
}
