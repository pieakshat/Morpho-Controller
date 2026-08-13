// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMorpho, Id, MarketParams} from "../interfaces/IMorpho.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IOwnableView} from "../interfaces/IOwnableView.sol";
import {MorphoMarketConfig, IncreaseCheckParams} from "../types/MorphoTypes.sol";
import {MorphoSharesMath} from "./MorphoSharesMath.sol";

/// @dev The subset of MorphoLeverageVault's own external ABI this contract reads back.
///      Declared locally rather than importing MorphoLeverageVault.sol itself, which would
///      be circular: the vault (via MorphoCore) is what constructs this contract.
interface IVaultMarketsView {
    function activeMarkets() external view returns (Id[] memory);
    function marketConfig(Id id) external view returns (MorphoMarketConfig memory);
}

/// @notice Risk-limit gate the engine consults on every allocator action, layered on top
///         of MorphoMarketRegistry's own whitelist and leverage cap rather than restating
///         them. Which markets are usable at all, and their leverage ceiling, stays owned
///         entirely by the registry — this contract only adds thresholds that don't already
///         exist anywhere: health factor, aggregate debt, per-asset exposure, price
///         deviation, rate limiting, a slippage-ceiling re-check, and an emergency pause.
/// @dev Deployed by MorphoCore's constructor and bound to that one vault, the same pattern
///      MorphoSwapExecutor already uses for a satellite contract that must be provably tied
///      to a single caller. Never decodes MarketAction.swapCalldata and never needs to —
///      every check here works off structured inputs the engine already computed
///      (IncreaseCheckParams) or live on-chain state, never the opaque swap bytes.
contract CircuitBreaker {
    IMorpho public immutable MORPHO;
    address public immutable VAULT;

    bool public paused;

    /// @dev Every threshold below defaults to 0, meaning unenforced, until the owner sets
    ///      it — these are additional safety margins on an action MorphoMarketRegistry has
    ///      already gated (whitelist + leverage cap), not a second gate of their own. A
    ///      freshly-registered market is immediately usable at whatever the registry allows;
    ///      nothing here needs separate setup before that's true.
    mapping(Id => uint256) public minHealthFactor;
    mapping(Id => uint256) public maxPriceDeviationBps;
    /// @dev 1e36-scaled, IOracle's own convention. Refreshed by both increases and decreases,
    ///      regardless of whether maxPriceDeviationBps is set, so the baseline is never stale
    ///      by the time the check does get turned on.
    mapping(Id => uint256) public lastObservedPrice;
    /// @dev When lastObservedPrice was written. A deviation check against an anchor from
    ///      months ago measures drift, not a break, so an observation older than
    ///      priceObservationMaxAge is treated as no anchor at all rather than as a breach.
    mapping(Id => uint256) public lastObservedAt;

    /// @dev Net exposure growth for the market inside the current window, not gross churn:
    ///      increases add, decreases subtract, floored at zero. Gating increases on gross
    ///      churn would let a de-risking unwind consume the very budget needed to re-enter
    ///      afterwards, which punishes exactly the behavior this contract wants.
    mapping(Id => uint256) public maxExposureChangePerWindow;
    mapping(Id => uint256) public windowStart;
    mapping(Id => uint256) public windowExposureChange;

    /// @dev Keyed by collateralToken, ASSET terms, summed across every active market that
    ///      shares it. There is no equivalent per-borrow-asset map: MorphoMarketRegistry
    ///      already enforces loanToken == ASSET for every registered market, so there is
    ///      only ever one borrow-side asset in this whole system — maxAggregateDebt below
    ///      already is that check.
    mapping(address => uint256) public maxAssetExposure;

    uint256 public maxAggregateDebt;
    /// @dev Ceiling on the slippage a single increase actually realized, measured after the
    ///      fact by the engine as the shortfall between the collateral the oracle implied
    ///      and the collateral the position really gained. Distinct from
    ///      MorphoMarketRegistry's maxSlippageBps, which bounds what a trade is *allowed* to
    ///      lose before it executes; this bounds what it *did* lose.
    uint256 public maxSlippageBpsCeiling;
    uint256 public rateLimitWindowSeconds;
    /// @dev Age beyond which lastObservedPrice stops being treated as a deviation anchor.
    ///      Zero means never expire, preserving the old always-compare behavior for anyone
    ///      who wants it.
    uint256 public priceObservationMaxAge;

    uint256 internal constant MAX_PRICE_DEVIATION_BPS_LIMIT = 10_000;
    /// @dev Mirrors MorphoMarketRegistry.MAX_SLIPPAGE_BPS_LIMIT.
    uint256 internal constant MAX_SLIPPAGE_BPS_CEILING_LIMIT = 1_000;

    error NotVaultOwner();
    error NotVault();
    error InvalidPriceDeviationBps(uint256 requested, uint256 limit);
    error InvalidSlippageBpsCeiling(uint256 requested, uint256 limit);
    error RateLimitWindowNotSet();
    error Paused();
    error PriceDeviationExceeded(Id id, uint256 newPrice, uint256 lastPrice, uint256 maxBps);
    error RateLimitExceeded(Id id, uint256 attempted, uint256 cap);
    error HealthFactorTooLow(Id id, uint256 healthFactor, uint256 minRequired);
    error MaxAggregateDebtExceeded(uint256 totalDebt, uint256 cap);
    error MaxAssetExposureExceeded(address collateralToken, uint256 exposure, uint256 cap);
    error SlippageCeilingExceeded(uint256 used, uint256 ceiling);

    event PausedSet(bool paused);
    event MinHealthFactorUpdated(Id indexed id, uint256 minHealthFactor);
    event MaxPriceDeviationBpsUpdated(Id indexed id, uint256 bps);
    event MaxExposureChangePerWindowUpdated(Id indexed id, uint256 cap);
    event MaxAssetExposureUpdated(address indexed collateralToken, uint256 cap);
    event MaxAggregateDebtUpdated(uint256 cap);
    event MaxSlippageBpsCeilingUpdated(uint256 ceiling);
    event RateLimitWindowSecondsUpdated(uint256 windowSeconds);
    event PriceObservationMaxAgeUpdated(uint256 maxAge);
    event PriceObserved(Id indexed id, uint256 price);

    /// @dev Single-sources admin rights from the vault's own owner rather than running a
    ///      second, separate Ownable2Step flow that could desync from it — an ownership
    ///      transfer on the vault carries over here with no extra step.
    ///
    ///      Deliberately does NOT accept msg.sender == VAULT. Doing so would authorize every
    ///      present and future vault code path to reach every setter here, and it buys
    ///      nothing: the owner resolved below can call these setters directly, so a
    ///      forwarding helper on the vault would only be a second route to the same place.
    modifier onlyOwner() {
        require(msg.sender == IOwnableView(VAULT).owner(), NotVaultOwner());
        _;
    }

    /// @dev Simpler than MorphoSwapExecutor's onlyVaultBundle: these hooks are called
    ///      synchronously from within the engine's own call frame, never through a
    ///      Bundler3.multicall indirection, so there's no Bundler3.initiator() to spoof and
    ///      a plain sender check is enough.
    modifier onlyVault() {
        require(msg.sender == VAULT, NotVault());
        _;
    }

    constructor(IMorpho morpho_) {
        MORPHO = morpho_;
        VAULT = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setMinHealthFactor(Id id, uint256 minHealthFactor_) external onlyOwner {
        minHealthFactor[id] = minHealthFactor_;
        emit MinHealthFactorUpdated(id, minHealthFactor_);
    }

    function setMaxPriceDeviationBps(Id id, uint256 bps) external onlyOwner {
        require(bps <= MAX_PRICE_DEVIATION_BPS_LIMIT, InvalidPriceDeviationBps(bps, MAX_PRICE_DEVIATION_BPS_LIMIT));
        maxPriceDeviationBps[id] = bps;
        emit MaxPriceDeviationBpsUpdated(id, bps);
    }

    /// @dev Rejects a live cap while rateLimitWindowSeconds is still 0. Without that guard
    ///      the zero window makes every call look like a fresh period, silently turning what
    ///      reads as a per-window budget into a per-action one. Set the window first.
    function setMaxExposureChangePerWindow(Id id, uint256 cap) external onlyOwner {
        require(cap == 0 || rateLimitWindowSeconds != 0, RateLimitWindowNotSet());
        maxExposureChangePerWindow[id] = cap;
        emit MaxExposureChangePerWindowUpdated(id, cap);
    }

    function setMaxAssetExposure(address collateralToken, uint256 cap) external onlyOwner {
        maxAssetExposure[collateralToken] = cap;
        emit MaxAssetExposureUpdated(collateralToken, cap);
    }

    function setMaxAggregateDebt(uint256 cap) external onlyOwner {
        maxAggregateDebt = cap;
        emit MaxAggregateDebtUpdated(cap);
    }

    function setMaxSlippageBpsCeiling(uint256 ceiling) external onlyOwner {
        require(
            ceiling <= MAX_SLIPPAGE_BPS_CEILING_LIMIT, InvalidSlippageBpsCeiling(ceiling, MAX_SLIPPAGE_BPS_CEILING_LIMIT)
        );
        maxSlippageBpsCeiling = ceiling;
        emit MaxSlippageBpsCeilingUpdated(ceiling);
    }

    function setRateLimitWindowSeconds(uint256 windowSeconds) external onlyOwner {
        rateLimitWindowSeconds = windowSeconds;
        emit RateLimitWindowSecondsUpdated(windowSeconds);
    }

    function setPriceObservationMaxAge(uint256 maxAge) external onlyOwner {
        priceObservationMaxAge = maxAge;
        emit PriceObservationMaxAgeUpdated(maxAge);
    }

    /*//////////////////////////////////////////////////////////////
                              ENGINE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if opening/adding to a position with these parameters would breach
    ///         pause, price-deviation, or rate-limit thresholds. Records the price
    ///         observation and rate-limit usage as it passes.
    function checkBeforeIncrease(IncreaseCheckParams calldata p) external onlyVault {
        evaluateBeforeIncrease(p);

        _recordPrice(p.marketId, p.price);
        _addWindowExposure(p.marketId, p.totalAmount);
    }

    /// @notice The read-only half of checkBeforeIncrease's logic, with no side effects.
    ///         Reverts under the exact same conditions checkBeforeIncrease would, with the
    ///         same typed errors — called internally by checkBeforeIncrease, and externally
    ///         (via `this.`, see previewBeforeIncrease) so an off-chain allocator can get an
    ///         identical answer via a free eth_call before it even fetches a swap quote.
    ///         Left unrestricted deliberately: it reveals nothing the public state variables
    ///         above don't already expose, and it cannot write anything.
    function evaluateBeforeIncrease(IncreaseCheckParams calldata p) public view {
        require(!paused, Paused());

        uint256 devBps = maxPriceDeviationBps[p.marketId];
        if (devBps != 0 && _anchorIsUsable(p.marketId)) {
            uint256 last = lastObservedPrice[p.marketId];
            uint256 diff = p.price > last ? p.price - last : last - p.price;
            require(diff <= (last * devBps) / 10_000, PriceDeviationExceeded(p.marketId, p.price, last, devBps));
        }

        uint256 cap = maxExposureChangePerWindow[p.marketId];
        if (cap == 0 || rateLimitWindowSeconds == 0) return;
        uint256 attempted = _previewWindowTotal(p.marketId, p.totalAmount);
        require(attempted <= cap, RateLimitExceeded(p.marketId, attempted, cap));
    }

    /// @notice A pure preview of checkBeforeIncrease: same code path via evaluateBeforeIncrease,
    ///         but as a genuine view call an off-chain allocator can simulate for free instead
    ///         of discovering a revert by broadcasting. Never mutates lastObservedPrice or the
    ///         rate-limit window, unlike the real hook.
    function previewBeforeIncrease(IncreaseCheckParams calldata p) external view returns (bool ok, bytes4 failureSelector) {
        try this.evaluateBeforeIncrease(p) {
            return (true, bytes4(0));
        } catch (bytes memory reason) {
            return (false, _selectorFromRevertReason(reason));
        }
    }

    /// @notice Reverts if the position just opened/added to is unhealthy, if aggregate debt
    ///         or this collateral asset's total exposure now exceeds its cap, or if the
    ///         slippage actually used on this trade exceeds the global ceiling. Pure reads —
    ///         no state to record here, unlike the before-hook.
    function checkAfterIncrease(IncreaseCheckParams calldata p) external view onlyVault {
        _checkHealthFactor(p);
        _checkAggregateAndAssetExposure(p);

        uint256 ceiling = maxSlippageBpsCeiling;
        require(ceiling == 0 || p.slippageBpsUsed <= ceiling, SlippageCeilingExceeded(p.slippageBpsUsed, ceiling));
    }

    /// @notice Bookkeeping only for a decrease: releases the unwound value back into the
    ///         market's rate-limit budget and refreshes the price anchor. Never reverts —
    ///         decreases reduce risk, so nothing about a decrease should be blockable by
    ///         this contract, including this call itself being asked to account for an
    ///         unusually large one.
    /// @dev Releasing rather than consuming is the whole point. The budget bounds how fast
    ///      exposure can grow; an unwind shrinks exposure, so charging it would mean a
    ///      de-risking allocator locks itself out of re-entering the market it just made
    ///      safer — worst precisely during the volatility that prompted the unwind.
    ///      Refreshing the anchor here keeps a long decrease-only stretch from leaving a
    ///      stale price behind for the next increase to be judged against.
    function checkAfterDecrease(Id id, uint256 unwoundValue, uint256 price) external onlyVault {
        _releaseWindowExposure(id, unwoundValue);
        _recordPrice(id, price);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice collateralValue * lltv / debtValue for the vault's live position in `id`,
    ///         Morpho Blue's own health-check formula. type(uint256).max (infinitely
    ///         healthy) when there's no debt, rather than dividing by zero.
    function healthFactor(Id id) external view returns (uint256) {
        MorphoMarketConfig memory cfg = IVaultMarketsView(VAULT).marketConfig(id);
        return _healthFactor(id, cfg.params);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _checkHealthFactor(IncreaseCheckParams calldata p) private view {
        uint256 hfFloor = minHealthFactor[p.marketId];
        if (hfFloor == 0) return;
        uint256 hf = _healthFactor(p.marketId, p.params);
        require(hf >= hfFloor, HealthFactorTooLow(p.marketId, hf, hfFloor));
    }

    /// @dev Same collateral-pricing pattern as MorphoPositionValuation._positionValue, but
    ///      this read is never wrapped in try/catch: this is the health of the one market
    ///      just acted on, inside a transaction that's about to revert everything anyway if
    ///      this reverts. isMarketPriceable already documents that increases revert while a
    ///      market's own oracle is down — this is that same behavior, not a new failure mode.
    function _healthFactor(Id id, MarketParams memory params) private view returns (uint256) {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, VAULT);
        if (borrowShares == 0) return type(uint256).max;

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
        uint256 debtValue = MorphoSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);

        uint256 price = IOracle(params.oracle).price();
        uint256 collateralValue = MorphoSharesMath.mulDivDown(collateral, price, MorphoSharesMath.ORACLE_PRICE_SCALE);

        return (collateralValue * params.lltv) / debtValue;
    }

    /// @dev One combined pass over the active set for both aggregate-debt and per-asset
    ///      exposure, rather than looping twice. Unlike _healthFactor above, the per-market
    ///      oracle read here IS wrapped in try/catch, degrading a broken oracle's collateral
    ///      contribution to zero exactly like MorphoPositionValuation._positionValue does —
    ///      this loop reaches into markets other than the one just acted on, so one broken
    ///      oracle on an unrelated active market must not block an increase into a
    ///      different, healthy one. The debt side is never degraded, matching
    ///      _positionValue's own asymmetry: never under-report a liability.
    function _checkAggregateAndAssetExposure(IncreaseCheckParams calldata p) private view {
        uint256 debtCap = maxAggregateDebt;
        uint256 assetCap = maxAssetExposure[p.params.collateralToken];
        if (debtCap == 0 && assetCap == 0) return;

        uint256 totalDebt;
        uint256 assetExposure;

        Id[] memory active = IVaultMarketsView(VAULT).activeMarkets();
        for (uint256 i = 0; i < active.length; ++i) {
            Id id = active[i];
            (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, VAULT);

            if (borrowShares > 0) {
                (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
                totalDebt += MorphoSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
            }

            if (collateral > 0) {
                MorphoMarketConfig memory cfg = IVaultMarketsView(VAULT).marketConfig(id);
                if (cfg.params.collateralToken == p.params.collateralToken) {
                    try IOracle(cfg.params.oracle).price() returns (uint256 price) {
                        assetExposure += MorphoSharesMath.mulDivDown(collateral, price, MorphoSharesMath.ORACLE_PRICE_SCALE);
                    } catch {}
                }
            }
        }

        require(debtCap == 0 || totalDebt <= debtCap, MaxAggregateDebtExceeded(totalDebt, debtCap));
        require(
            assetCap == 0 || assetExposure <= assetCap,
            MaxAssetExposureExceeded(p.params.collateralToken, assetExposure, assetCap)
        );
    }

    function _recordPrice(Id id, uint256 price) private {
        lastObservedPrice[id] = price;
        lastObservedAt[id] = block.timestamp;
        emit PriceObserved(id, price);
    }

    /// @dev An anchor is only worth comparing against if one exists and is recent enough.
    ///      A months-old anchor measures cumulative drift, which is indistinguishable from
    ///      a break under a single bps threshold, so it would reject legitimate increases
    ///      into any market that has simply been left alone for a while.
    function _anchorIsUsable(Id id) private view returns (bool) {
        if (lastObservedPrice[id] == 0) return false;
        uint256 maxAge = priceObservationMaxAge;
        return maxAge == 0 || block.timestamp - lastObservedAt[id] <= maxAge;
    }

    function _windowExpired(Id id) private view returns (bool) {
        return block.timestamp - windowStart[id] >= rateLimitWindowSeconds;
    }

    /// @dev What windowExposureChange[id] would become after adding `delta`, without
    ///      writing anything — the read-only twin of _addWindowExposure, used by
    ///      evaluateBeforeIncrease so a preview and the real check can't disagree.
    function _previewWindowTotal(Id id, uint256 delta) private view returns (uint256) {
        if (_windowExpired(id)) return delta;
        return windowExposureChange[id] + delta;
    }

    /// @dev Fixed-window counter: cheap and standard, but can admit up to ~2x the nominal
    ///      cap if a caller acts right at a window's end and again right after the next one
    ///      starts. That boundary-burst behavior is a known, accepted tradeoff, not a bug —
    ///      a sliding log would close it at the cost of unbounded per-market storage growth.
    function _addWindowExposure(Id id, uint256 delta) private {
        if (_windowExpired(id)) {
            windowStart[id] = block.timestamp;
            windowExposureChange[id] = delta;
        } else {
            windowExposureChange[id] += delta;
        }
    }

    /// @dev Saturating subtraction, never a revert: this runs on the decrease path, which
    ///      must stay unblockable. An unwind larger than the window's recorded growth just
    ///      empties the budget rather than wrapping.
    function _releaseWindowExposure(Id id, uint256 delta) private {
        if (_windowExpired(id)) {
            windowStart[id] = block.timestamp;
            windowExposureChange[id] = 0;
            return;
        }
        uint256 current = windowExposureChange[id];
        windowExposureChange[id] = current > delta ? current - delta : 0;
    }

    function _selectorFromRevertReason(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }
}
