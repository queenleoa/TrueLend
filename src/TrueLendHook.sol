// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Position as PoolPosition} from "v4-core/libraries/Position.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

interface IDummyRouter {
    function onLiquidation(
        uint256 positionId,
        uint128 debtRepaid,
        bool isFullyLiquidated
    ) external;
}

/**
 * @title TrueLendHook - INVERSE RANGE ORDER IMPLEMENTATION
 * @notice Implements oracleless lending via inverse range orders per Instadapp design
 *
 * ════════════════════════════════════════════════════════════════════════════════
 *                          CONCEPTUAL ALIGNMENT WITH INSTADAPP
 * ════════════════════════════════════════════════════════════════════════════════
 *
 * 1. COLLATERAL → REAL POOL LIQUIDITY:
 *    - Borrower's collateral becomes ACTUAL Uniswap V4 liquidity
 *    - This liquidity is positioned in a specific range (the liquidation band)
 *    - The hook owns this liquidity, but it's part of the pool's total liquidity
 *
 * 2. AUTOMATIC LIQUIDATION VIA AMM:
 *    - When price moves into the liquidation band, swaps naturally consume this liquidity
 *    - The pool automatically converts collateral → debt token
 *    - No manual intervention or BeforeSwapDelta tricks needed
 *    - Hook tracks how much liquidity was consumed by monitoring position state
 *
 * 3. NET LIQUIDITY IN POOL:
 *    - Total pool liquidity = LP liquidity + Hook's inverse positions
 *    - Traders swap against the sum of both
 *    - As liquidation occurs, hook's liquidity decreases, total pool liquidity decreases
 *
 * 4. KEY TECHNICAL REQUIREMENTS:
 *    - Liquidation range must be OUT OF RANGE at position creation
 *    - This ensures liquidity can be added with ONLY collateral token
 *    - Hook must track liquidity consumption during swaps
 *    - Liquidity must be reduced as partial liquidations occur
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    int24 constant TICK_SPACING = 60;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant MAX_SCAN = 20;

    uint256 public constant INTEREST_RATE_BPS = 500;
    uint256 public constant FEE_BUFFER_BPS = 200;
    uint256 public constant BASE_PENALTY_RATE_BPS = 1000;
    uint256 public constant PENALTY_MULTIPLIER = 100;
    uint256 public constant LP_PENALTY_SHARE_BPS = 9000;
    uint256 public constant SWAPPER_PENALTY_SHARE_BPS = 1000;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct Position {
        address owner;
        bool zeroForOne;
        uint128 collateral;
        uint128 debt;
        int24 tickLower;
        int24 tickUpper;
        uint16 ltBps;
        uint128 liquidityInitial; // Initial liquidity added
        uint128 liquidityRemaining; // Liquidity still in pool (decreases as liquidated)
        uint40 openTime;
        uint40 lastPenaltyTime;
        uint128 accumulatedPenalty;
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ════════════════════════════════════════════════════════════════════════════

    IDummyRouter public router;
    PoolKey public poolKey;

    mapping(uint256 => Position) public positions;
    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public positionIndex;

    mapping(address => uint128) public pendingLpPenalties;
    mapping(address => uint128) public pendingSwapperPenalties;
    address public lastSwapper;

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
        int24 tickUpper,
        uint128 liquidity
    );

    event PositionLiquidated(
        uint256 indexed positionId,
        uint128 liquidityConsumed,
        uint128 debtRepaid,
        uint128 penalty,
        bool fullyLiquidated
    );

    event PositionClosed(uint256 indexed positionId);
    event PenaltyAccrued(uint256 indexed positionId, uint128 amount);

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error OnlyRouter();
    error PositionNotActive();
    error InvalidAmount();
    error RouterAlreadySet();
    error InvalidLiquidity();
    error InvalidRangePosition();

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════

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
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false, // We use REAL liquidity, not delta tricks
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function setRouter(address _router) external {
        if (address(router) != address(0)) revert RouterAlreadySet();
        router = IDummyRouter(_router);
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        poolKey = key;
        return BaseHook.afterInitialize.selector;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                    POSITION OPENING - CREATE INVERSE ORDER
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open position - CREATE THE INVERSE RANGE ORDER
     *
     * CRITICAL: The liquidation range MUST be positioned outside current price
     * so that liquidity can be added using ONLY the collateral token:
     * - zeroForOne: range is BELOW current tick (tickUpper < currentTick) → only token0 needed
     * - !zeroForOne: range is ABOVE current tick (tickLower > currentTick) → only token1 needed
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

        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate liquidation range - ensures range is outside current price
        (tickLower, tickUpper) = _calculateTickRange(
            currentTick,
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );

        // VERIFY range is positioned correctly for single-token liquidity
        if (zeroForOne) {
            if (tickUpper >= currentTick) revert InvalidRangePosition();
        } else {
            if (tickLower <= currentTick) revert InvalidRangePosition();
        }

        Currency collateralCurrency = zeroForOne
            ? poolKey.currency0
            : poolKey.currency1;

        // Transfer collateral
        IERC20(Currency.unwrap(collateralCurrency)).safeTransferFrom(
            address(router),
            address(this),
            collateralAmount
        );

        // Calculate liquidity for out-of-range position
        // When range is entirely out of range, we can use the full collateral amount
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity;
        if (zeroForOne) {
            // Range below current: only token0 (collateral) needed
            // Use getLiquidityForAmount0 since we're entirely in token0
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceLower,
                sqrtPriceUpper,
                uint256(collateralAmount)
            );
        } else {
            // Range above current: only token1 (collateral) needed
            // Use getLiquidityForAmount1 since we're entirely in token1
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtPriceLower,
                sqrtPriceUpper,
                uint256(collateralAmount)
            );
        }

        if (liquidity == 0) revert InvalidLiquidity();

        // ADD INVERSE RANGE LIQUIDITY TO POOL
        poolManager.unlock(
            abi.encode(
                uint8(1), // Action: OPEN_POSITION
                positionId,
                collateralCurrency,
                collateralAmount,
                tickLower,
                tickUpper,
                liquidity
            )
        );

        // Store position
        positions[positionId] = Position({
            owner: owner,
            zeroForOne: zeroForOne,
            collateral: collateralAmount,
            debt: debtAmount,
            tickLower: tickLower,
            tickUpper: tickUpper,
            ltBps: ltBps,
            liquidityInitial: liquidity,
            liquidityRemaining: liquidity, // Initially all liquidity is remaining
            openTime: uint40(block.timestamp),
            lastPenaltyTime: uint40(block.timestamp),
            accumulatedPenalty: 0,
            isActive: true
        });

        positionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);

        emit PositionOpened(
            positionId,
            owner,
            zeroForOne,
            collateralAmount,
            debtAmount,
            tickLower,
            tickUpper,
            liquidity
        );
    }

    /**
     * @notice Unlock callback - manages liquidity operations
     */
    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));

        if (action == 1) {
            // OPEN_POSITION: Add inverse range liquidity
            (
                ,
                uint256 positionId,
                Currency collateralCurrency,
                uint128 collateralAmount,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidityDelta
            ) = abi.decode(
                    data,
                    (uint8, uint256, Currency, uint128, int24, int24, uint128)
                );

            // Approve poolManager to spend our tokens
            address tokenAddr = Currency.unwrap(collateralCurrency);
            IERC20(tokenAddr).safeIncreaseAllowance(
                address(poolManager),
                collateralAmount
            );

            // Add liquidity to the pool
            int256 liquidityDeltaSigned = int256(uint256(liquidityDelta));

            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDeltaSigned,
                    salt: bytes32(positionId)
                }),
                ""
            );

            // Settle the tokens required for adding liquidity
            if (delta.amount0() < 0) {
                uint256 amount = uint256(uint128(-delta.amount0()));
                poolKey.currency0.settle(
                    poolManager,
                    address(this),
                    amount,
                    false
                );
            }
            if (delta.amount1() < 0) {
                uint256 amount = uint256(uint128(-delta.amount1()));
                poolKey.currency1.settle(
                    poolManager,
                    address(this),
                    amount,
                    false
                );
            }
        } else if (action == 2) {
            // CLOSE_POSITION: Remove liquidity
            (
                ,
                uint256 positionId,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidityToRemove
            ) = abi.decode(data, (uint8, uint256, int24, int24, uint128));

            // Remove liquidity
            int256 liquidityDeltaSigned = -int256(uint256(liquidityToRemove));

            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDeltaSigned,
                    salt: bytes32(positionId)
                }),
                ""
            );

            // Take back the tokens
            if (delta.amount0() > 0) {
                uint256 amount = uint256(uint128(delta.amount0()));
                poolKey.currency0.take(
                    poolManager,
                    address(this),
                    amount,
                    false
                );
            }
            if (delta.amount1() > 0) {
                uint256 amount = uint256(uint128(delta.amount1()));
                poolKey.currency1.take(
                    poolManager,
                    address(this),
                    amount,
                    false
                );
            }
        }

        return "";
    }

    /**
     * @notice Close position - remove remaining inverse range liquidity
     */
    function withdrawCollateral(
        uint256 positionId,
        address recipient
    ) external returns (uint128 collateralAmount) {
        if (msg.sender != address(router)) revert OnlyRouter();

        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();

        collateralAmount = pos.collateral;
        Currency collateralCurrency = pos.zeroForOne
            ? poolKey.currency0
            : poolKey.currency1;

        // Remove the REMAINING inverse range liquidity (not initial)
        if (pos.liquidityRemaining > 0) {
            poolManager.unlock(
                abi.encode(
                    uint8(2), // Action: CLOSE_POSITION
                    positionId,
                    pos.tickLower,
                    pos.tickUpper,
                    pos.liquidityRemaining // Only remove what's left
                )
            );
        }

        // Transfer collateral back
        if (collateralAmount > 0) {
            IERC20(Currency.unwrap(collateralCurrency)).safeTransfer(
                recipient,
                collateralAmount
            );
        }

        _removePosition(positionId);
        emit PositionClosed(positionId);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         LIQUIDATION - TRACK AMM CONVERSIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice BeforeSwap - prepare to track liquidation
     *
     * Store the liquidity state BEFORE the swap so we can detect consumption in afterSwap
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        lastSwapper = sender;

        // Accrue penalties for positions in range
        uint256 scanned = 0;
        for (
            uint256 i = 0;
            i < activePositionIds.length && scanned < MAX_SCAN;
            i++
        ) {
            scanned++;
            uint256 posId = activePositionIds[i];
            Position storage pos = positions[posId];

            if (!pos.isActive) continue;

            bool inRange = (currentTick >= pos.tickLower &&
                currentTick <= pos.tickUpper);
            if (!inRange || pos.zeroForOne != params.zeroForOne) continue;

            _accruePenalty(posId, currentTick);
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    /**
     * @notice AfterSwap - detect liquidity consumption and process liquidations
     *
     * KEY FIX: Instead of using swapDelta directly, we query the actual pool position
     * to see how much liquidity was consumed. This correctly handles:
     * - Multiple overlapping positions
     * - Partial fills
     * - Complex swap scenarios
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, // Don't use swapDelta directly
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());

        // Check each position to see if liquidity was consumed
        uint256 scanned = 0;
        for (
            uint256 i = 0;
            i < activePositionIds.length && scanned < MAX_SCAN;
            i++
        ) {
            scanned++;
            uint256 posId = activePositionIds[i];
            Position storage pos = positions[posId];

            if (!pos.isActive || pos.liquidityRemaining == 0) continue;

            bool inRange = (currentTick >= pos.tickLower &&
                currentTick <= pos.tickUpper);
            if (!inRange || pos.zeroForOne != params.zeroForOne) continue;

            // Query actual liquidity state from the pool
            uint128 liquidityAfter = _getPositionLiquidity(
                posId,
                pos.tickLower,
                pos.tickUpper
            );

            // Calculate how much was consumed
            if (liquidityAfter < pos.liquidityRemaining) {
                uint128 liquidityConsumed = pos.liquidityRemaining -
                    liquidityAfter;

                // Update remaining liquidity
                pos.liquidityRemaining = liquidityAfter;

                // Process liquidation based on consumed liquidity
                _processLiquidation(posId, liquidityConsumed, currentTick);
            }
        }

        // Distribute accumulated penalties
        _distributePenalties(key.currency0);
        _distributePenalties(key.currency1);

        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Query actual liquidity for a position from the pool
     *
     * This tells us the real state of the liquidity, accounting for consumption by swaps
     */
    function _getPositionLiquidity(
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint128) {
        bytes32 positionKey = PoolPosition.calculatePositionKey(
            address(this),
            tickLower,
            tickUpper,
            bytes32(positionId)
        );

        return poolManager.getPositionLiquidity(poolKey.toId(), positionKey);
    }

    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            // fully token0
            amount0 = FullMath.mulDiv(
                uint256(liquidity) * (sqrtPriceBX96 - sqrtPriceAX96),
                FixedPoint96.Q96,
                sqrtPriceAX96 * sqrtPriceBX96
            );
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            // split between token0 and token1
            amount0 = FullMath.mulDiv(
                uint256(liquidity) * (sqrtPriceBX96 - sqrtPriceX96),
                FixedPoint96.Q96,
                sqrtPriceX96 * sqrtPriceBX96
            );
            amount1 = FullMath.mulDiv(
                uint256(liquidity) * (sqrtPriceX96 - sqrtPriceAX96),
                1,
                FixedPoint96.Q96
            );
        } else {
            // fully token1
            amount1 = FullMath.mulDiv(
                uint256(liquidity) * (sqrtPriceBX96 - sqrtPriceAX96),
                1,
                FixedPoint96.Q96
            );
        }
    }

    /**
     * @notice Process liquidation based on consumed liquidity
     *
     * Converts consumed liquidity to collateral/debt amounts and distributes penalties
     */
    function _processLiquidation(
        uint256 positionId,
        uint128 liquidityConsumed,
        int24 currentTick
    ) internal {
        Position storage pos = positions[positionId];

        // Convert consumed liquidity back to token amounts
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(pos.tickUpper);
        uint160 currentSqrtPrice = TickMath.getSqrtPriceAtTick(currentTick);

        uint128 collateralConverted;
        if (pos.zeroForOne) {
            // Calculate amount0 from consumed liquidity
            (uint256 amount0, ) = getAmountsForLiquidity(
                currentSqrtPrice,
                sqrtPriceLower,
                sqrtPriceUpper,
                liquidityConsumed
            );
            collateralConverted = uint128(amount0);
        } else {
            // Calculate amount1 from consumed liquidity
            (, uint256 amount1) = getAmountsForLiquidity(
                currentSqrtPrice,
                sqrtPriceLower,
                sqrtPriceUpper,
                liquidityConsumed
            );
            collateralConverted = uint128(amount1);
        }

        // Apply penalty
        uint128 penalty = pos.accumulatedPenalty;
        uint128 netConverted;
        if (collateralConverted > penalty) {
            netConverted = collateralConverted - penalty;
        } else {
            netConverted = 0;
            penalty = collateralConverted;
        }

        // Distribute penalties
        address collateralAddr = Currency.unwrap(
            pos.zeroForOne ? poolKey.currency0 : poolKey.currency1
        );

        uint128 lpPenalty = uint128(
            (uint256(penalty) * LP_PENALTY_SHARE_BPS) / BPS
        );
        uint128 swapperPenalty = penalty - lpPenalty;

        pendingLpPenalties[collateralAddr] += lpPenalty;
        pendingSwapperPenalties[collateralAddr] += swapperPenalty;

        // Calculate debt repaid (simplified 1:1 for MVP)
        uint128 debtRepaid = netConverted;

        // Update position state
        pos.collateral = pos.collateral > collateralConverted
            ? pos.collateral - collateralConverted
            : 0;
        pos.debt = pos.debt > debtRepaid ? pos.debt - debtRepaid : 0;
        pos.accumulatedPenalty = 0;
        pos.lastPenaltyTime = uint40(block.timestamp);

        bool fullyLiquidated = pos.collateral == 0 ||
            pos.liquidityRemaining == 0;

        // Notify router
        router.onLiquidation(positionId, debtRepaid, fullyLiquidated);

        if (fullyLiquidated) {
            _removePosition(positionId);
        }

        emit PositionLiquidated(
            positionId,
            liquidityConsumed,
            debtRepaid,
            penalty,
            fullyLiquidated
        );
    }

    /**
     * @notice Distribute accumulated penalties
     */
    function _distributePenalties(Currency currency) internal {
        address tokenAddr = Currency.unwrap(currency);

        uint128 lpAmount = pendingLpPenalties[tokenAddr];
        uint128 swapperAmount = pendingSwapperPenalties[tokenAddr];

        if (lpAmount > 0) {
            pendingLpPenalties[tokenAddr] = 0;

            // Settle first, then donate to LPs
            currency.settle(poolManager, address(this), lpAmount, false);

            if (currency == poolKey.currency0) {
                poolManager.donate(poolKey, lpAmount, 0, "");
            } else {
                poolManager.donate(poolKey, 0, lpAmount, "");
            }
        }

        if (swapperAmount > 0 && lastSwapper != address(0)) {
            pendingSwapperPenalties[tokenAddr] = 0;
            IERC20(tokenAddr).safeTransfer(lastSwapper, swapperAmount);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                    TICK CALCULATION - ENSURES OUT-OF-RANGE POSITIONING
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate tick range ensuring it's OUTSIDE current price
     *
     * CRITICAL: The range MUST be positioned such that:
     * - zeroForOne: tickUpper < currentTick (range below current price)
     * - !zeroForOne: tickLower > currentTick (range above current price)
     *
     * This ensures liquidity can be added with only the collateral token.
     */
    function _calculateTickRange(
        int24 currentTick,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        // Calculate target prices for LT threshold and 100% LTV
        uint256 priceLT_X96 = FullMath.mulDiv(
            FullMath.mulDiv(uint256(debt), BPS, ltBps),
            uint256(1 << 96),
            uint256(collateral)
        );

        uint256 price100_X96 = FullMath.mulDiv(
            uint256(debt),
            uint256(1 << 96),
            uint256(collateral)
        );

        uint160 sqrtPriceLT_X96 = _sqrt(priceLT_X96);
        uint160 sqrtPrice100_X96 = _sqrt(price100_X96);

        int24 tickAtLT = TickMath.getTickAtSqrtPrice(sqrtPriceLT_X96);
        int24 tickAt100 = TickMath.getTickAtSqrtPrice(sqrtPrice100_X96);

        tickAtLT = _alignTick(tickAtLT);
        tickAt100 = _alignTick(tickAt100);

        if (zeroForOne) {
            // Range must be BELOW current tick
            tickUpper = tickAtLT;
            tickLower = tickAt100;

            // Ensure tickUpper < currentTick with safety margin
            if (tickUpper >= currentTick) {
                tickUpper = currentTick - TICK_SPACING * 3; // Safety margin
                int24 range = tickAtLT - tickAt100;
                if (range > 0) {
                    tickLower = tickUpper - range;
                } else {
                    tickLower = tickUpper - TICK_SPACING * 10;
                }
            }
        } else {
            // Range must be ABOVE current tick
            tickLower = tickAtLT;
            tickUpper = tickAt100;

            // Ensure tickLower > currentTick with safety margin
            if (tickLower <= currentTick) {
                tickLower = currentTick + TICK_SPACING * 3; // Safety margin
                int24 range = tickAt100 - tickAtLT;
                if (range > 0) {
                    tickUpper = tickLower + range;
                } else {
                    tickUpper = tickLower + TICK_SPACING * 10;
                }
            }
        }

        tickLower = _alignTick(tickLower);
        tickUpper = _alignTick(tickUpper);

        // Ensure minimum range
        int24 minRange = TICK_SPACING * 10;
        if (tickUpper - tickLower < minRange) {
            int24 midpoint = (tickLower + tickUpper) / 2;
            tickLower = _alignTick(midpoint - minRange / 2);
            tickUpper = _alignTick(midpoint + minRange / 2);
        }

        // Validate bounds
        if (tickLower < TickMath.MIN_TICK) tickLower = TickMath.MIN_TICK;
        if (tickUpper > TickMath.MAX_TICK) tickUpper = TickMath.MAX_TICK;
        require(tickLower < tickUpper, "Invalid tick range");
    }

    function _sqrt(uint256 x) internal pure returns (uint160) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        uint256 y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        return uint160(y);
    }

    function _alignTick(int24 tick) internal pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        return compressed * TICK_SPACING;
    }

    function _getPenaltyRate(uint16 ltBps) internal pure returns (uint256) {
        uint256 rate = BASE_PENALTY_RATE_BPS;
        if (ltBps > 5000) {
            rate += ((ltBps - 5000) * PENALTY_MULTIPLIER) / 100;
        }
        return rate;
    }

    function _accruePenalty(uint256 positionId, int24 currentTick) internal {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return;

        if (currentTick < pos.tickLower || currentTick > pos.tickUpper) {
            pos.lastPenaltyTime = uint40(block.timestamp);
            return;
        }

        uint256 elapsed = block.timestamp - pos.lastPenaltyTime;
        if (elapsed == 0) return;

        uint256 rate = _getPenaltyRate(pos.ltBps);
        uint256 penalty = (uint256(pos.collateral) * rate * elapsed) /
            (BPS * SECONDS_PER_YEAR);

        if (penalty > type(uint128).max) {
            penalty = type(uint128).max;
        }

        pos.accumulatedPenalty += uint128(penalty);
        pos.lastPenaltyTime = uint40(block.timestamp);

        emit PenaltyAccrued(positionId, uint128(penalty));
    }

    function _removePosition(uint256 positionId) internal {
        positions[positionId].isActive = false;
        uint256 index = positionIndex[positionId];
        uint256 lastIndex = activePositionIds.length - 1;
        if (index != lastIndex) {
            uint256 lastId = activePositionIds[lastIndex];
            activePositionIds[index] = lastId;
            positionIndex[lastId] = index;
        }
        activePositionIds.pop();
        delete positionIndex[positionId];
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function getPosition(
        uint256 positionId
    ) external view returns (Position memory) {
        return positions[positionId];
    }

    function getCurrentTick() external view returns (int24) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        return tick;
    }

    function getActivePositionsCount() external view returns (uint256) {
        return activePositionIds.length;
    }
}
