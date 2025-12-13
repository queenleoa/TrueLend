// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {TrueLendRouter} from "../src/TrueLendRouter.sol";

contract DiagnosticTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TrueLendHook hook;
    TrueLendRouter router;
    PoolKey poolKey;
    
    MockERC20 token0;
    MockERC20 token1;
    
    address alice = makeAddr("alice");
    
    function setUp() public {
        deployFreshManagerAndRouters();
        
        token0 = new MockERC20("Mock ETH", "mETH", 18);
        token1 = new MockERC20("Mock USDC", "mUSDC", 18);
        
        console.log("Initial token0 address:", address(token0));
        console.log("Initial token1 address:", address(token1));
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
            console.log("Tokens SWAPPED after sorting");
        }
        
        console.log("Final token0 address:", address(token0));
        console.log("Final token1 address:", address(token1));
        console.log("token0 name:", token0.name());
        console.log("token1 name:", token1.name());
        
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        
        deployCodeTo("TrueLendHook.sol", abi.encode(address(manager)), hookAddress);
        hook = TrueLendHook(hookAddress);
        
        router = new TrueLendRouter(address(hook));
        hook.setLendingRouter(address(router), true);
        
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        
        _addLiquidity();
        
        token0.mint(alice, 100 ether);
        token1.mint(alice, 1_000_000e18);
        token0.mint(address(hook), 100 ether);
        
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }
    
    function _addLiquidity() internal {
        // Use concentrated liquidity with enough depth
        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        
        // Tight range for initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
        
        // Wider range covering liquidation zone
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: 600,
                tickUpper: 99960,  // Aligned to tick spacing 60
                liquidityDelta: 200 ether,  // More depth
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }
    
    function test_DiagnoseTickCalculation() public {
        console.log("\n=== DIAGNOSTIC TEST ===\n");
        
        // Get initial pool state
        (uint160 sqrtPriceX96, int24 currentTick, , ) = manager.getSlot0(poolKey.toId());
        console.log("Initial sqrtPriceX96:", sqrtPriceX96);
        console.log("Initial currentTick:", currentTick);
        
        uint256 initialPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        console.log("Initial price (token1/token0):", initialPrice);
        
        vm.startPrank(alice);
        
        // Create position
        console.log("\n=== Creating Position ===");
        console.log("Collateral (token1): 4000e18");
        console.log("Debt (token0): 1 ether");
        console.log("LT: 90");
        
        bytes32 positionId = router.borrow(
            poolKey,
            4000e18,  // collateral
            1 ether,  // debt
            90        // LT
        );
        
        TrueLendHook.BorrowPosition memory pos = hook.getPosition(positionId);
        
        console.log("\n=== Position Created ===");
        console.log("Position tickLower:", pos.tickLower);
        console.log("Position tickUpper:", pos.tickUpper);
        console.log("Current tick:", currentTick);
        console.log("needsLiquidation:", pos.needsLiquidation);
        
        if (pos.tickLower <= currentTick) {
            console.log("WARNING: tickLower is BELOW or AT current tick!");
            console.log("This means liquidation would trigger immediately!");
        } else {
            console.log("OK: tickLower is above current tick");
            console.log("Ticks to liquidation:", uint256(int256(pos.tickLower - currentTick)));
        }
        
        // Calculate what the liquidation price should be
        uint256 expectedLiqPrice = (90 * 4000e18) / (1e18 * 100);
        console.log("\n=== Expected Liquidation ===");
        console.log("Expected liquidation price (token1/token0):", expectedLiqPrice);
        console.log("Price needs to increase by factor:", expectedLiqPrice / (initialPrice > 0 ? initialPrice : 1));
        
        vm.stopPrank();
    }
}
