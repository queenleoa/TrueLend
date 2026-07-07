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
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// Native-ETH pool lifecycle: the native side is bridged to WETH at the hook
/// boundary — vaults hold WETH, payouts are WETH (no receive() DoS surface),
/// open/repay accept raw ETH via msg.value, and chunk settlement unwraps/wraps
/// against the PoolManager.
contract NativePoolTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TrueLendHook hook;
    WETH weth9;
    PoolKey poolKey;
    PoolId poolId;
    LendingVault vaultNative; // vault0: lends the native side (as WETH)
    LendingVault vault1;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address lender = makeAddr("lender");
    address keeper = makeAddr("keeper");
    address whale = makeAddr("whale");

    function setUp() public {
        deployFreshManagerAndRouters();
        weth9 = new WETH();
        token1 = new MockERC20("USD", "USD", 18);

        VaultFactory factory = new VaultFactory();
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            type(TrueLendHook).creationCode,
            abi.encode(address(manager), address(factory), address(this), address(weth9))
        );
        hook = new TrueLendHook{salt: salt}(manager, factory, address(this), address(weth9));
        require(address(hook) == hookAddress, "mismatch");

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // native ETH
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        poolId = poolKey.toId();
        (vaultNative, vault1,,) = hook.getPool(poolId);
        assertEq(address(vaultNative.asset()), address(weth9), "native vault holds WETH");

        // full-range liquidity, native side paid as msg.value
        token1.mint(address(this), 1_000_000e18);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 500_000e18);
        modifyLiquidityRouter.modifyLiquidity{value: 110_000e18}(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100_000e18, salt: 0}),
            ""
        );

        // lenders fund both vaults (native side deposited as WETH)
        vm.deal(lender, 300_000e18);
        token1.mint(lender, 300_000e18);
        vm.startPrank(lender);
        weth9.deposit{value: 200_000e18}();
        weth9.approve(address(vaultNative), type(uint256).max);
        vaultNative.deposit(200_000e18, lender);
        token1.approve(address(vault1), type(uint256).max);
        vault1.deposit(200_000e18, lender);
        vm.stopPrank();

        // actors
        vm.deal(alice, 1_000e18);
        vm.deal(whale, 5_000_000e18);
        token1.mint(whale, 5_000_000e18);
        vm.startPrank(whale);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(alice);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        _warmOracle();
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(whale);
        swapRouter.swap{value: zeroForOne ? amountIn : 0}(
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

    function _warmOracle() internal {
        for (uint256 i = 0; i < 9; i++) {
            skip(61);
            _swap(true, 1e15);
            _swap(false, 1e15);
        }
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    /// Full lifecycle with NATIVE collateral: payable open, chunked decay through
    /// the unwrap/settle path, WETH collateral returned on full repay.
    function test_native_collateral_lifecycle() public {
        // alice: 100 native ETH collateral via msg.value, borrows 50 token1, LT 90
        vm.prank(alice);
        bytes32 id = hook.open{value: 100e18}(poolKey, true, 100e18, 50e18, 9000, alice);
        assertEq(weth9.balanceOf(address(hook)), 100e18, "collateral custodied as WETH");
        assertEq(token1.balanceOf(alice), 50e18, "borrowed token1 received");

        // price falls into the range -> chunk executes (WETH unwrap -> native settle)
        _swap(true, 40_000e18);
        TrueLendHook.Position memory pos = hook.getPosition(id);
        assertGt(pos.liqStartedAt, 0, "liquidation started");
        assertLt(pos.collateral, 100e18, "chunk sold");
        assertLt(hook.debtOf(id), 50e18, "debt repaid by chunk");

        // recovery, then full repay: WETH collateral comes back (never raw ETH)
        _swap(false, 45_000e18);
        uint256 debt = hook.debtOf(id);
        token1.mint(alice, 5e18); // cover the repay margin over the borrowed 50
        vm.prank(alice);
        hook.repay(id, debt + 1e18);
        assertEq(hook.getPosition(id).borrower, address(0), "closed");
        assertGt(weth9.balanceOf(alice), 90e18, "collateral returned as WETH");
    }

    /// Borrowing the NATIVE side: debt disbursed as WETH, repayable with raw ETH
    /// via msg.value, chunk proceeds wrap-on-take into the WETH vault.
    function test_native_debt_lifecycle() public {
        // alice: 100 token1 collateral, borrows 50 of the native side
        token1.mint(alice, 100e18);
        vm.prank(alice);
        bytes32 id = hook.open(poolKey, false, 100e18, 50e18, 9000, alice);
        assertEq(weth9.balanceOf(alice), 50e18, "native debt disbursed as WETH");

        // repay part of it with raw ETH via msg.value
        vm.prank(alice);
        hook.repay{value: 20e18}(id, 20e18);
        assertApproxEqAbs(hook.debtOf(id), 30e18, 1e15, "native repay accepted");

        // adverse move (price of token1-collateral falls = tick rises), decay fires
        _swap(false, 40_000e18);
        TrueLendHook.Position memory pos = hook.getPosition(id);
        assertGt(pos.liqStartedAt, 0, "liquidation started");
        assertLt(pos.collateral, 100e18, "chunk sold; proceeds wrapped to WETH vault");

        // wrong-side native repay is rejected... (collateral side is token1 here,
        // debt side IS native, so value+mismatched amount must revert)
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.NativeValueMismatch.selector);
        hook.repay{value: 1e18}(id, 2e18);
    }

    /// msg.value on an ERC20-collateral open must revert rather than strand ETH.
    function test_native_valueMismatchReverts() public {
        token1.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(TrueLendHook.NativeValueMismatch.selector);
        hook.open{value: 1e18}(poolKey, false, 100e18, 50e18, 9000, alice);
    }

    /// forceClose on expiry works through the native settle path end to end.
    function test_native_forceClose_expiry() public {
        vm.prank(alice);
        bytes32 id = hook.open{value: 100e18}(poolKey, true, 100e18, 50e18, 9000, alice);
        skip(181 days);
        assertEq(hook.forceCloseReason(id), 2);
        vm.prank(keeper);
        hook.forceClose(id);
        assertEq(hook.getPosition(id).borrower, address(0), "closed");
        assertGt(token1.balanceOf(keeper), 0, "keeper rewarded");
        assertGt(token1.balanceOf(alice), 50e18, "surplus to borrower");
    }
}
