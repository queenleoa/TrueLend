// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITrueLendHook {
    function openPosition(
        uint256 positionId,
        address owner,
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (int24 tickLower, int24 tickUpper);
    
    function closePosition(uint256 positionId) external returns (
        uint128 collateralReturned,
        uint128 debtRemaining,
        uint128 penaltyOwed
    );
    
    function getPositionInfo(uint256 positionId) external view returns (
        uint128 collateral,
        uint128 debt,
        uint128 penalty,
        bool isActive,
        bool inLiquidation
    );
}

/**
 * @title TrueLendRouter
 * @notice Entry point for lenders and borrowers
 * 
 * SEPARATE POOLS PER TOKEN:
 *   pool0 = ETH lending pool (lenders deposit ETH)
 *   pool1 = USDC lending pool (lenders deposit USDC)
 * 
 * PENALTY DISTRIBUTION:
 *   When positions are underwater, penalty accrues at 30% APR
 *   95% → Lenders (increases pool totalDeposits)
 *   5%  → Swappers (received directly during liquidation)
 */
contract TrueLendRouter {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS & EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    error NotInitialized();
    error InvalidAmount();
    error InvalidLT();
    error InsufficientLiquidity();
    error InsufficientShares();
    error NotOwner();
    error PositionClosed();
    error OnlyHook();

    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed token, address indexed user, uint256 amount, uint256 shares);
    event PositionOpened(uint256 indexed id, address indexed owner, bool zeroForOne, uint128 collateral, uint128 debt);
    event PositionClosed(uint256 indexed id, uint128 collateralBack, uint128 debtPaid, uint128 penaltyPaid);
    event LiquidationProcessed(uint256 indexed positionId, uint128 debtRepaid, uint128 penaltyToLPs);

    // ════════════════════════════════════════════════════════════════════════════
    //                                 STRUCTS
    // ════════════════════════════════════════════════════════════════════════════

    struct Pool {
        uint128 totalDeposits;  // Total tokens in pool (grows with interest + penalties)
        uint128 totalBorrows;   // Total tokens borrowed out
        uint128 totalShares;    // Total share tokens
    }

    struct Position {
        address owner;
        bool zeroForOne;        // true = token0 collateral, borrow token1
        uint128 originalDebt;   // Track original debt for interest
        bool isActive;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                               CONSTANTS
    // ════════════════════════════════════════════════════════════════════════════

    uint16 public constant MIN_LT = 5000;   // 50%
    uint16 public constant MAX_LT = 9500;   // 95%

    // ════════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ════════════════════════════════════════════════════════════════════════════

    bool public initialized;
    address public token0;  // e.g., ETH
    address public token1;  // e.g., USDC
    ITrueLendHook public hook;

    Pool public pool0;
    Pool public pool1;

    mapping(address => mapping(address => uint256)) public shares;  // token => user => shares

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;

    // ════════════════════════════════════════════════════════════════════════════
    //                             INITIALIZATION
    // ════════════════════════════════════════════════════════════════════════════

    function initialize(address _token0, address _token1, address _hook) external {
        require(!initialized, "Already initialized");
        token0 = _token0;
        token1 = _token1;
        hook = ITrueLendHook(_hook);
        initialized = true;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                           LENDER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit tokens to earn yield from borrowers + liquidation penalties
     */
    function deposit(address token, uint256 amount) external returns (uint256 newShares) {
        require(initialized, "Not initialized");
        require(amount > 0, "Zero amount");

        Pool storage pool = _pool(token);

        if (pool.totalShares == 0) {
            newShares = amount;
        } else {
            newShares = (amount * pool.totalShares) / pool.totalDeposits;
        }

        pool.totalDeposits += uint128(amount);
        pool.totalShares += uint128(newShares);
        shares[token][msg.sender] += newShares;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(token, msg.sender, amount, newShares);
    }

    /**
     * @notice Withdraw tokens by burning shares
     */
    function withdraw(address token, uint256 shareAmount) external returns (uint256 amount) {
        require(initialized, "Not initialized");
        require(shareAmount > 0, "Zero shares");
        require(shares[token][msg.sender] >= shareAmount, "Insufficient shares");

        Pool storage pool = _pool(token);

        amount = (shareAmount * pool.totalDeposits) / pool.totalShares;
        require(amount <= pool.totalDeposits - pool.totalBorrows, "Insufficient liquidity");

        pool.totalDeposits -= uint128(amount);
        pool.totalShares -= uint128(shareAmount);
        shares[token][msg.sender] -= shareAmount;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdraw(token, msg.sender, amount, shareAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                          BORROWER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open a borrow position
     * @param collateral Amount of collateral to deposit
     * @param debt Amount to borrow
     * @param zeroForOne true = deposit token0 (ETH), borrow token1 (USDC)
     * @param ltBps Liquidation threshold (5000-9500)
     */
    function borrow(
        uint128 collateral,
        uint128 debt,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (uint256 positionId) {
        require(initialized, "Not initialized");
        require(collateral > 0 && debt > 0, "Zero amount");
        require(ltBps >= MIN_LT && ltBps <= MAX_LT, "Invalid LT");

        address collateralToken = zeroForOne ? token0 : token1;
        address debtToken = zeroForOne ? token1 : token0;
        Pool storage debtPool = zeroForOne ? pool1 : pool0;

        // Check liquidity
        require(debt <= debtPool.totalDeposits - debtPool.totalBorrows, "Insufficient liquidity");

        positionId = nextPositionId++;

        // Take collateral from borrower
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateral);

        // Send collateral to hook and create position
        IERC20(collateralToken).safeTransfer(address(hook), collateral);
        hook.openPosition(positionId, msg.sender, collateral, debt, zeroForOne, ltBps);

        // Record position
        positions[positionId] = Position({
            owner: msg.sender,
            zeroForOne: zeroForOne,
            originalDebt: debt,
            isActive: true
        });

        // Update pool and send debt to borrower
        debtPool.totalBorrows += debt;
        IERC20(debtToken).safeTransfer(msg.sender, debt);

        emit PositionOpened(positionId, msg.sender, zeroForOne, collateral, debt);
    }

    /**
     * @notice Repay debt and close position
     * @dev Borrower pays: remaining debt + any accrued penalty
     */
    function repay(uint256 positionId) external {
        Position storage pos = positions[positionId];
        require(pos.isActive, "Position closed");
        require(pos.owner == msg.sender, "Not owner");

        address debtToken = pos.zeroForOne ? token1 : token0;
        address collateralToken = pos.zeroForOne ? token0 : token1;
        Pool storage debtPool = pos.zeroForOne ? pool1 : pool0;

        // Close position in hook - get remaining collateral and penalty owed
        (uint128 collateralBack, uint128 debtRemaining, uint128 penaltyOwed) = hook.closePosition(positionId);

        uint128 totalPayment = debtRemaining + penaltyOwed;

        if (totalPayment > 0) {
            // Take repayment from borrower
            IERC20(debtToken).safeTransferFrom(msg.sender, address(this), totalPayment);

            // Reduce borrows
            if (debtPool.totalBorrows >= debtRemaining) {
                debtPool.totalBorrows -= debtRemaining;
            }

            // Penalty goes to lenders (95% - swapper already got 5% during liquidations)
            if (penaltyOwed > 0) {
                debtPool.totalDeposits += penaltyOwed;
            }
        }

        // Return collateral to borrower
        if (collateralBack > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralBack);
        }

        pos.isActive = false;
        emit PositionClosed(positionId, collateralBack, debtRemaining, penaltyOwed);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                           HOOK CALLBACKS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by hook when liquidation occurs during swaps
     * @param positionId Position being liquidated
     * @param debtRepaid Amount of debt repaid
     * @param penaltyToLPs Penalty amount for lenders (95% of accrued penalty)
     */
    function onLiquidation(
        uint256 positionId,
        address debtToken,
        uint128 debtRepaid,
        uint128 penaltyToLPs
    ) external {
        require(msg.sender == address(hook), "Only hook");

        Pool storage pool = _pool(debtToken);

        // Reduce borrows
        if (debtRepaid > 0 && pool.totalBorrows >= debtRepaid) {
            pool.totalBorrows -= debtRepaid;
        }

        // Penalty to lenders - increases their share value
        if (penaltyToLPs > 0) {
            pool.totalDeposits += penaltyToLPs;
        }

        emit LiquidationProcessed(positionId, debtRepaid, penaltyToLPs);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    function _pool(address token) internal view returns (Pool storage) {
        if (token == token0) return pool0;
        if (token == token1) return pool1;
        revert("Invalid token");
    }

    function getPool(address token) external view returns (
        uint128 deposits,
        uint128 borrows,
        uint128 available,
        uint128 totalShares
    ) {
        Pool storage p = _pool(token);
        return (p.totalDeposits, p.totalBorrows, p.totalDeposits - p.totalBorrows, p.totalShares);
    }

    function getExchangeRate(address token) external view returns (uint256) {
        Pool storage p = _pool(token);
        if (p.totalShares == 0) return 1e18;
        return (uint256(p.totalDeposits) * 1e18) / p.totalShares;
    }

    function getUserBalance(address token, address user) external view returns (uint256 underlying) {
        Pool storage p = _pool(token);
        uint256 userShares = shares[token][user];
        if (p.totalShares == 0 || userShares == 0) return 0;
        return (userShares * p.totalDeposits) / p.totalShares;
    }

    function getPosition(uint256 id) external view returns (Position memory) {
        return positions[id];
    }
}
