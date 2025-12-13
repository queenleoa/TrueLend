// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title TrueLend Oracleless Liquidation Hook
 * @notice AMM-native lending with TWAMM-style gradual liquidations
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using FixedPointMathLib for uint256;

    // Reentrancy lock to prevent hook from processing its own liquidation swaps
    bool private _inLiquidationSwap;

    error OnlyLendingRouter();
    error PositionNotActive();
    error InsufficientCollateral();
    error InvalidLiquidationThreshold();

    event PositionCreated(
        bytes32 indexed positionId,
        address indexed borrower,
        uint256 collateralAmount,
        uint256 debtAmount,
        int24 tickLower,
        int24 tickUpper,
        uint8 liquidationThreshold
    );

    event LiquidationChunkExecuted(
        bytes32 indexed positionId,
        uint256 collateralLiquidated,
        uint256 debtRepaid,
        uint256 penaltyAmount,
        int24 currentTick
    );

    event PositionFullyLiquidated(
        bytes32 indexed positionId,
        uint256 totalCollateralLiquidated,
        uint256 totalDebtRepaid,
        uint256 excessReturned
    );

    event PositionRepaid(
        bytes32 indexed positionId,
        uint256 amountRepaid,
        bool fullyRepaid
    );

    struct BorrowPosition {
        address borrower;
        address lendingRouter;
        uint256 collateralAmount;
        uint256 collateralRemaining;
        uint256 debtAmount;
        uint256 debtRepaid;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96Initial;
        uint256 creationTime;
        uint256 lastLiquidationTime;
        uint256 liquidationStartTime;
        uint256 totalTimeInLiquidation;
        uint8 liquidationThreshold;
        uint16 interestRate;
        bool needsLiquidation;
        bool isActive;
    }

    struct LiquidationSwapData {
        PoolKey poolKey;
        bytes32 positionId;
        uint256 amount;
    }

    // Constants
    uint256 public constant BASE_PENALTY_RATE = 500;
    uint256 public constant MAX_CHUNK_SIZE = 1000e18;
    uint256 public constant MIN_CHUNK_SIZE = 10e18;
    uint256 public constant TARGET_CHUNKS = 100;
    uint256 public constant CHUNK_TIME_INTERVAL = 1 minutes;

    // Storage
    mapping(bytes32 => BorrowPosition) public positions;
    mapping(PoolId => bytes32[]) public activePositions;
    mapping(address => bool) public isLendingRouter;
    mapping(PoolId => mapping(int24 => bytes32[])) internal positionsAtTick;
    mapping(PoolId => int24[]) internal activeTicks;
    mapping(PoolId => mapping(int24 => bool)) internal tickHasPositions;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    modifier onlyLendingRouter() {
        if (!isLendingRouter[msg.sender]) revert OnlyLendingRouter();
        _;
    }

    function setLendingRouter(address router, bool approved) external {
        isLendingRouter[router] = approved;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Skip hook logic if this is a liquidation swap from the hook itself
        if (_inLiquidationSwap) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        
        // Don't estimate - we'll check actual tick in afterSwap
        // Estimation with concentrated liquidity is too unreliable
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Check actual tick and activate/deactivate liquidations based on reality
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        _checkAndToggleLiquidations(key, currentTick);
        
        // Execute any active liquidation chunks
        _executeLiquidationChunks(key);
        return (this.afterSwap.selector, 0);
    }

    function _checkAndToggleLiquidations(
        PoolKey calldata key,
        int24 currentTick
    ) internal {
        PoolId poolId = key.toId();
        int24[] memory ticks = activeTicks[poolId];

        for (uint i = 0; i < ticks.length; i++) {
            int24 tick = ticks[i];
            bytes32[] memory posIds = positionsAtTick[poolId][tick];
            
            for (uint j = 0; j < posIds.length; j++) {
                BorrowPosition storage pos = positions[posIds[j]];
                if (!pos.isActive) continue;
                
                // Check if we're in liquidation range
                bool inRange = (currentTick >= pos.tickLower && currentTick <= pos.tickUpper);
                
                if (inRange && !pos.needsLiquidation) {
                    // Entered liquidation range
                    pos.needsLiquidation = true;
                    pos.liquidationStartTime = block.timestamp;
                    pos.lastLiquidationTime = block.timestamp - CHUNK_TIME_INTERVAL;
                } else if (!inRange && pos.needsLiquidation) {
                    // Exited liquidation range
                    pos.needsLiquidation = false;
                    pos.totalTimeInLiquidation += (block.timestamp - pos.liquidationStartTime);
                }
            }
        }
    }

    function _executeLiquidationChunks(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        bytes32[] memory activePos = activePositions[poolId];
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);

        for (uint i = 0; i < activePos.length; i++) {
            BorrowPosition storage pos = positions[activePos[i]];

            if (!pos.isActive || !pos.needsLiquidation) continue;
            if (pos.collateralRemaining == 0) continue;

            uint256 chunkSize = _calculateChunkSize(pos, key, currentTick);
            if (chunkSize < MIN_CHUNK_SIZE) continue;

            _executeSingleChunk(key, activePos[i], chunkSize);
            _checkPositionStatus(key, activePos[i]);
        }
    }

    function _calculateChunkSize(
        BorrowPosition storage pos,
        PoolKey calldata key,
        int24 currentTick
    ) internal view returns (uint256) {
        uint256 timeSinceLastChunk = block.timestamp - pos.lastLiquidationTime;
        if (timeSinceLastChunk < CHUNK_TIME_INTERVAL) return 0;

        uint256 baseChunk = pos.collateralRemaining / TARGET_CHUNKS;
        if (baseChunk < MIN_CHUNK_SIZE) baseChunk = pos.collateralRemaining;

        uint256 timeMultiplier = (timeSinceLastChunk * 10000) /
            CHUNK_TIME_INTERVAL;
        if (timeMultiplier > 50000) timeMultiplier = 50000;

        uint256 depthIntoRange = 0;
        
        if (currentTick >= pos.tickLower && currentTick <= pos.tickUpper) {
            int24 rangeWidth = pos.tickUpper - pos.tickLower;
            
            if (rangeWidth > 0) {
                int24 depthTicks = currentTick - pos.tickLower;
                
                if (depthTicks >= 0) {
                    uint256 depthTicksUint = uint256(int256(depthTicks));
                    uint256 rangeWidthUint = uint256(int256(rangeWidth));
                    
                    if (depthTicksUint <= rangeWidthUint) {
                        depthIntoRange = (depthTicksUint * 10000) / rangeWidthUint;
                    } else {
                        depthIntoRange = 10000;
                    }
                }
            }
        }

        uint128 poolLiquidity = poolManager.getLiquidity(key.toId());
        uint256 positionLiquidityEquiv = pos.collateralRemaining;
        uint256 liquidityPressure = poolLiquidity > 0
            ? (positionLiquidityEquiv * 10000) / uint256(poolLiquidity)
            : 0;
        if (liquidityPressure > 10000) liquidityPressure = 10000;

        uint256 chunkSize = baseChunk
            .mulDivDown(timeMultiplier, 10000)
            .mulDivDown(10000 + depthIntoRange, 10000)
            .mulDivDown(10000 + liquidityPressure, 10000);

        if (chunkSize > MAX_CHUNK_SIZE) chunkSize = MAX_CHUNK_SIZE;
        if (chunkSize > pos.collateralRemaining)
            chunkSize = pos.collateralRemaining;

        return chunkSize;
    }

    function _executeSingleChunk(
        PoolKey calldata key,
        bytes32 positionId,
        uint256 chunkSize
    ) internal {
        poolManager.unlock(
            abi.encode(
                LiquidationSwapData({
                    poolKey: key,
                    positionId: positionId,
                    amount: chunkSize
                })
            )
        );
    }

    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        LiquidationSwapData memory swapData = abi.decode(
            data,
            (LiquidationSwapData)
        );
        BorrowPosition storage pos = positions[swapData.positionId];

        IERC20(Currency.unwrap(swapData.poolKey.currency1)).approve(
            address(poolManager),
            swapData.amount
        );

        swapData.poolKey.currency1.settle(
            poolManager,
            address(this),
            swapData.amount,
            false
        );

        // Set reentrancy lock to prevent this swap from triggering hook logic
        _inLiquidationSwap = true;
        
        BalanceDelta swapDelta = poolManager.swap(
            swapData.poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapData.amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        
        // Clear reentrancy lock
        _inLiquidationSwap = false;

        uint256 ethReceived = uint256(uint128(-swapDelta.amount0()));
        swapData.poolKey.currency0.take(
            poolManager,
            address(this),
            ethReceived,
            false
        );

        uint256 penalty = _calculatePenalty(pos, swapData.amount, ethReceived);

        if (penalty > 0 && penalty < ethReceived) {
            IERC20(Currency.unwrap(swapData.poolKey.currency0)).approve(
                address(poolManager),
                penalty
            );
            
            poolManager.donate(
                swapData.poolKey,
                penalty,
                0,
                ""
            );

            swapData.poolKey.currency0.settle(
                poolManager,
                address(this),
                penalty,
                false
            );

            ethReceived -= penalty;
        }

        pos.collateralRemaining -= swapData.amount;
        pos.debtRepaid += ethReceived;
        pos.lastLiquidationTime = block.timestamp;

        (, int24 currentTick, , ) = poolManager.getSlot0(
            swapData.poolKey.toId()
        );

        emit LiquidationChunkExecuted(
            swapData.positionId,
            swapData.amount,
            ethReceived,
            penalty,
            currentTick
        );

        return "";
    }

    function _calculatePenalty(
        BorrowPosition storage pos,
        uint256 /* collateralLiquidated */,
        uint256 ethReceived
    ) internal view returns (uint256) {
        if (ethReceived == 0) return 0;
        
        uint256 ltFactor = (uint256(pos.liquidationThreshold) * 10000) / 100;
        uint256 timeInLiquidation = block.timestamp - pos.liquidationStartTime;
        uint256 timeFactor = 10000 + (timeInLiquidation * 100) / 1 hours;
        if (timeFactor > 50000) timeFactor = 50000;

        uint256 penalty = ethReceived
            .mulDivDown(BASE_PENALTY_RATE, 10000)
            .mulDivDown(ltFactor, 10000)
            .mulDivDown(timeFactor, 10000);

        return penalty;
    }

    function _checkPositionStatus(
        PoolKey calldata /* key */,
        bytes32 positionId
    ) internal {
        BorrowPosition storage pos = positions[positionId];
        uint256 totalDebt = _calculateTotalDebt(pos);

        if (pos.collateralRemaining == 0) {
            pos.isActive = false;
            pos.needsLiquidation = false;

            emit PositionFullyLiquidated(
                positionId,
                pos.collateralAmount,
                pos.debtRepaid,
                pos.debtRepaid > totalDebt ? pos.debtRepaid - totalDebt : 0
            );
            return;
        }

        if (pos.debtRepaid >= totalDebt) {
            pos.isActive = false;
            pos.needsLiquidation = false;

            emit PositionFullyLiquidated(
                positionId,
                pos.collateralAmount - pos.collateralRemaining,
                pos.debtRepaid,
                pos.collateralRemaining
            );
        }
    }

    function createPosition(
        PoolKey calldata key,
        address borrower,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint8 liquidationThreshold
    ) external onlyLendingRouter returns (bytes32 positionId) {
        if (collateralAmount == 0 || debtAmount == 0)
            revert InsufficientCollateral();
        if (liquidationThreshold > 99 || liquidationThreshold < 50)
            revert InvalidLiquidationThreshold();

        (uint160 sqrtPriceX96Current, int24 currentTick, , ) = poolManager
            .getSlot0(key.toId());

        (int24 tickLower, int24 tickUpper) = _calculateLiquidationTicks(
            sqrtPriceX96Current,
            currentTick,
            liquidationThreshold,
            collateralAmount,
            debtAmount
        );

        positionId = keccak256(
            abi.encodePacked(
                borrower,
                msg.sender,
                block.timestamp,
                collateralAmount,
                debtAmount
            )
        );

        require(
            IERC20(Currency.unwrap(key.currency1)).transferFrom(
                msg.sender,
                address(this),
                collateralAmount
            ),
            "Collateral transfer failed"
        );

        positions[positionId] = BorrowPosition({
            borrower: borrower,
            lendingRouter: msg.sender,
            collateralAmount: collateralAmount,
            collateralRemaining: collateralAmount,
            debtAmount: debtAmount,
            debtRepaid: 0,
            tickLower: tickLower,
            tickUpper: tickUpper,
            sqrtPriceX96Initial: sqrtPriceX96Current,
            creationTime: block.timestamp,
            lastLiquidationTime: block.timestamp,
            liquidationStartTime: 0,
            totalTimeInLiquidation: 0,
            liquidationThreshold: liquidationThreshold,
            interestRate: 500,
            needsLiquidation: false,
            isActive: true
        });

        activePositions[key.toId()].push(positionId);
        positionsAtTick[key.toId()][tickLower].push(positionId);

        if (!tickHasPositions[key.toId()][tickLower]) {
            activeTicks[key.toId()].push(tickLower);
            tickHasPositions[key.toId()][tickLower] = true;
        }

        require(
            IERC20(Currency.unwrap(key.currency0)).transfer(borrower, debtAmount),
            "Debt transfer failed"
        );

        emit PositionCreated(
            positionId,
            borrower,
            collateralAmount,
            debtAmount,
            tickLower,
            tickUpper,
            liquidationThreshold
        );
    }

    function repayDebt(
        PoolKey calldata /* key */,
        bytes32 positionId,
        uint256 repayAmount
    ) external {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();

        pos.debtRepaid += repayAmount;

        uint256 totalDebt = _calculateTotalDebt(pos);
        bool fullyRepaid = pos.debtRepaid >= totalDebt;

        if (fullyRepaid) {
            pos.isActive = false;
            pos.needsLiquidation = false;
        }

        emit PositionRepaid(positionId, repayAmount, fullyRepaid);
    }

    function _calculateLiquidationTicks(
        uint160 sqrtPriceX96Current,
        int24 /* currentTick */,
        uint8 liquidationThreshold,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        uint256 liquidationPrice = FullMath.mulDiv(
            uint256(liquidationThreshold) * collateralAmount,
            1,
            debtAmount * 100
        );

        uint160 sqrtPriceLiquidation = uint160(
            FixedPointMathLib.sqrt(liquidationPrice) << 96
        );

        tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLiquidation);

        uint160 sqrtPriceUpper = uint160(
            (uint256(sqrtPriceLiquidation) * 14142) / 10000
        );
        tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpper);

        if (tickLower > TickMath.MAX_TICK) tickLower = TickMath.MAX_TICK;
        if (tickUpper > TickMath.MAX_TICK) tickUpper = TickMath.MAX_TICK;
        if (tickLower < TickMath.MIN_TICK) tickLower = TickMath.MIN_TICK;
        if (tickUpper < TickMath.MIN_TICK) tickUpper = TickMath.MIN_TICK;
        
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + 600;
            if (tickUpper > TickMath.MAX_TICK) tickUpper = TickMath.MAX_TICK;
        }
    }

    /**
     * @notice Estimate new tick after swap with non-linear scaling for large swaps
     * @dev Uses progressive multipliers based on swap size relative to liquidity
     */
    function _estimateNewTick(
        PoolKey calldata key,
        SwapParams calldata params,
        int24 currentTick
    ) internal view returns (int24) {
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        console.log("_estimateNewTick called:");
        console.log("  liquidity:", liquidity);
        console.log("  currentTick:", uint256(int256(currentTick)));
        
        if (liquidity == 0) return currentTick;
        
        int256 amount = params.amountSpecified;
        console.log("  amount (int256):", uint256(amount < 0 ? -amount : amount));
        console.log("  amount is negative:", amount < 0);
        
        if (amount == 0) return currentTick;
        
        // For very large swaps relative to liquidity, they'll move price dramatically
        uint256 absAmount = amount < 0 ? uint256(-amount) : uint256(amount);
        uint256 liquidityUint = uint256(liquidity);
        
        console.log("  absAmount:", absAmount);
        console.log("  liquidityUint:", liquidityUint);
        console.log("  absAmount > liquidityUint/2?:", absAmount > liquidityUint / 2);
        
        // If swap is > 50% of liquidity, expect massive price movement
        // BUT: with concentrated liquidity, we'll likely hit range boundaries
        // So cap the estimate more conservatively
        if (absAmount > liquidityUint / 2) {
            console.log("  BRANCH: Large swap (>50% liquidity)");
            // For concentrated liquidity, large swaps will hit range boundaries
            // Don't assume we'll reach the price limit - estimate more conservatively
            
            // Estimate ~50-60% of max possible movement since liquidity will decrease
            // as we move through ranges
            if (params.sqrtPriceLimitX96 != 0) {
                int24 limitTick = TickMath.getTickAtSqrtPrice(params.sqrtPriceLimitX96);
                console.log("  limitTick:", uint256(int256(limitTick)));
                int24 movementToLimit = limitTick - currentTick;
                console.log("  movementToLimit:", uint256(int256(movementToLimit)));
                
                // Only expect to move ~50% of the way due to liquidity decreasing
                // in wider ranges (conservative estimate for concentrated liquidity)
                int24 conservativeEstimate = currentTick + (movementToLimit / 2);
                console.log("  Conservative estimate (50% of limit):", uint256(int256(conservativeEstimate)));
                return conservativeEstimate;
            } else {
                // No limit specified, estimate moderate movement
                // Don't go crazy - concentrated liquidity means less movement
                int24 moderateMove = params.zeroForOne ? int24(-30000) : int24(30000);
                return currentTick + moderateMove;
            }
        }
        
        console.log("  BRANCH: Normal swap (<50% liquidity)");
        // For smaller swaps, use non-linear approximation
        int256 liquidityInt = int256(liquidityUint);
        
        // Calculate basis points (amount * 10000 / liquidity)
        int256 bps = (amount * 10000) / liquidityInt;
        int256 absBps = bps < 0 ? -bps : bps;
        
        console.log("  bps:", uint256(absBps));
        console.log("  (Direction will come from zeroForOne parameter)");
        
        // Non-linear scaling based on swap size
        // Use ABSOLUTE value for calculation - direction comes from zeroForOne only
        // IMPORTANT: For concentrated liquidity, scale down estimates by ~50%
        // because liquidity decreases as we move through ranges
        int256 estimatedMoveInt;
        
        if (absBps < 100) {
            // < 1% of liquidity: roughly linear, ~10 ticks per bp
            estimatedMoveInt = int256(absBps) * 10;
            console.log("  Using 10x multiplier, estimatedMoveInt:", uint256(estimatedMoveInt));
        } else if (absBps < 1000) {
            // 1-10% of liquidity: accelerating impact
            estimatedMoveInt = int256(absBps) * 50;
            console.log("  Using 50x multiplier, estimatedMoveInt:", uint256(estimatedMoveInt));
        } else if (absBps < 5000) {
            // 10-50% of liquidity: strong exponential impact
            estimatedMoveInt = int256(absBps) * 200;
            console.log("  Using 200x multiplier, estimatedMoveInt:", uint256(estimatedMoveInt));
        } else {
            // Approaching 50% of liquidity: extreme impact
            estimatedMoveInt = int256(absBps) * 500;
            console.log("  Using 500x multiplier, estimatedMoveInt:", uint256(estimatedMoveInt));
        }
        
        // For concentrated liquidity: Scale down by 50% since liquidity will drop
        // as we move out of tight ranges into wider ranges with less depth
        estimatedMoveInt = estimatedMoveInt / 2;
        console.log("  After 50% concentration adjustment:", uint256(estimatedMoveInt));
        
        // Cap to reasonable bounds
        if (estimatedMoveInt > 150000) estimatedMoveInt = 150000;
        if (estimatedMoveInt < -150000) estimatedMoveInt = -150000;
        
        console.log("  After capping, estimatedMoveInt:", uint256(estimatedMoveInt));
        
        int24 estimatedMove = int24(estimatedMoveInt);
        int24 estimatedTick = params.zeroForOne 
            ? currentTick - estimatedMove 
            : currentTick + estimatedMove;
        
        console.log("  zeroForOne:", params.zeroForOne);
        console.log("  Calculated estimatedTick:", currentTick);
        console.log("  + estimatedMove:", uint256(int256(estimatedMove)));
        console.log("  = ", uint256(int256(estimatedTick)));
        
        // Clamp to valid tick range
        if (estimatedTick > TickMath.MAX_TICK) estimatedTick = TickMath.MAX_TICK;
        if (estimatedTick < TickMath.MIN_TICK) estimatedTick = TickMath.MIN_TICK;
        
        // Respect price limit as a bound
        if (params.sqrtPriceLimitX96 != 0) {
            int24 limitTick = TickMath.getTickAtSqrtPrice(params.sqrtPriceLimitX96);
            if (params.zeroForOne) {
                if (estimatedTick < limitTick) estimatedTick = limitTick;
            } else {
                if (estimatedTick > limitTick) estimatedTick = limitTick;
            }
        }
        
        console.log("  Final estimated tick:", uint256(int256(estimatedTick)));
        return estimatedTick;
    }

    function _calculateTotalDebt(
        BorrowPosition storage pos
    ) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - pos.creationTime;
        uint256 interest = pos.debtAmount.mulDivDown(
            pos.interestRate * timeElapsed,
            10000 * 365 days
        );
        return pos.debtAmount + interest;
    }

    function getPosition(
        bytes32 positionId
    ) external view returns (BorrowPosition memory) {
        return positions[positionId];
    }

    function getActivePositions(
        PoolKey calldata key
    ) external view returns (bytes32[] memory) {
        return activePositions[key.toId()];
    }
}
