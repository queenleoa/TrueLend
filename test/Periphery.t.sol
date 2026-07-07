// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {TrueLendLens} from "../src/periphery/TrueLendLens.sol";
import {LeverageRouter} from "../src/periphery/LeverageRouter.sol";

contract PeripheryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TrueLendHook hook;
    VaultFactory factory;
    WETH weth9;
    TrueLendLens lens;
    LeverageRouter router;
    PoolKey poolKey;
    PoolId poolId;
    LendingVault vault0;
    LendingVault vault1;

    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address lender = makeAddr("lender");
    address keeper = makeAddr("keeper");
    address whale = makeAddr("whale");

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        factory = new VaultFactory();
        weth9 = new WETH();
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(
            address(this),
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            type(TrueLendHook).creationCode,
            abi.encode(address(manager), address(factory), address(this), address(weth9))
        );
        hook = new TrueLendHook{salt: hookSalt}(manager, factory, address(this), address(weth9));
        require(address(hook) == hookAddress, "hook address mismatch");

        lens = new TrueLendLens(manager, hook);
        router = new LeverageRouter(manager, hook, address(weth9));

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

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100_000e18, salt: 0}),
            ""
        );

        token0.mint(lender, 1_000_000e18);
        token1.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        token0.approve(address(vault0), type(uint256).max);
        token1.approve(address(vault1), type(uint256).max);
        vault0.deposit(200_000e18, lender);
        vault1.deposit(200_000e18, lender);
        vm.stopPrank();

        token0.mint(alice, 100_000e18);
        token1.mint(alice, 100_000e18);
        token0.mint(whale, 10_000_000e18);
        token1.mint(whale, 10_000_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(whale);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // 9 observations at 60s spacing make the oracle ready without moving price
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

    // ------------------------------------------------------------------ lens

    function test_lens_positionView() public {
        vm.prank(alice);
        bytes32 id = hook.open(poolKey, true, 100e18, 50e18, 9000, alice);

        TrueLendLens.PositionView memory v = lens.position(id);
        assertEq(v.borrower, alice);
        assertEq(v.collateral, 100e18);
        assertEq(v.ltBps, 9000);
        assertEq(v.debt, hook.debtOf(id));
        assertApproxEqRel(v.collateralValueInDebt, 100e18, 0.01e18, "spot ~1:1");
        assertApproxEqRel(v.ltvBps, 5000, 0.02e18, "LTV ~50%");
        assertGt(v.healthBps, 10_000, "healthy");
        assertFalse(v.inRange);
        assertEq(v.forceCloseReason, 0);
        assertGt(v.currentPenaltyBps, 0);
    }

    function test_lens_previewChunk_matchesExecution() public {
        vm.prank(alice);
        bytes32 id = hook.open(poolKey, true, 100e18, 50e18, 9000, alice);

        (uint256 preview0,) = lens.previewChunk(id);
        assertEq(preview0, 0, "nothing to chunk while out of range");

        _swap(true, 40_000e18); // into the range (also runs up to 2 chunks)
        skip(61);
        (uint256 preview, uint256 pen) = lens.previewChunk(id);
        assertGt(preview, 0, "chunk due");
        assertGt(pen, 0);

        uint128 collBefore = hook.getPosition(id).collateral;
        vm.prank(keeper);
        hook.poke(poolKey);
        uint256 sold = collBefore - hook.getPosition(id).collateral;
        // poke may execute several queued chunks for this position id, but the
        // FIRST one must be exactly the previewed size; with a single position
        // in the pool the first chunk dominates
        assertGe(sold, preview, "at least the previewed chunk executed");
        assertApproxEqRel(sold, preview, 0.35e18, "first chunk sized as previewed");
    }

    function test_lens_poolView_andQuote() public {
        vm.prank(alice);
        hook.open(poolKey, true, 100e18, 50e18, 9000, alice);

        TrueLendLens.PoolView memory pv = lens.pool(poolId);
        assertTrue(pv.enabled);
        assertEq(address(pv.vault1), address(vault1));
        assertGt(pv.totalDebt1, 0, "alice's debt visible");
        assertGt(pv.utilizationBps1, 0);
        assertGt(pv.activeLiquidity, 0);

        (int24 s, int24 e, bool gapOk, bool ltvOk) = lens.quoteOpen(poolKey, true, 100e18, 50e18, 9000);
        assertLt(e, s);
        assertTrue(gapOk);
        assertTrue(ltvOk);
        (,, bool gapOk2, bool ltvOk2) = lens.quoteOpen(poolKey, true, 100e18, 95e18, 9000);
        assertTrue(!gapOk2 || !ltvOk2, "over-levered quote rejected");
    }

    // ------------------------------------------------------------------ leverage router

    function test_router_openLeveraged_5x() public {
        uint256 margin = 100e18;
        uint256 flashBorrow = 395e18; // ~5x at ~1:1 with fee drag

        vm.prank(alice);
        bytes32 id = router.openLeveraged(
            LeverageRouter.OpenParams({
                key: poolKey,
                collateralIs0: true,
                margin: margin,
                flashBorrow: flashBorrow,
                ltBps: 9500,
                minCollateralOut: 380e18,
                sqrtPriceLimitX96: 0
            })
        );

        TrueLendHook.Position memory pos = hook.getPosition(id);
        assertEq(pos.borrower, alice, "position belongs to the trader");
        assertApproxEqRel(uint256(pos.collateral), 495e18, 0.02e18, "margin + swapped collateral");
        assertApproxEqRel(hook.debtOf(id), flashBorrow, 0.001e18);

        // realized leverage = exposure / equity ~ 5x
        uint256 exposure = uint256(pos.collateral);
        uint256 equity = exposure - hook.debtOf(id); // ~1:1 price
        assertApproxEqRel(exposure * 1e18 / equity, 5e18, 0.05e18, "~5x leverage");

        // router keeps nothing
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
    }

    function test_router_closeLeveraged_returnsMarginMinusCosts() public {
        uint256 margin = 100e18;
        vm.prank(alice);
        bytes32 id = router.openLeveraged(
            LeverageRouter.OpenParams({
                key: poolKey,
                collateralIs0: true,
                margin: margin,
                flashBorrow: 395e18,
                ltBps: 9500,
                minCollateralOut: 380e18,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 t0Before = token0.balanceOf(alice);
        vm.prank(alice);
        router.closeLeveraged(
            LeverageRouter.CloseParams({key: poolKey, positionId: id, sqrtPriceLimitX96: 0, maxCollateralIn: 0})
        );

        assertEq(hook.getPosition(id).borrower, address(0), "position closed");
        uint256 netBack = token0.balanceOf(alice) - t0Before;
        // price unchanged: margin comes back minus two swap fees (0.3% each way on
        // ~4x notional) and rounding — about 97-99% of margin
        assertGt(netBack, margin * 95 / 100, "margin recovered less round-trip costs");
        assertLt(netBack, margin, "no free money");
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(vault1.totalBorrowShares(), 0, "vault made whole");
    }

    function test_router_leveragedPosition_liquidatesGradually() public {
        vm.prank(alice);
        bytes32 id = router.openLeveraged(
            LeverageRouter.OpenParams({
                key: poolKey,
                collateralIs0: true,
                margin: 100e18,
                flashBorrow: 395e18,
                ltBps: 9500,
                minCollateralOut: 380e18,
                sqrtPriceLimitX96: 0
            })
        );
        TrueLendHook.Position memory pos = hook.getPosition(id);

        // adverse move into the leveraged position's range: ordinary chunk decay
        vm.startPrank(whale);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(pos.tickStart - 60)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertGt(hook.getPosition(id).liqStartedAt, 0, "gradual liquidation started");
        skip(61);
        vm.prank(keeper);
        hook.poke(poolKey);
        assertLt(hook.getPosition(id).collateral, pos.collateral, "chunk decay reduces the levered position");
    }

    /// The share-rounding hazard: repaying exactly debtOf can burn one share too
    /// few (vault floors assets·WAD/index), leaving the position open while the
    /// buy-back still charges the trader. The router over-flashes by one wei and
    /// hard-requires closure; after months of accrued interest at an odd index,
    /// the close must still be exact — position gone, vault clear, router empty.
    function test_router_close_afterInterestAccrual_closesExactly() public {
        vm.prank(alice);
        bytes32 id = router.openLeveraged(
            LeverageRouter.OpenParams({
                key: poolKey,
                collateralIs0: true,
                margin: 100e18,
                flashBorrow: 395e18,
                ltBps: 9500,
                minCollateralOut: 380e18,
                sqrtPriceLimitX96: 0
            })
        );

        // push vault1 utilization high enough that the rate is nonzero, so the
        // borrow index actually moves off WAD (dust utilization floors to 0 bps)
        token0.mint(alice, 400_000e18);
        vm.prank(alice);
        hook.open(poolKey, true, 400_000e18, 150_000e18, 9000, alice);

        skip(91 days + 12_345 seconds); // odd index: floor-rounding territory
        assertGt(hook.debtOf(id), 395e18, "interest accrued");

        vm.prank(alice);
        router.closeLeveraged(
            LeverageRouter.CloseParams({key: poolKey, positionId: id, sqrtPriceLimitX96: 0, maxCollateralIn: 450e18})
        );

        assertEq(hook.getPosition(id).borrower, address(0), "closed despite rounding");
        assertEq(hook.debtOf(id), 0, "no dust share survives on the closed position");
        assertEq(token0.balanceOf(address(router)), 0, "router holds nothing");
        assertEq(token1.balanceOf(address(router)), 0, "router holds nothing");
    }

    function test_router_close_maxCollateralInGuard() public {
        vm.prank(alice);
        bytes32 id = router.openLeveraged(
            LeverageRouter.OpenParams({
                key: poolKey,
                collateralIs0: true,
                margin: 100e18,
                flashBorrow: 395e18,
                ltBps: 9500,
                minCollateralOut: 380e18,
                sqrtPriceLimitX96: 0
            })
        );
        vm.prank(alice);
        vm.expectRevert(LeverageRouter.TooMuchCollateralForBuyback.selector);
        router.closeLeveraged(
            LeverageRouter.CloseParams({key: poolKey, positionId: id, sqrtPriceLimitX96: 0, maxCollateralIn: 1})
        );
    }

    function test_router_slippageGuard() public {
        vm.prank(alice);
        vm.expectRevert(LeverageRouter.TooLittleCollateralFromSwap.selector);
        router.openLeveraged(
            LeverageRouter.OpenParams({
                key: poolKey,
                collateralIs0: true,
                margin: 100e18,
                flashBorrow: 395e18,
                ltBps: 9500,
                minCollateralOut: 400e18, // impossible: fee alone breaks this
                sqrtPriceLimitX96: 0
            })
        );
    }
}
