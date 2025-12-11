// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TrueLendHook} from "./TrueLendHook.sol";

/**
 * @title DummyRouter
 * @notice Simple router for testing TrueLendHook
 * 
 * This router manages user interactions with the lending hook:
 * - Opens positions by transferring collateral and calling hook
 * - Receives liquidation callbacks from hook
 * - Handles collateral withdrawals
 */
contract DummyRouter {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ════════════════════════════════════════════════════════════════════════════

    TrueLendHook public immutable hook;
    
    // Track debt repayments from liquidations
    mapping(uint256 => uint128) public totalDebtRepaid;
    mapping(uint256 => bool) public positionFullyLiquidated;

    // ════════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ════════════════════════════════════════════════════════════════════════════

    event PositionOpened(
        uint256 indexed positionId,
        address indexed user,
        address collateralToken,
        address debtToken,
        uint128 collateral,
        uint128 debt
    );
    
    event LiquidationReceived(
        uint256 indexed positionId,
        uint128 debtRepaid,
        bool fullyLiquidated
    );
    
    event CollateralWithdrawn(
        uint256 indexed positionId,
        address indexed user,
        uint128 collateralAmount
    );

    // ════════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════════════

    error OnlyHook();
    error InvalidAmount();
    error TransferFailed();

    // ════════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════

    constructor(address _hook) {
        hook = TrueLendHook(_hook);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              POSITION MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open a new lending position
     * @param positionId Unique identifier for this position
     * @param collateralToken Address of collateral token
     * @param debtToken Address of debt token
     * @param collateralAmount Amount of collateral to deposit
     * @param debtAmount Amount of debt to borrow
     * @param zeroForOne True if collateral is token0, debt is token1
     * @param ltBps Liquidation threshold in basis points (e.g., 8000 = 80%)
     */
    function openPosition(
        uint256 positionId,
        address collateralToken,
        address debtToken,
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (int24 tickLower, int24 tickUpper) {
        if (collateralAmount == 0 || debtAmount == 0) revert InvalidAmount();

        // Transfer collateral from user to router
        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        // Approve hook to spend collateral
        IERC20(collateralToken).safeIncreaseAllowance(
            address(hook),
            collateralAmount
        );

        // Open position in hook
        (tickLower, tickUpper) = hook.openPosition(
            positionId,
            msg.sender,  // owner
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );

        emit PositionOpened(
            positionId,
            msg.sender,
            collateralToken,
            debtToken,
            collateralAmount,
            debtAmount
        );
    }

    /**
     * @notice Callback from hook when liquidation occurs
     * @dev Only callable by the hook
     */
    function onLiquidation(
        uint256 positionId,
        uint128 debtRepaid,
        bool isFullyLiquidated
    ) external {
        if (msg.sender != address(hook)) revert OnlyHook();

        // Track debt repayment
        totalDebtRepaid[positionId] += debtRepaid;
        
        if (isFullyLiquidated) {
            positionFullyLiquidated[positionId] = true;
        }

        emit LiquidationReceived(positionId, debtRepaid, isFullyLiquidated);
    }

    /**
     * @notice Withdraw collateral after repaying debt
     * @param positionId Position to close
     * @param collateralToken Address of collateral token
     */
    function withdrawCollateral(
        uint256 positionId,
        address collateralToken
    ) external returns (uint128 collateralAmount) {
        // Call hook to withdraw
        collateralAmount = hook.withdrawCollateral(
            positionId,
            address(this)  // Receive collateral here first
        );

        if (collateralAmount == 0) revert InvalidAmount();

        // Transfer collateral to user
        IERC20(collateralToken).safeTransfer(msg.sender, collateralAmount);

        emit CollateralWithdrawn(positionId, msg.sender, collateralAmount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //                              VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get total debt repaid for a position through liquidations
     */
    function getDebtRepaid(uint256 positionId) external view returns (uint128) {
        return totalDebtRepaid[positionId];
    }

    /**
     * @notice Check if a position was fully liquidated
     */
    function isFullyLiquidated(uint256 positionId) external view returns (bool) {
        return positionFullyLiquidated[positionId];
    }

    /**
     * @notice Get position details from hook
     */
    function getPosition(uint256 positionId) external view returns (
        address owner,
        bool zeroForOne,
        uint128 collateral,
        uint128 debt,
        int24 tickLower,
        int24 tickUpper,
        uint16 ltBps,
        uint128 liquidity,
        bool isActive
    ) {
        TrueLendHook.Position memory pos = hook.getPosition(positionId);
        return (
            pos.owner,
            pos.zeroForOne,
            pos.collateral,
            pos.debt,
            pos.tickLower,
            pos.tickUpper,
            pos.ltBps,
            pos.liquidity,
            pos.isActive
        );
    }
}
