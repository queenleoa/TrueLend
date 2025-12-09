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
    
    function closePosition(uint256 positionId) external returns (
        uint128 collateralReturned,
        uint128 debtStillOwed,
        uint128 penaltyOwed
    );
}

/**
 * @title TrueLendRouter
 * @notice Manages two separate lending pools and handles borrow/repay operations
 * 
 * ARCHITECTURE:
 * ┌─────────────────────────────────────────────────────────────────┐
 * │                    LENDING POOLS (in Router)                     │
 * ├─────────────────────────────────────────────────────────────────┤
 * │                                                                  │
 * │  Pool 0 (ETH)                    Pool 1 (USDC)                  │
 * │  ├─ totalDeposits                ├─ totalDeposits               │
 * │  ├─ totalBorrows                 ├─ totalBorrows                │
 * │  ├─ totalShares                  ├─ totalShares                 │
 * │  └─ Lenders earn via shares      └─ Lenders earn via shares    │
 * │                                                                  │
 * │  BORROWERS:                                                      │
 * │  1. Deposit collateral (e.g., ETH)                              │
 * │  2. Borrow debt token (e.g., USDC) from pool                    │
 * │  3. Position created in Hook as inverse range order             │
 * │  4. On liquidation: Hook repays debt to pool + penalty to LPs   │
 * │                                                                  │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * INTEREST MODEL:
 *   Based on utilization rate of each pool independently
 *   borrowRate = baseRate + (utilizationRate × multiplier)
 */
