// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MorphoSharesMath} from "../../src/morpho/libraries/MorphoSharesMath.sol";

/// @notice Pure math tests for MorphoSharesMath — no fork, no mocks. Expected values below
///         are worked by hand against the library's own documented formula:
///           toAssetsX = shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
///           toSharesX = assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
///         rounding down (floor) or up (ceil) depending on which side is being protected.
contract MorphoSharesMathTest is Test {
    uint256 constant VIRTUAL_SHARES = 1e6;
    uint256 constant VIRTUAL_ASSETS = 1;

    /*//////////////////////////////////////////////////////////////
                    HAND-COMPUTED VALUES (see file header)
    //////////////////////////////////////////////////////////////*/

    function test_toAssetsDown_matchesHandComputedValue() public pure {
        // shares=2,500,000 totalAssets=10,000,000 totalShares=5,000,000
        // = floor(2,500,000 * 10,000,001 / 6,000,000) = floor(4,166,667.0833..) = 4,166,667
        uint256 result = MorphoSharesMath.toAssetsDown(2_500_000, 10_000_000, 5_000_000);
        assertEq(result, 4_166_667);
    }

    function test_toAssetsUp_matchesHandComputedValue() public pure {
        // Same inputs as above, division is inexact so ceil is exactly one more than floor.
        uint256 result = MorphoSharesMath.toAssetsUp(2_500_000, 10_000_000, 5_000_000);
        assertEq(result, 4_166_668);
    }

    function test_toSharesDown_matchesHandComputedValue() public pure {
        // assets=2,500,000 totalAssets=10,000,000 totalShares=5,000,000
        // = floor(2,500,000 * 6,000,000 / 10,000,001) = floor(1,499,999.85..) = 1,499,999
        uint256 result = MorphoSharesMath.toSharesDown(2_500_000, 10_000_000, 5_000_000);
        assertEq(result, 1_499_999);
    }

    function test_toSharesUp_matchesHandComputedValue() public pure {
        uint256 result = MorphoSharesMath.toSharesUp(2_500_000, 10_000_000, 5_000_000);
        assertEq(result, 1_500_000);
    }

    /*//////////////////////////////////////////////////////////////
                            ROUNDING DIRECTION
    //////////////////////////////////////////////////////////////*/

    function test_toAssetsUp_roundsUp() public pure {
        uint256 down = MorphoSharesMath.toAssetsDown(2_500_000, 10_000_000, 5_000_000);
        uint256 up = MorphoSharesMath.toAssetsUp(2_500_000, 10_000_000, 5_000_000);
        assertEq(up, down + 1, "up should exceed down by exactly one unit on inexact division");
    }

    function test_toSharesDown_roundsDown() public pure {
        uint256 down = MorphoSharesMath.toSharesDown(2_500_000, 10_000_000, 5_000_000);
        uint256 up = MorphoSharesMath.toSharesUp(2_500_000, 10_000_000, 5_000_000);
        assertEq(up, down + 1, "up should exceed down by exactly one unit on inexact division");
    }

    function test_mulDivDown_roundsDown() public pure {
        // 7*3/2 = 10.5 -> floor 10
        assertEq(MorphoSharesMath.mulDivDown(7, 3, 2), 10);
    }

    function test_mulDivUp_roundsUp() public pure {
        // 7*3/2 = 10.5 -> ceil 11
        assertEq(MorphoSharesMath.mulDivUp(7, 3, 2), 11);
    }

    /*//////////////////////////////////////////////////////////////
                          EMPTY MARKET EDGE CASE
    //////////////////////////////////////////////////////////////*/

    function test_emptyMarket_returnsVirtualOffsetOnly() public pure {
        // On an empty market, the virtual offset alone determines the exchange rate:
        // 1 virtual asset per 1e6 virtual shares.
        assertEq(MorphoSharesMath.toAssetsDown(VIRTUAL_SHARES, 0, 0), VIRTUAL_ASSETS);
        assertEq(MorphoSharesMath.toAssetsDown(VIRTUAL_SHARES / 2, 0, 0), 0, "half the virtual shares round down to zero assets");
        assertEq(MorphoSharesMath.toSharesDown(VIRTUAL_ASSETS, 0, 0), VIRTUAL_SHARES);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirrors _increasePosition's own math: totalAmount = ownAmount*leverage/1e18,
    ///      borrowAmount = totalAmount - ownAmount. Confirms that identity can never
    ///      underflow across the leverage range the registry actually allows (>= 1e18).
    function testFuzz_borrowAmountPlusOwnAmountEqualsTotalAmount(uint256 ownAmount, uint256 leverage) public pure {
        ownAmount = bound(ownAmount, 1, 1e30);
        leverage = bound(leverage, 1e18, 50e18);

        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 borrowAmount = totalAmount - ownAmount;

        assertEq(ownAmount + borrowAmount, totalAmount);
        assertGe(totalAmount, ownAmount, "leverage >= 1e18 must never shrink total exposure below own contribution");
    }

    /// @dev Rounding-direction invariant, not just the two hand-picked values above: for
    ///      any market state, "up" can never report less than "down".
    function testFuzz_toAssetsUp_gteToAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) public pure {
        shares = bound(shares, 0, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e30);

        assertGe(
            MorphoSharesMath.toAssetsUp(shares, totalAssets, totalShares),
            MorphoSharesMath.toAssetsDown(shares, totalAssets, totalShares)
        );
    }

    function testFuzz_toSharesUp_gteToSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
        assets = bound(assets, 0, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e30);

        assertGe(
            MorphoSharesMath.toSharesUp(assets, totalAssets, totalShares),
            MorphoSharesMath.toSharesDown(assets, totalAssets, totalShares)
        );
    }

    /// @dev No-value-creation invariant: rounding an assets amount down to shares and back
    ///      down to assets can only ever lose dust, never manufacture extra assets. This is
    ///      the property that keeps repeated supply-side conversions from being an attack.
    function testFuzz_assetsToSharesToAssetsDown_neverExceedsOriginal(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 0, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e30);

        uint256 shares = MorphoSharesMath.toSharesDown(assets, totalAssets, totalShares);
        uint256 assetsBack = MorphoSharesMath.toAssetsDown(shares, totalAssets, totalShares);

        assertLe(assetsBack, assets);
    }

    /// @dev Mirror of the above in the other direction: shares -> assets -> shares, both
    ///      rounded down, never manufactures extra shares either.
    function testFuzz_sharesToAssetsToSharesDown_neverExceedsOriginal(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        shares = bound(shares, 0, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e30);

        uint256 assets = MorphoSharesMath.toAssetsDown(shares, totalAssets, totalShares);
        uint256 sharesBack = MorphoSharesMath.toSharesDown(assets, totalAssets, totalShares);

        assertLe(sharesBack, shares);
    }
}
