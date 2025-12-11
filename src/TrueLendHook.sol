// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
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
 * @title TrueLendHook - PROPER NoOp Implementation
 * @notice Full implementation following Instadapp blog post architecture
 * 
 * KEY ARCHITECTURE (from blog post):
 * ════════════════════════════════════════════════════════════════════
 * 
 * INVERSE RANGE ORDER = RESERVED COLLATERAL
 * - Borrower's collateral is converted to PM claim tokens
 * - These claim tokens represent "reserved liquidity" in tick range
 * - NOT actual pool liquidity, but acts like it during liquidation
 * - When price enters range, beforeSwap uses these reserves
 * 
 * LIQUIDATION FLOW (NoOp):
 * 1. Swap occurs → beforeSwap() triggered
 * 2. Check positions in liquidation range
 * 3. Calculate collateral to liquidate
 * 4. Hook "injects" collateral into swap via BeforeSwapDelta:
 *    - Burns collateral claim tokens (provides output)
 *    - Mints debt claim tokens (receives input)
 * 5. This NoOps part of PM's swap
 * 6. Remaining swap goes through normal pool liquidity
 * 
 * EXAMPLE:
 * Position: 1 ETH collateral, 1000 USDC debt, 80% LT
 * Price drops to $1250 (40% into liquidation range)
 * 
 * Someone swaps 520 USDC → ETH:
 * - Hook liquidates 0.4 ETH (40% progress)
 * - Penalty: 0.01 ETH (30% APR × 7 days underwater)
 * - Net: 0.39 ETH available for swap
 * - At $1250/ETH: worth ~487 USDC
 * 
 * BeforeSwapDelta:
 * - Hook consumes 487 USDC (specified)
 * - Hook provides 0.39 ETH (unspecified)
 * - Remaining 33 USDC swaps through pool
 * ════════════════════════════════════════════════════════════════════
 */
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    int24 constant TICK_SPACING = 60;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    uint256 public constant INTEREST_RATE_BPS = 500;      // 5% APR
    uint256 public constant FEE_BUFFER_BPS = 200;         // 2%
    uint256 public constant BASE_PENALTY_RATE_BPS = 1000; // 10% APR base
    uint256 public constant PENALTY_RATE_MULTIPLIER = 10000; // 1.0x
    uint256 public constant LP_PENALTY_SHARE_BPS = 9000;  // 90%
    uint256 public constant SWAPPER_PENALTY_SHARE_BPS = 1000; // 10%
    uint256 public constant MIN_DONATE_THRESHOLD = 0.0001 ether; // Minimum for donate()

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct Position {
        address owner;
        bool zeroForOne;            // true = token0 collateral, borrow token1
        uint128 initialCollateral;  // Initial collateral in claim tokens
        uint128 collateral;         // Current collateral in claim tokens
        uint128 debt;               // Debt amount for tracking
        int24 tickLower;            // Full liquidation tick
        int24 tickUpper;            // Liquidation start tick
        uint16 ltBps;               // Liquidation threshold
        uint40 openTime;
        uint40 lastPenaltyTime;
        uint128 accumulatedPenalty; // Penalty in collateral token
        bool isActive;
    }

    struct CallbackData {
        uint256 positionId;
        uint128 collateralAmount;
        Currency collateralCurrency;
        address owner;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ════════════════════════════════════════════════════════════════════════════

    ITrueLendRouter public router;
    PoolKey public poolKey;
    
    mapping(uint256 => Position) public positions;
    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public positionIndex;
    
    /// @notice LP penalty rewards (in claim tokens)
    mapping(Currency => uint256) public totalLPPenalties;

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
    
    event PositionClosed(uint256 indexed positionId, uint128 collateralReturned);
    
    event LiquidationExecuted(
        uint256 indexed positionId,
        uint128 collateralLiquidated,
        uint128 penaltyDeducted,
        uint128 debtRepaid,
        bool fullyLiquidated
    );
    
    event PenaltyAccrued(uint256 indexed positionId, uint128 penaltyAmount);

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error OnlyRouter();
    error PositionNotActive();
    error InvalidAmount();
    error OnlyPoolManager();

    // ════════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ════════════════════════════════════════════════════════════════════════════

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

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
            afterSwap: true,              // ✓ DISTRIBUTE LP PENALTIES
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,  // ✓ RETURN CUSTOM DELTA
            afterSwapReturnDelta: false,  // Not needed - penalties handled in beforeSwap
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

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        poolKey = key;
        return BaseHook.afterInitialize.selector;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                    POSITION MANAGEMENT - CLAIM TOKENS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open position - Convert collateral to claim tokens (RESERVE)
     * 
     * FLOW (following CSMM pattern):
     * 1. Receive collateral ERC20 from Router
     * 2. Use PM.unlock() to convert to claim tokens
     * 3. In callback:
     *    - Settle collateral to PM (creates debit)
     *    - Take claim tokens back (creates credit)
     * 4. Hook now holds collateral as claim tokens = "reserved liquidity"
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

        Currency collateralCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;

        // Receive collateral from Router
        address collateralToken = Currency.unwrap(collateralCurrency);
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Get current tick
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate liquidation range
        (tickLower, tickUpper) = _calculateTickRange(
            currentTick,
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );

        // Convert collateral to claim tokens via unlock
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    positionId: positionId,
                    collateralAmount: collateralAmount,
                    collateralCurrency: collateralCurrency,
                    owner: owner
                })
            )
        );

        // Create position (collateral now held as claim tokens)
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

        positionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);

        emit PositionOpened(positionId, owner, zeroForOne, collateralAmount, debtAmount, tickLower, tickUpper);
    }

    /**
     * @notice Unlock callback - Convert ERC20 to claim tokens
     * 
     * PATTERN (from CSMM):
     * 1. Settle tokens to PM (ERC20 transfer, creates debit)
     * 2. Take claim tokens from PM (mint 6909, creates credit)
     * 3. Result: Hook holds claim tokens = reserved liquidity
     */
    function unlockCallback(bytes calldata data) 
        external 
        onlyPoolManager 
        returns (bytes memory) 
    {
        CallbackData memory params = abi.decode(data, (CallbackData));

        // Settle collateral to PM (creates debit)
        // burn = false → actual ERC20 transfer to PM
        params.collateralCurrency.settle(
            poolManager,
            address(this),
            params.collateralAmount,
            false // ERC20 transfer
        );

        // Take claim tokens from PM (creates credit to balance debit)
        // mint = true → receive ERC-6909 claim tokens
        params.collateralCurrency.take(
            poolManager,
            address(this),
            params.collateralAmount,
            true // mint claim tokens
        );

        // Hook now holds collateral as claim tokens
        // These represent "reserved liquidity" for liquidation
        return "";
    }

    /**
     * @notice Withdraw collateral when position repaid
     * 
     * FLOW:
     * 1. Burn claim tokens → get ERC20 from PM
     * 2. Transfer ERC20 to recipient
     */
    function withdrawPositionCollateral(uint256 positionId, address recipient)
        external
        returns (uint128 collateralAmount)
    {
        if (msg.sender != address(router)) revert OnlyRouter();
        
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();

        _accruePenalty(positionId);

        collateralAmount = pos.collateral;

        if (collateralAmount > 0) {
            Currency collateralCurrency = pos.zeroForOne 
                ? poolKey.currency0 
                : poolKey.currency1;
            
            // Use unlock to convert claim tokens back to ERC20
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        positionId: positionId,
                        collateralAmount: collateralAmount,
                        collateralCurrency: collateralCurrency,
                        owner: recipient
                    })
                )
            );

            // In callback, settle claim tokens and take ERC20
            // Then transfer to recipient
        }

        _removePosition(positionId);

        emit PositionClosed(positionId, collateralAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                    LIQUIDATION - PROPER NoOp LOGIC
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice BeforeSwap - PROPER NoOp Implementation
     * 
     * LOGIC (from blog post):
     * 1. Detect positions in liquidation range
     * 2. Calculate proportional liquidation amount
     * 3. Deduct penalty (90% LP, 10% swapper)
     * 4. Use remaining collateral to "fill" part of swap
     * 5. Return BeforeSwapDelta that NoOps this portion
     * 6. Settle with PM using claim tokens
     * 
     * CRITICAL: Liquidation occurs when swap direction is OPPOSITE to position
     * - Position with token0 collateral liquidates when buying token0 (selling token1)
     * - Position with token1 collateral liquidates when buying token1 (selling token0)
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get current tick
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        
        // Get current sqrt price for conversions
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        // Accumulate total liquidation across all positions in range
        int128 totalLiquidationSpecified = 0;   // Total debt token (input)
        int128 totalLiquidationUnspecified = 0; // Total collateral token (output)

        // Process all active positions
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            Position storage pos = positions[posId];

            if (!pos.isActive || pos.collateral == 0) continue;

            // CRITICAL: Liquidation occurs when swap direction is OPPOSITE
            // Position liquidates when someone is buying the collateral token
            if (pos.zeroForOne == params.zeroForOne) continue;

            // Check if in liquidation range
            if (currentTick < pos.tickLower || currentTick > pos.tickUpper) {
                // Not in range - just update penalty time
                pos.lastPenaltyTime = uint40(block.timestamp);
                continue;
            }

            // Position is underwater - accrue penalty
            _accruePenalty(posId);

            // Calculate liquidation amounts
            (int128 liquidationSpecified, int128 liquidationUnspecified) = 
                _executeLiquidation(posId, currentTick, sqrtPriceX96, sender);

            // Accumulate
            totalLiquidationSpecified += liquidationSpecified;
            totalLiquidationUnspecified += liquidationUnspecified;
        }

        // If no liquidations, return zero delta
        if (totalLiquidationSpecified == 0 && totalLiquidationUnspecified == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Create BeforeSwapDelta
        // This tells PM: "I'm handling this much of the swap"
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            totalLiquidationSpecified,   // Debt token we're consuming
            totalLiquidationUnspecified  // Collateral token we're providing
        );

        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                    AFTER SWAP - LP PENALTY DISTRIBUTION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice AfterSwap - Distribute LP penalties periodically
     * 
     * PATTERN (from CSMM tutorial):
     * - Penalties accumulate in beforeSwap
     * - Periodically distribute to LPs via donate()
     * - Threshold-based to avoid gas waste
     * 
     * NOTE: No afterSwapReturnDelta needed for TrueLend
     * - All revenue from liquidation penalties (handled in beforeSwap)
     * - Could add later for additional protocol fees if desired
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Distribute accumulated LP penalties
        _distributeLPPenalties(key);
        
        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Distribute LP penalties via donate()
     * 
     * MECHANISM (following CSMM pattern):
     * 1. Check if penalties exceed threshold
     * 2. Call poolManager.donate() to send to LPs
     * 3. Settle with PM (burn claim tokens)
     * 4. Reset penalty counter
     */
    function _distributeLPPenalties(PoolKey calldata key) internal {
        // Check both currencies for penalties
        uint256 penalties0 = totalLPPenalties[key.currency0];
        uint256 penalties1 = totalLPPenalties[key.currency1];
        
        // Need at least one currency above threshold
        if (penalties0 < MIN_DONATE_THRESHOLD && penalties1 < MIN_DONATE_THRESHOLD) {
            return;
        }
        
        // Prepare donate amounts
        uint256 amount0 = penalties0 >= MIN_DONATE_THRESHOLD ? penalties0 : 0;
        uint256 amount1 = penalties1 >= MIN_DONATE_THRESHOLD ? penalties1 : 0;
        
        if (amount0 == 0 && amount1 == 0) return;
        
        // Donate to LPs
        BalanceDelta delta = poolManager.donate(key, amount0, amount1, "");
        
        // Settle the donated amounts (burn claim tokens)
        // donate() creates debt that we must settle
        if (delta.amount0() < 0) {
            key.currency0.settle(
                poolManager,
                address(this),
                uint256(uint128(-delta.amount0())),
                true  // burn claim tokens
            );
        }
        
        if (delta.amount1() < 0) {
            key.currency1.settle(
                poolManager,
                address(this),
                uint256(uint128(-delta.amount1())),
                true  // burn claim tokens
            );
        }
        
        // Reset penalty counters
        if (amount0 > 0) totalLPPenalties[key.currency0] = 0;
        if (amount1 > 0) totalLPPenalties[key.currency1] = 0;
    }

    /**
     * @notice Execute liquidation for single position
     * @return liquidationSpecified Amount of input token (debt) consumed
     * @return liquidationUnspecified Amount of output token (collateral) provided
     */
    function _executeLiquidation(
        uint256 positionId,
        int24 currentTick,
        uint160 sqrtPriceX96,
        address swapper
    ) internal returns (int128 liquidationSpecified, int128 liquidationUnspecified) {
        Position storage pos = positions[positionId];

        // Calculate liquidation progress
        uint256 progressBps = _getLiquidationProgressBps(pos, currentTick);
        
        // Calculate target collateral to liquidate
        uint256 targetLiquidated = (uint256(pos.initialCollateral) * progressBps) / BPS;
        uint256 alreadyLiquidated = pos.initialCollateral - pos.collateral;
        
        if (targetLiquidated <= alreadyLiquidated) {
            return (0, 0);
        }
        
        uint128 collateralToLiquidate = uint128(targetLiquidated - alreadyLiquidated);
        if (collateralToLiquidate == 0) return (0, 0);

        // Deduct penalty
        uint128 penalty = pos.accumulatedPenalty;
        if (penalty > collateralToLiquidate) {
            penalty = collateralToLiquidate;
        }
        uint128 netCollateral = collateralToLiquidate - penalty;

        // Calculate debt amount at current price
        // netCollateral is in collateral token, need to convert to debt token
        uint128 debtAmount = _convertCollateralToDebt(
            netCollateral,
            sqrtPriceX96,
            pos.zeroForOne
        );

        // Update position state
        pos.collateral = pos.collateral > collateralToLiquidate 
            ? pos.collateral - collateralToLiquidate 
            : 0;
        
        uint128 debtReduction = uint128((uint256(pos.debt) * collateralToLiquidate) / pos.initialCollateral);
        pos.debt = pos.debt > debtReduction ? pos.debt - debtReduction : 0;
        
        pos.accumulatedPenalty = 0;
        pos.lastPenaltyTime = uint40(block.timestamp);

        bool fullyLiquidated = pos.collateral == 0;

        // Distribute penalties (in claim tokens)
        _distributePenalties(pos, penalty, swapper);

        // Settle with PoolManager using claim tokens
        _settleLiquidation(pos, netCollateral, debtAmount);

        // Callback to Router
        router.onLiquidation(positionId, debtAmount, collateralToLiquidate, fullyLiquidated);

        if (fullyLiquidated) {
            _removePosition(positionId);
        }

        emit LiquidationExecuted(positionId, collateralToLiquidate, penalty, debtAmount, fullyLiquidated);

        // Return deltas for BeforeSwapDelta
        // Specified = debt token (input) - positive means hook is owed by PM
        // Unspecified = collateral token (output) - negative means hook owes to PM
        liquidationSpecified = int128(uint128(debtAmount));
        liquidationUnspecified = -int128(uint128(netCollateral));
    }

    /**
     * @notice Settle liquidation with PoolManager
     * 
     * PATTERN (from CSMM):
     * For position with token0 collateral (zeroForOne = true):
     * - Burn token0 claim tokens (provide output)
     * - Mint token1 claim tokens (receive input)
     */
    function _settleLiquidation(
        Position storage pos,
        uint128 collateralAmount,
        uint128 debtAmount
    ) internal {
        if (pos.zeroForOne) {
            // Token0 collateral, token1 debt
            // Burn token0 claims (we owe token0 to PM)
            poolKey.currency0.settle(
                poolManager,
                address(this),
                collateralAmount,
                true // burn claim tokens
            );
            
            // Mint token1 claims (PM owes token1 to us)
            poolKey.currency1.take(
                poolManager,
                address(this),
                debtAmount,
                true // mint claim tokens
            );
        } else {
            // Token1 collateral, token0 debt
            poolKey.currency1.settle(
                poolManager,
                address(this),
                collateralAmount,
                true
            );
            
            poolKey.currency0.take(
                poolManager,
                address(this),
                debtAmount,
                true
            );
        }
    }

    /**
     * @notice Convert collateral amount to debt amount at current price
     */
    function _convertCollateralToDebt(
        uint128 collateralAmount,
        uint160 sqrtPriceX96,
        bool zeroForOne
    ) internal pure returns (uint128 debtAmount) {
        uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) >> 96;
        
        if (zeroForOne) {
            // Token0 collateral → token1 debt
            // debt = collateral * price
            debtAmount = uint128((uint256(collateralAmount) * priceX96) >> 96);
        } else {
            // Token1 collateral → token0 debt
            // debt = collateral / price
            if (priceX96 == 0) priceX96 = 1;
            debtAmount = uint128((uint256(collateralAmount) << 96) / priceX96);
        }
    }

    /**
     * @notice Calculate liquidation progress
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
            // Price dropping = tick decreasing
            ticksIntoRange = pos.tickUpper - currentTick;
        } else {
            // Price rising = tick increasing
            ticksIntoRange = currentTick - pos.tickLower;
        }

        if (ticksIntoRange <= 0) return 0;
        if (ticksIntoRange >= rangeWidth) return BPS;

        progressBps = (uint256(int256(ticksIntoRange)) * BPS) / uint256(int256(rangeWidth));
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         PENALTY MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    function _getPenaltyRate(uint16 ltBps) internal pure returns (uint256 penaltyRateBps) {
        penaltyRateBps = BASE_PENALTY_RATE_BPS;
        if (ltBps > 5000) {
            uint256 excessLT = ltBps - 5000;
            uint256 additionalPenalty = (excessLT * PENALTY_RATE_MULTIPLIER) / BPS;
            penaltyRateBps += additionalPenalty;
        }
    }

    function _accruePenalty(uint256 positionId) internal {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return;

        uint256 elapsed = block.timestamp - pos.lastPenaltyTime;
        if (elapsed == 0) return;

        // Only accrue if in range
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        if (currentTick < pos.tickLower || currentTick > pos.tickUpper) {
            pos.lastPenaltyTime = uint40(block.timestamp);
            return;
        }

        uint256 penaltyRate = _getPenaltyRate(pos.ltBps);
        uint256 penalty = (pos.collateral * penaltyRate * elapsed) / (BPS * SECONDS_PER_YEAR);
        pos.accumulatedPenalty += uint128(penalty);
        pos.lastPenaltyTime = uint40(block.timestamp);

        emit PenaltyAccrued(positionId, uint128(penalty));
    }

    function _distributePenalties(
        Position storage pos,
        uint128 totalPenalty,
        address swapper
    ) internal {
        if (totalPenalty == 0) return;

        Currency collateralCurrency = pos.zeroForOne 
            ? poolKey.currency0 
            : poolKey.currency1;

        uint128 lpPenalty = (totalPenalty * uint128(LP_PENALTY_SHARE_BPS)) / uint128(BPS);
        uint128 swapperPenalty = (totalPenalty * uint128(SWAPPER_PENALTY_SHARE_BPS)) / uint128(BPS);

        // Track LP penalties (in claim tokens) for later distribution via donate()
        totalLPPenalties[collateralCurrency] += lpPenalty;

        // Send swapper penalty immediately (convert claim → ERC20)
        // This incentivizes liquidation execution
        if (swapperPenalty > 0) {
            // Burn claim tokens
            collateralCurrency.settle(poolManager, address(this), swapperPenalty, true);
            // Send ERC20 to swapper
            collateralCurrency.take(poolManager, swapper, swapperPenalty, false);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                    TICK RANGE CALCULATION
    // ════════════════════════════════════════════════════════════════════════════

    function _calculateTickRange(
        int24 currentTick,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        // Calculate max debt with growth
        uint256 maxDebt = (uint256(debt) * (BPS + INTEREST_RATE_BPS + FEE_BUFFER_BPS)) / BPS;
        
        uint160 currentSqrtPrice = TickMath.getSqrtPriceAtTick(currentTick);
        
        // Calculate collateral value at current price
        uint256 collateralValue;
        if (zeroForOne) {
            uint256 priceX96 = uint256(currentSqrtPrice) * uint256(currentSqrtPrice) >> 96;
            collateralValue = (uint256(collateral) * priceX96) >> 96;
        } else {
            uint256 priceX96 = uint256(currentSqrtPrice) * uint256(currentSqrtPrice) >> 96;
            collateralValue = (uint256(collateral) << 96) / priceX96;
        }
        
        if (collateralValue == 0) collateralValue = 1;
        
        // Calculate price ratios
        uint256 triggerRatio = (maxDebt * BPS) / ((collateralValue * ltBps) / BPS);
        uint256 fullRatio = (maxDebt * BPS) / collateralValue;
        
        int256 triggerOffset = int256(triggerRatio) - int256(BPS);
        int256 fullOffset = int256(fullRatio) - int256(BPS);
        
        if (zeroForOne) {
            tickUpper = currentTick - int24(triggerOffset);
            tickLower = currentTick - int24(fullOffset);
        } else {
            tickLower = currentTick + int24(triggerOffset);
            tickUpper = currentTick + int24(fullOffset);
        }
        
        if (tickLower > tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }
        
        tickLower = _roundTick(tickLower, TICK_SPACING, true);
        tickUpper = _roundTick(tickUpper, TICK_SPACING, false);
        
        if (tickUpper - tickLower < TICK_SPACING * 2) {
            if (zeroForOne) {
                tickLower = tickUpper - TICK_SPACING * 2;
            } else {
                tickUpper = tickLower + TICK_SPACING * 2;
            }
        }
        
        require(tickLower >= TickMath.MIN_TICK && tickLower <= TickMath.MAX_TICK, "tickLower out of bounds");
        require(tickUpper >= TickMath.MIN_TICK && tickUpper <= TickMath.MAX_TICK, "tickUpper out of bounds");
        require(tickLower < tickUpper, "Invalid range");
    }

    function _roundTick(int24 tick, int24 spacing, bool roundDown) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (roundDown && tick < 0 && tick % spacing != 0) {
            compressed--;
        } else if (!roundDown && tick > 0 && tick % spacing != 0) {
            compressed++;
        }
        return compressed * spacing;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         HELPERS
    // ════════════════════════════════════════════════════════════════════════════

    function _removePosition(uint256 positionId) internal {
        Position storage pos = positions[positionId];
        
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

    function getPenaltyRateForLT(uint16 ltBps) external pure returns (uint256) {
        return _getPenaltyRate(ltBps);
    }

    function getPositionPenaltyRate(uint256 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        return _getPenaltyRate(pos.ltBps);
    }
}
