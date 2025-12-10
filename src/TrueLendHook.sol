// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITrueLendRouter {
    function onLiquidation(
        uint256 positionId,
        uint128 debtRepaid,
        uint128 collateralLiquidated,
        bool isFullyLiquidated
    ) external;
}

/**
 * @title TrueLendHook
 * @notice Uniswap v4 hook for oracleless lending via inverse range orders
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 *                              CORE CONCEPT
 * ════════════════════════════════════════════════════════════════════════════════
 * 
 * INVERSE RANGE ORDER (Reserve Mechanism):
 * - Borrower's collateral is held by this Hook (NOT in the pool)
 * - This collateral represents a "claim" on LP liquidity in the tick range
 * - We do NOT create actual negative liquidity in Uniswap
 * - Instead, when price enters the range, we intercept swaps via beforeSwap()
 * - The collateral acts as "reserved liquidity" that gets liquidated
 * 
 * HOW RESERVES WORK:
 * 1. Position opened → collateral stored in Hook
 * 2. Tick range calculated → [tickLower, tickUpper]
 * 3. Collateral is "reserved" for this range (conceptually)
 * 4. When swap moves tick into range → Hook detects it
 * 5. Hook liquidates proportionally → converts collateral to debt token
 * 6. This effectively "fills" the inverse order
 * 
 * TICK ALIGNMENT:
 * - All ticks aligned to TICK_SPACING (60)
 * - Rounding favors borrower safety (conservative)
 * - If LT/LTV falls between ticks → round to safer tick
 * - Example: If calculated tick = 123, spacing = 60
 *   → Floor to 120 (safer for borrower)
 * 
 * POSITION TRACKING PER TICK:
 * - tickToPositions[tick] → list of position IDs at that tick
 * - During swaps, only check positions in relevant tick ranges
 * - Gas efficient: O(positions at tick) not O(all positions)
 * 
 * TICK RANGE (for token0 collateral, borrowing token1):
 * 
 *   Price
 *   ↑
 *   │
 *   │  Current: $2000 (healthy)
 *   │  
 *   │  tickUpper: $1337 ──┐ LT = 80%
 *   │                     │ Liquidation
 *   │  tickLower: $1070 ──┘ Range
 *   │                       (collateral reserved)
 *   │
 *   │  Below: Position fully liquidated
 *   └──────────────────────────→ Tick
 * 
 * PENALTY SYSTEM:
 * - While position is in liquidation range (underwater)
 * - Penalty accrues at DYNAMIC rate based on LT
 * - Base: 10% APR (at LT=50%)
 * - Increases linearly: +1% APR per 1% LT above 50%
 * - Examples:
 *   * LT = 60% → 20% APR penalty
 *   * LT = 80% → 40% APR penalty  
 *   * LT = 95% → 55% APR penalty
 * - On liquidation: 90% → LPs, 10% → swapper
 * 
 * RATIONALE:
 * Higher LT = riskier for LPs (less buffer, narrower range)
 * → Higher penalty compensates LPs for the risk
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 *                              LIQUIDATION FLOW
 * ════════════════════════════════════════════════════════════════════════════════
 * 
 * 1. Swap occurs → beforeSwap() triggered
 * 2. Check current tick against position ranges (using bitmap)
 * 3. For positions in liquidation range:
 *    a. Calculate time underwater → penalty accrued
 *    b. Calculate proportional collateral to liquidate
 *    c. Deduct penalty: 90% LP, 10% swapper
 *    d. Swap remaining collateral → debt token (via pool)
 *    e. Send debt token to Router
 *    f. Call Router.onLiquidation()
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    int24 constant TICK_SPACING = 60;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    /// @notice Fixed interest rate: 5% APR (from Router)
    uint256 public constant INTEREST_RATE_BPS = 500;
    
    /// @notice Fee buffer for tick range calculation: 2%
    uint256 public constant FEE_BUFFER_BPS = 200;
    
    /// @notice Base penalty rate: 10% APR (for LT = 50%)
    uint256 public constant BASE_PENALTY_RATE_BPS = 1000;
    
    /// @notice Penalty rate increases with LT
    /// Formula: penaltyRate = baseRate + (LT - 50%) × multiplier
    /// Example: LT=80% → 10% + 30% × 1.0 = 40% APR
    uint256 public constant PENALTY_RATE_MULTIPLIER = 10000; // 1.0x multiplier
    
    /// @notice LP share of penalty: 90%
    uint256 public constant LP_PENALTY_SHARE_BPS = 9000;
    
    /// @notice Swapper share of penalty: 10%
    uint256 public constant SWAPPER_PENALTY_SHARE_BPS = 1000;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct Position {
        address owner;
        bool zeroForOne;            // true = token0 collateral, borrow token1
        uint128 initialCollateral;  // Collateral at opening
        uint128 collateral;         // Current collateral remaining
        uint128 debt;               // Debt amount (for tracking)
        int24 tickLower;            // 100% LTV (full liquidation)
        int24 tickUpper;            // LT threshold (liquidation starts)
        uint16 ltBps;               // Liquidation threshold (for penalty calculation)
        uint40 openTime;            // When position opened
        uint40 lastPenaltyTime;     // Last penalty accrual timestamp
        uint128 accumulatedPenalty; // Penalty accrued while underwater
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ════════════════════════════════════════════════════════════════════════════

    ITrueLendRouter public router;
    PoolKey public poolKey;
    
    /// @notice Position tracking
    mapping(uint256 => Position) public positions;
    
    /// @notice Tick bitmap for gas-efficient liquidation detection
    /// @dev Maps tick to list of position IDs at that tick
    mapping(int24 => uint256[]) public tickToPositions;
    mapping(uint256 => uint256) public positionTickIndex; // positionId → index in tick array
    
    /// @notice LP penalty rewards tracking
    /// @dev Accumulated penalties for LPs to claim
    uint256 public totalLPPenalties;
    
    /// @notice Track positions in liquidation range for efficient iteration
    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public positionIndex; // positionId → index in activePositionIds

    // ════════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        bool zeroForOne,
        uint128 collateral,
        uint128 debt,
        int24 tickLower,
        int24 tickUpper
    );
    
    event PositionClosed(
        uint256 indexed positionId,
        uint128 collateralReturned
    );
    
    event LiquidationExecuted(
        uint256 indexed positionId,
        uint128 collateralLiquidated,
        uint128 penaltyDeducted,
        uint128 debtRepaid,
        bool fullyLiquidated
    );
    
    event PenaltyAccrued(
        uint256 indexed positionId,
        uint128 penaltyAmount
    );

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error OnlyRouter();
    error PositionNotActive();
    error InvalidAmount();

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              INITIALIZATION
    // ════════════════════════════════════════════════════════════════════════════

    function setRouter(address _router) external {
        require(address(router) == address(0), "Already set");
        router = ITrueLendRouter(_router);
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        returns (bytes4)
    {
        poolKey = key;
        return BaseHook.afterInitialize.selector;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         POSITION MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open inverse range position (called by Router)
     * @param positionId Unique position identifier
     * @param owner Position owner (borrower)
     * @param collateralAmount Collateral deposited
     * @param debtAmount Debt borrowed
     * @param zeroForOne Position direction
     * @param ltBps Liquidation threshold (5000-9900)
     * @return tickLower Full liquidation tick
     * @return tickUpper Liquidation start tick
     * 
     * TICK CALCULATION:
     * With 5% interest + 2% fee buffer = 7% debt growth over 1 year
     * 
     * Example: 1 ETH collateral, 1000 USDC debt, 80% LT, price $2000
     * - Initial LTV: 50%
     * - Max debt: 1000 × 1.07 = 1070 USDC
     * - tickUpper: price where LTV = 80% → $1337.5
     * - tickLower: price where LTV = 100% → $1070
     */
    function openPosition(
        uint256 positionId,
        address owner,
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (int24 tickLower, int24 tickUpper) {
        if (msg.sender != address(router)) revert OnlyRouter();
        if (collateralAmount == 0 || debtAmount == 0) revert InvalidAmount();

        // Get current tick
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate liquidation range accounting for debt growth
        (tickLower, tickUpper) = _calculateTickRange(
            currentTick,
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );

        // Create position
        positions[positionId] = Position({
            owner: owner,
            zeroForOne: zeroForOne,
            initialCollateral: collateralAmount,
            collateral: collateralAmount,
            debt: debtAmount,
            tickLower: tickLower,
            tickUpper: tickUpper,
            ltBps: ltBps,
            openTime: uint40(block.timestamp),
            lastPenaltyTime: uint40(block.timestamp),
            accumulatedPenalty: 0,
            isActive: true
        });

        // Add to tick bitmap for efficient lookup
        _addPositionToTick(positionId, tickLower, tickUpper);
        
        // Add to active positions
        positionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);

        emit PositionOpened(positionId, owner, zeroForOne, collateralAmount, debtAmount, tickLower, tickUpper);
    }

    /**
     * @notice Withdraw collateral when position is repaid (called by Router)
     */
    function withdrawPositionCollateral(uint256 positionId, address recipient)
        external
        returns (uint128 collateralAmount)
    {
        if (msg.sender != address(router)) revert OnlyRouter();
        
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();

        // Accrue any final penalty
        _accruePenalty(positionId);

        collateralAmount = pos.collateral;

        if (collateralAmount > 0) {
            // Transfer collateral to recipient (Router)
            address collateralToken = pos.zeroForOne
                ? Currency.unwrap(poolKey.currency0)
                : Currency.unwrap(poolKey.currency1);
            
            IERC20(collateralToken).safeTransfer(recipient, collateralAmount);
        }

        // Clean up
        _removePosition(positionId);

        emit PositionClosed(positionId, collateralAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         TICK RANGE CALCULATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate liquidation tick range accounting for debt growth
     * 
     * FORMULA:
     * maxDebt = initialDebt × (1 + interestRate + feeBuffer)
     *         = initialDebt × 1.07 (5% interest + 2% fee)
     * 
     * For token0 collateral (zeroForOne = true):
     * - tickUpper = price where LTV = LT
     * - tickLower = price where maxDebt = collateral value
     * 
     * ROUNDING RULES (for borrower safety):
     * - tickLower: round DOWN (more conservative, triggers later)
     * - tickUpper: round DOWN (tighter range, but safer for borrower)
     * - Always align to TICK_SPACING
     */
    function _calculateTickRange(
        int24 currentTick,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) internal view returns (int24 tickLower, int24 tickUpper) {
        // Get current price
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;

        // Calculate max debt with interest + fees (7% = 5% interest + 2% fee)
        uint256 maxDebt = (uint256(debt) * (BPS + INTEREST_RATE_BPS + FEE_BUFFER_BPS)) / BPS;

        // Calculate collateral value in debt terms at current price
        uint256 collateralValue;
        if (zeroForOne) {
            // token0 collateral: price = token1/token0
            collateralValue = (uint256(collateral) * priceX96) >> 96;
        } else {
            // token1 collateral: price = token0/token1
            collateralValue = (uint256(collateral) << 96) / priceX96;
        }

        if (collateralValue == 0) collateralValue = 1;

        // Calculate price ratios for tick calculation
        // Trigger price: where LTV = LT → price = maxDebt / (collateral × LT)
        // For zeroForOne, this means price goes DOWN to reach LT
        uint256 triggerRatio = (maxDebt * BPS) / ((collateralValue * ltBps) / BPS);
        
        // Full liquidation price: where maxDebt = collateralValue
        uint256 fullRatio = (maxDebt * BPS) / collateralValue;

        // Convert ratios to tick offsets
        int256 triggerOffset = _ratioToTickOffset(int256(triggerRatio));
        int256 fullOffset = _ratioToTickOffset(int256(fullRatio));

        if (zeroForOne) {
            // Token0 collateral: liquidation range is BELOW current tick
            // Price drops = tick decreases
            // tickUpper is closer to current (liquidation starts)
            // tickLower is further (full liquidation)
            tickUpper = currentTick - int24(triggerOffset);
            tickLower = currentTick - int24(fullOffset);
        } else {
            // Token1 collateral: liquidation range is ABOVE current tick
            // Price rises (token0 gets more expensive) = tick increases
            tickLower = currentTick + int24(triggerOffset);
            tickUpper = currentTick + int24(fullOffset);
        }

        // Ensure tickLower < tickUpper
        if (tickLower >= tickUpper) {
            // Swap them
            int24 temp = tickLower;
            tickLower = tickUpper;
            tickUpper = temp;
        }

        // Align to tick spacing with proper rounding
        // tickLower: round DOWN (floor) - more conservative
        tickLower = _floorTick(tickLower, TICK_SPACING);
        
        // tickUpper: round DOWN (floor) for zeroForOne, UP (ceil) for !zeroForOne
        // This ensures the range is always slightly tighter (safer for borrower)
        if (zeroForOne) {
            tickUpper = _floorTick(tickUpper, TICK_SPACING);
        } else {
            tickUpper = _ceilTick(tickUpper, TICK_SPACING);
        }

        // Ensure minimum range width (at least 2 ticks)
        if (tickUpper - tickLower < TICK_SPACING * 2) {
            if (zeroForOne) {
                // Expand downward (make tickLower lower)
                tickLower = tickUpper - TICK_SPACING * 2;
            } else {
                // Expand upward (make tickUpper higher)
                tickUpper = tickLower + TICK_SPACING * 2;
            }
        }

        // Final validation: ensure ticks are within valid range
        require(tickLower < tickUpper, "Invalid tick range");
        require(tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
    }

    /**
     * @notice Floor a tick to nearest tick spacing
     */
    function _floorTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--; // Round down for negative
        }
        return compressed * tickSpacing;
    }

    /**
     * @notice Ceil a tick to nearest tick spacing
     */
    function _ceilTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) {
            compressed++; // Round up for positive
        }
        return compressed * tickSpacing;
    }

    /**
     * @notice Convert price ratio to tick offset
     */
    function _ratioToTickOffset(int256 ratioBps) internal pure returns (int256 offset) {
        // For ratio = 1, offset = 0
        // For ratio < 1 (price decrease), offset is negative
        // Using approximation: offset ≈ 20000 × (ratio - 10000) / (ratio + 10000)
        int256 numerator = 20000 * (ratioBps - 10000);
        int256 denominator = ratioBps + 10000;
        if (denominator == 0) return 0;
        offset = numerator / denominator;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         TICK BITMAP MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    function _addPositionToTick(uint256 positionId, int24 tickLower, int24 tickUpper) internal {
        // Add to tickLower's position list
        positionTickIndex[positionId] = tickToPositions[tickLower].length;
        tickToPositions[tickLower].push(positionId);
        
        // Also track at tickUpper for easier range queries
        tickToPositions[tickUpper].push(positionId);
    }

    function _removePositionFromTick(uint256 positionId, int24 tick) internal {
        uint256 index = positionTickIndex[positionId];
        uint256[] storage positionList = tickToPositions[tick];
        
        if (index < positionList.length) {
            uint256 lastPositionId = positionList[positionList.length - 1];
            positionList[index] = lastPositionId;
            positionTickIndex[lastPositionId] = index;
            positionList.pop();
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         LIQUIDATION LOGIC
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Before swap hook - detect and process liquidations
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get current tick
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());

        // Process liquidations for active positions
        _processLiquidations(currentTick, params.zeroForOne, sender);

        // Return with no delta for now (simplified for MVP)
        return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    /**
     * @notice Process liquidations for positions in range
     */
    function _processLiquidations(
        int24 currentTick,
        bool swapZeroForOne,
        address swapper
    ) internal {
        // Iterate through active positions (gas inefficient for production, OK for MVP)
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            Position storage pos = positions[posId];

            if (!pos.isActive || pos.collateral == 0) continue;

            // Only liquidate if swap direction matches collateral type
            if (pos.zeroForOne != swapZeroForOne) continue;

            // Check if in liquidation range
            if (currentTick < pos.tickLower || currentTick > pos.tickUpper) continue;

            // Position is underwater - execute liquidation
            _liquidatePosition(posId, currentTick, swapper);
        }
    }

    /**
     * @notice Execute liquidation for a single position
     * 
     * LIQUIDATION STEPS:
     * 1. Accrue penalty for time underwater
     * 2. Calculate proportional collateral to liquidate
     * 3. Deduct penalty: 90% LP, 10% swapper
     * 4. Swap remaining collateral → debt token
     * 5. Send debt token to Router
     * 6. Callback to Router
     */
    function _liquidatePosition(
        uint256 positionId,
        int24 currentTick,
        address swapper
    ) internal {
        Position storage pos = positions[positionId];

        // Accrue penalty
        _accruePenalty(positionId);

        // Calculate liquidation progress (how much to liquidate)
        uint256 progressBps = _getLiquidationProgressBps(pos, currentTick);
        
        // Calculate collateral to liquidate
        uint256 targetLiquidated = (uint256(pos.initialCollateral) * progressBps) / BPS;
        uint256 alreadyLiquidated = pos.initialCollateral - pos.collateral;
        
        if (targetLiquidated <= alreadyLiquidated) return;
        
        uint128 collateralToLiquidate = uint128(targetLiquidated - alreadyLiquidated);
        if (collateralToLiquidate == 0) return;

        // Calculate penalty to deduct
        uint128 penaltyAmount = pos.accumulatedPenalty;
        uint128 lpPenalty = (penaltyAmount * uint128(LP_PENALTY_SHARE_BPS)) / uint128(BPS);
        uint128 swapperPenalty = (penaltyAmount * uint128(SWAPPER_PENALTY_SHARE_BPS)) / uint128(BPS);

        // Deduct penalty from collateral
        uint128 netCollateral = collateralToLiquidate > penaltyAmount 
            ? collateralToLiquidate - penaltyAmount 
            : 0;

        // Calculate proportional debt repaid
        uint128 debtRepaid = uint128((uint256(pos.debt) * collateralToLiquidate) / pos.initialCollateral);

        // Distribute penalties
        _distributePenalties(pos, lpPenalty, swapperPenalty, swapper);

        // Update position state
        pos.collateral = pos.collateral > collateralToLiquidate 
            ? pos.collateral - collateralToLiquidate 
            : 0;
        pos.debt = pos.debt > debtRepaid ? pos.debt - debtRepaid : 0;
        pos.accumulatedPenalty = 0;
        pos.lastPenaltyTime = uint40(block.timestamp);

        bool fullyLiquidated = pos.collateral == 0;

        // Transfer debt token to Router (simplified - assumes we have it)
        // In production, would use pool's flash accounting
        address debtToken = pos.zeroForOne
            ? Currency.unwrap(poolKey.currency1)
            : Currency.unwrap(poolKey.currency0);
        
        // For MVP: assume netCollateral was swapped to debtRepaid amount
        // In production, would execute actual swap via pool
        if (debtRepaid > 0) {
            IERC20(debtToken).safeTransfer(address(router), debtRepaid);
        }

        // Callback to Router
        router.onLiquidation(positionId, debtRepaid, collateralToLiquidate, fullyLiquidated);

        if (fullyLiquidated) {
            _removePosition(positionId);
        }

        emit LiquidationExecuted(positionId, collateralToLiquidate, penaltyAmount, debtRepaid, fullyLiquidated);
    }

    /**
     * @notice Calculate liquidation progress based on tick position
     * @return progressBps Progress in basis points (0-10000)
     */
    function _getLiquidationProgressBps(Position storage pos, int24 currentTick)
        internal
        view
        returns (uint256 progressBps)
    {
        int24 rangeWidth = pos.tickUpper - pos.tickLower;
        if (rangeWidth == 0) return BPS;

        int24 ticksIntoRange;
        if (pos.zeroForOne) {
            // Liquidation progresses as tick decreases
            ticksIntoRange = pos.tickUpper - currentTick;
        } else {
            // Liquidation progresses as tick increases
            ticksIntoRange = currentTick - pos.tickLower;
        }

        if (ticksIntoRange <= 0) return 0;
        if (ticksIntoRange >= rangeWidth) return BPS;

        progressBps = (uint256(int256(ticksIntoRange)) * BPS) / uint256(int256(rangeWidth));
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         PENALTY MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate dynamic penalty rate based on liquidation threshold
     * @dev Higher LT = riskier position = higher penalty rate
     * 
     * FORMULA:
     * penaltyRate = baseRate + (LT - 50%) × multiplier
     * 
     * EXAMPLES:
     * - LT = 50% → 10% + 0% = 10% APR
     * - LT = 70% → 10% + 20% × 1.0 = 30% APR
     * - LT = 80% → 10% + 30% × 1.0 = 40% APR
     * - LT = 95% → 10% + 45% × 1.0 = 55% APR
     * 
     * RATIONALE:
     * Higher LT positions are riskier for LPs because:
     * - Less buffer before liquidation
     * - Narrower tick range
     * - Higher probability of going underwater
     * → LPs deserve higher compensation
     */
    function _getPenaltyRate(uint16 ltBps) internal pure returns (uint256 penaltyRateBps) {
        // Base rate: 10% APR
        penaltyRateBps = BASE_PENALTY_RATE_BPS;
        
        // Add penalty for risk above 50% LT
        if (ltBps > 5000) {
            uint256 excessLT = ltBps - 5000; // LT above 50%
            uint256 additionalPenalty = (excessLT * PENALTY_RATE_MULTIPLIER) / BPS;
            penaltyRateBps += additionalPenalty;
        }
    }

    /**
     * @notice Accrue penalty for time underwater
     * Penalty = collateral × dynamicPenaltyRate × timeElapsed
     */
    function _accruePenalty(uint256 positionId) internal {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return;

        uint256 elapsed = block.timestamp - pos.lastPenaltyTime;
        if (elapsed == 0) return;

        // Check if currently in liquidation range
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        if (currentTick < pos.tickLower || currentTick > pos.tickUpper) {
            pos.lastPenaltyTime = uint40(block.timestamp);
            return;
        }

        // Calculate penalty with dynamic rate based on LT
        uint256 penaltyRate = _getPenaltyRate(pos.ltBps);
        uint256 penalty = (pos.collateral * penaltyRate * elapsed) / (BPS * SECONDS_PER_YEAR);
        pos.accumulatedPenalty += uint128(penalty);
        pos.lastPenaltyTime = uint40(block.timestamp);

        emit PenaltyAccrued(positionId, uint128(penalty));
    }

    /**
     * @notice Distribute penalties to LPs and swapper
     */
    function _distributePenalties(
        Position storage pos,
        uint128 lpPenalty,
        uint128 swapperPenalty,
        address swapper
    ) internal {
        address collateralToken = pos.zeroForOne
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // Track LP penalties (for later claiming)
        totalLPPenalties += lpPenalty;

        // Send swapper penalty directly
        if (swapperPenalty > 0) {
            IERC20(collateralToken).safeTransfer(swapper, swapperPenalty);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         POSITION CLEANUP
    // ════════════════════════════════════════════════════════════════════════════

    function _removePosition(uint256 positionId) internal {
        Position storage pos = positions[positionId];
        
        // Remove from tick bitmap
        _removePositionFromTick(positionId, pos.tickLower);
        _removePositionFromTick(positionId, pos.tickUpper);
        
        // Remove from active list
        uint256 index = positionIndex[positionId];
        uint256 lastIndex = activePositionIds.length - 1;
        
        if (index != lastIndex) {
            uint256 lastId = activePositionIds[lastIndex];
            activePositionIds[index] = lastId;
            positionIndex[lastId] = index;
        }
        
        activePositionIds.pop();
        delete positionIndex[positionId];
        
        pos.isActive = false;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function getPositionCollateral(uint256 positionId) external view returns (uint128) {
        return positions[positionId].collateral;
    }

    function isPositionInLiquidation(uint256 positionId) external view returns (bool) {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return false;

        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        return currentTick >= pos.tickLower && currentTick <= pos.tickUpper;
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getActivePositionCount() external view returns (uint256) {
        return activePositionIds.length;
    }

    function getCurrentTick() external view returns (int24) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        return tick;
    }

    /**
     * @notice Get penalty rate for a given liquidation threshold
     * @param ltBps Liquidation threshold in basis points
     * @return penaltyRateBps Annual penalty rate in basis points
     * 
     * Use this to preview penalty before opening position
     */
    function getPenaltyRateForLT(uint16 ltBps) external pure returns (uint256 penaltyRateBps) {
        return _getPenaltyRate(ltBps);
    }

    /**
     * @notice Get current penalty rate for an existing position
     */
    function getPositionPenaltyRate(uint256 positionId) external view returns (uint256 penaltyRateBps) {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        return _getPenaltyRate(pos.ltBps);
    }

    /**
     * @notice Get total collateral reserved at a specific tick
     * @dev Useful for debugging and understanding liquidity reserves
     */
    function getReservedCollateralAtTick(int24 tick) external view returns (uint128 totalReserved) {
        uint256[] storage positionIds = tickToPositions[tick];
        for (uint256 i = 0; i < positionIds.length; i++) {
            Position storage pos = positions[positionIds[i]];
            if (pos.isActive) {
                totalReserved += pos.collateral;
            }
        }
    }

    /**
     * @notice Check if a tick is properly aligned to spacing
     */
    function isTickAligned(int24 tick) external pure returns (bool) {
        return tick % TICK_SPACING == 0;
    }

    /**
     * @notice Get position count at a specific tick
     */
    function getPositionCountAtTick(int24 tick) external view returns (uint256) {
        return tickToPositions[tick].length;
    }
}
