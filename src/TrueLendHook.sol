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
import {FullMath} from "v4-core/libraries/FullMath.sol"; // Import from v4-core
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title TrueLend Oracleless Liquidation Hook
 * @notice AMM-native lending with TWAMM-style gradual liquidations
 * @dev Liquidations happen incrementally across multiple swaps without interfering with user trades
 *
 * ARCHITECTURE:
 * - User swaps proceed normally through the pool, unaffected by liquidations
 * - When price crosses into liquidation range, positions are marked for liquidation
 * - Liquidation happens asynchronously via TWAMM-style incremental swaps in afterSwap
 * - Each swap executes small liquidation chunks based on time, depth, and liquidity pressure
 * - Penalties from liquidations are distributed to LPs via donate() function
 *
 * GAS OPTIMIZATION OPPORTUNITIES:
 * - Use bitmap for tick tracking instead of array iteration (similar to Uniswap's TickBitmap)
 * - Batch process multiple positions at same tick in single loop
 * - Cache frequently accessed storage variables
 * - Use unchecked arithmetic where overflow is impossible
 * - Consider merkle tree for position tracking if >100 active positions
 *
 * KNOWN LIMITATIONS (MVP):
 * - No liquidity withdrawal protection: LPs can withdraw liquidity that borrower positions rely on
 *   Production solution: Track "reserved liquidity" and prevent withdrawals that would leave
 *   insufficient liquidity for active liquidation ranges
 * - Simplified tick math: Production would need precise decimal handling for various token pairs
 * - No handling of positions larger than available pool liquidity
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
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
        // Collateral and debt tracking
        uint256 collateralAmount; // Original USDC deposited
        uint256 collateralRemaining; // USDC not yet liquidated
        uint256 debtAmount; // Original ETH borrowed
        uint256 debtRepaid; // ETH repaid via liquidation
        // Price/tick range for liquidation
        int24 tickLower; // Liquidation start tick
        int24 tickUpper; // Liquidation end tick
        uint160 sqrtPriceX96Initial; // Price at position creation
        // Time tracking
        uint256 creationTime;
        uint256 lastLiquidationTime;
        uint256 liquidationStartTime; // When first entered liquidation range
        uint256 totalTimeInLiquidation;
        // Parameters
        uint8 liquidationThreshold; // LT as percentage (90 = 90%)
        uint16 interestRate; // APR in basis points (500 = 5%)
        // State
        bool needsLiquidation;
        bool isActive;
    }

    struct LiquidationSwapData {
        PoolKey poolKey;
        bytes32 positionId;
        uint256 amount;
    }

    // Constants
    uint256 public constant BASE_PENALTY_RATE = 500; // 5% base penalty (in basis points)
    uint256 public constant MAX_CHUNK_SIZE = 1000e18; // Max 1000 USDC per chunk
    uint256 public constant MIN_CHUNK_SIZE = 10e18; // Min 10 USDC per chunk
    uint256 public constant TARGET_CHUNKS = 100; // Target 100 chunks for full liquidation
    uint256 public constant CHUNK_TIME_INTERVAL = 1 minutes; // Min time between chunks

    // Storage
    mapping(bytes32 => BorrowPosition) public positions;
    mapping(PoolId => bytes32[]) public activePositions;
    mapping(address => bool) public isLendingRouter;

    // Tick -> position IDs for efficient range queries
    // GAS OPTIMIZATION: Could use bitmap like TickBitmap.sol for O(1) tick queries
    mapping(PoolId => mapping(int24 => bytes32[])) internal positionsAtTick;

    // Track which ticks have positions (for efficient iteration)
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
                beforeAddLiquidity: false, // Allow normal liquidity addition
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Detect liquidation range crossing
                afterSwap: true, // Execute TWAMM liquidation chunks
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false, // Don't interfere with user swaps
                afterSwapReturnDelta: false, // Don't need this - not modifying user output
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    modifier onlyLendingRouter() {
        if (!isLendingRouter[msg.sender]) revert OnlyLendingRouter();
        _;
    }

    // ============ Admin Functions ============

    function setLendingRouter(address router, bool approved) external {
        // In production, add access control (Ownable, etc.)
        isLendingRouter[router] = approved;
    }

    // ============ Hook Functions ============

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get current and estimated new tick
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            key.toId()
        );

        // Estimate where price will be after this swap
        int24 estimatedNewTick = _estimateNewTick(key, params, currentTick);

        // Check if we're crossing into any liquidation ranges
        _checkAndActivateLiquidations(key, currentTick, estimatedNewTick);

        // Return zero delta - user's swap proceeds normally, completely unaffected
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Execute TWAMM-style liquidation chunks for all active positions
        // This happens AFTER user's swap is complete, so doesn't affect their execution
        _executeLiquidationChunks(key);

        return (this.afterSwap.selector, 0);
    }

    // ============ Core Liquidation Logic ============

    function _checkAndActivateLiquidations(
        PoolKey calldata key,
        int24 currentTick,
        int24 newTick
    ) internal {
        PoolId poolId = key.toId();
        int24[] memory ticks = activeTicks[poolId];

        // GAS OPTIMIZATION: This loop could be optimized using bitmap
        // to find only ticks within current -> new tick range
        for (uint i = 0; i < ticks.length; i++) {
            int24 tick = ticks[i];

            // Check if we crossed this tick
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
                        // Activate liquidation
                        pos.needsLiquidation = true;
                        pos.liquidationStartTime = block.timestamp;
                        pos.lastLiquidationTime = block.timestamp;
                    }
                }
            }

            // Check if we crossed back out of range (reversible liquidation)
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
                        // Deactivate liquidation - position is safe again
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

        // GAS OPTIMIZATION: Could batch process positions at same tick
        for (uint i = 0; i < activePos.length; i++) {
            BorrowPosition storage pos = positions[activePos[i]];

            if (!pos.isActive || !pos.needsLiquidation) continue;
            if (pos.collateralRemaining == 0) continue;

            // Calculate chunk size for this position
            uint256 chunkSize = _calculateChunkSize(pos, key, currentTick);

            if (chunkSize < MIN_CHUNK_SIZE) continue; // Not enough time passed or too small

            // Execute liquidation chunk
            _executeSingleChunk(key, activePos[i], chunkSize);

            // Check if position is now fully liquidated or safe
            _checkPositionStatus(key, activePos[i]);
        }
    }

    function _calculateChunkSize(
        BorrowPosition storage pos,
        PoolKey calldata key,
        int24 currentTick
    ) internal view returns (uint256) {
        // Time-based component: how long since last liquidation
        uint256 timeSinceLastChunk = block.timestamp - pos.lastLiquidationTime;
        if (timeSinceLastChunk < CHUNK_TIME_INTERVAL) return 0;

        // Base chunk size: divide total collateral into target chunks
        uint256 baseChunk = pos.collateralRemaining / TARGET_CHUNKS;
        if (baseChunk < MIN_CHUNK_SIZE) baseChunk = pos.collateralRemaining;

        // Time multiplier: longer time = larger chunk (cap at 5x)
        uint256 timeMultiplier = (timeSinceLastChunk * 10000) /
            CHUNK_TIME_INTERVAL;
        if (timeMultiplier > 50000) timeMultiplier = 50000;

        // Depth multiplier: deeper in range = more urgent
        uint256 depthIntoRange = 0;
        if (currentTick >= pos.tickLower) {
            int24 rangeWidth = pos.tickUpper - pos.tickLower;
            int24 depthTicks = currentTick - pos.tickLower;
            depthIntoRange =
                (uint256(uint24(depthTicks)) * 10000) /
                uint256(uint24(rangeWidth));
        }

        // Liquidity pressure: how much of pool liquidity does this position represent
        uint128 poolLiquidity = poolManager.getLiquidity(key.toId());
        uint256 positionLiquidityEquiv = pos.collateralRemaining;
        uint256 liquidityPressure = poolLiquidity > 0
            ? (positionLiquidityEquiv * 10000) / uint256(poolLiquidity)
            : 0;
        if (liquidityPressure > 10000) liquidityPressure = 10000;

        // Combined formula accounting for time, depth, and liquidity pressure
        uint256 chunkSize = baseChunk
            .mulDivDown(timeMultiplier, 10000)
            .mulDivDown(10000 + depthIntoRange, 10000)
            .mulDivDown(10000 + liquidityPressure, 10000);

        // Apply bounds
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
        // Execute liquidation swap via unlock callback
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
     * @notice Unlock callback executes the TWAMM liquidation swap
     * @dev This is where the actual liquidation happens:
     *      1. Hook swaps borrower's USDC collateral for ETH
     *      2. Calculates penalty based on LT, time, and amount
     *      3. Distributes penalty to LPs via donate()
     *      4. Remaining ETH goes toward repaying borrower's debt
     */
    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        LiquidationSwapData memory swapData = abi.decode(
            data,
            (LiquidationSwapData)
        );
        BorrowPosition storage pos = positions[swapData.positionId];

        // Settle borrower's USDC collateral to PM
        swapData.poolKey.currency1.settle(
            poolManager,
            address(this),
            swapData.amount,
            false
        );

        // Execute swap: USDC → ETH (borrower's collateral buying ETH to repay debt)
        // This is a SEPARATE swap from the user's swap that triggered liquidation
        BalanceDelta swapDelta = poolManager.swap(
            swapData.poolKey,
            SwapParams({ // Use SwapParams directly, not IPoolManager.SwapParams
                zeroForOne: false, // Buying ETH (token0) with USDC (token1)
                amountSpecified: -int256(swapData.amount), // Exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Take the ETH we received from the swap
        uint256 ethReceived = uint256(uint128(swapDelta.amount0()));
        swapData.poolKey.currency0.take(
            poolManager,
            address(this),
            ethReceived,
            false
        );

        // Calculate penalty based on LT, time in liquidation, and amount
        uint256 penalty = _calculatePenalty(pos, swapData.amount, ethReceived);

        // ============ LP PENALTY DISTRIBUTION ============
        // Penalties are distributed to LPs via the donate() function
        // donate() adds funds directly to the pool's LP fee accumulator
        // LPs can then claim these fees proportional to their liquidity position
        // This is how LPs earn revenue from liquidations happening in their pool
        if (penalty > 0 && penalty < ethReceived) {
            poolManager.donate(
                swapData.poolKey,
                penalty, // ETH penalty goes to LPs as additional fees
                0, // No token1 donation
                ""
            );

            // Settle the penalty donation (transfer ETH to PM)
            swapData.poolKey.currency0.settle(
                poolManager,
                address(this),
                penalty,
                false
            );

            ethReceived -= penalty; // Reduce ETH allocated to debt repayment
        }

        // Update position accounting
        pos.collateralRemaining -= swapData.amount;
        pos.debtRepaid += ethReceived;
        pos.lastLiquidationTime = block.timestamp;

        // Get current tick for event
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
        // Penalty formula:
        // penalty = ethReceived * basePenalty * LT_factor * time_factor

        // LT factor: higher LT = higher risk = higher penalty to compensate LPs
        uint256 ltFactor = (uint256(pos.liquidationThreshold) * 10000) / 100;

        // Time factor: longer in liquidation = higher penalty (cap at 5x)
        uint256 timeInLiquidation = block.timestamp - pos.liquidationStartTime;
        uint256 timeFactor = 10000 + (timeInLiquidation * 100) / 1 hours; // +1% per hour
        if (timeFactor > 50000) timeFactor = 50000;

        // Combined penalty calculation
        uint256 penalty = ethReceived
        .mulDivDown(BASE_PENALTY_RATE, 10000) // Base 5%
            .mulDivDown(ltFactor, 10000)
            .mulDivDown(timeFactor, 10000); // Multiply by LT factor // Multiply by time factor

        return penalty;
    }

    // In _checkPositionStatus function, around line 463:

    function _checkPositionStatus(
        PoolKey calldata /*key*/,
        bytes32 positionId
    ) internal {
        BorrowPosition storage pos = positions[positionId];

        // Declare totalDebt once at the top
        uint256 totalDebt = _calculateTotalDebt(pos);

        // Check if fully liquidated (all collateral consumed)
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

        // Check if position is now safe (debt fully repaid before collateral exhausted)
        // Now we just use totalDebt without redeclaring it
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

    // ============ Position Management ============

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

        // Get current price and tick
        (uint160 sqrtPriceX96Current, int24 currentTick, , ) = poolManager
            .getSlot0(key.toId());

        // Calculate liquidation range ticks using Uniswap's TickMath
        (int24 tickLower, int24 tickUpper) = _calculateLiquidationTicks(
            sqrtPriceX96Current,
            currentTick,
            liquidationThreshold,
            collateralAmount,
            debtAmount
        );

        // Generate unique position ID
        positionId = keccak256(
            abi.encodePacked(
                borrower,
                msg.sender,
                block.timestamp,
                collateralAmount,
                debtAmount
            )
        );

        // Create position
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
            interestRate: 500, // 5% APR
            needsLiquidation: false,
            isActive: true
        });

        // Add to tracking structures
        activePositions[key.toId()].push(positionId);
        positionsAtTick[key.toId()][tickLower].push(positionId);

        if (!tickHasPositions[key.toId()][tickLower]) {
            activeTicks[key.toId()].push(tickLower);
            tickHasPositions[key.toId()][tickLower] = true;
        }

        // Transfer collateral to hook (simplified for MVP - production needs proper unlock callback)
        // In production, this would use unlock() to properly handle token transfers

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

        // Transfer ETH from borrower (simplified for MVP)
        // Production would use unlock callback for proper accounting

        // Update debt
        pos.debtRepaid += repayAmount;

        // Check if fully repaid
        uint256 totalDebt = _calculateTotalDebt(pos);
        bool fullyRepaid = pos.debtRepaid >= totalDebt;

        if (fullyRepaid) {
            pos.isActive = false;
            pos.needsLiquidation = false;
            // Return remaining collateral logic here
        }

        emit PositionRepaid(positionId, repayAmount, fullyRepaid);
    }

    // ============ Helper Functions ============

    /**
     * @notice Calculate liquidation tick range using proper Uniswap v4 math
     * @dev Uses TickMath library for accurate conversions
     * sqrtPriceX96 = sqrt(token1/token0) * 2^96 = sqrt(USDC/ETH) * 2^96
     * For ETH/USDC pool: token0 = ETH, token1 = USDC
     * Price goes UP (ETH more expensive) means moving to HIGHER ticks
     */
    function _calculateLiquidationTicks(
        uint160 sqrtPriceX96Current,
        int24 currentTick,
        uint8 liquidationThreshold,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        // Current price: price = (sqrtPriceX96 / 2^96)^2 = token1/token0 = USDC/ETH
        uint256 currentPrice = FullMath.mulDiv(
            uint256(sqrtPriceX96Current),
            uint256(sqrtPriceX96Current),
            1 << 192
        );

        // Liquidation starts when LTV reaches liquidationThreshold
        // LTV = debt * price / collateral
        // At liquidation: debt * liquidationPrice / collateral = LT / 100
        // liquidationPrice = (LT * collateral) / (debt * 100)
        uint256 liquidationPrice = FullMath.mulDiv(
            uint256(liquidationThreshold) * collateralAmount,
            1,
            debtAmount * 100
        );

        // Convert liquidation price to sqrtPriceX96
        // sqrtPrice = sqrt(price) * 2^96
        uint160 sqrtPriceLiquidation = uint160(
            FixedPointMathLib.sqrt(liquidationPrice) << 96
        );

        // Get tick from sqrtPrice using Uniswap's TickMath
        tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLiquidation);

        // Upper tick: approximate as ~sqrt(2) * liquidation price
        // This represents when collateral is nearly exhausted
        uint160 sqrtPriceUpper = uint160(
            (uint256(sqrtPriceLiquidation) * 14142) / 10000
        );
        tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpper);

        // Ensure ticks are within valid bound
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
        // Use sqrtPriceLimitX96 if specified
        if (params.sqrtPriceLimitX96 != 0) {
            return TickMath.getTickAtSqrtPrice(params.sqrtPriceLimitX96);
        }

        // Simplified estimation for MVP
        // Production would use more sophisticated price impact calculation
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        if (liquidity == 0) return currentTick;

        // Very rough estimate
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
        // Calculate debt with simple accrued interest
        uint256 timeElapsed = block.timestamp - pos.creationTime;
        uint256 interest = pos.debtAmount.mulDivDown(
            pos.interestRate * timeElapsed,
            10000 * 365 days
        );
        return pos.debtAmount + interest;
    }

    // ============ View Functions ============

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
