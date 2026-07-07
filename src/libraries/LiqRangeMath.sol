// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title LiqRangeMath
/// @notice Places a position's liquidation range and values amounts at ticks.
/// All math is done in sqrt-price Q96 space via mulDiv, so it is exact for any
/// token-decimal pair (decimals live inside the raw amounts, never in formulas).
///
/// Direction convention (price P = token1 per token0):
///  - collateral = token0, debt = token1: collateral value falls as P falls.
///    Liquidation range sits BELOW spot and is entered as the tick falls.
///  - collateral = token1, debt = token0: debt value rises as P rises.
///    Liquidation range sits ABOVE spot and is entered as the tick rises.
library LiqRangeMath {
    uint256 internal constant BPS = 10_000;

    error ZeroAmount();
    error LtOutOfRange();

    /// @notice sqrt price (Q96) at which debtValue == lt * collateralValue.
    /// @param collateralIs0 true if collateral is currency0
    /// @param collateral    raw collateral amount
    /// @param debt          raw debt amount (include any buffer the caller wants)
    /// @param ltBps         liquidation threshold in bps (e.g. 9000 = 90%)
    function liquidationSqrtPriceX96(bool collateralIs0, uint256 collateral, uint256 debt, uint16 ltBps)
        public
        pure
        returns (uint160)
    {
        if (collateral == 0 || debt == 0) revert ZeroAmount();
        if (ltBps == 0 || ltBps > BPS) revert LtOutOfRange();

        // priceX128 = P_liq * 2^128, computed with a 512-bit intermediate.
        //  collateral=token0: LTV = D / (C * P)  -> P_liq = D * 1e4 / (lt * C)
        //  collateral=token1: LTV = D * P / C    -> P_liq = lt * C / (1e4 * D)
        uint256 priceX128 = collateralIs0
            ? FullMath.mulDiv(debt * BPS, 1 << 128, uint256(ltBps) * collateral)
            : FullMath.mulDiv(uint256(ltBps) * collateral, 1 << 128, debt * BPS);

        // sqrt(P * 2^128) = sqrt(P) * 2^64; shift 32 more for Q96.
        uint256 sqrtPX96 = FixedPointMathLib.sqrt(priceX128) << 32;

        // Clamp into the representable tick range.
        if (sqrtPX96 <= TickMath.MIN_SQRT_PRICE) sqrtPX96 = TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPX96 >= TickMath.MAX_SQRT_PRICE) sqrtPX96 = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sqrtPX96);
    }

    /// @notice Full liquidation range as ticks aligned to the pool's tickSpacing.
    /// tickStart is rounded in the direction that triggers liquidation EARLIER
    /// (conservative for the lender); tickEnd extends `rangeWidth` ticks further
    /// into the adverse direction.
    function liquidationRange(
        bool collateralIs0,
        uint256 collateral,
        uint256 debt,
        uint16 ltBps,
        int24 rangeWidth,
        int24 tickSpacing
    ) public pure returns (int24 tickStart, int24 tickEnd) {
        uint160 sqrtP = liquidationSqrtPriceX96(collateralIs0, collateral, debt, ltBps);
        int24 raw = TickMath.getTickAtSqrtPrice(sqrtP);

        if (collateralIs0) {
            // Danger below spot: entered as tick falls. Earlier trigger = higher tick.
            tickStart = _alignUp(raw, tickSpacing);
            tickEnd = _alignDown(tickStart - rangeWidth, tickSpacing);
        } else {
            // Danger above spot: entered as tick rises. Earlier trigger = lower tick.
            tickStart = _alignDown(raw, tickSpacing);
            tickEnd = _alignUp(tickStart + rangeWidth, tickSpacing);
        }
        tickStart = _clampToSpacing(tickStart, tickSpacing);
        tickEnd = _clampToSpacing(tickEnd, tickSpacing);
    }

    /// @notice Whether `tick` is inside the liquidation range.
    function inRange(bool collateralIs0, int24 tick, int24 tickStart, int24 tickEnd) internal pure returns (bool) {
        return collateralIs0 ? (tick <= tickStart && tick >= tickEnd) : (tick >= tickStart && tick <= tickEnd);
    }

    /// @notice Whether `tick` is past the far edge of the range (range exhausted).
    function pastRange(bool collateralIs0, int24 tick, int24 tickEnd) internal pure returns (bool) {
        return collateralIs0 ? (tick < tickEnd) : (tick > tickEnd);
    }

    /// @notice Depth into the range in bps (0 at tickStart, 10_000 at tickEnd).
    function depthBps(bool collateralIs0, int24 tick, int24 tickStart, int24 tickEnd) public pure returns (uint256) {
        if (!inRange(collateralIs0, tick, tickStart, tickEnd)) {
            return pastRange(collateralIs0, tick, tickEnd) ? BPS : 0;
        }
        int24 width = collateralIs0 ? tickStart - tickEnd : tickEnd - tickStart;
        if (width == 0) return BPS;
        int24 depth = collateralIs0 ? tickStart - tick : tick - tickStart;
        return FullMath.mulDiv(uint256(uint24(depth)), BPS, uint256(uint24(width)));
    }

    /// @notice Value of `amount` of one currency in units of the other, at sqrtPriceX96.
    /// @param zeroForOne true: token0 amount -> token1 value; false: token1 -> token0.
    function convertAtSqrtPrice(uint256 amount, uint160 sqrtPriceX96, bool zeroForOne) public pure returns (uint256) {
        if (zeroForOne) {
            // amount * P = amount * (sqrtP/2^96)^2, in two mulDivs to avoid overflow
            return FullMath.mulDiv(FullMath.mulDiv(amount, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        }
        return FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// @notice Open-time check: the borrow/collateral LTV at `worstTick` must sit
    /// at or below headroom·LT (headroom in bps applied to LT), so interest accrual
    /// does not immediately erode a fresh position into its range.
    function openLtvOk(
        uint256 collateral,
        uint256 borrow,
        int24 worstTick,
        bool collateralIs0,
        uint16 ltBps,
        uint256 headroomBps
    ) public pure returns (bool) {
        uint256 collValueInDebt =
            convertAtSqrtPrice(collateral, TickMath.getSqrtPriceAtTick(worstTick), collateralIs0);
        return collValueInDebt != 0
            && FullMath.mulDiv(borrow, BPS * BPS, collValueInDebt) <= uint256(ltBps) * headroomBps;
    }

    /// @notice Force-close eligibility: 1 = range exhausted, 2 = term expired,
    /// 3 = health breached at the current price, 0 = none.
    ///
    /// Health breach: at the CURRENT price, remaining collateral (after a buffer)
    /// no longer covers the debt — interest erosion or a partial gap-through has
    /// made waiting strictly worse for lenders. The buffer is capped at half the
    /// position's own LT gap: a fixed buffer wider than (1 − LT) would preempt
    /// the entire gradual range for high-LT positions, since a position enters
    /// its range at LTV = LT by definition (parameter-model finding, PARAMETERS.md).
    function forceCloseReason(
        bool collateralIs0,
        int24 tick,
        int24 tickEnd,
        uint256 expiry,
        uint256 collateral,
        uint256 debt,
        uint16 ltBps,
        uint256 bufferBps
    ) public view returns (uint8) {
        if (pastRange(collateralIs0, tick, tickEnd)) return 1;
        if (block.timestamp > expiry) return 2;
        uint256 collValue = convertAtSqrtPrice(collateral, TickMath.getSqrtPriceAtTick(tick), collateralIs0);
        uint256 halfGap = (BPS - ltBps) / 2;
        if (bufferBps > halfGap) bufferBps = halfGap;
        if (FullMath.mulDiv(collValue, BPS - bufferBps, BPS) < debt) return 3;
        return 0;
    }

    /// @notice Token depth of `liquidity` spread across [tickA, tickB], measured
    /// in the collateral token's units. Rough but cheap and monotone — used for
    /// the chunk pressure metric and the per-chunk impact cap.
    function rangeDepthTokens(bool collateralIs0, int24 tickA, int24 tickB, uint128 liquidity)
        public
        pure
        returns (uint256)
    {
        if (liquidity == 0) return 0;
        (uint160 lo, uint160 hi) = tickA < tickB
            ? (TickMath.getSqrtPriceAtTick(tickA), TickMath.getSqrtPriceAtTick(tickB))
            : (TickMath.getSqrtPriceAtTick(tickB), TickMath.getSqrtPriceAtTick(tickA));
        return collateralIs0
            ? SqrtPriceMath.getAmount0Delta(lo, hi, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(lo, hi, liquidity, false);
    }

    function _alignUp(int24 tick, int24 spacing) private pure returns (int24) {
        int24 aligned = (tick / spacing) * spacing;
        if (aligned < tick) aligned += spacing; // works for negatives: -7/5*5 = -5 >= -7
        return aligned;
    }

    function _alignDown(int24 tick, int24 spacing) private pure returns (int24) {
        int24 aligned = (tick / spacing) * spacing;
        if (aligned > tick) aligned -= spacing;
        return aligned;
    }

    function _clampToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 maxUsable = (TickMath.MAX_TICK / spacing) * spacing;
        int24 minUsable = (TickMath.MIN_TICK / spacing) * spacing;
        if (tick > maxUsable) return maxUsable;
        if (tick < minUsable) return minUsable;
        return tick;
    }
}
