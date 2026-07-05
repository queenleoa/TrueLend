// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LiqRangeMath} from "../src/libraries/LiqRangeMath.sol";

/// Random-walk driver: opens/repays/liquidates positions while price whipsaws.
contract Handler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;
    TrueLendHook immutable hook;
    PoolSwapTest immutable swapRouter;
    PoolKey poolKey;
    PoolId poolId;
    MockERC20 token0;
    MockERC20 token1;

    bytes32[] public allPositions;

    constructor(
        IPoolManager _manager,
        TrueLendHook _hook,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        MockERC20 _t0,
        MockERC20 _t1
    ) {
        manager = _manager;
        hook = _hook;
        swapRouter = _swapRouter;
        poolKey = _key;
        poolId = _key.toId();
        token0 = _t0;
        token1 = _t1;
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    function positionsCount() external view returns (uint256) {
        return allPositions.length;
    }

    // ---------------------------------------------------------------- actions

    function open(bool collateralIs0, uint256 collateral, uint256 ltvPct, uint256 ltSeed) external {
        collateral = bound(collateral, 1e18, 300e18);
        ltvPct = bound(ltvPct, 10, 75);
        uint16 ltBps = uint16(bound(ltSeed, 5000, 9900));

        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint256 collValue = LiqRangeMath.convertAtSqrtPrice(collateral, sqrtP, collateralIs0);
        uint256 borrow = collValue * ltvPct / 100;
        if (borrow == 0) return;

        token0.mint(address(this), collateral);
        token1.mint(address(this), collateral);
        try hook.open(poolKey, collateralIs0, collateral, borrow, ltBps) returns (bytes32 id) {
            allPositions.push(id);
        } catch {} // oracle-adverse pricing, gap, or headroom can reject: fine
    }

    function repay(uint256 idx, uint256 pct) external {
        if (allPositions.length == 0) return;
        bytes32 id = allPositions[bound(idx, 0, allPositions.length - 1)];
        uint256 debt = hook.debtOf(id);
        if (debt == 0) return;
        uint256 amount = debt * bound(pct, 10, 120) / 100; // sometimes overpay
        if (amount == 0) return;
        TrueLendHook.Position memory pos = hook.getPosition(id);
        MockERC20 debtToken = pos.collateralIs0 ? token1 : token0;
        debtToken.mint(address(this), amount);
        hook.repay(id, amount);
    }

    function swap(bool zeroForOne, uint256 amountIn) external {
        amountIn = bound(amountIn, 1e18, 30_000e18);
        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        tokenIn.mint(address(this), amountIn);
        try swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function warpAndPoke(uint256 dt) external {
        skip(bound(dt, 30, 900));
        hook.poke(poolKey);
    }

    function forceClose(uint256 idx) external {
        if (allPositions.length == 0) return;
        bytes32 id = allPositions[bound(idx, 0, allPositions.length - 1)];
        if (hook.forceCloseReason(id) == 0) return;
        hook.forceClose(id);
    }
}

contract TrueLendInvariantsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    TrueLendHook hook;
    Handler handler;
    PoolKey poolKey;
    PoolId poolId;
    LendingVault vault0;
    LendingVault vault1;
    MockERC20 token0;
    MockERC20 token1;
    address lender = makeAddr("lender");

    function setUp() public {
        deployFreshManagerAndRouters();
        token0 = new MockERC20("T0", "T0", 18);
        token1 = new MockERC20("T1", "T1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        VaultFactory factory = new VaultFactory();
        address hookAddress =
            address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("TrueLendHook.sol", abi.encode(address(manager), address(factory)), hookAddress);
        hook = TrueLendHook(hookAddress);

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

        token0.mint(address(this), 10_000_000e18);
        token1.mint(address(this), 10_000_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100_000e18, salt: 0}),
            ""
        );

        token0.mint(lender, 2_000_000e18);
        token1.mint(lender, 2_000_000e18);
        vm.startPrank(lender);
        token0.approve(address(vault0), type(uint256).max);
        token1.approve(address(vault1), type(uint256).max);
        vault0.deposit(500_000e18, lender);
        vault1.deposit(500_000e18, lender);
        vm.stopPrank();

        handler = new Handler(manager, hook, swapRouter, poolKey, token0, token1);

        // warm the oracle so the handler can open positions
        token0.mint(address(handler), 1e24);
        token1.mint(address(handler), 1e24);
        for (uint256 i = 0; i < 9; i++) {
            skip(61);
            handler.swap(true, 1e18);
            handler.swap(false, 1e18);
        }

        targetContract(address(handler));
    }

    /// The hook holds exactly the sum of open positions' collateral — nothing
    /// strands and nothing leaks, through any interleaving of actions.
    function invariant_hookHoldsExactlySumOfCollateral() public view {
        uint256 sum0;
        uint256 sum1;
        uint256 n = handler.positionsCount();
        for (uint256 i = 0; i < n; i++) {
            TrueLendHook.Position memory pos = hook.getPosition(handler.allPositions(i));
            if (pos.borrower == address(0)) continue;
            if (pos.collateralIs0) sum0 += pos.collateral;
            else sum1 += pos.collateral;
        }
        assertEq(token0.balanceOf(address(hook)), sum0, "token0 conservation");
        assertEq(token1.balanceOf(address(hook)), sum1, "token1 conservation");
    }

    /// Position debt shares always reconcile with vault totals.
    function invariant_debtSharesMatchVaults() public view {
        uint256 shares0; // debt in vault0 = positions with collateral1
        uint256 shares1;
        uint256 n = handler.positionsCount();
        for (uint256 i = 0; i < n; i++) {
            TrueLendHook.Position memory pos = hook.getPosition(handler.allPositions(i));
            if (pos.borrower == address(0)) continue;
            if (pos.collateralIs0) shares1 += pos.debtShares;
            else shares0 += pos.debtShares;
        }
        assertEq(vault0.totalBorrowShares(), shares0, "vault0 debt reconciles");
        assertEq(vault1.totalBorrowShares(), shares1, "vault1 debt reconciles");
    }

    /// Vault balances always cover tracked reserves (cash never goes phantom).
    function invariant_vaultBalancesCoverReserves() public view {
        assertGe(token0.balanceOf(address(vault0)), vault0.reserves());
        assertGe(token1.balanceOf(address(vault1)), vault1.reserves());
    }

    /// Utilization never exceeds the hard cap after any sequence.
    function invariant_utilizationWithinCap() public view {
        assertLe(vault0.utilizationBps(), 9001); // +1 bp rounding slack
        assertLe(vault1.utilizationBps(), 9001);
    }

    /// Lenders can only be pushed below principal by *uncovered* bad debt — the
    /// declared waterfall — never by any other action sequence. (Write-offs can
    /// happen on both the forceClose and the chunk-exhaustion paths; the vault
    /// tracks the lifetime uncovered shortfall.)
    function invariant_lenderLossOnlyFromUncoveredShortfall() public view {
        if (vault0.totalUncoveredShortfall() == 0) {
            assertGe(vault0.convertToAssets(vault0.balanceOf(lender)) + 2, 500_000e18);
        }
        if (vault1.totalUncoveredShortfall() == 0) {
            assertGe(vault1.convertToAssets(vault1.balanceOf(lender)) + 2, 500_000e18);
        }
    }
}
