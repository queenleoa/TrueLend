// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BitMath} from "v4-core/libraries/BitMath.sol";

/// @title TriggerIndex
/// @notice Sparse index of "trigger ticks" (positions' range boundaries) so that
/// afterSwap only touches positions whose boundaries were actually crossed.
/// Ticks must be pre-aligned to the pool's tickSpacing. Storage per pool:
/// a word-bitmap over compressed ticks plus a position list per trigger tick.
library TriggerIndex {
    struct State {
        mapping(int16 => uint256) bitmap; // wordPos -> bits over compressed ticks
        mapping(int24 => bytes32[]) idsAt; // trigger tick -> position ids
    }

    function _split(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        bitPos = uint8(uint24(compressed % 256));
    }

    function register(State storage self, int24 tick, int24 spacing, bytes32 id) internal {
        int24 compressed = tick / spacing; // tick is aligned; exact division
        self.idsAt[tick].push(id);
        (int16 wordPos, uint8 bitPos) = _split(compressed);
        self.bitmap[wordPos] |= (1 << bitPos);
    }

    function deregister(State storage self, int24 tick, int24 spacing, bytes32 id) internal {
        bytes32[] storage ids = self.idsAt[tick];
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            if (ids[i] == id) {
                ids[i] = ids[n - 1];
                ids.pop();
                break;
            }
        }
        if (ids.length == 0) {
            int24 compressed = tick / spacing;
            (int16 wordPos, uint8 bitPos) = _split(compressed);
            self.bitmap[wordPos] &= ~(uint256(1) << bitPos);
        }
    }

    /// @notice Collect trigger ticks in (fromTick, toTick] (direction-aware),
    /// bounded by maxTriggers. Returns the found ticks and the tick up to which
    /// the walk is complete (== toTick unless the cap was hit).
    function crossedTriggers(State storage self, int24 fromTick, int24 toTick, int24 spacing, uint256 maxTriggers)
        internal
        view
        returns (int24[] memory ticks, uint256 count, int24 walkedTo)
    {
        ticks = new int24[](maxTriggers);
        walkedTo = toTick;
        if (fromTick == toTick) return (ticks, 0, toTick);

        bool up = toTick > fromTick;
        // compressed half-open window: scan c in (cFrom, cTo] going up, [cTo, cFrom) going down
        int24 cFrom = _compress(fromTick, spacing);
        int24 cTo = _compress(toTick, spacing);

        if (up) {
            for (int24 c = cFrom + 1; c <= cTo; c++) {
                if (!_isSet(self, c)) {
                    c = _nextSetAbove(self, c, cTo); // skip within word gaps cheaply
                    if (c > cTo) break;
                }
                int24 t = c * spacing;
                // trigger crossed if fromTick < t <= toTick
                if (t > fromTick && t <= toTick) {
                    if (count == maxTriggers) {
                        walkedTo = t - 1; // resume from here next time
                        return (ticks, count, walkedTo);
                    }
                    ticks[count++] = t;
                }
            }
        } else {
            for (int24 c = cFrom; c >= cTo; c--) {
                if (!_isSet(self, c)) {
                    c = _nextSetBelow(self, c, cTo);
                    if (c < cTo) break;
                }
                int24 t = c * spacing;
                // going down: trigger crossed if toTick <= t < fromTick... a position
                // boundary at exactly fromTick was already processed previously; at
                // exactly toTick it is crossed now.
                if (t < fromTick && t >= toTick) {
                    if (count == maxTriggers) {
                        walkedTo = t + 1;
                        return (ticks, count, walkedTo);
                    }
                    ticks[count++] = t;
                }
            }
        }
    }

    function idsAtTick(State storage self, int24 tick) internal view returns (bytes32[] storage) {
        return self.idsAt[tick];
    }

    function _compress(int24 tick, int24 spacing) private pure returns (int24 c) {
        c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
    }

    function _isSet(State storage self, int24 compressed) private view returns (bool) {
        (int16 wordPos, uint8 bitPos) = _split(compressed);
        return self.bitmap[wordPos] & (1 << bitPos) != 0;
    }

    /// @dev Next set compressed tick >= c, capped at cMax (returns cMax+1 if none).
    function _nextSetAbove(State storage self, int24 c, int24 cMax) private view returns (int24) {
        while (c <= cMax) {
            (int16 wordPos, uint8 bitPos) = _split(c);
            uint256 word = self.bitmap[wordPos] >> bitPos;
            if (word != 0) {
                uint8 lsb = BitMath.leastSignificantBit(word);
                int24 found = c + int24(uint24(lsb));
                return found; // may exceed cMax; caller checks
            }
            // jump to the start of the next word
            c = (int24(wordPos) + 1) * 256;
        }
        return cMax + 1;
    }

    /// @dev Next set compressed tick <= c, floored at cMin (returns cMin-1 if none).
    function _nextSetBelow(State storage self, int24 c, int24 cMin) private view returns (int24) {
        while (c >= cMin) {
            (int16 wordPos, uint8 bitPos) = _split(c);
            uint256 word = self.bitmap[wordPos] << (255 - bitPos); // keep bits <= bitPos
            if (word != 0) {
                uint8 msb = BitMath.mostSignificantBit(word);
                int24 found = c - int24(uint24(255 - msb));
                return found;
            }
            c = int24(wordPos) * 256 - 1; // end of previous word
        }
        return cMin - 1;
    }
}
