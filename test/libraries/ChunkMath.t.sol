// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChunkMath} from "../../src/libraries/ChunkMath.sol";

contract ChunkMathTest is Test {
    function base() internal pure returns (ChunkMath.Params memory p) {
        p = ChunkMath.Params({
            remaining: 100e18,
            targetChunks: 100,
            elapsed: 60,
            interval: 60,
            timeCapX: 5,
            depthBps: 0,
            pressureBps: 0,
            minChunk: 1e15,
            maxChunk: 50e18
        });
    }

    function test_zeroBeforeInterval() public pure {
        ChunkMath.Params memory p = base();
        p.elapsed = 59;
        assertEq(ChunkMath.chunkSize(p), 0);
        p.elapsed = 0;
        assertEq(ChunkMath.chunkSize(p), 0);
    }

    function test_zeroWhenNothingRemains() public pure {
        ChunkMath.Params memory p = base();
        p.remaining = 0;
        assertEq(ChunkMath.chunkSize(p), 0);
    }

    function test_baseChunk_noMultipliers() public pure {
        // exactly one interval, no depth/pressure: remaining/target
        assertEq(ChunkMath.chunkSize(base()), 1e18);
    }

    function test_timeMultiplier_catchupAndCap() public pure {
        ChunkMath.Params memory p = base();
        p.elapsed = 180; // 3 intervals missed -> 3x
        assertEq(ChunkMath.chunkSize(p), 3e18);
        p.elapsed = 6000; // 100 intervals -> capped at 5x
        assertEq(ChunkMath.chunkSize(p), 5e18);
    }

    function test_depthAndPressure_doubleEach() public pure {
        ChunkMath.Params memory p = base();
        p.depthBps = 10_000;
        assertEq(ChunkMath.chunkSize(p), 2e18);
        p.depthBps = 0;
        p.pressureBps = 10_000;
        assertEq(ChunkMath.chunkSize(p), 2e18);
        p.depthBps = 10_000;
        p.pressureBps = 10_000;
        assertEq(ChunkMath.chunkSize(p), 4e18);
        // over-range inputs clamp to 100%
        p.depthBps = 50_000;
        p.pressureBps = 50_000;
        assertEq(ChunkMath.chunkSize(p), 4e18);
    }

    function test_halfDepth() public pure {
        ChunkMath.Params memory p = base();
        p.depthBps = 5000;
        assertEq(ChunkMath.chunkSize(p), 1.5e18);
    }

    function test_maxChunkClamp() public pure {
        ChunkMath.Params memory p = base();
        p.maxChunk = 0.5e18;
        assertEq(ChunkMath.chunkSize(p), 0.5e18);
    }

    function test_minChunkClamp_boundedByRemaining() public pure {
        ChunkMath.Params memory p = base();
        p.remaining = 0.0005e18; // base would be 0.000005; min is 0.001 > remaining
        // tiny position: base = remaining (finish it), min clamp pushes to minChunk,
        // remaining clamp brings it back down
        assertEq(ChunkMath.chunkSize(p), 0.0005e18);
    }

    function test_tinyPosition_finishesWhole() public pure {
        ChunkMath.Params memory p = base();
        p.remaining = 50; // remaining/target == 0 -> base = remaining
        assertEq(ChunkMath.chunkSize(p), 50);
    }

    function testFuzz_invariants(
        uint256 remaining,
        uint256 elapsed,
        uint256 depthBps,
        uint256 pressureBps,
        uint256 minChunk,
        uint256 maxChunk
    ) public pure {
        ChunkMath.Params memory p = base();
        p.remaining = bound(remaining, 0, 1e30);
        p.elapsed = bound(elapsed, 0, 365 days);
        p.depthBps = bound(depthBps, 0, 50_000);
        p.pressureBps = bound(pressureBps, 0, 50_000);
        p.minChunk = bound(minChunk, 0, 1e24);
        p.maxChunk = bound(maxChunk, p.minChunk, 1e27); // sane config: min <= max

        uint256 size = ChunkMath.chunkSize(p);

        // never exceeds what's left
        assertLe(size, p.remaining);
        // respects the cap whenever the cap is above the floor
        if (size > 0 && p.remaining >= p.minChunk) assertLe(size, p.maxChunk);
        // nothing due before the interval
        if (p.elapsed < p.interval) assertEq(size, 0);
        // monotonicity in depth
        if (p.elapsed >= p.interval && p.remaining > 0) {
            ChunkMath.Params memory deeper = p;
            deeper.depthBps = p.depthBps + 1000;
            assertGe(ChunkMath.chunkSize(deeper), size);
        }
    }

    // ---------------------------------------------------------------- penalty

    function test_penalty_knownValues() public pure {
        // base 0.5% (50 bps), LT 90%, fresh liquidation: 50 * 0.9 * 1.0 = 45 bps
        assertEq(ChunkMath.penaltyBps(50, 9000, 0, 5), 45);
        // after 1 hour: 2x time factor -> 90 bps
        assertEq(ChunkMath.penaltyBps(50, 9000, 1 hours, 5), 90);
        // after 10 hours: capped at 5x -> 225 bps
        assertEq(ChunkMath.penaltyBps(50, 9000, 10 hours, 5), 225);
        // LT 50%: 50 * 0.5 = 25 bps
        assertEq(ChunkMath.penaltyBps(50, 5000, 0, 5), 25);
    }

    function testFuzz_penalty_boundedByCap(uint16 ltBps, uint256 timeInLiq) public pure {
        ltBps = uint16(bound(ltBps, 1, 10_000));
        timeInLiq = bound(timeInLiq, 0, 3650 days);
        uint256 p = ChunkMath.penaltyBps(50, ltBps, timeInLiq, 5);
        assertLe(p, 50 * 5); // base * timeCap is the absolute ceiling (lt <= 100%)
    }
}
