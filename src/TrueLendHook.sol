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
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITrueLendRouter {
    function onLiquidation(uint256 positionId, address debtToken, uint128 debtRepaid, uint128 penaltyToLPs) external;
}

/**
 * @title TrueLendHook
 * @notice Uniswap v4 hook for oracleless lending with inverse range orders
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 *                              TICK RANGE LOGIC
 * ════════════════════════════════════════════════════════════════════════════════
 * 
 * For ETH/USDC (ETH = token0, USDC = token1):
 *   - Uniswap price = USDC per ETH
 *   - Higher tick = higher ETH price
 * 
 * Example: ETH at $2000, deposit 1 ETH, borrow 1000 USDC, LT = 80%
 *   - LTV = 1000/2000 = 50%
 *   - Liquidation trigger: price where LTV = LT
 *     triggerPrice = debt / (collateral × LT) = 1000 / (1 × 0.8) = $1250
 *   - Full liquidation: price where collateralValue = debt
 *     fullPrice = debt / collateral = $1000
 * 
 * For token0 collateral (zeroForOne = true):
 *   - Liquidation range is BELOW current tick
 *   - tickUpper = tick at trigger price ($1250)
 *   - tickLower = tick at full liquidation price ($1000)
 * 
 * LOWER LT → trigger CLOSER to current price, WIDER range (gradual liquidation)
 * HIGHER LT → trigger FURTHER from current price, NARROWER range (fast once triggered)
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 *                              PENALTY SYSTEM
 * ════════════════════════════════════════════════════════════════════════════════
 * 
 * When position is in liquidation range (underwater):
 *   - Penalty accrues at 30% APR on remaining collateral value
 *   - On liquidation: 95% to LPs (via Router), 5% to swappers (direct)
 * 
 * This incentivizes:
 *   1. LPs to provide liquidity (earn penalty yield)
 *   2. Swappers to execute liquidations (earn 5% reward)
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS & EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    error OnlyRouter();
    error PositionNotActive();
    error InvalidAmount();

    event PositionOpened(
        uint256 indexed id,
        address owner,
        bool zeroForOne,
        uint128 collateral,
        uint128 debt,
        int24 tickLower,
        int24 tickUpper
    );
    event PositionClosed(uint256 indexed id, uint128 collateralReturned, uint128 penaltyPaid);
    event Liquidation(
        uint256 indexed id,
        uint128 collateralLiquidated,
        uint128 debtRepaid,
        uint128 penaltyToLPs,
        uint128 penaltyToSwapper,
        bool fullyLiquidated
    );

    // ════════════════════════════════════════════════════════════════════════════
    //                                 STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct Position {
        address owner;
        bool zeroForOne;            // true = token0 collateral, borrow token1
        uint128 collateral;         // Remaining collateral
        uint128 debt;               // Remaining debt
        uint128 originalCollateral;
        uint128 originalDebt;
        int24 tickLower;            // Full liquidation tick
        int24 tickUpper;            // Trigger tick
        uint40 lastPenaltyTime;     // Last time penalty was calculated
        uint128 accumulatedPenalty; // Penalty accrued while underwater
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                               CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    int24 constant TICK_SPACING = 60;

    /// @notice 30% APR penalty rate when underwater
    /// 30% / year = 30e18 / 31536000 ≈ 9.51e11 per second
    uint256 public constant PENALTY_RATE_PER_SECOND = 365; //find a way to write actual rate

    /// @notice 95% of penalty goes to LPs
    uint256 public constant LP_PENALTY_BPS = 9500;

    /// @notice 5% of penalty goes to swappers
    uint256 public constant SWAPPER_PENALTY_BPS = 500;

    // ════════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ════════════════════════════════════════════════════════════════════════════

    ITrueLendRouter public router;
    PoolKey public poolKey;
    bool public poolKeySet;

    mapping(uint256 => Position) public positions;
    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public positionIndex; // positionId => index in activePositionIds

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════

    constructor(IPoolManager _pm) BaseHook(_pm) {}

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
    //                                SETUP
    // ════════════════════════════════════════════════════════════════════════════

    function setRouter(address _router) external {
        require(address(router) == address(0), "Already set");
        router = ITrueLendRouter(_router);
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal override returns (bytes4)
    {
        poolKey = key;
        poolKeySet = true;
        return this.afterInitialize.selector;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         POSITION MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open a new inverse position
     * @dev Called by router after transferring collateral to this contract
     */
    function openPosition(
        uint256 positionId,
        address owner,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (int24 tickLower, int24 tickUpper) {
        require(msg.sender == address(router), "Only router");
        require(poolKeySet, "Pool not set");
        require(collateral > 0 && debt > 0, "Zero amount");

        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Calculate liquidation range
        (tickLower, tickUpper) = _calcLiquidationRange(currentTick, collateral, debt, zeroForOne, ltBps);

        positions[positionId] = Position({
            owner: owner,
            zeroForOne: zeroForOne,
            collateral: collateral,
            debt: debt,
            originalCollateral: collateral,
            originalDebt: debt,
            tickLower: tickLower,
            tickUpper: tickUpper,
            lastPenaltyTime: uint40(block.timestamp),
            accumulatedPenalty: 0,
            isActive: true
        });

        // Track active position
        positionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);

        emit PositionOpened(positionId, owner, zeroForOne, collateral, debt, tickLower, tickUpper);
    }

    /**
     * @notice Close position and return remaining collateral
     * @dev Called by router when borrower repays
     */
    function closePosition(uint256 positionId) external returns (
        uint128 collateralReturned,
        uint128 debtRemaining,
        uint128 penaltyOwed
    ) {
        require(msg.sender == address(router), "Only router");

        Position storage pos = positions[positionId];
        require(pos.isActive, "Not active");

        // Accrue any final penalty
        _accruePenalty(positionId);

        collateralReturned = pos.collateral;
        debtRemaining = pos.debt;
        penaltyOwed = pos.accumulatedPenalty;

        // Transfer collateral back to router (router will send to borrower)
        if (collateralReturned > 0) {
            address collateralToken = pos.zeroForOne
                ? Currency.unwrap(poolKey.currency0)
                : Currency.unwrap(poolKey.currency1);
            IERC20(collateralToken).safeTransfer(address(router), collateralReturned);
        }

        // Cleanup
        pos.isActive = false;
        _removeFromActive(positionId);

        emit PositionClosed(positionId, collateralReturned, penaltyOwed);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          TICK RANGE CALCULATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate liquidation tick range
     * 
     * FORMULA:
     *   triggerPrice = debt / (collateral × LT)  → tickUpper for zeroForOne
     *   fullPrice = debt / collateral            → tickLower for zeroForOne
     * 
     * Price ratio to tick: tickOffset ≈ ln(ratio) × 10000 ≈ 2×(ratio-1)/(ratio+1) × 10000
     */
    function _calcLiquidationRange(
        int24 currentTick,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) internal view returns (int24 tickLower, int24 tickUpper) {
        // Get current price to calculate collateral value
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;

        // Calculate collateral value in debt terms
        uint256 collateralValue;
        if (zeroForOne) {
            // token0 collateral, price = token1/token0
            collateralValue = (uint256(collateral) * priceX96) >> 96;
        } else {
            // token1 collateral, need token0/token1
            collateralValue = (uint256(collateral) << 96) / priceX96;
        }

        if (collateralValue == 0) collateralValue = 1;

        // LTV in basis points
        uint256 ltvBps = (uint256(debt) * BPS) / collateralValue;
        if (ltvBps == 0) ltvBps = 1;
        if (ltvBps > BPS) ltvBps = BPS;

        // Price ratios (relative to current price):
        // Trigger: LTV/LT (when currentLTV = LT)
        // Full: LTV/100% = LTV (when collateralValue = debt)
        
        int256 triggerRatio = int256((ltvBps * BPS) / ltBps); // in BPS (e.g., 6250 for 62.5%)
        int256 fullRatio = int256(ltvBps);                     // in BPS (e.g., 5000 for 50%)

        // Convert ratios to tick offsets
        // tick ∝ ln(price), so tickOffset ≈ 10000 × ln(ratio)
        // Using approximation: ln(r) ≈ 2(r-1)/(r+1) for r near 1
        int256 triggerOffset = _ratioToTickOffset(triggerRatio);
        int256 fullOffset = _ratioToTickOffset(fullRatio);

        if (zeroForOne) {
            // Token0 collateral: price drops = tick decreases
            // Range is BELOW current tick
            tickUpper = currentTick + int24(triggerOffset); // Trigger (less negative = higher tick)
            tickLower = currentTick + int24(fullOffset);     // Full (more negative = lower tick)
        } else {
            // Token1 collateral: for us "price drop" means tick increases
            // Range is ABOVE current tick
            tickLower = currentTick - int24(triggerOffset);
            tickUpper = currentTick - int24(fullOffset);
        }

        // Ensure tickLower < tickUpper
        if (tickLower > tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }

        // Align to tick spacing
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING;
        tickUpper = ((tickUpper / TICK_SPACING) + 1) * TICK_SPACING;

        // Minimum range width
        if (tickUpper - tickLower < TICK_SPACING * 2) {
            tickLower = tickUpper - TICK_SPACING * 2;
        }
    }

    /**
     * @notice Convert price ratio to tick offset
     * @param ratioBps Price ratio in basis points (10000 = 1.0)
     * @return offset Tick offset (negative for prices below current)
     */
    function _ratioToTickOffset(int256 ratioBps) internal pure returns (int256 offset) {
        // ln(r) ≈ 2(r-1)/(r+1) for r = ratioBps/10000
        // offset = 10000 × ln(r) ≈ 20000 × (ratioBps - 10000) / (ratioBps + 10000)
        int256 num = 2 * (ratioBps - 10000) * 10000;
        int256 denom = ratioBps + 10000;
        if (denom == 0) return 0;
        offset = num / denom;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              SWAP HOOK
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Before swap - detect and process liquidations
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        (
            uint128 totalCollateralLiquidated,
            uint128 totalDebtRepaid,
            uint128 totalSwapperReward
        ) = _processLiquidations(currentTick, params.zeroForOne, key, sender);

        if (totalCollateralLiquidated == 0) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Transfer swapper reward
        if (totalSwapperReward > 0) {
            address debtToken = params.zeroForOne
                ? Currency.unwrap(key.currency1)
                : Currency.unwrap(key.currency0);
            // In a real implementation, this would be handled via the delta
            // For simplicity, we assume swapper gets their share via the improved swap rate
        }

        // Return delta: we provide collateral, the swap provides debt
        BeforeSwapDelta delta = toBeforeSwapDelta(
            -int128(totalCollateralLiquidated),  // We provide collateral (negative = outflow)
            int128(totalDebtRepaid)              // We receive debt (positive = inflow)
        );

        return (this.beforeSwap.selector, delta, 0);
    }

    /**
     * @notice Process liquidations for positions in range
     */
    function _processLiquidations(
        int24 currentTick,
        bool swapZeroForOne,
        PoolKey calldata key,
        address swapper
    ) internal returns (
        uint128 totalCollateral,
        uint128 totalDebt,
        uint128 totalSwapperReward
    ) {
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            Position storage pos = positions[posId];

            if (!pos.isActive || pos.collateral == 0) continue;

            // Only liquidate positions where swap direction matches collateral type
            if (pos.zeroForOne != swapZeroForOne) continue;

            // Check if in liquidation range
            bool inRange = currentTick >= pos.tickLower && currentTick <= pos.tickUpper;
            if (!inRange) continue;

            (uint128 col, uint128 dbt, uint128 swpReward) = _liquidatePosition(posId, currentTick, key);
            totalCollateral += col;
            totalDebt += dbt;
            totalSwapperReward += swpReward;
        }
    }

    /**
     * @notice Liquidate a single position
     */
    function _liquidatePosition(
        uint256 positionId,
        int24 currentTick,
        PoolKey calldata key
    ) internal returns (uint128 collateralLiquidated, uint128 debtRepaid, uint128 swapperReward) {
        Position storage pos = positions[positionId];

        // Accrue penalty first
        _accruePenalty(positionId);

        // Calculate liquidation progress (0% at tickUpper to 100% at tickLower for zeroForOne)
        int24 rangeWidth = pos.tickUpper - pos.tickLower;
        if (rangeWidth == 0) rangeWidth = 1;

        int24 ticksIntoRange;
        if (pos.zeroForOne) {
            // Liquidation progresses as tick decreases
            ticksIntoRange = pos.tickUpper - currentTick;
        } else {
            // Liquidation progresses as tick increases
            ticksIntoRange = currentTick - pos.tickLower;
        }

        if (ticksIntoRange < 0) ticksIntoRange = 0;
        if (ticksIntoRange > rangeWidth) ticksIntoRange = rangeWidth;

        uint256 progressPct = (uint256(int256(ticksIntoRange)) * PRECISION) / uint256(int256(rangeWidth));
        uint256 targetLiquidated = (uint256(pos.originalCollateral) * progressPct) / PRECISION;
        uint256 alreadyLiquidated = pos.originalCollateral - pos.collateral;

        if (targetLiquidated <= alreadyLiquidated) return (0, 0, 0);

        collateralLiquidated = uint128(targetLiquidated - alreadyLiquidated);

        // Proportional debt and penalty
        debtRepaid = uint128((uint256(pos.originalDebt) * collateralLiquidated) / pos.originalCollateral);

        // Calculate penalty share for this liquidation
        uint256 penaltyShare = (uint256(pos.accumulatedPenalty) * collateralLiquidated) / pos.collateral;
        uint128 penaltyToLPs = uint128((penaltyShare * LP_PENALTY_BPS) / BPS);
        swapperReward = uint128((penaltyShare * SWAPPER_PENALTY_BPS) / BPS);

        // Update position
        pos.collateral -= collateralLiquidated;
        pos.debt = pos.debt >= debtRepaid ? pos.debt - debtRepaid : 0;
        pos.accumulatedPenalty -= uint128(penaltyShare);

        bool fullyLiquidated = pos.collateral == 0;
        if (fullyLiquidated) {
            pos.isActive = false;
            _removeFromActive(positionId);
        }

        // Notify router
        address debtToken = pos.zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        router.onLiquidation(positionId, debtToken, debtRepaid, penaltyToLPs);

        emit Liquidation(positionId, collateralLiquidated, debtRepaid, penaltyToLPs, swapperReward, fullyLiquidated);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                           PENALTY ACCRUAL
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Accrue penalty for position if underwater
     * @dev Penalty = 30% APR × time × collateral value
     */
    function _accruePenalty(uint256 positionId) internal {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return;

        uint256 elapsed = block.timestamp - pos.lastPenaltyTime;
        if (elapsed == 0) return;

        pos.lastPenaltyTime = uint40(block.timestamp);

        // Check if in liquidation range
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        bool inRange = currentTick >= pos.tickLower && currentTick <= pos.tickUpper;

        if (!inRange) return;

        // Penalty accrues on remaining collateral
        uint256 penalty = (PENALTY_RATE_PER_SECOND * elapsed * pos.collateral) / PRECISION;
        pos.accumulatedPenalty += uint128(penalty);
    }

    function _removeFromActive(uint256 positionId) internal {
        uint256 idx = positionIndex[positionId];
        uint256 lastIdx = activePositionIds.length - 1;

        if (idx != lastIdx) {
            uint256 lastId = activePositionIds[lastIdx];
            activePositionIds[idx] = lastId;
            positionIndex[lastId] = idx;
        }

        activePositionIds.pop();
        delete positionIndex[positionId];
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function getPosition(uint256 id) external view returns (Position memory) {
        return positions[id];
    }

    function getPositionInfo(uint256 id) external view returns (
        uint128 collateral,
        uint128 debt,
        uint128 penalty,
        bool isActive,
        bool inLiquidation
    ) {
        Position storage pos = positions[id];
        collateral = pos.collateral;
        debt = pos.debt;
        isActive = pos.isActive;

        // Calculate current penalty (including pending)
        penalty = pos.accumulatedPenalty;
        if (isActive && pos.collateral > 0) {
            (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
            inLiquidation = currentTick >= pos.tickLower && currentTick <= pos.tickUpper;

            if (inLiquidation) {
                uint256 elapsed = block.timestamp - pos.lastPenaltyTime;
                penalty += uint128((PENALTY_RATE_PER_SECOND * elapsed * pos.collateral) / PRECISION);
            }
        }
    }

    function getCurrentTick() external view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolKey.toId());
    }

    function isInLiquidationRange(uint256 positionId) external view returns (bool) {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return false;

        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        return currentTick >= pos.tickLower && currentTick <= pos.tickUpper;
    }

    function getLiquidationProgress(uint256 positionId) external view returns (uint256 progressBps) {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return 0;

        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Outside range
        if (currentTick > pos.tickUpper) return 0;
        if (currentTick < pos.tickLower) return 10000;

        int24 rangeWidth = pos.tickUpper - pos.tickLower;
        int24 ticksIntoRange = pos.zeroForOne
            ? pos.tickUpper - currentTick
            : currentTick - pos.tickLower;

        return (uint256(int256(ticksIntoRange)) * 10000) / uint256(int256(rangeWidth));
    }

    function getActivePositionCount() external view returns (uint256) {
        return activePositionIds.length;
    }

    function getActivePositions() external view returns (uint256[] memory) {
        return activePositionIds;
    }
}
