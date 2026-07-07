// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {TrueLendHook} from "../TrueLendHook.sol";
import {LendingVault} from "../LendingVault.sol";
import {LiqRangeMath} from "../libraries/LiqRangeMath.sol";
import {ChunkMath} from "../libraries/ChunkMath.sol";

/// @title TrueLendLens
/// @notice Read-only aggregation over the hook, the vaults, and pool state — the
/// first periphery contract (DESIGN.md §3.1). Custodies nothing, holds no state,
/// and can be redeployed freely; every number is reconstructed from public views
/// and the same linked libraries the hook itself executes.
///
/// Position enumeration is deliberately absent: the hook does not index positions
/// by owner on-chain. Index `PositionOpened` events off-chain and query by id.
contract TrueLendLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    TrueLendHook public immutable hook;

    constructor(IPoolManager _poolManager, TrueLendHook _hook) {
        poolManager = _poolManager;
        hook = _hook;
    }

    // ------------------------------------------------------------------ position

    struct PositionView {
        // stored
        address borrower;
        PoolId poolId;
        bool collateralIs0;
        uint128 collateral;
        uint16 ltBps;
        int24 tickStart;
        int24 tickEnd;
        uint40 expiry;
        uint40 liqStartedAt;
        uint40 timeInLiqAccrued;
        // derived, at the current tick
        int24 currentTick;
        uint256 debt; // live, interest-accrued, debt-asset units
        uint256 collateralValueInDebt; // at the current tick
        uint256 ltvBps; // debt / collateral value
        uint256 healthBps; // usable collateral value / debt; < 10_000 = force-closable
        bool inRange; // gradual liquidation active at this tick
        uint256 timeInLiquidation; // accrued + live episode, seconds
        uint256 currentPenaltyBps; // effective per-chunk penalty right now
        uint8 forceCloseReason; // 0 none · 1 range exhausted · 2 expired · 3 health
    }

    function position(bytes32 positionId) external view returns (PositionView memory v) {
        TrueLendHook.Position memory p = hook.getPosition(positionId);
        if (p.borrower == address(0)) return v;

        v.borrower = p.borrower;
        v.poolId = p.poolId;
        v.collateralIs0 = p.collateralIs0;
        v.collateral = p.collateral;
        v.ltBps = p.ltBps;
        v.tickStart = p.tickStart;
        v.tickEnd = p.tickEnd;
        v.expiry = p.expiry;
        v.liqStartedAt = p.liqStartedAt;
        v.timeInLiqAccrued = p.timeInLiqAccrued;

        (, int24 tick,,) = poolManager.getSlot0(p.poolId);
        v.currentTick = tick;
        v.debt = hook.debtOf(positionId);
        v.collateralValueInDebt =
            LiqRangeMath.convertAtSqrtPrice(p.collateral, TickMath.getSqrtPriceAtTick(tick), p.collateralIs0);
        v.ltvBps = v.collateralValueInDebt == 0
            ? type(uint256).max
            : FullMath.mulDiv(v.debt, BPS, v.collateralValueInDebt);
        v.inRange = LiqRangeMath.inRange(p.collateralIs0, tick, p.tickStart, p.tickEnd);
        v.timeInLiquidation = _timeInLiquidation(p);

        TrueLendHook.Config memory cfg = hook.getConfig(p.poolId);
        v.currentPenaltyBps = ChunkMath.penaltyBps(cfg.basePenaltyBps, p.ltBps, v.timeInLiquidation, cfg.timeCapX);
        v.forceCloseReason = hook.forceCloseReason(positionId);
        v.healthBps = _healthBps(p, cfg, tick, v.debt, v.collateralValueInDebt);
    }

    /// @notice Usable collateral value (after the LT-capped buffer) over debt, in
    /// bps. 10_000 is the force-close boundary (reason 3); healthy positions sit
    /// above it. type(uint256).max when debt is zero.
    function healthBps(bytes32 positionId) external view returns (uint256) {
        TrueLendHook.Position memory p = hook.getPosition(positionId);
        if (p.borrower == address(0)) return 0;
        (, int24 tick,,) = poolManager.getSlot0(p.poolId);
        uint256 debt = hook.debtOf(positionId);
        uint256 collValue =
            LiqRangeMath.convertAtSqrtPrice(p.collateral, TickMath.getSqrtPriceAtTick(tick), p.collateralIs0);
        return _healthBps(p, hook.getConfig(p.poolId), tick, debt, collValue);
    }

    /// @notice The chunk the engine would execute for this position right now:
    /// collateral amount (0 if not due or not in range) and the penalty bps that
    /// would apply. Replicates `_executeChunk` sizing via the same libraries.
    function previewChunk(bytes32 positionId)
        external
        view
        returns (uint256 chunkCollateral, uint256 penaltyBps_)
    {
        TrueLendHook.Position memory p = hook.getPosition(positionId);
        if (p.borrower == address(0) || p.liqStartedAt == 0) return (0, 0);

        TrueLendHook.Config memory cfg = hook.getConfig(p.poolId);
        (, int24 tick,,) = poolManager.getSlot0(p.poolId);
        uint256 depthTokens =
            LiqRangeMath.rangeDepthTokens(p.collateralIs0, p.tickStart, p.tickEnd, poolManager.getLiquidity(p.poolId));
        if (depthTokens == 0) return (0, 0);

        chunkCollateral = ChunkMath.chunkSize(
            ChunkMath.Params({
                remaining: p.collateral,
                targetChunks: cfg.targetChunks,
                elapsed: block.timestamp - p.lastChunkAt,
                interval: cfg.chunkInterval,
                timeCapX: cfg.timeCapX,
                depthBps: LiqRangeMath.depthBps(p.collateralIs0, tick, p.tickStart, p.tickEnd),
                pressureBps: FullMath.mulDiv(p.collateral, BPS, depthTokens),
                minChunk: 0,
                maxChunk: FullMath.mulDiv(depthTokens, cfg.maxChunkDepthBps, BPS)
            })
        );
        penaltyBps_ = ChunkMath.penaltyBps(cfg.basePenaltyBps, p.ltBps, _timeInLiquidation(p), cfg.timeCapX);
    }

    // ------------------------------------------------------------------ pool

    struct PoolView {
        LendingVault vault0;
        LendingVault vault1;
        bool enabled;
        int24 currentTick;
        uint128 activeLiquidity;
        uint256 queueLength; // positions pending liquidation processing
        int24 processedTick;
        // per-vault lending state
        uint256 cash0;
        uint256 cash1;
        uint256 totalDebt0;
        uint256 totalDebt1;
        uint256 utilizationBps0;
        uint256 utilizationBps1;
        uint256 borrowRateBps0;
        uint256 borrowRateBps1;
        uint256 reserves0;
        uint256 reserves1;
    }

    function pool(PoolId poolId) external view returns (PoolView memory v) {
        (LendingVault v0, LendingVault v1, int24 processedTick, bool enabled) = hook.getPool(poolId);
        v.vault0 = v0;
        v.vault1 = v1;
        v.enabled = enabled;
        v.processedTick = processedTick;
        if (!enabled) return v;
        (, v.currentTick,,) = poolManager.getSlot0(poolId);
        v.activeLiquidity = poolManager.getLiquidity(poolId);
        v.queueLength = hook.queueLength(poolId);
        v.cash0 = v0.cash();
        v.cash1 = v1.cash();
        v.totalDebt0 = v0.totalDebtAssets();
        v.totalDebt1 = v1.totalDebtAssets();
        v.utilizationBps0 = v0.utilizationBps();
        v.utilizationBps1 = v1.utilizationBps();
        v.borrowRateBps0 = v0.rateBps(v.utilizationBps0);
        v.borrowRateBps1 = v1.rateBps(v.utilizationBps1);
        v.reserves0 = v0.reserves();
        v.reserves1 = v1.reserves();
    }

    // ------------------------------------------------------------------ quoting

    /// @notice Where a prospective loan's liquidation range would sit, and whether
    /// the spot-price checks pass. NOTE: valued at SPOT only — the hook's actual
    /// open() additionally values collateral at the worse of spot and its internal
    /// filter, so a quote that passes here can still revert when recent history is
    /// adverse. A quote that fails here fails on-chain too.
    function quoteOpen(
        PoolKey calldata key,
        bool collateralIs0,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint16 ltBps
    ) external view returns (int24 tickStart, int24 tickEnd, bool gapOk, bool ltvOkAtSpot) {
        PoolId poolId = key.toId();
        TrueLendHook.Config memory cfg = hook.getConfig(poolId);
        (, int24 spotTick,,) = poolManager.getSlot0(poolId);

        (tickStart, tickEnd) = LiqRangeMath.liquidationRange(
            collateralIs0, collateralAmount, borrowAmount, ltBps, cfg.rangeWidth, key.tickSpacing
        );
        gapOk = collateralIs0 ? tickStart <= spotTick - cfg.minGapTicks : tickStart >= spotTick + cfg.minGapTicks;
        ltvOkAtSpot = LiqRangeMath.openLtvOk(collateralAmount, borrowAmount, spotTick, collateralIs0, ltBps, 9500);
    }

    // ------------------------------------------------------------------ internals

    function _timeInLiquidation(TrueLendHook.Position memory p) internal view returns (uint256 t) {
        t = p.timeInLiqAccrued;
        if (p.liqStartedAt != 0) t += block.timestamp - p.liqStartedAt;
    }

    function _healthBps(
        TrueLendHook.Position memory p,
        TrueLendHook.Config memory cfg,
        int24, /* tick */
        uint256 debt,
        uint256 collValue
    ) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 bufferBps = cfg.slippageBufferBps;
        uint256 halfGap = (BPS - p.ltBps) / 2;
        if (bufferBps > halfGap) bufferBps = halfGap;
        uint256 usable = FullMath.mulDiv(collValue, BPS - bufferBps, BPS);
        return FullMath.mulDiv(usable, BPS, debt);
    }
}
