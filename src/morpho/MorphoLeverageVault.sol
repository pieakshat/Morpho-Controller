// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, MarketParams} from "./interfaces/IMorpho.sol";
import {IMorpho} from "./interfaces/IMorpho.sol";
import {IBundler3} from "./interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "./interfaces/IGeneralAdapter1.sol";
import {MarketAction} from "./types/MorphoTypes.sol";
import {MorphoCore} from "./libraries/MorphoCore.sol";
import {MorphoMarketRegistry} from "./libraries/MorphoMarketRegistry.sol";
import {MorphoPositionValuation} from "./libraries/MorphoPositionValuation.sol";
import {MorphoLeverageEngine} from "./libraries/MorphoLeverageEngine.sol";
import {MorphoSwapExecutor} from "./libraries/MorphoSwapExecutor.sol";

/// @notice Standalone ERC-4626 vault that directly manages leveraged positions across
///         multiple Morpho markets, driven by an off-chain engine submitting MarketAction[].
/// @dev Deliberately independent of AggVault/IAdapter — this vault IS the position holder,
///      not something plugged into another vault. Composable with AggVault later for free:
///      its existing ERC4626Adapter can wrap any standards-compliant ERC4626 vault with
///      zero new code, as long as this one behaves correctly as one.
contract MorphoLeverageVault is ERC4626, Ownable2Step, ReentrancyGuard, MorphoPositionValuation, MorphoLeverageEngine {
    error NotAllocator();

    event AllocatorUpdated(address indexed account, bool allowed);

    mapping(address => bool) private _isAllocator;

    /// @dev Owner always has allocator rights too — same convention as AggVault's own
    ///      onlyAllocator, kept consistent across the two codebases even though this
    ///      vault doesn't inherit AggVault's actual access-control code.
    modifier onlyAllocator() {
        if (msg.sender != owner() && !_isAllocator[msg.sender]) revert NotAllocator();
        _;
    }

    constructor(
        IERC20 asset_,
        address owner_,
        IMorpho morpho_,
        IBundler3 bundler3_,
        IGeneralAdapter1 generalAdapter_,
        MorphoSwapExecutor swapExecutor_
    )
        ERC20("Morpho Leverage Vault", "mlvUSDC")
        ERC4626(asset_)
        Ownable(owner_)
        MorphoCore(morpho_, bundler3_, generalAdapter_, swapExecutor_)
        MorphoMarketRegistry(address(asset_))
    {}

    /*//////////////////////////////////////////////////////////////
                                ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev The full picture: idle balance plus every active Morpho position's net value.
    ///      Drives share pricing — this must be honest, unlike maxWithdrawable below which
    ///      is deliberately conservative.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalMorphoAssets();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev Deliberately reports ONLY idle balance, not total position value. Unwinding a
    ///      leveraged position needs swap-route data only the off-chain engine can supply —
    ///      a plain synchronous withdraw() can't do that. This clamp is what keeps AggVault-
    ///      style "don't promise more liquidity than is synchronously available" honest;
    ///      the off-chain engine is responsible for keeping enough idle buffer around.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 ownerAssets = super.maxWithdraw(owner_);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return ownerAssets < idle ? ownerAssets : idle;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 ownerShares = super.maxRedeem(owner_);
        uint256 idleShares = _convertToShares(IERC20(asset()).balanceOf(address(this)), Math.Rounding.Floor);
        return ownerShares < idleShares ? ownerShares : idleShares;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner_);
    }

    /*//////////////////////////////////////////////////////////////
                            OFF-CHAIN ENGINE ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys idle capital into markets, unwinds positions back to idle capital,
    ///         or both in one call — a genuine rebalance, decrease on one market feeding
    ///         an increase on another, same transaction.
    function executeActions(MarketAction[] calldata actions) external onlyAllocator nonReentrant {
        uint256 length = actions.length;
        for (uint256 i = 0; i < length; ++i) {
            MarketAction calldata action = actions[i];
            if (action.isIncrease) {
                _increasePosition(action);
            } else {
                _decreasePosition(action);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REGISTRY ADMIN
    //////////////////////////////////////////////////////////////*/

    function registerMarket(MarketParams calldata params, uint256 targetLeverage) external onlyOwner returns (Id) {
        return _registerMarket(params, targetLeverage);
    }

    function setMarketEnabled(Id id, bool enabled) external onlyOwner {
        _setMarketEnabled(id, enabled);
    }

    function setMarketLeverage(Id id, uint256 targetLeverage) external onlyOwner {
        _setMarketLeverage(id, targetLeverage);
    }

    function setAllocator(address account, bool allowed) external onlyOwner {
        _isAllocator[account] = allowed;
        emit AllocatorUpdated(account, allowed);
    }

    function isAllocator(address account) external view returns (bool) {
        return _isAllocator[account];
    }
}
