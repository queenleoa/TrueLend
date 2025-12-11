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
    function setRouter(address router) external;
    
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
    
    function getPenaltyRate(uint16 ltBps) 
        external pure 
        returns (uint256 penaltyRateBps);
    
    function previewLiquidationRange(
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) external view returns (int24 tickLower, int24 tickUpper, uint256 penaltyRateBps);
}

/**
 * @title TrueLendRouter
 * @notice Periphery contract for TrueLend lending protocol
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 *                              ARCHITECTURE
 * ════════════════════════════════════════════════════════════════════════════════
 * 
 * LENDING POOLS:
 * - Separate pools for token0 and token1
 * - Share-based accounting (like Compound cTokens)
 * - Fixed 5% APR interest rate
 * - Interest accrues to totalDeposits, benefiting all lenders
 * 
 * POSITION FLOW:
 * 
 * BORROW:
 * 1. User deposits collateral → Router validates LTV
 * 2. Router transfers collateral → Hook
 * 3. Hook creates inverse range position
 * 4. Router mints debt from pool → User
 * 
 * LIQUIDATION (via Hook during swaps):
 * 1. Hook detects position in liquidation range
 * 2. Hook swaps collateral → debt token
 * 3. Hook calls Router.onLiquidation()
 * 4. Router receives debt tokens, credits to pool
 * 
 * REPAY:
 * 1. User repays debt + interest → Router
 * 2. Interest added to pool (benefits lenders)
 * 3. Hook returns remaining collateral → Router → User
 * 
 * ════════════════════════════════════════════════════════════════════════════════
 */
