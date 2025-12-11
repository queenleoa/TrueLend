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
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDummyRouter {
    function onLiquidation(
        uint256 positionId,
        uint128 debtRepaid,
        bool isFullyLiquidated
    ) external;
}

/**
 * @title TrueLendHook
 * @notice Oracleless lending via inverse range orders (reserve mechanism)
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 *                              HOW IT WORKS
 * ════════════════════════════════════════════════════════════════════════════════
 * 
 * RESERVE MECHANISM (not actual negative liquidity):
 * 1. Borrower's collateral → Hook holds as ERC-6909 claim tokens
 * 2. Tick range [tickLower, tickUpper] calculated based on LT
 * 3. When price enters range → beforeSwap() detects it
 * 4. Hook NoOps swap by providing liquidity from collateral
 * 5. Penalty accrues for time underwater (locks LP liquidity)
 * 6. Distribution: 90% LP (via donate), 10% swapper
 * 
 * CLAIM TOKEN FLOW:
 * - Open: collateral.settle() + collateral.take(mint=true) → Hook has claims
 * - Liquidate: debtToken.take(mint=true) + collateralToken.settle(burn=true)
 * - Close: collateral.settle(burn=true) + collateral.take(mint=false)
 * 
 * BEFORESWAP DELTA:
 * - Specified: token user specified amount for (input for exactInput, output for exactOutput)
 * - Unspecified: the other token
 * - Positive delta = Hook is OWED by PM (Hook receives)
 * - Negative delta = Hook OWES to PM (Hook gives)
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
    
    uint256 public constant INTEREST_RATE_BPS = 500;      // 5% APR
    uint256 public constant FEE_BUFFER_BPS = 200;         // 2% buffer
    uint256 public constant BASE_PENALTY_RATE_BPS = 1000; // 10% APR base
    uint256 public constant PENALTY_MULTIPLIER = 100;     // +1% per 1% LT above 50%
    uint256 public constant LP_PENALTY_SHARE_BPS = 9000;  // 90% to LPs
    uint256 public constant SWAPPER_PENALTY_SHARE_BPS = 1000; // 10% to swapper

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct Position {
        address owner;
        bool zeroForOne;            // true = currency0 collateral, borrow currency1
        uint128 initialCollateral;
        uint128 collateral;         // Current collateral (as claim tokens)
        uint128 debt;
        int24 tickLower;            // Full liquidation tick
        int24 tickUpper;            // Liquidation start tick
        uint16 ltBps;               // Liquidation threshold
        uint40 openTime;
        uint40 lastPenaltyTime;
        uint128 accumulatedPenalty;
        bool isActive;
    }

    struct LiquidationCache {
        uint128 collateralToLiquidate;
        uint128 penalty;
        uint128 netCollateral;
        uint128 debtRepaid;
        bool fullyLiquidated;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ════════════════════════════════════════════════════════════════════════════

    IDummyRouter public router;
    PoolKey public poolKey;
    
    mapping(uint256 => Position) public positions;
    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public positionIndex;
    
    // Penalties pending distribution
    mapping(Currency => uint128) public pendingLpPenalties;
    mapping(Currency => uint128) public pendingSwapperPenalties;
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
        uint16 ltBps
    );
    
    event PositionLiquidated(
        uint256 indexed positionId,
        uint128 collateralLiquidated,
        uint128 penalty,
        uint128 debtRepaid,
        bool fullyLiquidated
    );
    
    event PositionClosed(uint256 indexed positionId, uint128 collateralReturned);
    event PenaltyAccrued(uint256 indexed positionId, uint128 amount, uint256 timeElapsed);
    event PenaltyDistributed(Currency indexed currency, uint128 lpAmount, uint128 swapperAmount);

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error OnlyRouter();
    error PositionNotActive();
    error InvalidAmount();
    error RouterAlreadySet();

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
            afterSwap: true,
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
        if (address(router) != address(0)) revert RouterAlreadySet();
        router = IDummyRouter(_router);
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
    //                         POSITION MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open position - mint claim tokens for collateral
     * 
     * FLOW:
     * 1. Transfer collateral: Router → Hook (ERC20)
     * 2. Via unlock callback:
     *    - settle: Hook sends tokens → PM (creates debit)
     *    - take: Hook mints claim tokens ← PM (creates credit, balances)
     * 3. Store position with tick range
     * 
     * TICK CALCULATION:
     * - Current price: $3000 (1 ETH = 3000 USDC)
     * - Borrow: 1500 USDC against 1 ETH, LT=80%
     * - Max debt (1yr): 1500 × 1.07 = 1605 USDC
     * - tickUpper: price where LTV=80% → $2006.25 (liquidation starts)
     * - tickLower: price where LTV=100% → $1605 (full liquidation)
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

        (tickLower, tickUpper) = _calculateTickRange(
            currentTick,
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );

        Currency collateralCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;

        // Transfer collateral from Router to Hook
        IERC20(Currency.unwrap(collateralCurrency)).safeTransferFrom(
            address(router),
            address(this),
            collateralAmount
        );

        // Mint claim tokens via unlock
        poolManager.unlock(
            abi.encode(CallbackAction.OPEN_POSITION, collateralCurrency, collateralAmount)
        );

        // Store position
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

        emit PositionOpened(
            positionId, owner, zeroForOne,
            collateralAmount, debtAmount,
            tickLower, tickUpper, ltBps
        );
    }

    enum CallbackAction {
        OPEN_POSITION,
        CLOSE_POSITION
    }

    /**
     * @notice Unlock callback for claim token management
     * 
     * OPEN_POSITION:
     * - settle(mint=false): Send actual tokens Hook → PM
     * - take(mint=true): Mint claim tokens for Hook
     * 
     * CLOSE_POSITION:
     * - settle(mint=true): Burn claim tokens
     * - take(mint=false): Receive actual tokens back
     */
    function unlockCallback(bytes calldata data) 
        external 
        onlyPoolManager 
        returns (bytes memory) 
    {
        (CallbackAction action, Currency currency, uint128 amount) = 
            abi.decode(data, (CallbackAction, Currency, uint128));

        if (action == CallbackAction.OPEN_POSITION) {
            // Send tokens to PM, mint claims for Hook
            currency.settle(poolManager, address(this), amount, false);
            currency.take(poolManager, address(this), amount, true);
        }
        else if (action == CallbackAction.CLOSE_POSITION) {
            // Burn claims, receive tokens back
            currency.settle(poolManager, address(this), amount, true);
            currency.take(poolManager, address(this), amount, false);
        }

        return "";
    }

    /**
     * @notice Withdraw collateral when borrower repays
     * 
     * FLOW:
     * 1. Burn claim tokens via unlock
     * 2. Receive actual tokens back
     * 3. Transfer to Router
     */
    function withdrawCollateral(uint256 positionId, address recipient)
        external
        returns (uint128 collateralAmount)
    {
        if (msg.sender != address(router)) revert OnlyRouter();
        
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();

        collateralAmount = pos.collateral;
        Currency collateralCurrency = pos.zeroForOne ? poolKey.currency0 : poolKey.currency1;

        if (collateralAmount > 0) {
            // Burn claims and receive tokens via unlock
            poolManager.unlock(
                abi.encode(CallbackAction.CLOSE_POSITION, collateralCurrency, collateralAmount)
            );

            // Transfer to Router
            IERC20(Currency.unwrap(collateralCurrency)).safeTransfer(recipient, collateralAmount);
        }

        _removePosition(positionId);

        emit PositionClosed(positionId, collateralAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         TICK CALCULATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate liquidation tick range
     * 
     * LOGIC:
     * 1. Max debt = debt × 1.07 (5% interest + 2% buffer over 1 year)
     * 2. Collateral value = collateral × current price
     * 3. Trigger price: where LTV = LT
     * 4. Full price: where LTV = 100%
     * 5. Convert prices to ticks, align to spacing
     * 
     * EXAMPLE (zeroForOne = true, i.e. ETH collateral, USDC debt):
     * - Current: 1 ETH @ $3000, borrow 1500 USDC, LT=80%
     * - maxDebt = 1605 USDC
     * - collateralValue = 1 ETH × $3000 = $3000
     * - triggerPrice: 1605 / (1 × 0.80) = $2006.25 → tickUpper
     * - fullPrice: 1605 / 1 = $1605 → tickLower
     * - As price drops from $3000 → $2006 → $1605, liquidation progresses
     */
    function _calculateTickRange(
        int24 currentTick,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        // Max debt with 1-year growth
        uint256 maxDebt = (uint256(debt) * (BPS + INTEREST_RATE_BPS + FEE_BUFFER_BPS)) / BPS;

        // Current price
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;

        // Collateral value in debt token terms
        uint256 collateralValue;
        if (zeroForOne) {
            collateralValue = (uint256(collateral) * priceX96) >> 96;
        } else {
            collateralValue = (uint256(collateral) << 96) / priceX96;
        }
        if (collateralValue == 0) collateralValue = 1;

        // Price ratios
        uint256 triggerRatio = (maxDebt * BPS) / ((collateralValue * ltBps) / BPS);
        uint256 fullRatio = (maxDebt * BPS) / collateralValue;

        // Convert to tick offsets (linear approximation)
        int256 triggerOffset = _priceRatioToTickOffset(triggerRatio);
        int256 fullOffset = _priceRatioToTickOffset(fullRatio);

        if (zeroForOne) {
            // Price drops → tick decreases
            tickUpper = currentTick - int24(triggerOffset);
            tickLower = currentTick - int24(fullOffset);
        } else {
            // Price rises → tick increases
            tickLower = currentTick + int24(triggerOffset);
            tickUpper = currentTick + int24(fullOffset);
        }

        // Ensure tickLower < tickUpper
        if (tickLower >= tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }

        // Align to tick spacing
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING;
        tickUpper = ((tickUpper / TICK_SPACING) + 1) * TICK_SPACING;

        // Ensure minimum range
        if (tickUpper - tickLower < TICK_SPACING * 2) {
            if (zeroForOne) {
                tickLower = tickUpper - TICK_SPACING * 2;
            } else {
                tickUpper = tickLower + TICK_SPACING * 2;
            }
        }
    }

    function _priceRatioToTickOffset(uint256 ratioBps) internal pure returns (int256) {
        if (ratioBps == BPS) return 0;
        
        // Approximate: offset ≈ 20000 × (ratio - 10000) / (ratio + 10000)
        int256 numerator = int256(20000 * (ratioBps - BPS));
        int256 denominator = int256(ratioBps + BPS);
        return numerator / denominator;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         LIQUIDATION LOGIC
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice BeforeSwap: Detect and execute liquidations
     * 
     * FLOW:
     * 1. Check if any positions in liquidation range
     * 2. Accrue penalties for time underwater
     * 3. Calculate liquidation amount (proportional to tick depth)
     * 4. Create BeforeSwapDelta to NoOp the swap
     * 5. Manage claim tokens (mint debt, burn collateral)
     * 6. Store penalties for afterSwap distribution
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        lastSwapper = sender;

        // Find position to liquidate (simplified: one per swap for MVP)
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            Position storage pos = positions[posId];

            if (!pos.isActive || pos.collateral == 0) continue;

            // Check if in range and swap direction matches
            bool inRange = (currentTick >= pos.tickLower && currentTick <= pos.tickUpper);
            if (!inRange || pos.zeroForOne != params.zeroForOne) continue;

            // Accrue penalty
            _accruePenalty(posId, currentTick);

            // Execute liquidation
            BeforeSwapDelta delta = _executeLiquidation(posId, currentTick, params);
            return (BaseHook.beforeSwap.selector, delta, 0);
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    /**
     * @notice Execute liquidation for a position
     * 
     * LIQUIDATION STEPS:
     * 1. Calculate collateral to liquidate (based on tick depth)
     * 2. Deduct penalty (time-based)
     * 3. Store penalty for distribution
     * 4. Create BeforeSwapDelta for NoOp
     * 5. Manage claim tokens
     * 6. Notify Router
     * 
     * BEFORESWAP DELTA LOGIC (for zeroForOne=true, exactInput):
     * - User wants to sell USDC for ETH
     * - Hook has ETH collateral to liquidate
     * - Hook takes USDC (mint claims) → debt repayment
     * - Hook gives ETH (burn claims) → to user
     * - BeforeSwapDelta(+USDC, -ETH) reduces amountToSwap
     */
    function _executeLiquidation(
        uint256 positionId,
        int24 currentTick,
        SwapParams calldata params
    ) internal returns (BeforeSwapDelta delta) {
        Position storage pos = positions[positionId];

        // Calculate amounts
        LiquidationCache memory cache = _calculateLiquidationAmounts(pos, currentTick);
        
        if (cache.collateralToLiquidate == 0) {
            return toBeforeSwapDelta(0, 0);
        }

        // Store penalties for afterSwap
        Currency collateralCurrency = pos.zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency debtCurrency = pos.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        
        uint128 lpPenalty = (cache.penalty * uint128(LP_PENALTY_SHARE_BPS)) / uint128(BPS);
        uint128 swapperPenalty = cache.penalty - lpPenalty;
        
        pendingLpPenalties[collateralCurrency] += lpPenalty;
        pendingSwapperPenalties[collateralCurrency] += swapperPenalty;

        // Manage claim tokens for liquidation
        delta = _manageLiquidationClaims(
            params,
            cache.netCollateral,
            cache.debtRepaid,
            debtCurrency,
            collateralCurrency
        );

        // Update position
        pos.collateral = pos.collateral > cache.collateralToLiquidate 
            ? pos.collateral - cache.collateralToLiquidate 
            : 0;
        pos.debt = pos.debt > cache.debtRepaid ? pos.debt - cache.debtRepaid : 0;
        pos.accumulatedPenalty = 0;
        pos.lastPenaltyTime = uint40(block.timestamp);

        // Send debt to Router
        if (cache.debtRepaid > 0) {
            IERC20(Currency.unwrap(debtCurrency)).safeTransfer(address(router), cache.debtRepaid);
        }

        // Notify Router
        router.onLiquidation(positionId, cache.debtRepaid, cache.fullyLiquidated);

        if (cache.fullyLiquidated) {
            _removePosition(positionId);
        }

        emit PositionLiquidated(
            positionId,
            cache.collateralToLiquidate,
            cache.penalty,
            cache.debtRepaid,
            cache.fullyLiquidated
        );
    }

    /**
     * @notice Calculate liquidation amounts
     */
    function _calculateLiquidationAmounts(
        Position storage pos,
        int24 currentTick
    ) internal view returns (LiquidationCache memory cache) {
        // Calculate progress through liquidation range
        uint256 progressBps = _getLiquidationProgress(pos, currentTick);
        
        // Target collateral to liquidate based on tick depth
        uint256 targetLiquidated = (uint256(pos.initialCollateral) * progressBps) / BPS;
        uint256 alreadyLiquidated = pos.initialCollateral - pos.collateral;
        
        if (targetLiquidated <= alreadyLiquidated) {
            return cache; // All zeros
        }
        
        cache.collateralToLiquidate = uint128(targetLiquidated - alreadyLiquidated);
        
        // Deduct penalty
        cache.penalty = pos.accumulatedPenalty;
        if (cache.penalty > cache.collateralToLiquidate) {
            cache.penalty = cache.collateralToLiquidate;
        }
        
        cache.netCollateral = cache.collateralToLiquidate - cache.penalty;
        
        // Calculate debt repaid (proportional to collateral liquidated)
        cache.debtRepaid = uint128(
            (uint256(pos.debt) * cache.netCollateral) / pos.collateral
        );
        
        cache.fullyLiquidated = (pos.collateral <= cache.collateralToLiquidate);
    }

    /**
     * @notice Manage claim tokens during liquidation
     * 
     * CLAIM TOKEN LOGIC:
     * - take(mint=true): Hook mints claims (receives tokens)
     * - settle(burn=true): Hook burns claims (gives tokens)
     * 
     * For zeroForOne swap (selling currency0 for currency1):
     * - User gives currency0 → Hook takes (mints claims)
     * - User receives currency1 → Hook settles (burns claims)
     */
    function _manageLiquidationClaims(
        SwapParams calldata params,
        uint128 netCollateral,
        uint128 debtRepaid,
        Currency debtCurrency,
        Currency collateralCurrency
    ) internal returns (BeforeSwapDelta delta) {
        bool isExactInput = params.amountSpecified < 0;

        if (isExactInput) {
            // ExactInput: User specifies input amount
            // Hook takes input (debt), gives output (collateral)
            
            // Take debt token (mint claims for Hook)
            debtCurrency.take(poolManager, address(this), debtRepaid, true);
            
            // Give collateral token (burn claims)
            collateralCurrency.settle(poolManager, address(this), netCollateral, true);
            
            // BeforeSwapDelta(specified, unspecified)
            // Specified = input = debt (positive = Hook is owed)
            // Unspecified = output = collateral (negative = Hook owes)
            delta = toBeforeSwapDelta(int128(debtRepaid), -int128(netCollateral));
        } else {
            // ExactOutput: User specifies output amount
            // Hook takes input (debt), gives output (collateral)
            
            debtCurrency.take(poolManager, address(this), debtRepaid, true);
            collateralCurrency.settle(poolManager, address(this), netCollateral, true);
            
            // Specified = output = collateral (negative = Hook owes)
            // Unspecified = input = debt (positive = Hook is owed)
            delta = toBeforeSwapDelta(-int128(netCollateral), int128(debtRepaid));
        }
    }

    /**
     * @notice AfterSwap: Distribute penalties to LPs and swapper
     * 
     * LP PENALTIES:
     * - Via donate() which requires settlement first
     * - Hook must settle tokens to PM before calling donate()
     * 
     * SWAPPER PENALTIES:
     * - Direct ERC20 transfer
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _distributePenalties(key.currency0);
        _distributePenalties(key.currency1);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _distributePenalties(Currency currency) internal {
        uint128 lpAmount = pendingLpPenalties[currency];
        uint128 swapperAmount = pendingSwapperPenalties[currency];

        // Distribute to LPs via donate
        if (lpAmount > 0) {
            pendingLpPenalties[currency] = 0;
            
            // Settle tokens before donate
            currency.settle(poolManager, address(this), lpAmount, false);
            
            // Donate to LPs
            if (currency == poolKey.currency0) {
                poolManager.donate(poolKey, lpAmount, 0, "");
            } else {
                poolManager.donate(poolKey, 0, lpAmount, "");
            }
            
            emit PenaltyDistributed(currency, lpAmount, 0);
        }

        // Transfer to swapper
        if (swapperAmount > 0 && lastSwapper != address(0)) {
            pendingSwapperPenalties[currency] = 0;
            IERC20(Currency.unwrap(currency)).safeTransfer(lastSwapper, swapperAmount);
            emit PenaltyDistributed(currency, 0, swapperAmount);
        }
    }

    /**
     * @notice Calculate liquidation progress based on tick position
     * 
     * LOGIC:
     * - 0% at tickUpper (just entered range)
     * - 100% at tickLower (fully liquidated)
     * - Linear interpolation between
     * 
     * For zeroForOne (price dropping):
     * - ticksIntoRange = tickUpper - currentTick
     * - As price drops, currentTick decreases, ticksIntoRange increases
     */
    function _getLiquidationProgress(Position storage pos, int24 currentTick)
        internal
        view
        returns (uint256 progressBps)
    {
        int24 rangeWidth = pos.tickUpper - pos.tickLower;
        if (rangeWidth == 0) return BPS;

        int24 ticksIntoRange;
        if (pos.zeroForOne) {
            ticksIntoRange = pos.tickUpper - currentTick;
        } else {
            ticksIntoRange = currentTick - pos.tickLower;
        }

        if (ticksIntoRange <= 0) return 0;
        if (ticksIntoRange >= rangeWidth) return BPS;

        progressBps = (uint256(uint24(ticksIntoRange)) * BPS) / uint256(uint24(rangeWidth));
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         PENALTY CALCULATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Dynamic penalty rate based on LT
     * 
     * FORMULA: penaltyRate = 10% + (LT - 50%) × 1.0
     * 
     * RATIONALE:
     * Higher LT = narrower range = riskier for LPs = higher compensation
     * 
     * LT=50% → 10% APR (safe, wide range)
     * LT=80% → 40% APR (moderate, medium range)
     * LT=95% → 55% APR (risky, narrow range)
     */
    function _getPenaltyRate(uint16 ltBps) internal pure returns (uint256 penaltyRateBps) {
        penaltyRateBps = BASE_PENALTY_RATE_BPS;
        
        if (ltBps > 5000) {
            uint256 excessLt = ltBps - 5000;
            uint256 additionalPenalty = (excessLt * PENALTY_MULTIPLIER) / 100;
            penaltyRateBps += additionalPenalty;
        }
    }

    /**
     * @notice Accrue penalty for time in liquidation range
     * 
     * PENALTY LOGIC:
     * - Only accrues while in liquidation range (underwater)
     * - Based on time elapsed since last accrual
     * - Rate determined by LT (riskier = higher rate)
     * - Locks LP liquidity → LPs deserve compensation
     * 
     * CALCULATION:
     * penalty = collateral × penaltyRate × timeElapsed / YEAR
     */
    function _accruePenalty(uint256 positionId, int24 currentTick) internal {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return;

        // Only accrue if in range
        if (currentTick < pos.tickLower || currentTick > pos.tickUpper) {
            pos.lastPenaltyTime = uint40(block.timestamp);
            return;
        }

        uint256 timeElapsed = block.timestamp - pos.lastPenaltyTime;
        if (timeElapsed == 0) return;

        uint256 penaltyRate = _getPenaltyRate(pos.ltBps);
        uint256 penalty = (pos.collateral * penaltyRate * timeElapsed) 
            / (BPS * SECONDS_PER_YEAR);
        
        pos.accumulatedPenalty += uint128(penalty);
        pos.lastPenaltyTime = uint40(block.timestamp);

        emit PenaltyAccrued(positionId, uint128(penalty), timeElapsed);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         HELPERS
    // ════════════════════════════════════════════════════════════════════════════

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
    //                         VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getActivePositionCount() external view returns (uint256) {
        return activePositionIds.length;
    }

    function isPositionInLiquidation(uint256 positionId) external view returns (bool) {
        Position storage pos = positions[positionId];
        if (!pos.isActive) return false;

        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        return currentTick >= pos.tickLower && currentTick <= pos.tickUpper;
    }

    function getCurrentTick() external view returns (int24) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        return tick;
    }

    function getPenaltyRate(uint16 ltBps) external pure returns (uint256) {
        return _getPenaltyRate(ltBps);
    }
}