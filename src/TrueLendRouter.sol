// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface ITrueLendHook {
    function openPosition(
        uint256 positionId,
        address owner,
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (int24 tickLower, int24 tickUpper);
    
    function withdrawPositionCollateral(uint256 positionId, address recipient) 
        external 
        returns (uint128 collateralAmount);
    
    function getPositionCollateral(uint256 positionId) 
        external view 
        returns (uint128 remainingCollateral);
    
    function isPositionInLiquidation(uint256 positionId) 
        external view 
        returns (bool inRange);
}

/**
 * @title TrueLendRouter
 * @notice MVP: Simplified lending router with fixed interest rates
 * 
 * ARCHITECTURE:
 * ┌─────────────────────────────────────────────────────────────────┐
 * │                         LENDING POOLS                            │
 * ├─────────────────────────────────────────────────────────────────┤
 * │                                                                  │
 * │  Pool 0 (ETH)                    Pool 1 (USDC)                  │
 * │  ├─ totalDeposits                ├─ totalDeposits               │
 * │  ├─ totalBorrows                 ├─ totalBorrows                │
 * │  └─ totalShares                  └─ totalShares                 │
 * │                                                                  │
 * │  BORROW FLOW:                                                    │
 * │  1. User deposits collateral → Router                           │
 * │  2. Router transfers collateral → Hook                          │
 * │  3. Hook creates inverse range position                         │
 * │  4. Router sends borrowed tokens → User                         │
 * │                                                                  │
 * │  LIQUIDATION FLOW (tick-wise):                                  │
 * │  Hook (during swap):                                             │
 * │    1. Detects position in range                                 │
 * │    2. Calculates proportional liquidation                       │
 * │    3. Deducts penalty (e.g., 30% of liquidated collateral)      │
 * │       ├─ 95% penalty → LPs directly (Hook distributes)          │
 * │       └─ 5% penalty → Swapper directly (Hook sends)             │
 * │    4. Swaps remaining collateral (after penalty) → debt token   │
 * │    5. Sends debt token to Router                                │
 * │                                                                  │
 * │  Router (callback):                                              │
 * │    1. Receives debt repayment from Hook                         │
 * │    2. Updates: decrease totalBorrows                            │
 * │    3. Tracks position state                                     │
 * │                                                                  │
 * │  REPAY FLOW:                                                     │
 * │  1. User repays debt + interest → Router                        │
 * │  2. Hook transfers remaining collateral → Router                │
 * │  3. Router returns collateral → User                            │
 * │                                                                  │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * MVP SIMPLIFICATIONS:
 * - Fixed interest rate (5% APR)
 * - User-chosen LT (50%-99%)
 * - Flexible initial LTV
 * - Tick range accounts for debt growth:
 *   * tickUpper = LT price (liquidation starts)
 *   * tickLower = 100% LTV price including interest/fees (full liquidation)
 * 
 * KEY DESIGN:
 * - Hook handles LP/swapper compensation directly
 * - Router handles lender/borrower redistribution
 * - Collateral flow: Hook → Router → User
 */
