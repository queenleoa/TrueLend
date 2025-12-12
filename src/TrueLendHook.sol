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
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title TrueLend Oracleless Liquidation Hook
 * @notice AMM-native lending with TWAMM-style gradual liquidations
 * @dev MVP: Simplified token handling for hackathon demo
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

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
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            key.toId()
        );

        int24 estimatedNewTick = _estimateNewTick(key, params, currentTick);
        _checkAndActivateLiquidations(key, currentTick, estimatedNewTick);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _executeLiquidationChunks(key);
        return (this.afterSwap.selector, 0);
    }

    function _checkAndActivateLiquidations(
        PoolKey calldata key,
        int24 currentTick,
        int24 newTick
    ) internal {
        PoolId poolId = key.toId();
        int24[] memory ticks = activeTicks[poolId];

        for (uint i = 0; i < ticks.length; i++) {
            int24 tick = ticks[i];
            bool crossedIntoRange = (currentTick < tick && newTick >= tick);

            if (crossedIntoRange) {
                bytes32[] memory posIds = positionsAtTick[poolId][tick];
                for (uint j = 0; j < posIds.length; j++) {
                    BorrowPosition storage pos = positions[posIds[j]];
                    if (
                        pos.isActive &&
                        !pos.needsLiquidation &&
                        newTick >= pos.tickLower
                    ) {
                        pos.needsLiquidation = true;
                        pos.liquidationStartTime = block.timestamp;
                        pos.lastLiquidationTime = block.timestamp;
                    }
                }
            }

            bool crossedOutOfRange = (currentTick >= tick && newTick < tick);
            if (crossedOutOfRange) {
                bytes32[] memory posIds = positionsAtTick[poolId][tick];
                for (uint j = 0; j < posIds.length; j++) {
                    BorrowPosition storage pos = positions[posIds[j]];
                    if (
                        pos.isActive &&
                        pos.needsLiquidation &&
                        newTick < pos.tickLower
                    ) {
                        pos.needsLiquidation = false;
                        pos.totalTimeInLiquidation += (block.timestamp -
                            pos.liquidationStartTime);
                    }
                }
            }
        }
    }

    function _executeLiquidationChunks(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        bytes32[] memory activePos = activePositions[poolId];
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolId
        );

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
        if (currentTick >= pos.tickLower) {
            int24 rangeWidth = pos.tickUpper - pos.tickLower;
            int24 depthTicks = currentTick - pos.tickLower;
            depthIntoRange =
                (uint256(uint24(depthTicks)) * 10000) /
                uint256(uint24(rangeWidth));
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

    /**
     * @notice Unlock callback - executes liquidation swap
     * @dev MVP: Simplified for hackathon - assumes hook has collateral
     */
    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        LiquidationSwapData memory swapData = abi.decode(
            data,
            (LiquidationSwapData)
        );
        BorrowPosition storage pos = positions[swapData.positionId];

        // MVP: Hook should have collateral from createPosition()
        // Approve PoolManager to take collateral for the swap
        address token1Address = Currency.unwrap(swapData.poolKey.currency1);
        IERC20(token1Address).approve(address(poolManager), swapData.amount);

        // Transfer collateral to PoolManager (settle)
        poolManager.sync(swapData.poolKey.currency1);
        poolManager.settle();
        IERC20(token1Address).transfer(address(poolManager), swapData.amount);

        // Execute swap: USDC → ETH
        BalanceDelta swapDelta = poolManager.swap(
            swapData.poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapData.amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Calculate how much ETH we got
        // In a zeroForOne=false swap, amount0 is negative (we get token0)
        uint256 ethReceived = uint256(int256(-swapDelta.amount0()));

        // Take the ETH from PoolManager
        poolManager.sync(swapData.poolKey.currency0);
        poolManager.take(
            swapData.poolKey.currency0,
            address(this),
            ethReceived
        );

        // Calculate penalty
        uint256 penalty = _calculatePenalty(pos, swapData.amount, ethReceived);

        // Donate penalty to LPs
        if (penalty > 0 && penalty < ethReceived) {
            address token0Address = Currency.unwrap(swapData.poolKey.currency0);
            IERC20(token0Address).approve(address(poolManager), penalty);

            IERC20(token0Address).transfer(address(poolManager), penalty);
            poolManager.sync(swapData.poolKey.currency0);
            
            poolManager.donate(swapData.poolKey, penalty, 0, "");

            ethReceived -= penalty;
        }

        // Update position
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
        uint256 collateralLiquidated,
        uint256 ethReceived
    ) internal view returns (uint256) {
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
        PoolKey calldata /*key*/,
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

    /**
     * @notice Create borrow position
     * @dev MVP: Router should transfer collateral before calling this
     */
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

        // MVP: Transfer collateral from router to hook
        IERC20(Currency.unwrap(key.currency1)).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
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

        // MVP: Send borrowed tokens to borrower
        IERC20(Currency.unwrap(key.currency0)).transfer(borrower, debtAmount);

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
        PoolKey calldata key,
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
        int24 currentTick,
        uint8 liquidationThreshold,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        uint256 currentPrice = FullMath.mulDiv(
            uint256(sqrtPriceX96Current),
            uint256(sqrtPriceX96Current),
            1 << 192
        );

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
    }

    function _estimateNewTick(
        PoolKey calldata key,
        SwapParams calldata params,
        int24 currentTick
    ) internal view returns (int24) {
        if (params.sqrtPriceLimitX96 != 0) {
            return TickMath.getTickAtSqrtPrice(params.sqrtPriceLimitX96);
        }

        uint128 liquidity = poolManager.getLiquidity(key.toId());
        if (liquidity == 0) return currentTick;

        int24 estimatedMove = int24(
            params.amountSpecified / int256(uint256(liquidity)) / 1000
        );
        return
            params.zeroForOne
                ? currentTick - estimatedMove
                : currentTick + estimatedMove;
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
