// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title ChunkMath
/// @notice The liquidation pacing formula. Pure; all knobs passed in so the hook's
/// per-pool config owns the numbers and tests can sweep them.
///
///   chunk = (remaining / targetChunks)
///         * min(elapsed / interval, timeCapX)   — missed intervals catch up, capped
///         * (1 + depth)                          — deeper into the range → faster
///         * (1 + pressure)                       — position large vs pool depth → faster
///   clamped to [minChunk, min(maxChunk, remaining)], 0 if interval not elapsed.
library ChunkMath {
    uint256 internal constant BPS = 10_000;

    struct Params {
        uint256 remaining; // collateral not yet liquidated
        uint256 targetChunks; // e.g. 100
        uint256 elapsed; // seconds since last chunk for this position
        uint256 interval; // CHUNK_INTERVAL seconds
        uint256 timeCapX; // max time multiplier, integer (e.g. 5)
        uint256 depthBps; // 0..10_000 from LiqRangeMath.depthBps
        uint256 pressureBps; // 0..10_000, position value / active liquidity value
        uint256 minChunk; // dust floor for a single chunk
        uint256 maxChunk; // absolute cap for a single chunk
    }

    function chunkSize(Params memory p) internal pure returns (uint256) {
        if (p.remaining == 0 || p.interval == 0 || p.elapsed < p.interval) return 0;

        uint256 base = p.remaining / p.targetChunks;
        if (base == 0) base = p.remaining; // tiny position: finish it

        uint256 timeX = p.elapsed / p.interval; // >= 1 here
        if (timeX > p.timeCapX) timeX = p.timeCapX;

        uint256 depth = p.depthBps > BPS ? BPS : p.depthBps;
        uint256 pressure = p.pressureBps > BPS ? BPS : p.pressureBps;

        uint256 size = base * timeX;
        size = FullMath.mulDiv(size, BPS + depth, BPS);
        size = FullMath.mulDiv(size, BPS + pressure, BPS);

        if (size > p.maxChunk) size = p.maxChunk;
        if (size < p.minChunk) size = p.minChunk;
        if (size > p.remaining) size = p.remaining;
        return size;
    }

    /// @notice Per-chunk penalty on proceeds, in bps.
    ///   penaltyBps = base * (ltBps/1e4) * min(1 + timeInLiq/1h, timeCapX)
    /// The time factor uses 1-hour granularity like v1, capped.
    function penaltyBps(uint256 basePenaltyBps, uint16 ltBps, uint256 timeInLiquidation, uint256 timeCapX)
        internal
        pure
        returns (uint256)
    {
        uint256 timeX100 = 100 + (timeInLiquidation * 100) / 1 hours; // 1.00x + 1x per hour
        uint256 cap = timeCapX * 100;
        if (timeX100 > cap) timeX100 = cap;
        // base * lt * time, bps-normalized at each step
        return FullMath.mulDiv(FullMath.mulDiv(basePenaltyBps, ltBps, BPS), timeX100, 100);
    }
}