contract TrueLendRouter {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS & TYPES
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Simple lending pool for a single token
     */
    struct LendingPool {
        uint128 totalDeposits;      // Total tokens in pool
        uint128 totalBorrows;       // Total tokens borrowed out
        uint128 totalShares;        // Total share tokens
    }

    /**
     * @notice Borrow position - tracks debt and ownership
     * @dev Collateral is held in Hook, not here
     */
    struct BorrowPosition {
        address owner;
        bool zeroForOne;            // true = token0 collateral, borrow token1
        uint128 initialDebt;        // Debt at opening
        uint128 currentDebt;        // Current debt (increases with interest)
        uint128 collateralAmount;   // Initial collateral (Hook holds actual amount)
        uint40 openTime;            // When position opened
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                                 CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    
    /// @notice Fixed interest rate: 5% APR
    uint256 public constant INTEREST_RATE_BPS = 500;  // 5%
    
    /// @notice Liquidation threshold bounds
    uint16 public constant MIN_LT = 5000;   // 50%
    uint16 public constant MAX_LT = 9900;   // 99%

    // ════════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ════════════════════════════════════════════════════════════════════════════

    IPoolManager public immutable poolManager;
    ITrueLendHook public hook;
    PoolKey public poolKey;
    
    address public immutable token0;
    address public immutable token1;
    
    LendingPool public pool0;
    LendingPool public pool1;
    
    /// @notice User shares: token => user => shares
    mapping(address => mapping(address => uint256)) public shares;
    
    /// @notice Borrow positions
    uint256 public nextPositionId = 1;
    mapping(uint256 => BorrowPosition) public positions;

    // ════════════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Borrow(
        uint256 indexed positionId,
        address indexed borrower,
        bool zeroForOne,
        uint128 collateral,
        uint128 debt,
        uint16 ltBps
    );
    event Repay(
        uint256 indexed positionId, 
        uint128 debtPaid, 
        uint128 collateralReturned
    );
    event PartialLiquidation(
        uint256 indexed positionId,
        uint128 debtRepaid,
        uint128 collateralLiquidated
    );
    event FullLiquidation(uint256 indexed positionId);

    // ════════════════════════════════════════════════════════════════════════════
    //                                 ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error InvalidToken();
    error InvalidLT();
    error InsufficientLiquidity();
    error InsufficientShares();
    error PositionNotActive();
    error NotPositionOwner();
    error OnlyHook();

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════

    constructor(
        IPoolManager _poolManager,
        address _token0,
        address _token1
    ) {
        poolManager = _poolManager;
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @notice Initialize with hook address and pool key
     * @dev Called once after hook deployment
     */
    function initialize(address _hook, PoolKey memory _poolKey) external {
        require(address(hook) == address(0), "Already initialized");
        hook = ITrueLendHook(_hook);
        poolKey = _poolKey;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          LENDER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit tokens into lending pool
     * @param token Token to deposit (token0 or token1)
     * @param amount Amount to deposit
     * @return sharesIssued Share tokens minted
     * 
     * Shares represent proportional claim on pool
     */
    function deposit(address token, uint256 amount) 
        external 
        returns (uint256 sharesIssued) 
    {
        if (amount == 0) revert ZeroAmount();
        
        LendingPool storage pool = _getPool(token);
        
        // Calculate shares
        if (pool.totalShares == 0) {
            sharesIssued = amount;
        } else {
            sharesIssued = (amount * pool.totalShares) / pool.totalDeposits;
        }
        
        // Update pool
        pool.totalDeposits += uint128(amount);
        pool.totalShares += uint128(sharesIssued);
        shares[token][msg.sender] += sharesIssued;
        
        // Transfer tokens
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        emit Deposit(token, msg.sender, amount, sharesIssued);
    }

    /**
     * @notice Withdraw tokens by burning shares
     * @param token Token to withdraw
     * @param shareAmount Shares to burn
     * @return amountWithdrawn Underlying tokens returned
     */
    function withdraw(address token, uint256 shareAmount) 
        external 
        returns (uint256 amountWithdrawn) 
    {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[token][msg.sender] < shareAmount) revert InsufficientShares();
        
        LendingPool storage pool = _getPool(token);
        
        // Calculate underlying
        amountWithdrawn = (shareAmount * pool.totalDeposits) / pool.totalShares;
        
        // Check liquidity
        uint128 available = pool.totalDeposits - pool.totalBorrows;
        if (amountWithdrawn > available) revert InsufficientLiquidity();
        
        // Update pool
        pool.totalDeposits -= uint128(amountWithdrawn);
        pool.totalShares -= uint128(shareAmount);
        shares[token][msg.sender] -= shareAmount;
        
        // Transfer tokens
        IERC20(token).safeTransfer(msg.sender, amountWithdrawn);
        
        emit Withdraw(token, msg.sender, amountWithdrawn, shareAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         BORROWER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open a borrow position with flexible LTV and user-chosen LT
     * @param collateralAmount Collateral to deposit
     * @param debtAmount Amount to borrow
     * @param zeroForOne true = deposit token0, borrow token1
     * @param ltBps Liquidation threshold (5000-9900 = 50%-99%)
     * @return positionId Unique position identifier
     * 
     * FLOW:
     * 1. Validate LT bounds and liquidity
     * 2. Get current price from pool
     * 3. Validate initial LTV < LT
     * 4. Take collateral from user → send to Hook
     * 5. Hook creates inverse range position
     * 6. Update pool: increase borrows
     * 7. Send borrowed tokens to user
     * 
     * TICK RANGE (Hook calculates this):
     * - Accounts for debt growth over time (interest + fees + penalty)
     * - tickUpper = price where LTV = LT (liquidation starts)
     * - tickLower = price where debt+interest+fees = collateral value (full liquidation)
     * - Example: 1 ETH collateral, 1000 USDC debt, 80% LT
     *   * Current price: $2000, initial LTV: 50%
     *   * tickUpper: price $1250 (80% LTV - liquidation trigger)
     *   * tickLower: price where debt+interest = collateral (100% LTV)
     */
    function borrow(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (uint256 positionId) {
        if (collateralAmount == 0 || debtAmount == 0) revert ZeroAmount();
        if (ltBps < MIN_LT || ltBps > MAX_LT) revert InvalidLT();
        
        address collateralToken = zeroForOne ? token0 : token1;
        address debtToken = zeroForOne ? token1 : token0;
        LendingPool storage debtPool = _getPool(debtToken);
        
        // Check liquidity
        uint128 available = debtPool.totalDeposits - debtPool.totalBorrows;
        if (debtAmount > available) revert InsufficientLiquidity();
        
        // Validate initial LTV < LT
        _validateInitialLTV(collateralAmount, debtAmount, zeroForOne, ltBps);
        
        // Generate position ID
        positionId = nextPositionId++;
        
        // Take collateral from user and send to Hook
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).safeTransfer(address(hook), collateralAmount);
        
        // Create inverse position in Hook
        hook.openPosition(
            positionId,
            msg.sender,
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );
        
        // Record position
        positions[positionId] = BorrowPosition({
            owner: msg.sender,
            zeroForOne: zeroForOne,
            initialDebt: debtAmount,
            currentDebt: debtAmount,
            collateralAmount: collateralAmount,
            openTime: uint40(block.timestamp),
            isActive: true
        });
        
        // Update pool: increase borrows
        debtPool.totalBorrows += debtAmount;
        
        // Send borrowed tokens to user
        IERC20(debtToken).safeTransfer(msg.sender, debtAmount);
        
        emit Borrow(positionId, msg.sender, zeroForOne, collateralAmount, debtAmount, ltBps);
    }

    /**
     * @notice Repay debt and close position
     * @param positionId Position to repay
     * 
     * FLOW:
     * 1. Calculate debt owed (initial + 5% interest)
     * 2. Take repayment from user
     * 3. Call Hook to withdraw remaining collateral (Hook → Router)
     * 4. Update pool: decrease borrows
     * 5. Router transfers collateral → User
     * 
     * NOTE: If position was liquidated, collateral amount will be reduced.
     *       Hook already distributed penalties to LPs/swappers during liquidation.
     */
    function repay(uint256 positionId) external {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        
        address debtToken = pos.zeroForOne ? token1 : token0;
        address collateralToken = pos.zeroForOne ? token0 : token1;
        LendingPool storage debtPool = _getPool(debtToken);
        
        // Calculate total debt with interest
        uint256 timeElapsed = block.timestamp - pos.openTime;
        uint256 interest = (pos.initialDebt * INTEREST_RATE_BPS * timeElapsed) / 
                          (BPS * SECONDS_PER_YEAR);
        pos.currentDebt = uint128(pos.initialDebt + interest);
        
        // Take debt repayment from user
        if (pos.currentDebt > 0) {
            IERC20(debtToken).safeTransferFrom(msg.sender, address(this), pos.currentDebt);
            
            // Update pool
            if (debtPool.totalBorrows >= pos.currentDebt) {
                debtPool.totalBorrows -= pos.currentDebt;
            } else {
                debtPool.totalBorrows = 0;
            }
        }
        
        // Withdraw remaining collateral from Hook (Hook → Router)
        uint128 collateralReturned = hook.withdrawPositionCollateral(positionId, address(this));
        
        // Transfer collateral to user (Router → User)
        if (collateralReturned > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralReturned);
        }
        
        // Mark closed
        pos.isActive = false;
        
        emit Repay(positionId, pos.currentDebt, collateralReturned);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          HOOK CALLBACKS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by Hook during swap when liquidation occurs
     * @param positionId Position being liquidated
     * @param debtRepaid Debt repaid via swapping liquidated collateral
     * @param collateralLiquidated Amount of collateral liquidated (before penalty)
     * @param isFullyLiquidated Whether position is completely closed
     * 
     * LIQUIDATION FLOW (what Hook did before calling this):
     * 1. Detected position in liquidation range during swap
     * 2. Calculated proportional liquidation based on tick position
     * 3. Took collateral to liquidate (e.g., 0.3 ETH)
     * 4. Deducted penalty (e.g., 30% = 0.09 ETH):
     *    - 95% (0.0855 ETH) → distributed to LPs directly
     *    - 5% (0.0045 ETH) → sent to swapper directly
     * 5. Swapped remaining (0.21 ETH) → debt token (e.g., 420 USDC)
     * 6. Sent debt token (420 USDC) to Router
     * 7. Called this callback
     * 
     * WHAT ROUTER DOES:
     * - Update totalBorrows (decrease by debt repaid)
     * - Update position tracking
     * - Mark as closed if fully liquidated
     * 
     * NOTE: Hook already handled LP/swapper compensation.
     *       Router only handles borrower/lender accounting.
     */
    function onLiquidation(
        uint256 positionId,
        uint128 debtRepaid,
        uint128 collateralLiquidated,
        bool isFullyLiquidated
    ) external {
        if (msg.sender != address(hook)) revert OnlyHook();
        
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return;
        
        address debtToken = pos.zeroForOne ? token1 : token0;
        LendingPool storage debtPool = _getPool(debtToken);
        
        // Update position tracking
        if (pos.currentDebt >= debtRepaid) {
            pos.currentDebt -= debtRepaid;
        } else {
            pos.currentDebt = 0;
        }
        
        // Update pool borrows (debt was repaid to lenders)
        if (debtPool.totalBorrows >= debtRepaid) {
            debtPool.totalBorrows -= debtRepaid;
        } else {
            debtPool.totalBorrows = 0;
        }
        
        // Mark as closed if fully liquidated
        if (isFullyLiquidated) {
            pos.isActive = false;
            emit FullLiquidation(positionId);
        } else {
            emit PartialLiquidation(positionId, debtRepaid, collateralLiquidated);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            VALIDATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate initial LTV is below liquidation threshold
     * @param collateralAmount Collateral being deposited
     * @param debtAmount Debt being borrowed
     * @param zeroForOne Position direction
     * @param ltBps Liquidation threshold
     * 
     * CALCULATION:
     * 1. Get current tick from pool
     * 2. Convert tick to price
     * 3. Calculate collateral value in debt token terms
     * 4. Calculate LTV = debt / collateralValue
     * 5. Require LTV < LT
     */
    function _validateInitialLTV(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) internal view {
        // Get current tick
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        
        // Convert to price (sqrtPriceX96 → priceX96)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        
        // Calculate collateral value in debt terms
        uint256 collateralValue;
        if (zeroForOne) {
            // token0 collateral: price = token1/token0
            // collateralValue in token1 = collateral × price
            collateralValue = (uint256(collateralAmount) * priceX96) >> 96;
        } else {
            // token1 collateral: need token0/token1 = 1/price
            // collateralValue in token0 = collateral / price
            collateralValue = (uint256(collateralAmount) << 96) / priceX96;
        }
        
        require(collateralValue > 0, "Zero collateral value");
        
        // Calculate LTV in basis points
        uint256 ltvBps = (uint256(debtAmount) * BPS) / collateralValue;
        
        // Must be safely below LT
        require(ltvBps < ltBps, "Initial LTV too high");
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function _getPool(address token) internal view returns (LendingPool storage) {
        if (token == token0) return pool0;
        if (token == token1) return pool1;
        revert InvalidToken();
    }

    /**
     * @notice Get pool information
     */
    function getPoolInfo(address token) external view returns (
        uint128 totalDeposits,
        uint128 totalBorrows,
        uint128 available,
        uint128 totalShares,
        uint256 utilizationRate
    ) {
        LendingPool storage pool = _getPool(token);
        totalDeposits = pool.totalDeposits;
        totalBorrows = pool.totalBorrows;
        available = totalDeposits - totalBorrows;
        totalShares = pool.totalShares;
        utilizationRate = totalDeposits > 0 ? 
            (uint256(totalBorrows) * BPS) / totalDeposits : 0;
    }

    /**
     * @notice Get exchange rate (underlying per share)
     */
    function getExchangeRate(address token) external view returns (uint256) {
        LendingPool storage pool = _getPool(token);
        if (pool.totalShares == 0) return PRECISION;
        return (uint256(pool.totalDeposits) * PRECISION) / pool.totalShares;
    }

    /**
     * @notice Get user's underlying token balance
     */
    function getUserBalance(address token, address user) external view returns (uint256) {
        LendingPool storage pool = _getPool(token);
        uint256 userShares = shares[token][user];
        if (pool.totalShares == 0 || userShares == 0) return 0;
        return (userShares * pool.totalDeposits) / pool.totalShares;
    }

    /**
     * @notice Get position details
     */
    function getPosition(uint256 positionId) external view returns (BorrowPosition memory) {
        return positions[positionId];
    }

    /**
     * @notice Get current position debt with interest
     */
    function getPositionDebt(uint256 positionId) public view returns (uint128) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        
        uint256 timeElapsed = block.timestamp - pos.openTime;
        uint256 interest = (pos.initialDebt * INTEREST_RATE_BPS * timeElapsed) / 
                          (BPS * SECONDS_PER_YEAR);
        
        return uint128(pos.initialDebt + interest);
    }

    /**
     * @notice Get current price from pool (token1 per token0)
     */
    function getCurrentPrice() external view returns (uint256 priceX96) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
    }

    /**
     * @notice Calculate current LTV of a position
     */
    function getPositionLTV(uint256 positionId) external view returns (uint256 ltvBps) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        
        // Get current price
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        
        // Get remaining collateral from Hook
        uint128 collateralInHook = hook.getPositionCollateral(positionId);
        if (collateralInHook == 0) return BPS; // 100% LTV if no collateral
        
        // Calculate collateral value
        uint256 collateralValue;
        if (pos.zeroForOne) {
            collateralValue = (uint256(collateralInHook) * priceX96) >> 96;
        } else {
            collateralValue = (uint256(collateralInHook) << 96) / priceX96;
        }
        
        if (collateralValue == 0) return BPS;
        
        // Get current debt with interest
        uint128 currentDebt = getPositionDebt(positionId);
        
        ltvBps = (uint256(currentDebt) * BPS) / collateralValue;
    }
    
    /**
     * @notice Check if position is currently in liquidation range
     */
    function isPositionUnderwater(uint256 positionId) external view returns (bool) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return false;
        
        return hook.isPositionInLiquidation(positionId);
    }
    
    /**
     * @notice Get comprehensive position status
     */
    function getPositionStatus(uint256 positionId) external view returns (
        address owner,
        bool isActive,
        uint128 initialDebt,
        uint128 currentDebt,
        uint128 collateralRemaining,
        bool isUnderwater,
        uint256 currentLTV
    ) {
        BorrowPosition storage pos = positions[positionId];
        owner = pos.owner;
        isActive = pos.isActive;
        initialDebt = pos.initialDebt;
        currentDebt = getPositionDebt(positionId);
        collateralRemaining = hook.getPositionCollateral(positionId);
        isUnderwater = hook.isPositionInLiquidation(positionId);
        
        // Calculate LTV
        if (collateralRemaining > 0 && isActive) {
            (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
            uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
            
            uint256 collateralValue;
            if (pos.zeroForOne) {
                collateralValue = (uint256(collateralRemaining) * priceX96) >> 96;
            } else {
                collateralValue = (uint256(collateralRemaining) << 96) / priceX96;
            }
            
            if (collateralValue > 0) {
                currentLTV = (uint256(currentDebt) * BPS) / collateralValue;
            }
        }
    }
}
