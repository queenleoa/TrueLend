// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TruncatedOracle
/// @notice Hook-internal manipulation-resistant price view. Three defenses stacked:
///   1. Truncation: each recorded observation may move at most MAX_ABS_TICK_MOVE
///      from the previous one (Uniswap's truncated-oracle constant), so a one-block
///      spike takes many observations to enter the record.
///   2. Median read: the borrow-side price is the median of the ring buffer, so a
///      minority of corrupted observations is ignored entirely.
///   3. Widen-only extremes: the raw min/max tick seen since the last observation
///      is recorded alongside it; the borrow-side bound includes recent extremes,
///      so a spike-and-revert inside one interval still counts against the borrower.
///
/// Observations are written from `beforeSwap` with the PRE-swap tick (recording the
/// price as of the start of the swap is what makes single-swap manipulation inert),
/// at most once per OBS_INTERVAL. The oracle is `ready()` only once the ring has
/// fully populated — new pools cannot originate loans while their history is thin.
library TruncatedOracle {
    int24 internal constant MAX_ABS_TICK_MOVE = 9116; // ~2.49x per observation
    uint32 internal constant OBS_INTERVAL = 60; // seconds between observations
    uint256 internal constant CARDINALITY = 9; // median window ~9 minutes

    struct Observation {
        int24 tick; // truncated tick
        int24 rawMin; // raw extreme lows seen during the interval
        int24 rawMax; // raw extreme highs seen during the interval
        uint32 timestamp;
    }

    struct State {
        Observation[CARDINALITY] obs;
        uint8 index; // last written slot
        uint8 count; // number of populated slots
        int24 pendingMin; // raw extremes accumulating in the current interval
        int24 pendingMax;
        bool initialized;
    }

    function initialize(State storage self, int24 tick, uint32 timestamp) internal {
        self.obs[0] = Observation({tick: tick, rawMin: tick, rawMax: tick, timestamp: timestamp});
        self.index = 0;
        self.count = 1;
        self.pendingMin = tick;
        self.pendingMax = tick;
        self.initialized = true;
    }

    /// @notice Record the pre-swap tick. Cheap no-op path when inside the interval.
    function observe(State storage self, int24 rawTick, uint32 timestamp) internal {
        if (rawTick < self.pendingMin) self.pendingMin = rawTick;
        if (rawTick > self.pendingMax) self.pendingMax = rawTick;

        Observation storage last = self.obs[self.index];
        if (timestamp < last.timestamp + OBS_INTERVAL) return;

        // Truncate movement relative to the last recorded tick.
        int24 prev = last.tick;
        int24 truncated = rawTick;
        if (truncated > prev + MAX_ABS_TICK_MOVE) truncated = prev + MAX_ABS_TICK_MOVE;
        if (truncated < prev - MAX_ABS_TICK_MOVE) truncated = prev - MAX_ABS_TICK_MOVE;

        uint8 next = uint8((self.index + 1) % CARDINALITY);
        self.obs[next] =
            Observation({tick: truncated, rawMin: self.pendingMin, rawMax: self.pendingMax, timestamp: timestamp});
        self.index = next;
        if (self.count < CARDINALITY) self.count++;

        self.pendingMin = rawTick;
        self.pendingMax = rawTick;
    }

    /// @notice True once the ring is fully populated (bootstrap gate for originations).
    function ready(State storage self) internal view returns (bool) {
        return self.count == CARDINALITY;
    }

    /// @notice Median of the recorded (truncated) ticks.
    function medianTick(State storage self) internal view returns (int24) {
        uint256 n = self.count;
        int24[] memory ticks = new int24[](n);
        for (uint256 i = 0; i < n; i++) {
            ticks[i] = self.obs[i].tick;
        }
        // insertion sort; n <= 9
        for (uint256 i = 1; i < n; i++) {
            int24 key = ticks[i];
            uint256 j = i;
            while (j > 0 && ticks[j - 1] > key) {
                ticks[j] = ticks[j - 1];
                j--;
            }
            ticks[j] = key;
        }
        return ticks[n / 2];
    }

    /// @notice The tick least favorable to a borrower whose collateral is
    /// currency0 (value rises with tick) or currency1 (value falls with tick).
    /// Takes the worse of {median, current spot, recent raw extremes}.
    function borrowTick(State storage self, int24 spotTick, bool collateralIs0) internal view returns (int24 worst) {
        worst = medianTick(self);
        if (collateralIs0) {
            // lower tick = lower collateral valuation = worse for borrower
            if (spotTick < worst) worst = spotTick;
            if (self.pendingMin < worst) worst = self.pendingMin;
            int24 m = _ringExtreme(self, true);
            if (m < worst) worst = m;
        } else {
            if (spotTick > worst) worst = spotTick;
            if (self.pendingMax > worst) worst = self.pendingMax;
            int24 m = _ringExtreme(self, false);
            if (m > worst) worst = m;
        }
    }

    /// @dev Raw extreme across the most recent third of the ring (recent intervals
    /// only — old excursions age out, but nothing inside the recent window narrows).
    function _ringExtreme(State storage self, bool wantMin) private view returns (int24 extreme) {
        uint256 lookback = CARDINALITY / 3; // 3 most recent observations
        extreme = wantMin ? type(int24).max : type(int24).min;
        for (uint256 i = 0; i < lookback && i < self.count; i++) {
            uint256 slot = (uint256(self.index) + CARDINALITY - i) % CARDINALITY;
            Observation storage o = self.obs[slot];
            if (wantMin) {
                if (o.rawMin < extreme) extreme = o.rawMin;
            } else {
                if (o.rawMax > extreme) extreme = o.rawMax;
            }
        }
    }
}
