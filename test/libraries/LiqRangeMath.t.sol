// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiqRangeMath} from "../../src/libraries/LiqRangeMath.sol";

contract LiqRangeMathTest is Test {
    uint256 constant BPS = 10_000;

    // ---------------------------------------------------------------- known values

    /// 1 WETH (18d) collateral, 1800 USDC (6d) debt, LT 90% -> liquidation at $2,000.
    function test_liquidationPrice_ethCollateral_usdcDebt() public pure {
        // token0 = WETH, token1 = USDC (price = USDC per WETH)
        uint160 sqrtP = LiqRangeMath.liquidationSqrtPriceX96(true, 1e18, 1800e6, 9000);
        // value of 1 WETH at that price should be exactly debt/LT = 2000 USDC
        uint256 collValueInDebt = LiqRangeMath.convertAtSqrtPrice(1e18, sqrtP, true);
        assertApproxEqRel(collValueInDebt, 2000e6, 1e12); // 1e-6 rel tol
    }

    /// Mirror direction: 4000 USDC (token1) collateral, 1 WETH (token0) debt, LT 90%.
    /// Liquidation when WETH rises to 0.9 * 4000 = $3,600.
    function test_liquidationPrice_usdcCollateral_ethDebt() public pure {
        uint160 sqrtP = LiqRangeMath.liquidationSqrtPriceX96(false, 4000e6, 1e18, 9000);
        // at P_liq the debt's value equals lt * collateral: 1 WETH == 3600 USDC
        uint256 debtValueInColl = LiqRangeMath.convertAtSqrtPrice(1e18, sqrtP, true);
        assertApproxEqRel(debtValueInColl, 3600e6, 1e12);
    }

    /// Equal-decimals pair at LT 100%: liquidation price is exactly debt/collateral.
    function test_liquidationPrice_lt100() public pure {
        uint160 sqrtP = LiqRangeMath.liquidationSqrtPriceX96(true, 10e18, 5e18, 10_000);
        uint256 v = LiqRangeMath.convertAtSqrtPrice(10e18, sqrtP, true);
        assertApproxEqRel(v, 5e18, 1e12);
    }

    // ---------------------------------------------------------------- fuzz: defining property

    /// At the computed price, debt / collateralValue == LT (both directions).
    function testFuzz_liquidationPrice_definingProperty(
        bool collateralIs0,
        uint256 collateral,
        uint256 debt,
        uint16 ltBps
    ) public pure {
        collateral = bound(collateral, 1e6, 1e30);
        debt = bound(debt, 1e6, 1e30);
        ltBps = uint16(bound(ltBps, 500, 10_000));

        uint160 sqrtP = LiqRangeMath.liquidationSqrtPriceX96(collateralIs0, collateral, debt, ltBps);

        // collateral value measured in debt units at sqrtP
        uint256 collValue = LiqRangeMath.convertAtSqrtPrice(collateral, sqrtP, collateralIs0);
        vm.assume(collValue > 1e4); // avoid degenerate rounding at dust values

        uint256 ltvBps = FullMath.mulDiv(debt, BPS, collValue);
        assertApproxEqAbs(ltvBps, ltBps, 2); // within 2 bps (sqrt + division rounding)
    }

    function test_liquidationPrice_revertsOnZero() public {
        vm.expectRevert(LiqRangeMath.ZeroAmount.selector);
        this.callLiqPrice(true, 0, 1e18, 9000);
        vm.expectRevert(LiqRangeMath.ZeroAmount.selector);
        this.callLiqPrice(true, 1e18, 0, 9000);
        vm.expectRevert(LiqRangeMath.LtOutOfRange.selector);
        this.callLiqPrice(true, 1e18, 1e18, 0);
        vm.expectRevert(LiqRangeMath.LtOutOfRange.selector);
        this.callLiqPrice(true, 1e18, 1e18, 10_001);
    }

    function callLiqPrice(bool c0, uint256 c, uint256 d, uint16 lt) external pure returns (uint160) {
        return LiqRangeMath.liquidationSqrtPriceX96(c0, c, d, lt);
    }

    // ---------------------------------------------------------------- range geometry

    function testFuzz_range_alignmentAndDirection(
        bool collateralIs0,
        uint256 collateral,
        uint256 debt,
        uint16 ltBps,
        uint8 spacingChoice
    ) public pure {
        collateral = bound(collateral, 1e6, 1e30);
        debt = bound(debt, 1e6, 1e30);
        ltBps = uint16(bound(ltBps, 500, 10_000));
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        int24 spacing = spacings[spacingChoice % 4];
        int24 width = 3466;

        (int24 tickStart, int24 tickEnd) =
            LiqRangeMath.liquidationRange(collateralIs0, collateral, debt, ltBps, width, spacing);

        assertEq(tickStart % spacing, 0, "start aligned");
        assertEq(tickEnd % spacing, 0, "end aligned");
        if (collateralIs0) {
            assertLt(tickEnd, tickStart, "range extends downward");
        } else {
            assertGt(tickEnd, tickStart, "range extends upward");
        }
        assertLe(tickStart, TickMath.MAX_TICK);
        assertGe(tickStart, TickMath.MIN_TICK);
        assertLe(tickEnd, TickMath.MAX_TICK);
        assertGe(tickEnd, TickMath.MIN_TICK);
    }

    /// tickStart rounding is conservative: liquidation triggers no later than the
    /// exact threshold price in both directions.
    function testFuzz_range_conservativeRounding(uint256 collateral, uint256 debt, uint16 ltBps) public pure {
        collateral = bound(collateral, 1e6, 1e30);
        debt = bound(debt, 1e6, 1e30);
        ltBps = uint16(bound(ltBps, 500, 10_000));
        int24 spacing = 60;

        // collateral = token0: exact trigger tick may be between aligned ticks;
        // aligned start must be >= raw tick (triggers earlier as price falls).
        uint160 sqrtP = LiqRangeMath.liquidationSqrtPriceX96(true, collateral, debt, ltBps);
        int24 raw = TickMath.getTickAtSqrtPrice(sqrtP);
        (int24 s0,) = LiqRangeMath.liquidationRange(true, collateral, debt, ltBps, 3466, spacing);
        if (s0 < TickMath.MAX_TICK / spacing * spacing) assertGe(s0, raw);

        // collateral = token1: aligned start must be <= raw tick (earlier as price rises).
        sqrtP = LiqRangeMath.liquidationSqrtPriceX96(false, collateral, debt, ltBps);
        raw = TickMath.getTickAtSqrtPrice(sqrtP);
        (int24 s1,) = LiqRangeMath.liquidationRange(false, collateral, debt, ltBps, 3466, spacing);
        if (s1 > TickMath.MIN_TICK / spacing * spacing) assertLe(s1, raw);
    }

    // ---------------------------------------------------------------- inRange / depth

    function test_inRange_and_depth_directions() public pure {
        // collateral = token0: range [start=1000 .. end=-2000], entered going down
        assertFalse(LiqRangeMath.inRange(true, 1500, 1000, -2000)); // safe side
        assertTrue(LiqRangeMath.inRange(true, 1000, 1000, -2000)); // at start
        assertTrue(LiqRangeMath.inRange(true, -500, 1000, -2000)); // inside
        assertFalse(LiqRangeMath.inRange(true, -2500, 1000, -2000)); // past end
        assertTrue(LiqRangeMath.pastRange(true, -2500, -2000));

        assertEq(LiqRangeMath.depthBps(true, 1500, 1000, -2000), 0);
        assertEq(LiqRangeMath.depthBps(true, 1000, 1000, -2000), 0);
        assertEq(LiqRangeMath.depthBps(true, -500, 1000, -2000), 5000);
        assertEq(LiqRangeMath.depthBps(true, -2000, 1000, -2000), 10_000);
        assertEq(LiqRangeMath.depthBps(true, -9999, 1000, -2000), 10_000);

        // collateral = token1: range [start=1000 .. end=4000], entered going up
        assertFalse(LiqRangeMath.inRange(false, 500, 1000, 4000));
        assertTrue(LiqRangeMath.inRange(false, 2500, 1000, 4000));
        assertTrue(LiqRangeMath.pastRange(false, 4500, 4000));
        assertEq(LiqRangeMath.depthBps(false, 2500, 1000, 4000), 5000);
    }

    // ---------------------------------------------------------------- conversion helper

    function test_convert_identityAtPriceOne() public pure {
        uint160 one = uint160(1 << 96); // sqrt(1) in Q96
        assertEq(LiqRangeMath.convertAtSqrtPrice(123456789, one, true), 123456789);
        assertEq(LiqRangeMath.convertAtSqrtPrice(123456789, one, false), 123456789);
    }

    function testFuzz_convert_roundTrip(uint256 amount, uint256 priceSeed) public pure {
        amount = bound(amount, 1e12, 1e30);
        // sqrt prices across a wide but sane band: ticks -200k..200k
        int24 tick = int24(int256(bound(priceSeed, 0, 400_000))) - 200_000;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);

        uint256 there = LiqRangeMath.convertAtSqrtPrice(amount, sqrtP, true);
        vm.assume(there > 1e6); // skip precision-degenerate corner
        uint256 back = LiqRangeMath.convertAtSqrtPrice(there, sqrtP, false);
        // integer rounding loses ~1 unit of `there`; tolerance must scale with it
        uint256 relTol = 1e18 / there + 1e9; // 1/there relative, floor 1e-9
        assertApproxEqRel(back, amount, relTol);
    }
}
