// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";

/// @dev Library calls are inlined, so `vm.expectRevert` has no external call to attach to.
///      This exposes the primitives externally purely so the overflow assertions below have
///      a real call boundary to target.
contract MathHarness {
    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return MorphoSharesMath.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return MorphoSharesMath.mulDivUp(x, y, d);
    }

    function toAssetsUp(uint256 s, uint256 ta, uint256 ts) external pure returns (uint256) {
        return MorphoSharesMath.toAssetsUp(s, ta, ts);
    }
}

/// @notice Dumps MorphoSharesMath's own output to JSON for the TypeScript mirror in
///         allocator/packages/core to assert against.
///
/// @dev Not a test of the contract; it is the source of truth the off-chain mirror is
///      checked against. The mirror has to reproduce these rounding directions exactly,
///      because computing a repay from an independently-rounded value estimate is what
///      caused the repay-overshoot underflow inside Morpho twice during the build.
///
///      Offline on purpose. Vectors are committed, so the TypeScript suite needs no network
///      and no RPC key. Regenerate with:
///        forge test --match-path 'test/vectors/MathVectors.t.sol'
///
///      Each line is `op,arg0,arg1,arg2,expected`, parsed by test/shares-math.test.ts. A flat
///      CSV rather than nested JSON because Foundry's serializer builds arrays of objects
///      awkwardly, and the shape here is uniform anyway.
contract MathVectorsTest is Test {
    string[] private lines;

    function _push(string memory op, uint256 a, uint256 b, uint256 c, uint256 expected) private {
        lines.push(
            string.concat(op, ",", vm.toString(a), ",", vm.toString(b), ",", vm.toString(c), ",", vm.toString(expected))
        );
    }

    function _allConversions(uint256 x, uint256 totalAssets, uint256 totalShares) private {
        _push("toAssetsDown", x, totalAssets, totalShares, MorphoSharesMath.toAssetsDown(x, totalAssets, totalShares));
        _push("toAssetsUp", x, totalAssets, totalShares, MorphoSharesMath.toAssetsUp(x, totalAssets, totalShares));
        _push("toSharesDown", x, totalAssets, totalShares, MorphoSharesMath.toSharesDown(x, totalAssets, totalShares));
        _push("toSharesUp", x, totalAssets, totalShares, MorphoSharesMath.toSharesUp(x, totalAssets, totalShares));
    }

    function test_writeMathVectors() public {
        // Empty market: only the virtual offset is in play. This is the case the virtual
        // shares exist for, and the easiest one to get wrong by dropping a +1.
        _allConversions(0, 0, 0);
        _allConversions(1, 0, 0);
        _allConversions(1e6, 0, 0);
        _allConversions(1e18, 0, 0);

        // Boundaries where up and down must actually diverge. If the mirror rounds the wrong
        // way these are the lines that catch it; anything evenly divisible would not.
        _allConversions(1, 1, 1);
        _allConversions(3, 7, 11);
        _allConversions(999_999, 1_000_001, 999_983);
        _allConversions(1, 2, 3);
        _allConversions(7, 3, 5);

        // Real market state, read off the pinned Arbitrum fork block (wstETH/USDC 86%):
        // ~2,201,565 USDC borrowed against ~2,998,289 supplied.
        uint256 tba = 2_201_565_000000;
        uint256 tbs = 2_150_000_000000 * 1e6;
        _allConversions(0, tba, tbs);
        _allConversions(1, tba, tbs);
        _allConversions(96_180_242_592_309_781, tba, tbs); // borrowShares from the anvil loop
        _allConversions(100_000_000000, tba, tbs);
        _allConversions(796_724_000000, tba, tbs); // the market's real available liquidity

        // Large but still valid, to pin behaviour well away from the everyday range without
        // crossing into the uint256 overflow the contract would revert on.
        _allConversions(1e30, 1e30, 1e30);
        _allConversions(type(uint128).max, 1e24, 1e30);

        // The primitives directly, including the exact +1 boundary for rounding up.
        _push("mulDivDown", 10, 3, 4, MorphoSharesMath.mulDivDown(10, 3, 4));
        _push("mulDivUp", 10, 3, 4, MorphoSharesMath.mulDivUp(10, 3, 4));
        _push("mulDivDown", 12, 3, 4, MorphoSharesMath.mulDivDown(12, 3, 4));
        _push("mulDivUp", 12, 3, 4, MorphoSharesMath.mulDivUp(12, 3, 4)); // exact: up == down
        _push("mulDivDown", 1, 1, 1e18, MorphoSharesMath.mulDivDown(1, 1, 1e18));
        _push("mulDivUp", 1, 1, 1e18, MorphoSharesMath.mulDivUp(1, 1, 1e18));

        // Oracle pricing, the shape MorphoPositionValuation uses. Price is the live wstETH
        // oracle reading at the pinned block.
        uint256 price = 2_322_919_887_065_307_219_008_086_849;
        _push(
            "mulDivDown",
            86_098_535_344_958_775_195,
            price,
            MorphoSharesMath.ORACLE_PRICE_SCALE,
            MorphoSharesMath.mulDivDown(86_098_535_344_958_775_195, price, MorphoSharesMath.ORACLE_PRICE_SCALE)
        );
        _push(
            "mulDivDown",
            1e18,
            price,
            MorphoSharesMath.ORACLE_PRICE_SCALE,
            MorphoSharesMath.mulDivDown(1e18, price, MorphoSharesMath.ORACLE_PRICE_SCALE)
        );
        // Inverse direction, as an increase's minOut floor computes it.
        _push(
            "mulDivDown",
            200_000_000000,
            MorphoSharesMath.ORACLE_PRICE_SCALE,
            price,
            MorphoSharesMath.mulDivDown(200_000_000000, MorphoSharesMath.ORACLE_PRICE_SCALE, price)
        );

        string memory obj = "vectors";
        vm.serializeUint(obj, "VIRTUAL_SHARES", MorphoSharesMath.VIRTUAL_SHARES);
        vm.serializeUint(obj, "VIRTUAL_ASSETS", MorphoSharesMath.VIRTUAL_ASSETS);
        vm.serializeUint(obj, "ORACLE_PRICE_SCALE", MorphoSharesMath.ORACLE_PRICE_SCALE);
        string memory out = vm.serializeString(obj, "cases", lines);

        vm.writeJson(out, "./allocator/packages/core/test/vectors/shares-math.json");
    }

    /// @dev Pins the exact inputs the TypeScript mirror claims to reject, so the parity
    ///      claim in allocator/packages/core/test/overflow.test.ts is verified on both sides
    ///      rather than asserted on one. bigint has no overflow, so without these the mirror
    ///      would happily return values no chain could produce.
    function test_overflowBoundsMatchTheMirror() public {
        MathHarness h = new MathHarness();
        uint256 big = 1 << 200; // squared, this is 2**400

        vm.expectRevert(stdError.arithmeticError);
        h.mulDivDown(big, big, 1);

        vm.expectRevert(stdError.arithmeticError);
        h.mulDivUp(big, big, 1);

        // mulDivUp's second overflow point: the product alone fits, but adding (d - 1) does
        // not. A mirror guarding only the product would wrongly succeed here.
        assertEq(h.mulDivDown(type(uint256).max, 1, 2), type(uint256).max / 2);
        vm.expectRevert(stdError.arithmeticError);
        h.mulDivUp(type(uint256).max, 1, 2);

        vm.expectRevert(stdError.divisionError);
        h.mulDivDown(1, 1, 0);

        // The virtual-offset addition is itself a checked add.
        vm.expectRevert(stdError.arithmeticError);
        h.toAssetsUp(1, 0, type(uint256).max);
    }

    /// @dev The invariant whose violation caused the repay-overshoot bug: converting shares
    ///      up to assets and back down must never yield more shares than you started with,
    ///      or Morpho's `borrowShares -= shares` underflows. Fuzzed here so the vectors above
    ///      are not the only thing standing behind the mirror.
    function testFuzz_roundTripNeverGainsShares(uint256 shares, uint256 totalAssets, uint256 totalShares) public pure {
        shares = bound(shares, 0, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);

        uint256 assets = MorphoSharesMath.toAssetsUp(shares, totalAssets, totalShares);
        assertGe(MorphoSharesMath.toSharesDown(assets, totalAssets, totalShares), shares);
    }
}
