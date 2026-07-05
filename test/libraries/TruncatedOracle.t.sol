// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TruncatedOracle} from "../../src/libraries/TruncatedOracle.sol";

/// Library-with-storage harness.
contract OracleHarness {
    using TruncatedOracle for TruncatedOracle.State;

    TruncatedOracle.State internal state;

    function initialize(int24 tick, uint32 ts) external {
        state.initialize(tick, ts);
    }

    function observe(int24 tick, uint32 ts) external {
        state.observe(tick, ts);
    }

    function ready() external view returns (bool) {
        return state.ready();
    }

    function medianTick() external view returns (int24) {
        return state.medianTick();
    }

    function borrowTick(int24 spot, bool collateralIs0) external view returns (int24) {
        return state.borrowTick(spot, collateralIs0);
    }
}

contract TruncatedOracleTest is Test {
    OracleHarness oracle;
    uint32 constant T0 = 1_000_000;
    uint32 constant STEP = 60; // == OBS_INTERVAL

    function setUp() public {
        oracle = new OracleHarness();
        oracle.initialize(0, T0);
    }

    /// Fill the ring with `tick` at proper intervals until ready.
    function _fill(int24 tick) internal returns (uint32 ts) {
        ts = T0;
        for (uint256 i = 1; i < 9; i++) {
            ts += STEP;
            oracle.observe(tick, ts);
        }
        assertTrue(oracle.ready());
    }

    // ---------------------------------------------------------------- bootstrap

    function test_notReadyUntilRingFills() public {
        assertFalse(oracle.ready());
        uint32 ts = T0;
        for (uint256 i = 1; i < 8; i++) {
            ts += STEP;
            oracle.observe(0, ts);
            assertFalse(oracle.ready());
        }
        oracle.observe(0, ts + STEP);
        assertTrue(oracle.ready());
    }

    function test_intraIntervalObservationsDontAdvanceRing() public {
        // many observations within one interval: still not ready
        for (uint256 i = 1; i <= 50; i++) {
            oracle.observe(int24(int256(i)), T0 + uint32(i)); // 1s apart
        }
        assertFalse(oracle.ready());
    }

    // ---------------------------------------------------------------- truncation

    function test_truncation_clampsRecordedMove() public {
        uint32 ts = _fill(0);
        // raw tick jumps +50_000 in one interval; recorded tick is clamped to +9116
        oracle.observe(50_000, ts + STEP);
        // median still 0 (one outlier among nine), but the *recorded* value is
        // observable once a majority arrives truncated step by step:
        // next observation from the same raw spike moves at most another 9116.
        oracle.observe(50_000, ts + 2 * STEP);
        oracle.observe(50_000, ts + 3 * STEP);
        oracle.observe(50_000, ts + 4 * STEP);
        oracle.observe(50_000, ts + 5 * STEP);
        // 5 of 9 slots now hold the truncated ladder [9116, 18232, 27348, 36464, 45580];
        // median = 5th smallest = 9116 -> a sustained move takes many intervals to
        // pull the median, exactly the property we want.
        assertEq(oracle.medianTick(), 9116);
    }

    function test_honestLargeMove_convergesOverTime() public {
        uint32 ts = _fill(0);
        // a real repricing sustains; after 9 intervals the whole ring reflects it
        int24 target = 30_000;
        for (uint256 i = 1; i <= 9; i++) {
            oracle.observe(target, ts + uint32(i) * STEP);
        }
        // ladder reaches 30_000 after ceil(30000/9116)=4 steps; ring is then full of it
        assertEq(oracle.medianTick(), target);
    }

    // ---------------------------------------------------------------- median

    function test_median_ignoresMinoritySpikes() public {
        uint32 ts = _fill(1000);
        // 4 spiked observations out of 9 cannot move the median
        oracle.observe(9000, ts + STEP);
        oracle.observe(9000, ts + 2 * STEP);
        oracle.observe(9000, ts + 3 * STEP);
        oracle.observe(9000, ts + 4 * STEP);
        assertEq(oracle.medianTick(), 1000);
    }

    // ---------------------------------------------------------------- worse-of / extremes

    function test_borrowTick_takesWorseOfSpot() public {
        _fill(1000);
        // collateral = token0: lower tick is worse for the borrower
        assertEq(oracle.borrowTick(400, true), 400); // spot below median -> spot
        // collateral = token1: higher tick is worse
        assertEq(oracle.borrowTick(5000, false), 5000);
    }

    function test_borrowTick_medianWhenSpotFavorable() public {
        _fill(1000);
        // spot pumped above median: token0-collateral borrower still priced at median
        assertEq(oracle.borrowTick(8000, true), 1000);
        // spot dumped below: token1-collateral borrower still priced at median
        assertEq(oracle.borrowTick(-8000, false), 1000);
    }

    function test_extremes_spikeAndRevertWithinIntervalStillCounts() public {
        uint32 ts = _fill(1000);
        // attacker pumps to 20_000 mid-interval and reverts to 1000 in the same
        // interval — no new ring slot is written, but pendingMax remembers.
        oracle.observe(20_000, ts + 10); // intra-interval: only extremes update
        oracle.observe(1000, ts + 20);
        // token1-collateral borrower (higher tick = worse) is priced at the spike
        assertEq(oracle.borrowTick(1000, false), 20_000);
        // token0-collateral borrower unaffected by an upward spike
        assertEq(oracle.borrowTick(1000, true), 1000);
    }

    function test_extremes_ageOut() public {
        uint32 ts = _fill(1000);
        // spike gets recorded into one interval's extremes...
        oracle.observe(20_000, ts + 10);
        ts += STEP;
        oracle.observe(1000, ts); // rolls the interval; spike is in slot's rawMax
        assertEq(oracle.borrowTick(1000, false), 20_000);
        // ...then ages out of the 3-observation lookback after 3 calm intervals
        for (uint256 i = 1; i <= 3; i++) {
            ts += STEP;
            oracle.observe(1000, ts);
        }
        assertEq(oracle.borrowTick(1000, false), 1000);
    }

    function testFuzz_borrowTick_neverFavorableToBorrower(int24 spot, bool collateralIs0) public {
        spot = int24(bound(spot, -100_000, 100_000));
        _fill(1000);
        int24 worst = oracle.borrowTick(spot, collateralIs0);
        if (collateralIs0) {
            assertLe(worst, spot); // collateral never valued above spot
            assertLe(worst, oracle.medianTick()); // nor above median
        } else {
            assertGe(worst, spot);
            assertGe(worst, oracle.medianTick());
        }
    }
}