contract TrueLendRouter {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS & TYPES
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Lending pool for a single token
     * @dev Lenders deposit and get shares, borrowers borrow and pay interest
     */
    struct LendingPool {
        uint128 totalDeposits;      // Total tokens in pool (increases with interest + penalties)
        uint128 totalBorrows;       // Total tokens borrowed out
        uint128 totalShares;        // Total share tokens minted
        uint40 lastAccrualTime;     // Last time interest was accrued
    }

    /**
     * @notice Borrow position metadata tracked by router
     * @dev Actual collateral is held by Hook, this tracks ownership and debt
     */
    struct BorrowPosition {
        address owner;
        bool zeroForOne;            // true = token0 collateral, borrow token1
        uint128 debtAmount;         // Current debt owed (increases with interest)
        uint128 collateralAmount;   // Collateral deposited (held in Hook)
        uint40 openTime;            // When position was opened
        uint40 lastInterestTime;    // Last time interest was accrued
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                                 CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    
    // Interest rate model parameters (in BPS)
    uint256 constant BASE_RATE = 200;           // 2% base rate
    uint256 constant RATE_MULTIPLIER = 1000;    // 10% max additional rate
    uint256 constant OPTIMAL_UTIL = 8000;       // 80% optimal utilization
    
    // Liquidation threshold bounds
    uint16 public constant MIN_LT = 5000;       // 50%
    uint16 public constant MAX_LT = 9900;       // 99%

    // ════════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ════════════════════════════════════════════════════════════════════════════

    IPoolManager public immutable poolManager;
    ITrueLendHook public hook;
    PoolKey public poolKey;
    
    address public immutable token0;            // e.g., ETH
    address public immutable token1;            // e.g., USDC
    
    LendingPool public pool0;                   // ETH lending pool
    LendingPool public pool1;                   // USDC lending pool
    
    // User shares: token => user => shares
    mapping(address => mapping(address => uint256)) public shares;
    
    // Borrow positions
    uint256 public nextPositionId = 1;
    mapping(uint256 => BorrowPosition) public positions;
    mapping(address => uint256[]) public userPositions;  // user => positionIds[]

    // ════════════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Borrow(
        uint256 indexed positionId,
        address indexed borrower,
        address collateralToken,
        address debtToken,
        uint128 collateral,
        uint128 debt,
        uint16 ltBps
    );
    event Repay(uint256 indexed positionId, uint128 debtPaid, uint128 penaltyPaid, uint128 collateralReturned);
    event LiquidationCallback(uint256 indexed positionId, uint128 debtRepaid, uint128 penaltyToLPs);
    event InterestAccrued(address indexed token, uint256 interestAmount, uint256 newTotalDeposits);

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
        
        pool0.lastAccrualTime = uint40(block.timestamp);
        pool1.lastAccrualTime = uint40(block.timestamp);
    }

    /**
     * @notice Set the hook address and pool key (called once after hook deployment)
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
     * @notice Deposit tokens into lending pool to earn interest
     * @param token Address of token to deposit (token0 or token1)
     * @param amount Amount to deposit
     * @return sharesIssued Number of share tokens minted
     * 
     * MECHANICS:
     * - Accrue interest first to get accurate share price
     * - If first deposit: shares = amount (1:1)
     * - Otherwise: shares = (amount × totalShares) / totalDeposits
     * - Shares represent proportional claim on pool + accrued interest
     */
    function deposit(address token, uint256 amount) 
        external 
        returns (uint256 sharesIssued) 
    {
        if (amount == 0) revert ZeroAmount();
        
        LendingPool storage pool = _getPool(token);
        
        // Accrue interest before deposit to get accurate share price
        _accrueInterest(token);
        
        // Calculate shares to issue
        if (pool.totalShares == 0) {
            // First deposit: 1:1 ratio
            sharesIssued = amount;
        } else {
            // Subsequent deposits: proportional to current exchange rate
            sharesIssued = (amount * pool.totalShares) / pool.totalDeposits;
        }
        
        // Update pool state
        pool.totalDeposits += uint128(amount);
        pool.totalShares += uint128(sharesIssued);
        shares[token][msg.sender] += sharesIssued;
        
        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        emit Deposit(token, msg.sender, amount, sharesIssued);
    }

    /**
     * @notice Withdraw tokens by burning shares
     * @param token Address of token to withdraw
     * @param shareAmount Number of shares to burn
     * @return amountWithdrawn Amount of underlying tokens returned
     * 
     * MECHANICS:
     * - Accrue interest first to get accurate exchange rate
     * - amount = (shares × totalDeposits) / totalShares
     * - Can only withdraw available liquidity (not borrowed out)
     */
    function withdraw(address token, uint256 shareAmount) 
        external 
        returns (uint256 amountWithdrawn) 
    {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[token][msg.sender] < shareAmount) revert InsufficientShares();
        
        LendingPool storage pool = _getPool(token);
        
        // Accrue interest before withdrawal
        _accrueInterest(token);
        
        // Calculate underlying amount
        amountWithdrawn = (shareAmount * pool.totalDeposits) / pool.totalShares;
        
        // Check available liquidity
        uint128 available = pool.totalDeposits - pool.totalBorrows;
        if (amountWithdrawn > available) revert InsufficientLiquidity();
        
        // Update pool state
        pool.totalDeposits -= uint128(amountWithdrawn);
        pool.totalShares -= uint128(shareAmount);
        shares[token][msg.sender] -= shareAmount;
        
        // Transfer tokens to user
        IERC20(token).safeTransfer(msg.sender, amountWithdrawn);
        
        emit Withdraw(token, msg.sender, amountWithdrawn, shareAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         BORROWER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Borrow tokens with collateral
     * @param collateralAmount Amount of collateral to deposit
     * @param debtAmount Amount to borrow
     * @param zeroForOne true = token0 collateral, borrow token1; false = vice versa
     * @param ltBps Liquidation threshold in basis points (5000-9900)
     * @return positionId Unique identifier for this position
     * 
     * FLOW:
     * 1. Validate LT and check liquidity
     * 2. Take collateral from borrower
     * 3. Create inverse position in Hook (collateral sent there)
     * 4. Update lending pool (increase borrows)
     * 5. Send borrowed tokens to user
     * 
     * PRICE CHECK:
     * - Get current price from pool to validate LTV
     * - LTV = debt / (collateral × price)
     * - Initial LTV must be < LT
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
        
        // Accrue interest on debt pool
        _accrueInterest(debtToken);
        
        // Check available liquidity
        uint128 available = debtPool.totalDeposits - debtPool.totalBorrows;
        if (debtAmount > available) revert InsufficientLiquidity();
        
        // Validate initial LTV against LT using current pool price
        _validateInitialLTV(collateralAmount, debtAmount, zeroForOne, ltBps);
        
        // Generate position ID
        positionId = nextPositionId++;
        
        // Take collateral from borrower and send to Hook
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(hook), collateralAmount);
        
        // Create inverse position in Hook
        (int24 tickLower, int24 tickUpper) = hook.openPosition(
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
            debtAmount: debtAmount,
            collateralAmount: collateralAmount,
            openTime: uint40(block.timestamp),
            lastInterestTime: uint40(block.timestamp),
            isActive: true
        });
        
        userPositions[msg.sender].push(positionId);
        
        // Update pool: increase borrows
        debtPool.totalBorrows += debtAmount;
        
        // Send borrowed tokens to user
        IERC20(debtToken).safeTransfer(msg.sender, debtAmount);
        
        emit Borrow(positionId, msg.sender, collateralToken, debtToken, collateralAmount, debtAmount, ltBps);
    }

    /**
     * @notice Repay debt and close position
     * @param positionId Position to repay
     * 
     * FLOW:
     * 1. Validate position ownership
     * 2. Accrue interest on position
     * 3. Close position in Hook (returns collateral - liquidated amount)
     * 4. Collect repayment from borrower (debt + penalty)
     * 5. Update lending pool (decrease borrows, add penalty to deposits)
     * 6. Return remaining collateral to borrower
     */
    function repay(uint256 positionId) external {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        
        address collateralToken = pos.zeroForOne ? token0 : token1;
        address debtToken = pos.zeroForOne ? token1 : token0;
        LendingPool storage debtPool = _getPool(debtToken);
        
        // Accrue interest on position
        _accruePositionInterest(positionId);
        
        // Close position in Hook
        (
            uint128 collateralReturned,
            uint128 debtStillOwed,
            uint128 penaltyOwed
        ) = hook.closePosition(positionId);
        
        // Total payment = remaining debt + penalty
        uint128 totalPayment = debtStillOwed + penaltyOwed;
        
        if (totalPayment > 0) {
            // Take payment from borrower
            IERC20(debtToken).safeTransferFrom(msg.sender, address(this), totalPayment);
            
            // Update pool: decrease borrows, add penalty to deposits
            if (debtPool.totalBorrows >= debtStillOwed) {
                debtPool.totalBorrows -= debtStillOwed;
            } else {
                debtPool.totalBorrows = 0;
            }
            
            // Penalty increases totalDeposits (rewards lenders)
            if (penaltyOwed > 0) {
                debtPool.totalDeposits += penaltyOwed;
            }
        }
        
        // Return collateral to borrower (Hook already sent it to router)
        if (collateralReturned > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralReturned);
        }
        
        // Mark position as closed
        pos.isActive = false;
        
        emit Repay(positionId, debtStillOwed, penaltyOwed, collateralReturned);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          HOOK CALLBACKS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by Hook when liquidation occurs during a swap
     * @param positionId Position being liquidated
     * @param debtToken Token the debt is denominated in
     * @param debtRepaid Amount of debt repaid via liquidation
     * @param penaltyToLPs Penalty amount allocated to LPs (already in router)
     * 
     * MECHANICS:
     * - Hook has already swapped collateral → debt token
     * - Hook sends debt token + LP penalty to router
     * - Router updates: decrease borrows, increase deposits (penalty)
     * - Swapper gets their 5% directly from Hook
     */
    function onLiquidation(
        uint256 positionId,
        address debtToken,
        uint128 debtRepaid,
        uint128 penaltyToLPs
    ) external {
        if (msg.sender != address(hook)) revert OnlyHook();
        
        LendingPool storage pool = _getPool(debtToken);
        BorrowPosition storage pos = positions[positionId];
        
        // Update position debt
        if (pos.debtAmount >= debtRepaid) {
            pos.debtAmount -= debtRepaid;
        } else {
            pos.debtAmount = 0;
        }
        
        // Update pool: decrease borrows
        if (pool.totalBorrows >= debtRepaid) {
            pool.totalBorrows -= debtRepaid;
        } else {
            pool.totalBorrows = 0;
        }
        
        // Penalty increases totalDeposits (rewards lenders via higher share value)
        if (penaltyToLPs > 0) {
            pool.totalDeposits += penaltyToLPs;
        }
        
        // If fully liquidated, mark as closed
        if (pos.collateralAmount == 0 || pos.debtAmount == 0) {
            pos.isActive = false;
        }
        
        emit LiquidationCallback(positionId, debtRepaid, penaltyToLPs);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         INTEREST ACCRUAL
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Accrue interest on a lending pool
     * @param token Token pool to accrue interest on
     * 
     * INTEREST MODEL:
     * utilizationRate = totalBorrows / totalDeposits
     * borrowRate = baseRate + (utilizationRate × multiplier)
     * interest = totalBorrows × borrowRate × timeElapsed
     * 
     * Interest increases totalDeposits (rewards lenders)
     */
    function _accrueInterest(address token) internal {
        LendingPool storage pool = _getPool(token);
        
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        if (elapsed == 0 || pool.totalBorrows == 0) {
            pool.lastAccrualTime = uint40(block.timestamp);
            return;
        }
        
        // Calculate utilization rate
        uint256 utilizationRate = (uint256(pool.totalBorrows) * BPS) / pool.totalDeposits;
        
        // Calculate borrow rate (simple model)
        uint256 borrowRate;
        if (utilizationRate <= OPTIMAL_UTIL) {
            // Below optimal: linear increase
            borrowRate = BASE_RATE + (utilizationRate * RATE_MULTIPLIER) / OPTIMAL_UTIL;
        } else {
            // Above optimal: steeper increase
            uint256 excessUtil = utilizationRate - OPTIMAL_UTIL;
            borrowRate = BASE_RATE + RATE_MULTIPLIER + (excessUtil * RATE_MULTIPLIER * 2) / (BPS - OPTIMAL_UTIL);
        }
        
        // Calculate interest (per second rate)
        // borrowRate is annual in BPS, convert to per-second
        uint256 ratePerSecond = (borrowRate * PRECISION) / (365 days * BPS);
        uint256 interest = (pool.totalBorrows * ratePerSecond * elapsed) / PRECISION;
        
        // Add interest to deposits (rewards lenders)
        pool.totalDeposits += uint128(interest);
        pool.lastAccrualTime = uint40(block.timestamp);
        
        emit InterestAccrued(token, interest, pool.totalDeposits);
    }

    /**
     * @notice Accrue interest on a specific borrow position
     * @param positionId Position to accrue interest on
     * 
     * Updates the position's debt based on time elapsed and borrow rate
     */
    function _accruePositionInterest(uint256 positionId) internal {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return;
        
        uint256 elapsed = block.timestamp - pos.lastInterestTime;
        if (elapsed == 0) return;
        
        address debtToken = pos.zeroForOne ? token1 : token0;
        LendingPool storage pool = _getPool(debtToken);
        
        // Use same rate calculation as pool
        uint256 utilizationRate = (uint256(pool.totalBorrows) * BPS) / pool.totalDeposits;
        uint256 borrowRate;
        
        if (utilizationRate <= OPTIMAL_UTIL) {
            borrowRate = BASE_RATE + (utilizationRate * RATE_MULTIPLIER) / OPTIMAL_UTIL;
        } else {
            uint256 excessUtil = utilizationRate - OPTIMAL_UTIL;
            borrowRate = BASE_RATE + RATE_MULTIPLIER + (excessUtil * RATE_MULTIPLIER * 2) / (BPS - OPTIMAL_UTIL);
        }
        
        uint256 ratePerSecond = (borrowRate * PRECISION) / (365 days * BPS);
        uint256 interest = (pos.debtAmount * ratePerSecond * elapsed) / PRECISION;
        
        pos.debtAmount += uint128(interest);
        pos.lastInterestTime = uint40(block.timestamp);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            VALIDATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate initial LTV is below liquidation threshold
     * @dev Fetches current price from pool and calculates LTV
     */
    function _validateInitialLTV(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) internal view {
        // Get current tick from pool
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        
        // Convert tick to price
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        
        // Calculate collateral value in debt terms
        uint256 collateralValue;
        if (zeroForOne) {
            // token0 collateral, price = token1/token0
            collateralValue = (uint256(collateralAmount) * priceX96) >> 96;
        } else {
            // token1 collateral, need inverse price
            collateralValue = (uint256(collateralAmount) << 96) / priceX96;
        }
        
        // Calculate LTV
        uint256 ltvBps = (uint256(debtAmount) * BPS) / collateralValue;
        
        // Must be below liquidation threshold
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
     * @notice Get lending pool info
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
        utilizationRate = totalDeposits > 0 ? (uint256(totalBorrows) * BPS) / totalDeposits : 0;
    }

    /**
     * @notice Get current borrow rate for a pool
     */
    function getBorrowRate(address token) external view returns (uint256 rateAnnualBps) {
        LendingPool storage pool = _getPool(token);
        if (pool.totalDeposits == 0) return BASE_RATE;
        
        uint256 utilizationRate = (uint256(pool.totalBorrows) * BPS) / pool.totalDeposits;
        
        if (utilizationRate <= OPTIMAL_UTIL) {
            rateAnnualBps = BASE_RATE + (utilizationRate * RATE_MULTIPLIER) / OPTIMAL_UTIL;
        } else {
            uint256 excessUtil = utilizationRate - OPTIMAL_UTIL;
            rateAnnualBps = BASE_RATE + RATE_MULTIPLIER + (excessUtil * RATE_MULTIPLIER * 2) / (BPS - OPTIMAL_UTIL);
        }
    }

    /**
     * @notice Get exchange rate (how much underlying per share)
     */
    function getExchangeRate(address token) external view returns (uint256 rate) {
        LendingPool storage pool = _getPool(token);
        if (pool.totalShares == 0) return PRECISION;
        return (uint256(pool.totalDeposits) * PRECISION) / pool.totalShares;
    }

    /**
     * @notice Get user's underlying balance
     */
    function getUserBalance(address token, address user) external view returns (uint256 underlyingBalance) {
        LendingPool storage pool = _getPool(token);
        uint256 userShares = shares[token][user];
        if (pool.totalShares == 0 || userShares == 0) return 0;
        return (userShares * pool.totalDeposits) / pool.totalShares;
    }

    /**
     * @notice Get position info
     */
    function getPosition(uint256 positionId) external view returns (BorrowPosition memory) {
        return positions[positionId];
    }

    /**
     * @notice Get all positions for a user
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    /**
     * @notice Get current price from the pool
     */
    function getCurrentPrice() external view returns (uint256 priceX96) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
    }
}
