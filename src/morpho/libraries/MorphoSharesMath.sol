// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Shares<->assets conversion matching Morpho Blue's own SharesMathLib exactly.
/// @dev Reimplemented locally, pinned against morpho-org/morpho-blue @ v1.0.0, commit
///      55d2d99304fb3fb930c688462ae2ccabb1d533ad (src/libraries/SharesMathLib.sol +
///      MathLib.sol, GPL-2.0-or-later), instead of imported, so /morpho stays
///      dependency-free. The formula, constants, and rounding directions must stay
///      bit-for-bit identical to Morpho's own math at that pin — this is Layer 0, so any
///      drift here is a bug, not an improvement. Uses plain (x*y)/d division rather than
///      an overflow-safe 512-bit mulDiv to match Morpho Blue's own overflow bounds,
///      keeping valuation consistent with the protocol's behavior at the edges.
library MorphoSharesMath {
    /// @dev Chosen low enough to avoid overflow, high enough for precision. Virtual shares
    ///      can never be redeemed — they exist purely to prevent inflation attacks on an
    ///      empty market (OpenZeppelin's virtual-shares technique).
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev The fixed-point scale an IOracle's price() is expressed in, matching Morpho
    ///      Blue's ConstantsLib.sol at the pin cited above. collateral.mulDivDown(price,
    ///      this) gives collateral value in loan-token terms, matching Morpho's own
    ///      internal health-check math (Morpho.sol's _isHealthy).
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