contract TrueLendRouter {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct LendingPool {
        uint128 totalDeposits;      // Total tokens deposited (increases with interest)
        uint128 totalBorrows;       // Total tokens borrowed out
        uint128 totalShares;        // Total share tokens issued
        uint40 lastAccrualTime;     // Last interest accrual timestamp
    }

    struct BorrowPosition {
        address owner;
        bool zeroForOne;            // true = token0 collateral, borrow token1
        uint128 initialDebt;        // Debt at opening (before interest)
        uint128 initialCollateral;  // Collateral at opening
        int24 tickLower;            // Full liquidation tick
        int24 tickUpper;            // Liquidation start tick
        uint16 ltBps;               // Liquidation threshold
        uint40 openTime;            // When position opened
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    
    /// @notice Fixed interest rate: 5% APR
    uint256 public constant INTEREST_RATE_BPS = 500;
    
    /// @notice Liquidation threshold bounds
    uint16 public constant MIN_LT = 5000;   // 50%
    uint16 public constant MAX_LT = 9900;   // 99%

    // ════════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ════════════════════════════════════════════════════════════════════════════

    IPoolManager public immutable poolManager;
    ITrueLendHook public hook;
    PoolKey public poolKey;
    bool public initialized;
    
    address public immutable token0;
    address public immutable token1;
    
    LendingPool public pool0;
    LendingPool public pool1;
    
    /// @notice User shares: token => user => shares
    mapping(address => mapping(address => uint256)) public shares;
    
    /// @notice Borrow positions
    uint256 public nextPositionId = 1;
    mapping(uint256 => BorrowPosition) public positions;
    
    /// @notice Track debt per position (updated on liquidation)
    mapping(uint256 => uint128) public positionDebtRemaining;

    // ════════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Borrow(
        uint256 indexed positionId,
        address indexed borrower,
        bool zeroForOne,
        uint128 collateral,
        uint128 debt,
        uint16 ltBps,
        int24 tickLower,
        int24 tickUpper
    );
    event Repay(
        uint256 indexed positionId,
        uint128 debtPaid,
        uint128 interestPaid,
        uint128 collateralReturned
    );
    event PartialLiquidation(
        uint256 indexed positionId,
        uint128 debtRepaid,
        uint128 collateralLiquidated
    );
    event FullLiquidation(uint256 indexed positionId, uint128 totalDebtCleared);
    event InterestAccrued(address indexed token, uint256 interestAmount);

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error InvalidToken();
    error InvalidLT();
    error InvalidLTV();
    error InsufficientLiquidity();
    error InsufficientShares();
    error PositionNotActive();
    error NotPositionOwner();
    error OnlyHook();
    error AlreadyInitialized();
    error NotInitialized();

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
        
        // Initialize pool timestamps
        pool0.lastAccrualTime = uint40(block.timestamp);
        pool1.lastAccrualTime = uint40(block.timestamp);
    }

    /**
     * @notice Initialize with hook address and pool key
     * @dev CRITICAL: Must call hook.setRouter() to establish bidirectional link
     */
    function initialize(address _hook, PoolKey memory _poolKey) external {
        if (initialized) revert AlreadyInitialized();
        
        hook = ITrueLendHook(_hook);
        poolKey = _poolKey;
        initialized = true;
        
        // CRITICAL: Set this Router as the Hook's router
        hook.setRouter(address(this));
    }

    modifier whenInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          INTEREST ACCRUAL
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Accrue interest for a pool
     * @dev Interest is added to totalDeposits, increasing share value for lenders
     */
    function _accrueInterest(address token) internal {
        LendingPool storage pool = _getPool(token);
        
        if (pool.totalBorrows == 0) {
            pool.lastAccrualTime = uint40(block.timestamp);
            return;
        }
        
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        if (elapsed == 0) return;
        
        // Interest = borrows × rate × time
        uint256 interest = (uint256(pool.totalBorrows) * INTEREST_RATE_BPS * elapsed) 
            / (BPS * SECONDS_PER_YEAR);
        
        // Add interest to deposits (benefits lenders via increased share value)
        pool.totalDeposits += uint128(interest);
        pool.lastAccrualTime = uint40(block.timestamp);
        
        emit InterestAccrued(token, interest);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          LENDER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit tokens to earn interest
     * @param token Token to deposit (token0 or token1)
     * @param amount Amount to deposit
     * @return sharesIssued Share tokens representing deposit
     */
    function deposit(address token, uint256 amount) 
        external 
        whenInitialized
        returns (uint256 sharesIssued) 
    {
        if (amount == 0) revert ZeroAmount();
        
        // Accrue interest first
        _accrueInterest(token);
        
        LendingPool storage pool = _getPool(token);
        
        // Calculate shares
        if (pool.totalShares == 0) {
            sharesIssued = amount;
        } else {
            // shares = amount × totalShares / totalDeposits
            sharesIssued = (amount * pool.totalShares) / pool.totalDeposits;
        }
        
        if (sharesIssued == 0) revert ZeroAmount();
        
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
        whenInitialized
        returns (uint256 amountWithdrawn) 
    {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[token][msg.sender] < shareAmount) revert InsufficientShares();
        
        // Accrue interest first
        _accrueInterest(token);
        
        LendingPool storage pool = _getPool(token);
        
        // Calculate underlying: amount = shares × totalDeposits / totalShares
        amountWithdrawn = (shareAmount * pool.totalDeposits) / pool.totalShares;
        
        // Check available liquidity
        uint256 available = pool.totalDeposits - pool.totalBorrows;
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
     * @notice Open a borrow position
     * @param collateralAmount Collateral to deposit
     * @param debtAmount Amount to borrow
     * @param zeroForOne true = deposit token0, borrow token1
     * @param ltBps Liquidation threshold (5000-9900 = 50%-99%)
     * @return positionId Unique position identifier
     * 
     * FLOW:
     * 1. Validate LT and liquidity
     * 2. Validate initial LTV < LT  
     * 3. Transfer collateral: User → Router → Hook
     * 4. Hook creates inverse range position
     * 5. Transfer borrowed tokens: Pool → User
     */
    function borrow(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external whenInitialized returns (uint256 positionId) {
        if (collateralAmount == 0 || debtAmount == 0) revert ZeroAmount();
        if (ltBps < MIN_LT || ltBps > MAX_LT) revert InvalidLT();
        
        address collateralToken = zeroForOne ? token0 : token1;
        address debtToken = zeroForOne ? token1 : token0;
        
        // Accrue interest on debt pool
        _accrueInterest(debtToken);
        
        LendingPool storage debtPool = _getPool(debtToken);
        
        // Check liquidity
        uint256 available = debtPool.totalDeposits - debtPool.totalBorrows;
        if (debtAmount > available) revert InsufficientLiquidity();
        
        // Validate initial LTV < LT
        uint256 initialLTV = _calculateLTV(collateralAmount, debtAmount, zeroForOne);
        if (initialLTV >= ltBps) revert InvalidLTV();
        
        // Generate position ID
        positionId = nextPositionId++;
        
        // Transfer collateral: User → Router
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        
        // Approve and transfer collateral: Router → Hook
        IERC20(collateralToken).approve(address(hook), collateralAmount);
        IERC20(collateralToken).safeTransfer(address(hook), collateralAmount);
        
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
            initialDebt: debtAmount,
            initialCollateral: collateralAmount,
            tickLower: tickLower,
            tickUpper: tickUpper,
            ltBps: ltBps,
            openTime: uint40(block.timestamp),
            isActive: true
        });
        
        // Track remaining debt
        positionDebtRemaining[positionId] = debtAmount;
        
        // Update pool borrows
        debtPool.totalBorrows += debtAmount;
        
        // Send borrowed tokens: Pool → User
        IERC20(debtToken).safeTransfer(msg.sender, debtAmount);
        
        emit Borrow(
            positionId, msg.sender, zeroForOne, 
            collateralAmount, debtAmount, ltBps,
            tickLower, tickUpper
        );
    }

    /**
     * @notice Repay debt and close position
     * @param positionId Position to repay
     * 
     * FLOW:
     * 1. Calculate debt owed (remaining + interest)
     * 2. Take repayment from user
     * 3. Interest portion added to pool deposits (benefits lenders)
     * 4. Request remaining collateral from Hook
     * 5. Return collateral to user
     */
    function repay(uint256 positionId) external whenInitialized {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        
        address debtToken = pos.zeroForOne ? token1 : token0;
        address collateralToken = pos.zeroForOne ? token0 : token1;
        
        // Accrue pool interest
        _accrueInterest(debtToken);
        
        LendingPool storage debtPool = _getPool(debtToken);
        
        // Calculate remaining debt (may have been partially liquidated)
        uint128 remainingDebt = positionDebtRemaining[positionId];
        
        // Calculate interest owed
        uint256 timeElapsed = block.timestamp - pos.openTime;
        uint256 interest = (uint256(remainingDebt) * INTEREST_RATE_BPS * timeElapsed) 
            / (BPS * SECONDS_PER_YEAR);
        
        uint128 totalOwed = remainingDebt + uint128(interest);
        
        // Take repayment from user
        if (totalOwed > 0) {
            IERC20(debtToken).safeTransferFrom(msg.sender, address(this), totalOwed);
        }
        
        // Update pool: decrease borrows, interest goes to deposits
        if (debtPool.totalBorrows >= remainingDebt) {
            debtPool.totalBorrows -= remainingDebt;
        } else {
            debtPool.totalBorrows = 0;
        }
        
        // Interest portion increases deposits (benefits lenders)
        // Note: This is already handled by _accrueInterest, but we add any extra
        
        // Withdraw remaining collateral from Hook
        uint128 collateralReturned = hook.withdrawPositionCollateral(positionId, address(this));
        
        // Transfer collateral to user
        if (collateralReturned > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralReturned);
        }
        
        // Mark position closed
        pos.isActive = false;
        positionDebtRemaining[positionId] = 0;
        
        emit Repay(positionId, remainingDebt, uint128(interest), collateralReturned);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          HOOK CALLBACKS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by Hook when liquidation occurs during a swap
     * @param positionId Position being liquidated
     * @param debtRepaid Debt token amount received from liquidation swap
     * @param collateralLiquidated Collateral amount liquidated
     * @param isFullyLiquidated Whether position is fully closed
     * 
     * WHAT HOOK ALREADY DID:
     * 1. Detected position in liquidation range
     * 2. Calculated collateral to liquidate
     * 3. Deducted penalty (90% LP, 10% swapper)
     * 4. Swapped collateral → debt token
     * 5. Transferred debt token to this Router
     * 
     * WHAT ROUTER DOES:
     * 1. Receive debt tokens (repayment)
     * 2. Update position debt tracking
     * 3. Update pool borrows (decrease)
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
        
        // Update position debt tracking
        if (positionDebtRemaining[positionId] >= debtRepaid) {
            positionDebtRemaining[positionId] -= debtRepaid;
        } else {
            positionDebtRemaining[positionId] = 0;
        }
        
        // Decrease pool borrows (debt was repaid)
        if (debtPool.totalBorrows >= debtRepaid) {
            debtPool.totalBorrows -= debtRepaid;
        } else {
            debtPool.totalBorrows = 0;
        }
        
        // Debt tokens received stay in Router (add back to available liquidity)
        // This is automatic since debt tokens are now in the contract
        
        if (isFullyLiquidated) {
            pos.isActive = false;
            emit FullLiquidation(positionId, pos.initialDebt);
        } else {
            emit PartialLiquidation(positionId, debtRepaid, collateralLiquidated);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            LTV CALCULATION
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate LTV in basis points
     * @dev Uses current pool price
     */
    function _calculateLTV(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne
    ) internal view returns (uint256 ltvBps) {
        // Get current tick
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        
        // Convert to price
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        
        // Calculate collateral value in debt terms
        uint256 collateralValue;
        if (zeroForOne) {
            // token0 collateral: value = collateral × price
            collateralValue = (uint256(collateralAmount) * priceX96) >> 96;
        } else {
            // token1 collateral: value = collateral / price
            if (priceX96 == 0) return BPS; // Max LTV if price is 0
            collateralValue = (uint256(collateralAmount) << 96) / priceX96;
        }
        
        if (collateralValue == 0) return BPS;
        
        ltvBps = (uint256(debtAmount) * BPS) / collateralValue;
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
     * @notice Get pool information with pending interest
     */
    function getPoolInfo(address token) external view returns (
        uint128 totalDeposits,
        uint128 totalBorrows,
        uint128 available,
        uint128 totalShares,
        uint256 utilizationRateBps,
        uint256 pendingInterest
    ) {
        LendingPool storage pool = _getPool(token);
        
        // Calculate pending interest
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        pendingInterest = pool.totalBorrows > 0
            ? (uint256(pool.totalBorrows) * INTEREST_RATE_BPS * elapsed) / (BPS * SECONDS_PER_YEAR)
            : 0;
        
        totalDeposits = pool.totalDeposits + uint128(pendingInterest);
        totalBorrows = pool.totalBorrows;
        available = totalDeposits - totalBorrows;
        totalShares = pool.totalShares;
        utilizationRateBps = totalDeposits > 0 
            ? (uint256(totalBorrows) * BPS) / totalDeposits 
            : 0;
    }

    /**
     * @notice Get exchange rate (underlying per share)
     */
    function getExchangeRate(address token) external view returns (uint256) {
        LendingPool storage pool = _getPool(token);
        if (pool.totalShares == 0) return PRECISION;
        
        // Include pending interest
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        uint256 pendingInterest = pool.totalBorrows > 0
            ? (uint256(pool.totalBorrows) * INTEREST_RATE_BPS * elapsed) / (BPS * SECONDS_PER_YEAR)
            : 0;
        
        uint256 totalWithInterest = pool.totalDeposits + pendingInterest;
        return (totalWithInterest * PRECISION) / pool.totalShares;
    }

    /**
     * @notice Get user's underlying token balance
     */
    function getUserBalance(address token, address user) external view returns (uint256) {
        LendingPool storage pool = _getPool(token);
        uint256 userShares = shares[token][user];
        if (pool.totalShares == 0 || userShares == 0) return 0;
        
        // Include pending interest
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        uint256 pendingInterest = pool.totalBorrows > 0
            ? (uint256(pool.totalBorrows) * INTEREST_RATE_BPS * elapsed) / (BPS * SECONDS_PER_YEAR)
            : 0;
        
        uint256 totalWithInterest = pool.totalDeposits + pendingInterest;
        return (userShares * totalWithInterest) / pool.totalShares;
    }

    /**
     * @notice Get position details
     */
    function getPosition(uint256 positionId) external view returns (BorrowPosition memory) {
        return positions[positionId];
    }

    /**
     * @notice Get current debt owed for position (remaining + interest)
     */
    function getPositionDebt(uint256 positionId) public view returns (uint128 totalDebt) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        
        uint128 remaining = positionDebtRemaining[positionId];
        
        uint256 timeElapsed = block.timestamp - pos.openTime;
        uint256 interest = (uint256(remaining) * INTEREST_RATE_BPS * timeElapsed) 
            / (BPS * SECONDS_PER_YEAR);
        
        totalDebt = remaining + uint128(interest);
    }

    /**
     * @notice Get current price from pool
     */
    function getCurrentPrice() external view returns (uint256 priceX96) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
    }

    /**
     * @notice Get current tick
     */
    function getCurrentTick() external view returns (int24 tick) {
        (, tick, , ) = poolManager.getSlot0(poolKey.toId());
    }

    /**
     * @notice Calculate current LTV of a position
     */
    function getPositionLTV(uint256 positionId) external view returns (uint256 ltvBps) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        
        // Get remaining collateral from Hook
        uint128 collateralRemaining = hook.getPositionCollateral(positionId);
        if (collateralRemaining == 0) return BPS; // 100% if no collateral
        
        // Get current debt
        uint128 currentDebt = getPositionDebt(positionId);
        
        ltvBps = _calculateLTV(collateralRemaining, currentDebt, pos.zeroForOne);
    }

    /**
     * @notice Check if position is in liquidation range
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
        uint256 currentLTV,
        int24 tickLower,
        int24 tickUpper
    ) {
        BorrowPosition storage pos = positions[positionId];
        
        owner = pos.owner;
        isActive = pos.isActive;
        initialDebt = pos.initialDebt;
        currentDebt = getPositionDebt(positionId);
        collateralRemaining = hook.getPositionCollateral(positionId);
        isUnderwater = pos.isActive ? hook.isPositionInLiquidation(positionId) : false;
        tickLower = pos.tickLower;
        tickUpper = pos.tickUpper;
        
        if (collateralRemaining > 0 && isActive) {
            currentLTV = _calculateLTV(collateralRemaining, currentDebt, pos.zeroForOne);
        } else if (isActive) {
            currentLTV = BPS; // 100% if no collateral
        }
    }

    /**
     * @notice Preview borrow parameters before opening position
     */
    function previewBorrow(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external view returns (
        uint256 initialLTV,
        int24 tickLower,
        int24 tickUpper,
        uint256 penaltyRateBps,
        bool isValid
    ) {
        initialLTV = _calculateLTV(collateralAmount, debtAmount, zeroForOne);
        isValid = initialLTV < ltBps && ltBps >= MIN_LT && ltBps <= MAX_LT;
        
        (tickLower, tickUpper, penaltyRateBps) = hook.previewLiquidationRange(
            collateralAmount, debtAmount, zeroForOne, ltBps
        );
    }
}
