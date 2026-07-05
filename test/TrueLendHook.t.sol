// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {TrueLendHook} from "../src/TrueLendHook.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LiqRangeMath} from "../src/libraries/LiqRangeMath.sol";

contract TrueLendHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TrueLendHook hook;
    VaultFactory factory;
    PoolKey poolKey;
    PoolId poolId;
    LendingVault vault0;
    LendingVault vault1;

    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice"); // borrower
    address bob = makeAddr("bob"); // second borrower
    address lender = makeAddr("lender");
    address keeper = makeAddr("keeper");
    address whale = makeAddr("whale"); // price mover

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        factory = new VaultFactory();
        // mine + CREATE2, exactly like production deployment (links libraries)
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(
            address(this),
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            type(TrueLendHook).creationCode,
            abi.encode(address(manager), address(factory))
        );
        hook = new TrueLendHook{salt: hookSalt}(manager, factory);
        require(address(hook) == hookAddress, "hook address mismatch");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        poolId = poolKey.toId();
        (vault0, vault1,,) = hook.getPool(poolId);

        // deep full-range liquidity so swap behavior is predictable
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100_000e18, salt: 0}),
            ""
        );

        // lenders fund both vaults
        token0.mint(lender, 1_000_000e18);
        token1.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        token0.approve(address(vault0), type(uint256).max);
        token1.approve(address(vault1), type(uint256).max);
        vault0.deposit(200_000e18, lender);
        vault1.deposit(200_000e18, lender);
        vm.stopPrank();

        // borrowers & whale
        for (uint256 i = 0; i < 3; i++) {
            address user = [alice, bob, whale][i];
            token0.mint(user, 100_000e18);
            token1.mint(user, 100_000e18);
            vm.startPrank(user);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            token0.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        token0.mint(whale, 10_000_000e18);
        token1.mint(whale, 10_000_000e18);

        _warmOracle();
    }

    // ------------------------------------------------------------------ helpers

    /// 9 observations at 60s spacing make the oracle ready without moving price.
    function _warmOracle() internal {
        for (uint256 i = 0; i < 9; i++) {
            skip(61);
            _swap(true, 1e15);
            _swap(false, 1e15);
        }
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(whale);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    /// Standard test position: 100 token0 collateral, 50 token1 debt, LT 90%.
    /// Liquidation starts near tick -5878 (price ~0.556), range ends ~3466 lower.
    function _openDefault() internal returns (bytes32 id) {
        vm.prank(alice);
        id = hook.open(poolKey, true, 100e18, 50e18, 9000);
    }

    // ------------------------------------------------------------------ open

    function test_open_happyPath() public {
        uint256 aliceT1Before = token1.balanceOf(alice);
        bytes32 id = _openDefault();

        TrueLendHook.Position memory pos = hook.getPosition(id);
        assertEq(pos.borrower, alice);
        assertEq(pos.collateral, 100e18);
        assertTrue(pos.collateralIs0);
        assertEq(pos.ltBps, 9000);
        assertEq(token1.balanceOf(alice) - aliceT1Before, 50e18, "borrowed funds received");
        assertEq(token0.balanceOf(address(hook)), 100e18, "collateral held by hook");

        // liquidation range: below spot, aligned, ~sqrt(2) wide
        assertLt(pos.tickStart, _tick());
        assertLt(pos.tickEnd, pos.tickStart);
        assertEq(pos.tickStart % 60, 0);
        assertApproxEqAbs(pos.tickStart - pos.tickEnd, 3466, 120);
        // trigger tick sits at the LT price: debt / (lt * collateral) = 0.5556
        uint256 collValueAtStart =
            LiqRangeMath.convertAtSqrtPrice(100e18, TickMath.getSqrtPriceAtTick(pos.tickStart), true);
        assertApproxEqRel(collValueAtStart, uint256(50e18) * 10_000 / 9000, 0.01e18);

        assertApproxEqAbs(hook.debtOf(id), 50e18, 1e15);
        assertApproxEqAbs(vault1.utilizationBps(), 2, 1); // 50 borrowed of 200k deposited
    }

    /// The headline feature: LT 99% works. The borrower takes ~94% LTV, gets
    /// liquidation-triggered by a ~2% adverse move, decays gradually instead of
    /// being wiped, and recovers fully when price comes back.
    function test_open_lt99_maxLeverage() public {
        // 100 collateral, 93.5 debt: LTV 93.5% <= 95% of LT 99%
        vm.prank(alice);
        bytes32 id = hook.open(poolKey, true, 100e18, 93.5e18, 9900);

        TrueLendHook.Position memory pos = hook.getPosition(id);
        // liquidation starts ~5.6% below spot (943 -> tick ~ -540 after alignment)
        assertGt(pos.tickStart, -700);
        assertLt(pos.tickStart, -300);

        // ...but one notch above the headroom cap is rejected
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.LtvTooHigh.selector);
        hook.open(poolKey, true, 100e18, 95e18, 9900);

        // a ~7% adverse move starts the (gradual!) liquidation
        _swap(true, 4_000e18);
        pos = hook.getPosition(id);
        assertGt(pos.liqStartedAt, 0, "liquidation started fast at LT99");
        assertGt(pos.collateral, 95e18, "but only a paced chunk sold, no wipeout");
        assertLt(hook.debtOf(id), 93.5e18, "chunk already deleveraged the debt");

        // price recovers: the position survives with almost all collateral
        skip(61);
        _swap(false, 4_500e18);
        pos = hook.getPosition(id);
        assertEq(pos.liqStartedAt, 0, "paused on recovery");
        assertGt(pos.collateral, 90e18);

        // borrower can walk away whole by repaying
        uint256 debt = hook.debtOf(id);
        vm.prank(alice);
        hook.repay(id, debt + 1e18);
        assertEq(hook.getPosition(id).borrower, address(0), "closed");
        assertGt(token0.balanceOf(alice), 100_000e18 - 10e18, "collateral (minus decay) back");
    }

    function test_open_bothDirections() public {
        vm.prank(alice);
        bytes32 id = hook.open(poolKey, false, 100e18, 50e18, 9000);
        TrueLendHook.Position memory pos = hook.getPosition(id);
        // collateral = token1: danger is above spot
        assertGt(pos.tickStart, _tick());
        assertGt(pos.tickEnd, pos.tickStart);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 100e18);
    }

    function test_open_reverts() public {
        // LTV above headroom (95% of LT): 86 > 0.95*90
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.LtvTooHigh.selector);
        hook.open(poolKey, true, 100e18, 86e18, 9000);

        // LT bounds
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.LtOutOfBounds.selector);
        hook.open(poolKey, true, 100e18, 10e18, 4999);
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.LtOutOfBounds.selector);
        hook.open(poolKey, true, 100e18, 10e18, 9901);

        // zero amounts
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.AmountTooSmall.selector);
        hook.open(poolKey, true, 0, 10e18, 9000);

        // unknown pool
        PoolKey memory fake = poolKey;
        fake.fee = 500;
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.PoolNotEnabled.selector);
        hook.open(fake, true, 100e18, 10e18, 9000);
    }

    function test_open_blockedUntilOracleReady() public {
        // fresh second pool with a cold oracle
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        if (address(a) > address(b)) (a, b) = (b, a);
        PoolKey memory k2 = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(k2, SQRT_PRICE_1_1);

        a.mint(alice, 1000e18);
        vm.startPrank(alice);
        a.approve(address(hook), type(uint256).max);
        vm.expectRevert(TrueLendHook.OracleNotReady.selector);
        hook.open(k2, true, 100e18, 10e18, 9000);
        vm.stopPrank();
    }

    function test_open_rejectsNativePools() public {
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(); // NativeNotSupported, wrapped by the hook-call dispatcher
        manager.initialize(nativeKey, SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------ manipulation defense

    function test_open_manipulatedPriceDoesNotRaiseBorrowLimit() public {
        // pump token0's price ~25% in this block (median & extremes unaffected upward)
        _swap(false, 12_000e18);
        assertGt(_tick(), 2000); // spot pumped

        // at the pumped spot, 100 token0 is worth ~125 token1, so 86 would pass a
        // naive spot check (86/125 = 69% < 85.5%); the worse-of price says no.
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.LtvTooHigh.selector);
        hook.open(poolKey, true, 100e18, 86e18, 9000);
    }

    // ------------------------------------------------------------------ repay

    function test_repay_partial() public {
        bytes32 id = _openDefault();
        vm.prank(alice);
        hook.repay(id, 20e18);
        assertApproxEqAbs(hook.debtOf(id), 30e18, 1e15);
        assertEq(hook.getPosition(id).borrower, alice, "still open");
    }

    function test_repay_full_closesAndReturnsCollateral() public {
        bytes32 id = _openDefault();
        skip(30 days);
        uint256 debt = hook.debtOf(id);
        // utilization here is ~2bps so the integer-bps rate floors to zero;
        // meaningful-interest accrual is covered in LendingVault.t.sol
        assertGe(debt, 50e18);

        uint256 aliceT0Before = token0.balanceOf(alice);
        vm.prank(alice);
        hook.repay(id, debt + 1e18); // overpay; excess refunded

        assertEq(hook.getPosition(id).borrower, address(0), "closed");
        assertEq(token0.balanceOf(alice) - aliceT0Before, 100e18, "collateral returned");
        assertEq(hook.debtOf(id), 0);
        assertEq(vault1.totalBorrowShares(), 0);
    }

    function test_repay_byThirdParty_collateralGoesToBorrower() public {
        bytes32 id = _openDefault();
        uint256 debt = hook.debtOf(id);
        uint256 aliceT0Before = token0.balanceOf(alice);
        vm.startPrank(bob);
        token1.approve(address(hook), type(uint256).max);
        hook.repay(id, debt + 1e18);
        vm.stopPrank();
        assertEq(token0.balanceOf(alice) - aliceT0Before, 100e18, "collateral to borrower, not payer");
    }

    // ------------------------------------------------------------------ liquidation lifecycle

    function test_liquidation_startsAndChunksOnCrossing() public {
        bytes32 id = _openDefault();
        TrueLendHook.Position memory pos = hook.getPosition(id);

        // drive price into the range: sell token0 hard
        _swap(true, 40_000e18);
        assertLt(_tick(), pos.tickStart, "price entered the range");

        pos = hook.getPosition(id);
        assertGt(pos.liqStartedAt, 0, "liquidation started");
        assertLt(pos.collateral, 100e18, "first chunk executed in the same swap");
        assertGt(pos.collateral, 90e18, "...but only a small chunk (rate limited)");
        assertLt(hook.debtOf(id), 50e18, "chunk proceeds repaid debt");
        assertEq(hook.queueLength(poolId), 1);
    }

    function test_liquidation_penaltyDonatedToLPs() public {
        bytes32 id = _openDefault();
        (, uint256 feeGrowth1Before) = manager.getFeeGrowthGlobals(poolId);
        _swap(true, 40_000e18);
        // the chunk sold token0 for token1 and donated the penalty in token1
        (, uint256 feeGrowth1After) = manager.getFeeGrowthGlobals(poolId);
        assertGt(feeGrowth1After, feeGrowth1Before, "penalty flowed to in-range LPs");
        assertGt(hook.getPosition(id).liqStartedAt, 0);
    }

    function test_liquidation_decaysWithPokes() public {
        bytes32 id = _openDefault();
        _swap(true, 40_000e18);

        uint256 lastCollateral = hook.getPosition(id).collateral;
        for (uint256 i = 0; i < 5; i++) {
            skip(61);
            vm.prank(keeper);
            hook.poke(poolKey);
            uint256 nowCollateral = hook.getPosition(id).collateral;
            assertLt(nowCollateral, lastCollateral, "each poke decays the position");
            lastCollateral = nowCollateral;
        }
    }

    function test_liquidation_rateLimited_noDoubleChunkWithinInterval() public {
        bytes32 id = _openDefault();
        _swap(true, 40_000e18);
        uint256 collAfterFirst = hook.getPosition(id).collateral;

        // more swaps in the same block: no time elapsed, no further chunks
        _swap(true, 100e18);
        _swap(false, 100e18);
        assertEq(hook.getPosition(id).collateral, collAfterFirst, "chunk pacing respected");
    }

    function test_liquidation_pausesOnRecovery() public {
        bytes32 id = _openDefault();
        _swap(true, 40_000e18);
        assertGt(hook.getPosition(id).liqStartedAt, 0);

        // some time passes in liquidation, then price recovers above the range start
        skip(120);
        _swap(false, 45_000e18);
        TrueLendHook.Position memory pos = hook.getPosition(id);
        assertGt(_tick(), pos.tickStart);
        assertEq(pos.liqStartedAt, 0, "liquidation paused");
        assertGt(pos.timeInLiqAccrued, 0);

        // pokes do nothing while safe; queue drains lazily
        uint256 coll = pos.collateral;
        skip(120);
        vm.prank(keeper);
        hook.poke(poolKey);
        assertEq(hook.getPosition(id).collateral, coll, "no decay while out of range");
        assertEq(hook.queueLength(poolId), 0, "queue cleaned");

        // and resumes when it re-enters (recovery overshot upward, so this needs
        // to be large enough to bring the tick back below the range start)
        _swap(true, 52_000e18);
        skip(61);
        vm.prank(keeper);
        hook.poke(poolKey);
        assertLt(hook.getPosition(id).collateral, coll, "decay resumed");
    }

    function test_liquidation_quietMarket_pokeCatchesUp() public {
        bytes32 id = _openDefault();
        _swap(true, 40_000e18);
        uint256 coll1 = hook.getPosition(id).collateral;

        // no swaps for 10 minutes; a single poke catches up (time multiplier capped at 5x)
        skip(600);
        vm.prank(keeper);
        hook.poke(poolKey);
        uint256 sold1 = 100e18 - coll1; // first chunk size (1 interval)
        uint256 sold2 = coll1 - hook.getPosition(id).collateral;
        assertGt(sold2, sold1 * 3, "catch-up chunk is larger");
        assertLt(sold2, sold1 * 8, "...but capped");
    }

    function test_liquidation_fullDebtRepayment_closesAndReturnsRemainder() public {
        // faster decay for this test: 20 target chunks
        TrueLendHook.Config memory cfg = _cfg();
        cfg.targetChunks = 20;
        hook.setConfig(poolId, cfg);

        bytes32 id = _openDefault();
        _swap(true, 40_000e18);

        uint256 aliceT0Before = token0.balanceOf(alice);
        bool closed;
        for (uint256 i = 0; i < 200; i++) {
            skip(61);
            vm.prank(keeper);
            hook.poke(poolKey);
            if (hook.getPosition(id).borrower == address(0)) {
                closed = true;
                break;
            }
        }
        assertTrue(closed, "position closed by decay");
        assertEq(vault1.totalBorrowShares(), 0, "vault made whole");
        assertGt(token0.balanceOf(alice), aliceT0Before, "unsold collateral returned to borrower");
    }

    function test_multiplePositions_bothProcessed() public {
        bytes32 idA = _openDefault();
        vm.prank(bob);
        bytes32 idB = hook.open(poolKey, true, 200e18, 90e18, 8000);

        // deep enough to cross both range starts but stay INSIDE both ranges
        // (tick ~ -7570; ranges end near -9200/-9300)
        _swap(true, 46_000e18);
        skip(61);
        vm.prank(keeper);
        hook.poke(poolKey);

        assertLt(hook.getPosition(idA).collateral, 100e18, "position A decaying");
        assertLt(hook.getPosition(idB).collateral, 200e18, "position B decaying");
    }

    // ------------------------------------------------------------------ forceClose

    function test_forceClose_rangeExhausted_withBadDebtWaterfall() public {
        bytes32 id = _openDefault();
        TrueLendHook.Position memory pos = hook.getPosition(id);

        uint256 lenderValueBefore = vault1.convertToAssets(vault1.balanceOf(lender));

        // price gaps far beyond the range end in one swap
        _swap(true, 120_000e18);
        assertLt(_tick(), pos.tickEnd, "past the range");
        assertEq(hook.forceCloseReason(id), 1);

        uint256 keeperBefore = token1.balanceOf(keeper);
        vm.prank(keeper);
        hook.forceClose(id);

        assertEq(hook.getPosition(id).borrower, address(0), "closed");
        assertGt(token1.balanceOf(keeper), keeperBefore, "keeper rewarded");
        assertEq(vault1.totalBorrowShares(), 0, "debt fully accounted");
        // selling ~100 token0 at a crashed price cannot cover 50 token1 debt:
        // lenders take the post-reserve haircut
        uint256 lenderValueAfter = vault1.convertToAssets(vault1.balanceOf(lender));
        assertLt(lenderValueAfter, lenderValueBefore, "bad debt socialized after reserves");
    }

    function test_forceClose_expiry() public {
        bytes32 id = _openDefault();
        skip(181 days);
        assertEq(hook.forceCloseReason(id), 2);

        uint256 aliceT1Before = token1.balanceOf(alice);
        vm.prank(keeper);
        hook.forceClose(id);

        assertEq(hook.getPosition(id).borrower, address(0));
        assertEq(vault1.totalBorrowShares(), 0, "debt repaid in full");
        // healthy price: sale of 100 token0 (~100 token1) covers debt + interest;
        // surplus goes back to the borrower
        assertGt(token1.balanceOf(alice), aliceT1Before, "borrower got the surplus");
    }

    /// The "what if all LP liquidity is gone" case: forceClose must NOT fire-sale
    /// collateral into an empty book. With the slippage bound, nothing fills, the
    /// position survives intact, and the close succeeds once liquidity returns.
    function test_forceClose_drainedPool_noFireSale() public {
        bytes32 id = _openDefault();
        skip(181 days); // expiry makes it eligible without moving price
        assertEq(hook.forceCloseReason(id), 2);

        // LP pulls all liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -100_000e18, salt: 0}),
            ""
        );

        uint256 lenderValueBefore = vault1.convertToAssets(vault1.balanceOf(lender));
        vm.prank(keeper);
        hook.forceClose(id);

        // nothing filled: collateral intact, debt intact, no write-off
        TrueLendHook.Position memory pos = hook.getPosition(id);
        assertEq(pos.borrower, alice, "position still open");
        assertEq(pos.collateral, 100e18, "collateral NOT fire-sold");
        assertGt(pos.debtShares, 0);
        assertEq(vault1.totalUncoveredShortfall(), 0, "no bad debt booked");
        assertEq(vault1.convertToAssets(vault1.balanceOf(lender)), lenderValueBefore, "lenders unharmed");

        // liquidity returns -> retry closes cleanly
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100_000e18, salt: 0}),
            ""
        );
        vm.prank(keeper);
        hook.forceClose(id);
        assertEq(hook.getPosition(id).borrower, address(0), "closed on retry");
        assertEq(vault1.totalBorrowShares(), 0);
    }

    function test_forceClose_revertsWhenHealthy() public {
        bytes32 id = _openDefault();
        assertEq(hook.forceCloseReason(id), 0);
        vm.prank(keeper);
        vm.expectRevert(TrueLendHook.NotEligibleForForceClose.selector);
        hook.forceClose(id);
    }

    // ------------------------------------------------------------------ decimals

    function test_decimals_usdcWethPair() public {
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        bool wethIs0 = address(weth) < address(usdc);
        (MockERC20 t0, MockERC20 t1) = wethIs0 ? (weth, usdc) : (usdc, weth);

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        // price: 2500 USDC per WETH, in raw token1-per-token0 units
        uint256 ratioX128 = wethIs0 ? FullMath.mulDiv(2500e6, 1 << 128, 1e18) : FullMath.mulDiv(1e18, 1 << 128, 2500e6);
        uint160 sqrtP = uint160(FixedPointMathLib.sqrt(ratioX128) << 32);
        manager.initialize(k, sqrtP);

        // add liquidity around price and fund the USDC vault
        t0.mint(address(this), 1e40);
        t1.mint(address(this), 1e40);
        t0.approve(address(modifyLiquidityRouter), type(uint256).max);
        t1.approve(address(modifyLiquidityRouter), type(uint256).max);
        (, int24 tk,,) = manager.getSlot0(k.toId());
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: ((tk - 60_000) / 60) * 60,
                tickUpper: ((tk + 60_000) / 60) * 60,
                liquidityDelta: 1e21,
                salt: 0
            }),
            ""
        );
        (LendingVault v0, LendingVault v1,,) = hook.getPool(k.toId());
        LendingVault usdcVault = wethIs0 ? v1 : v0;
        usdc.mint(lender, 10_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcVault), type(uint256).max);
        usdcVault.deposit(1_000_000e6, lender);
        vm.stopPrank();

        // warm the oracle on this pool
        weth.mint(whale, 1e30);
        usdc.mint(whale, 1e30);
        vm.startPrank(whale);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 9; i++) {
            skip(61);
            swapRouter.swap(
                k,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: wethIs0 == (i % 2 == 0) ? -int256(1e14) : -int256(1e6),
                    sqrtPriceLimitX96: (i % 2 == 0) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        vm.stopPrank();

        // alice: 10 WETH collateral, borrow 12,500 USDC (50% LTV), LT 90%
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(hook), type(uint256).max);
        bytes32 id = hook.open(k, wethIs0, 10e18, 12_500e6, 9000);
        vm.stopPrank();

        // liquidation trigger sits at debt/(lt*coll) = $1,388.9 per WETH
        TrueLendHook.Position memory pos = hook.getPosition(id);
        uint256 wethValueAtStart =
            LiqRangeMath.convertAtSqrtPrice(1e18, TickMath.getSqrtPriceAtTick(pos.tickStart), wethIs0);
        assertApproxEqRel(wethValueAtStart, 1388.9e6, 0.01e18);

        // full repay round-trips collateral
        usdc.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hook), type(uint256).max);
        hook.repay(id, hook.debtOf(id) + 100e6);
        vm.stopPrank();
        assertEq(weth.balanceOf(alice), 10e18, "collateral returned");
    }

    // ------------------------------------------------------------------ config plumbing

    function _cfg() internal view returns (TrueLendHook.Config memory) {
        return hook.getConfig(poolId);
    }

    function test_config_onlyOwner() public {
        TrueLendHook.Config memory cfg = _cfg();
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.NotOwner.selector);
        hook.setConfig(poolId, cfg);
    }
}
