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
 * @title TrueLendRouter - CORRECTED VERSION
 * @notice Fixed validation and collateral flow issues
 * 
 * KEY FIXES:
 * 1. Proper collateral transfer flow (User → Router → Hook)
 * 2. Fixed LTV validation with correct price calculations
 * 3. Proper approval for Hook to pull collateral
 * 4. Cleaner liquidation callback handling
 */
contract TrueLendRouter {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STRUCTS & TYPES
    // ════════════════════════════════════════════════════════════════════════════

    struct LendingPool {
        uint128 totalDeposits;
        uint128 totalBorrows;
        uint128 totalShares;
    }

    struct BorrowPosition {
        address owner;
        bool zeroForOne;
        uint128 initialDebt;
        uint128 currentDebt;
        uint128 collateralAmount;
        uint40 openTime;
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                                 CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint256 constant BPS = 10000;
    uint256 constant PRECISION = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    
    uint256 public constant INTEREST_RATE_BPS = 500;  // 5%
    
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
    
    mapping(address => mapping(address => uint256)) public shares;
    
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
    event Repay(uint256 indexed positionId, uint128 debtPaid, uint128 collateralReturned);
    event PartialLiquidation(uint256 indexed positionId, uint128 debtRepaid, uint128 collateralLiquidated);
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
    error InitialLTVTooHigh();

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

    function initialize(address _hook, PoolKey memory _poolKey) external {
        require(address(hook) == address(0), "Already initialized");
        hook = ITrueLendHook(_hook);
        poolKey = _poolKey;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          LENDER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function deposit(address token, uint256 amount) 
        external 
        returns (uint256 sharesIssued) 
    {
        if (amount == 0) revert ZeroAmount();
        
        LendingPool storage pool = _getPool(token);
        
        if (pool.totalShares == 0) {
            sharesIssued = amount;
        } else {
            sharesIssued = (amount * pool.totalShares) / pool.totalDeposits;
        }
        
        pool.totalDeposits += uint128(amount);
        pool.totalShares += uint128(sharesIssued);
        shares[token][msg.sender] += sharesIssued;
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        emit Deposit(token, msg.sender, amount, sharesIssued);
    }

    function withdraw(address token, uint256 shareAmount) 
        external 
        returns (uint256 amountWithdrawn) 
    {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[token][msg.sender] < shareAmount) revert InsufficientShares();
        
        LendingPool storage pool = _getPool(token);
        
        amountWithdrawn = (shareAmount * pool.totalDeposits) / pool.totalShares;
        
        uint128 available = pool.totalDeposits - pool.totalBorrows;
        if (amountWithdrawn > available) revert InsufficientLiquidity();
        
        pool.totalDeposits -= uint128(amountWithdrawn);
        pool.totalShares -= uint128(shareAmount);
        shares[token][msg.sender] -= shareAmount;
        
        IERC20(token).safeTransfer(msg.sender, amountWithdrawn);
        
        emit Withdraw(token, msg.sender, amountWithdrawn, shareAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                         BORROWER FUNCTIONS - FIXED
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Borrow with flexible LTV - FIXED VERSION
     * 
     * FLOW (FIXED):
     * 1. Take collateral from user → Router
     * 2. Router approves Hook to pull collateral
     * 3. Hook.openPosition() pulls collateral from Router
     * 4. Router sends borrowed tokens → User
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
        
        // FIXED: Validate initial LTV < LT
        _validateInitialLTVFixed(collateralAmount, debtAmount, zeroForOne, ltBps);
        
        positionId = nextPositionId++;
        
        // FIXED: Proper collateral flow
        // 1. Take collateral from user
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        
        // 2. Approve Hook to pull collateral
        IERC20(collateralToken).safeApprove(address(hook), collateralAmount);
        
        // 3. Hook pulls collateral from Router
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
        
        // Update pool
        debtPool.totalBorrows += debtAmount;
        
        // Send borrowed tokens to user
        IERC20(debtToken).safeTransfer(msg.sender, debtAmount);
        
        emit Borrow(positionId, msg.sender, zeroForOne, collateralAmount, debtAmount, ltBps);
    }

    /**
     * @notice Repay debt and close position
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
        
        // Take debt repayment
        if (pos.currentDebt > 0) {
            IERC20(debtToken).safeTransferFrom(msg.sender, address(this), pos.currentDebt);
            
            if (debtPool.totalBorrows >= pos.currentDebt) {
                debtPool.totalBorrows -= pos.currentDebt;
            } else {
                debtPool.totalBorrows = 0;
            }
        }
        
        // Withdraw collateral from Hook
        uint128 collateralReturned = hook.withdrawPositionCollateral(positionId, address(this));
        
        // Transfer collateral to user
        if (collateralReturned > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralReturned);
        }
        
        pos.isActive = false;
        
        emit Repay(positionId, pos.currentDebt, collateralReturned);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          HOOK CALLBACKS
    // ════════════════════════════════════════════════════════════════════════════

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
        
        // Update position debt
        if (pos.currentDebt >= debtRepaid) {
            pos.currentDebt -= debtRepaid;
        } else {
            pos.currentDebt = 0;
        }
        
        // Update pool borrows
        if (debtPool.totalBorrows >= debtRepaid) {
            debtPool.totalBorrows -= debtRepaid;
        } else {
            debtPool.totalBorrows = 0;
        }
        
        if (isFullyLiquidated) {
            pos.isActive = false;
            emit FullLiquidation(positionId);
        } else {
            emit PartialLiquidation(positionId, debtRepaid, collateralLiquidated);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                        VALIDATION - FIXED
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice FIXED: Validate initial LTV with proper price math
     */
    function _validateInitialLTVFixed(
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) internal view {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        
        // Calculate collateral value in debt token terms
        uint256 collateralValue;
        if (zeroForOne) {
            // token0 collateral, borrowing token1
            // price = token1/token0
            // collateralValue = collateral * price
            uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) >> 96;
            collateralValue = (uint256(collateralAmount) * priceX96) >> 96;
        } else {
            // token1 collateral, borrowing token0
            // need inverse price
            uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) >> 96;
            if (priceX96 == 0) priceX96 = 1;
            collateralValue = (uint256(collateralAmount) << 96) / priceX96;
        }
        
        if (collateralValue == 0) revert InitialLTVTooHigh();
        
        // Calculate LTV
        uint256 ltvBps = (uint256(debtAmount) * BPS) / collateralValue;
        
        // FIXED: Must be safely below LT (add 5% buffer)
        if (ltvBps >= ltBps - 500) revert InitialLTVTooHigh();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function _getPool(address token) internal view returns (LendingPool storage) {
        if (token == token0) return pool0;
        if (token == token1) return pool1;
        revert InvalidToken();
    }

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

    function getExchangeRate(address token) external view returns (uint256) {
        LendingPool storage pool = _getPool(token);
        if (pool.totalShares == 0) return PRECISION;
        return (uint256(pool.totalDeposits) * PRECISION) / pool.totalShares;
    }

    function getUserBalance(address token, address user) external view returns (uint256) {
        LendingPool storage pool = _getPool(token);
        uint256 userShares = shares[token][user];
        if (pool.totalShares == 0 || userShares == 0) return 0;
        return (userShares * pool.totalDeposits) / pool.totalShares;
    }

    function getPosition(uint256 positionId) external view returns (BorrowPosition memory) {
        return positions[positionId];
    }

    function getPositionDebt(uint256 positionId) public view returns (uint128) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        
        uint256 timeElapsed = block.timestamp - pos.openTime;
        uint256 interest = (pos.initialDebt * INTEREST_RATE_BPS * timeElapsed) / 
                          (BPS * SECONDS_PER_YEAR);
        
        return uint128(pos.initialDebt + interest);
    }

    function getCurrentPrice() external view returns (uint256 priceX96) {
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
    }

    function getPositionLTV(uint256 positionId) external view returns (uint256 ltvBps) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return 0;
        
        (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        
        uint128 collateralInHook = hook.getPositionCollateral(positionId);
        if (collateralInHook == 0) return BPS;
        
        uint256 collateralValue;
        if (pos.zeroForOne) {
            collateralValue = (uint256(collateralInHook) * priceX96) >> 96;
        } else {
            if (priceX96 == 0) return BPS;
            collateralValue = (uint256(collateralInHook) << 96) / priceX96;
        }
        
        if (collateralValue == 0) return BPS;
        
        uint128 currentDebt = getPositionDebt(positionId);
        ltvBps = (uint256(currentDebt) * BPS) / collateralValue;
    }
    
    function isPositionUnderwater(uint256 positionId) external view returns (bool) {
        BorrowPosition storage pos = positions[positionId];
        if (!pos.isActive) return false;
        return hook.isPositionInLiquidation(positionId);
    }
    
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
        
        if (collateralRemaining > 0 && isActive) {
            (, int24 tick, , ) = poolManager.getSlot0(poolKey.toId());
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
            uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
            
            uint256 collateralValue;
            if (pos.zeroForOne) {
                collateralValue = (uint256(collateralRemaining) * priceX96) >> 96;
            } else {
                if (priceX96 > 0) {
                    collateralValue = (uint256(collateralRemaining) << 96) / priceX96;
                }
            }
            
            if (collateralValue > 0) {
                currentLTV = (uint256(currentDebt) * BPS) / collateralValue;
            }
        }
    }
}
