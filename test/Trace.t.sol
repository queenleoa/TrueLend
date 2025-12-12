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

contract TraceTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TrueLendHook hook;
    TrueLendRouter router;
    PoolKey poolKey;
    
    MockERC20 token0;
    MockERC20 token1;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    function setUp() public {
        deployFreshManagerAndRouters();
        
        token0 = new MockERC20("Mock ETH", "mETH", 18);
        token1 = new MockERC20("Mock USDC", "mUSDC", 18);
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
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
        token0.mint(bob, 100 ether);
        token1.mint(bob, 1_000_000e18);
        token0.mint(address(hook), 100 ether);
        
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(bob);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
    
    function _addLiquidity() internal {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        
        int24 tickLower = -600;
        int24 tickUpper = 600;
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }
    
    function test_TraceSimpleSwapFirst() public {
        console.log("\n=== TRACE: Simple Swap Without Position ===\n");
        
        vm.startPrank(bob);
        
        console.log("Bob's token1 balance before:", token1.balanceOf(bob));
        console.log("Pool token1 balance before:", token1.balanceOf(address(manager)));
        
        try swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1000e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        ) {
            console.log("Simple swap SUCCESS");
            
            (uint160 sqrtPrice, int24 tick, , ) = manager.getSlot0(poolKey.toId());
            console.log("After swap - tick:", tick);
            console.log("After swap - sqrtPrice:", sqrtPrice);
        } catch Error(string memory reason) {
            console.log("Simple swap FAILED with:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Simple swap FAILED with low-level error");
            console.logBytes(lowLevelData);
        }
        
        vm.stopPrank();
    }
    
    function test_TracePositionCreation() public {
        console.log("\n=== TRACE: Position Creation ===\n");
        
        vm.startPrank(alice);
        
        console.log("Alice token1 balance:", token1.balanceOf(alice));
        console.log("Router token1 allowance:", token1.allowance(alice, address(router)));
        console.log("Hook token0 balance:", token0.balanceOf(address(hook)));
        
        try router.borrow(
            poolKey,
            4000e18,
            1 ether,
            90
        ) returns (bytes32 positionId) {
            console.log("Position created SUCCESS");
            console.logBytes32(positionId);
            
            TrueLendHook.BorrowPosition memory pos = hook.getPosition(positionId);
            console.log("Position tickLower:", pos.tickLower);
            console.log("Position collateral:", pos.collateralRemaining);
            console.log("Hook token1 balance after:", token1.balanceOf(address(hook)));
            console.log("Alice token0 balance after:", token0.balanceOf(alice));
        } catch Error(string memory reason) {
            console.log("Position creation FAILED with:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Position creation FAILED with low-level error");
            console.logBytes(lowLevelData);
        }
        
        vm.stopPrank();
    }
    
    function test_TraceSwapWithPosition() public {
        console.log("\n=== TRACE: Swap With Position ===\n");
        
        // Create position
        vm.startPrank(alice);
        bytes32 positionId = router.borrow(poolKey, 4000e18, 1 ether, 90);
        console.log("Position created with ID:");
        console.logBytes32(positionId);
        vm.stopPrank();
        
        // Check position state
        TrueLendHook.BorrowPosition memory posBefore = hook.getPosition(positionId);
        console.log("Position needsLiquidation:", posBefore.needsLiquidation);
        console.log("Position tickLower:", posBefore.tickLower);
        
        // Get current tick
        (, int24 currentTick, , ) = manager.getSlot0(poolKey.toId());
        console.log("Current tick:", currentTick);
        
        // Try swap
        vm.startPrank(bob);
        
        console.log("\nAttempting small swap...");
        console.log("Bob token1 balance:", token1.balanceOf(bob));
        console.log("Bob token1 allowance to swapRouter:", token1.allowance(bob, address(swapRouter)));
        
        try swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1000e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        ) {
            console.log("Swap SUCCESS");
            
            (, int24 newTick, , ) = manager.getSlot0(poolKey.toId());
            console.log("New tick:", newTick);
            
            TrueLendHook.BorrowPosition memory posAfter = hook.getPosition(positionId);
            console.log("Position needsLiquidation after:", posAfter.needsLiquidation);
            console.log("Position collateralRemaining:", posAfter.collateralRemaining);
            
        } catch Error(string memory reason) {
            console.log("Swap FAILED with error:", reason);
        } catch Panic(uint256 errorCode) {
            console.log("Swap FAILED with Panic code:", errorCode);
            if (errorCode == 0x11) {
                console.log("  -> This is arithmetic overflow/underflow");
            } else if (errorCode == 0x12) {
                console.log("  -> This is divide by zero");
            }
        } catch (bytes memory lowLevelData) {
            console.log("Swap FAILED with low-level error");
            console.logBytes(lowLevelData);
            
            // Try to decode common errors
            if (lowLevelData.length >= 4) {
                bytes4 errorSelector;
                assembly {
                    errorSelector := mload(add(lowLevelData, 0x20))
                }
                console.log("Error selector:");
                console.logBytes4(errorSelector);
            }
        }
        
        vm.stopPrank();
    }
    
    function test_DecodeErrorCodes() public pure {
        console.log("\n=== ERROR CODE REFERENCE ===\n");
        console.log("0x575e24b4 = ?");
        console.log("0xa9e35b2f = ?");
        console.log("0x4e487b71 = Panic(uint256) selector");
        console.log("0x11 = Arithmetic overflow/underflow");
        console.log("0x12 = Division by zero");
        console.log("\nWrappedError structure:");
        console.log("  First param: 0x...C0 (likely a pointer/offset)");
        console.log("  Second param: Error selector");
        console.log("  Third param: Panic data with code 0x11");
        console.log("  Fourth param: Another error selector");
    }
}
