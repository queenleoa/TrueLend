// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {TrueLendRouter} from "../src/TrueLendRouter.sol";

contract TrueLendTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TrueLendHook hook;
    TrueLendRouter router;
    PoolKey poolKey;
    
    MockERC20 token0; // ETH mock
    MockERC20 token1; // USDC mock
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    // We'll start at 1:1 and use swaps to move price to desired levels
    
    function setUp() public {
        // Deploy v4-core contracts
        deployFreshManagerAndRouters();
        
        // Deploy mock tokens
        token0 = new MockERC20("Mock ETH", "mETH", 18);
        token1 = new MockERC20("Mock USDC", "mUSDC", 18);
        
        // Ensure token0 < token1 (Uniswap requirement)
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Deploy hook to an address with the proper flags set
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);
        
        // Use deployCodeTo to deploy to the flag address (for testing)
        deployCodeTo("TrueLendHook.sol", abi.encode(address(manager)), hookAddress);
        hook = TrueLendHook(hookAddress);
        
        // Deploy router
        router = new TrueLendRouter(address(hook));
        
        // Approve router in hook
        hook.setLendingRouter(address(router), true);
        
        // Setup pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: hook
        });
        
        // Initialize pool at 1:1 price for simplicity
        // We can adjust price through swaps later if needed
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        
        // Add liquidity for testing
        _addLiquidity();
        
        // Mint tokens to test accounts
        token0.mint(alice, 100 ether);
        token1.mint(alice, 1_000_000e18);
        token0.mint(bob, 100 ether);
        token1.mint(bob, 1_000_000e18);
        
        // Approve hook for alice and bob
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
    
    function _addLiquidity() internal {
        // Add wide range liquidity for testing
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether); // Match token0 for 1:1 ratio
        
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        
        // Use a much smaller tick range to avoid extreme liquidity calculations
        int24 tickLower = -600; // ~0.95x to ~1.05x price range
        int24 tickUpper = 600;
        
        // Much smaller liquidity delta that's proportional to token amounts
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 10 ether, // Reasonable amount for 100 ether tokens
                salt: bytes32(0)
            }),
            ""
        );
    }
    
    /// @notice Test 1: No liquidation when price stays below threshold
    /// Starting at 1:1, small swaps keep price below liquidation threshold
    function test_NoLiquidation_PriceBelowThreshold() public {
        vm.startPrank(alice);
        
        // Create position: Borrow 1 ETH against 4000 USDC at 90% LT
        // Liquidation starts when collateral value < 90% of debt value
        bytes32 positionId = router.borrow(
            poolKey,
            4000e18, // collateral USDC
            1 ether,  // debt ETH
            90        // 90% LT
        );
        
        TrueLendHook.BorrowPosition memory posBefore = hook.getPosition(positionId);
        assertEq(posBefore.collateralRemaining, 4000e18, "Initial collateral incorrect");
        assertEq(posBefore.isActive, true, "Position should be active");
        assertEq(posBefore.needsLiquidation, false, "Should not need liquidation");
        
        vm.stopPrank();
        
        // Execute small swap as Bob (price remains safe)
        vm.startPrank(bob);
        
        // Small swap: buy some ETH with USDC
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // USDC → ETH (buying ETH)
                amountSpecified: -1000e18, // Exact input: 1000 USDC
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        vm.stopPrank();
        
        // Check position after swap
        TrueLendHook.BorrowPosition memory posAfter = hook.getPosition(positionId);
        
        // Assertions
        assertEq(posAfter.collateralRemaining, 4000e18, "Collateral should be untouched");
        assertEq(posAfter.debtRepaid, 0, "No debt should be repaid");
        assertEq(posAfter.isActive, true, "Position should still be active");
        assertEq(posAfter.needsLiquidation, false, "Should not need liquidation");
        
        console.log("Test 1 Passed: No liquidation when below threshold");
    }
    
    /// @notice Test 2: Partial liquidation when price enters liquidation range
    /// Larger swaps push price into liquidation territory, incremental liquidation occurs
    function test_PartialLiquidation_PriceEntersRange() public {
        vm.startPrank(alice);
        
        // Create position: same as test 1
        bytes32 positionId = router.borrow(
            poolKey,
            4000e18, // collateral USDC
            1 ether,  // debt ETH
            90        // 90% LT
        );
        
        vm.stopPrank();
        
        // Execute swap that pushes into liquidation range
        vm.startPrank(bob);
        
        // Larger swap to trigger liquidation
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // USDC → ETH
                amountSpecified: -5000e18, // 5000 USDC
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        // Check position after first swap
        TrueLendHook.BorrowPosition memory pos1 = hook.getPosition(positionId);
        assertEq(pos1.needsLiquidation, true, "Should be marked for liquidation");
        
        uint256 collateralAfterFirst = pos1.collateralRemaining;
        uint256 debtRepaidAfterFirst = pos1.debtRepaid;
        
        // Some liquidation should have occurred
        assertLt(collateralAfterFirst, 4000e18, "Some collateral should be liquidated");
        assertGt(debtRepaidAfterFirst, 0, "Some debt should be repaid");
        
        console.log("After first swap:");
        console.log("  Collateral remaining:", collateralAfterFirst);
        console.log("  Debt repaid:", debtRepaidAfterFirst);
        
        // Wait 1 minute (for time-based chunk calculation)
        vm.warp(block.timestamp + 61);
        
        // Execute another swap to trigger more liquidation
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1000e18, // Another 1000 USDC
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        vm.stopPrank();
        
        // Check position after second swap
        TrueLendHook.BorrowPosition memory pos2 = hook.getPosition(positionId);
        
        // More liquidation should have occurred
        assertLt(pos2.collateralRemaining, collateralAfterFirst, "More collateral liquidated");
        assertGt(pos2.debtRepaid, debtRepaidAfterFirst, "More debt repaid");
        assertEq(pos2.isActive, true, "Position should still be active");
        
        console.log("After second swap:");
        console.log("  Collateral remaining:", pos2.collateralRemaining);
        console.log("  Debt repaid:", pos2.debtRepaid);
        console.log("Test 2 Passed: Partial liquidation executed incrementally");
    }
    
    /// @notice Test 3: Full liquidation when price moves through entire range
    /// Multiple swaps push price high enough to liquidate all collateral
    function test_FullLiquidation_PriceThroughRange() public {
        vm.startPrank(alice);
        
        // Create position
        bytes32 positionId = router.borrow(
            poolKey,
            4000e18, // collateral USDC
            1 ether,  // debt ETH
            90        // 90% LT
        );
        
        vm.stopPrank();
        
        vm.startPrank(bob);
        
        // Execute multiple swaps to move price through entire liquidation range
        for (uint i = 0; i < 5; i++) {
            // Large swap
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -10000e18, // 10k USDC per swap
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                ""
            );
            
            // Wait between swaps for time-based chunks
            vm.warp(block.timestamp + 61);
            
            // Check if fully liquidated
            TrueLendHook.BorrowPosition memory pos = hook.getPosition(positionId);
            console.log("After swap", i + 1);
            console.log("  Collateral remaining:", pos.collateralRemaining);
            console.log("  Debt repaid:", pos.debtRepaid);
            console.log("  Is active:", pos.isActive);
            
            if (!pos.isActive) {
                console.log("Position fully liquidated after", i + 1, "swaps");
                break;
            }
        }
        
        vm.stopPrank();
        
        // Final position check
        TrueLendHook.BorrowPosition memory finalPos = hook.getPosition(positionId);
        
        // Position should be fully liquidated
        assertEq(finalPos.collateralRemaining, 0, "All collateral should be liquidated");
        assertEq(finalPos.isActive, false, "Position should be closed");
        assertGt(finalPos.debtRepaid, 0, "Debt should be substantially repaid");
        
        console.log("Final position state:");
        console.log("  Total collateral liquidated:", finalPos.collateralAmount);
        console.log("  Total debt repaid:", finalPos.debtRepaid);
        console.log("Test 3 Passed: Full liquidation completed");
    }
    
    /// @notice Helper to get current pool price
    function _getCurrentPrice() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        // price = (sqrtPriceX96 / 2^96)^2
        return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);
    }
}
