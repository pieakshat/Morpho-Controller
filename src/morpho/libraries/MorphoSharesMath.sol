// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Shares<->assets conversion matching Morpho Blue's own SharesMathLib exactly.
/// @dev Verified 2026-08-03 against Morpho Labs' real SharesMathLib.sol + MathLib.sol
///      (GPL-2.0-or-later). Reimplemented locally rather than imported so /morpho stays
///      dependency-free, but the formula, constants, and rounding directions must match
///      Morpho's real math bit-for-bit — this is Layer 0, not a place to improve on them.
///      Deliberately uses simple (x*y)/d division, not an overflow-safe 512-bit mulDiv,
///      because that's what the real Morpho Blue does — matching its overflow bounds is
///      what keeps our valuation consistent with the protocol's own behavior at the edges.
library MorphoSharesMath {
    /// @dev Chosen low enough to avoid overflow, high enough for precision. Virtual shares
    ///      can never be redeemed — they exist purely to prevent inflation attacks on an
    ///      empty market (OpenZeppelin's virtual-shares technique).
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev Verified against Morpho Blue's real ConstantsLib.sol — the fixed-point scale
    ///      an IOracle's price() is expressed in. collateral.mulDivDown(price, this) gives
    ///      collateral value in loan-token terms, exactly matching Morpho's own internal
    ///      health-check math (Morpho.sol's _isHealthy).
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @dev Value of `shares` in assets, rounding down — use for what a position is owed
    ///      (supply side), so we never over-report a claimable amount.
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivDown(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @dev Value of `shares` in assets, rounding up — use for what a position owes
    ///      (borrow/debt side), so we never under-report a liability.
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @dev Value of `assets` in shares, rounding down.
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivDown(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Value of `assets` in shares, rounding up.
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Exposed (not private) so callers can reuse the exact same rounding-down
    ///      primitive for oracle-price math — one canonical implementation of Morpho's
    ///      arithmetic, not a second copy living in the valuation logic.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return _mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return _mulDivUp(x, y, d);
    }

    function _mulDivDown(uint256 x, uint256 y, uint256 d) private pure returns (uint256) {
        return (x * y) / d;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) private pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }
}
