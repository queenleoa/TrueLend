// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TrueLendHook} from "./TrueLendHook.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title TrueLendRouter
 * @notice Router for creating and managing borrow positions
 * @dev MVP: Simplified for hackathon demo
 */
contract TrueLendRouter {
    TrueLendHook public immutable hook;
    
    event LoanCreated(
        address indexed borrower,
        bytes32 indexed positionId,
        uint256 collateralAmount,
        uint256 borrowAmount
    );
    
    event LoanRepaid(
        address indexed borrower,
        bytes32 indexed positionId,
        uint256 repaidAmount
    );

    constructor(address _hook) {
        hook = TrueLendHook(_hook);
    }

    /**
     * @notice Create a borrow position
     * @param key The pool key for ETH/USDC pool
     * @param collateralAmount Amount of USDC to deposit as collateral
     * @param borrowAmount Amount of ETH to borrow
     * @param liquidationThreshold LT as percentage (e.g., 90 = 90%)
     */
    function borrow(
        PoolKey calldata key,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint8 liquidationThreshold
    ) external returns (bytes32 positionId) {
        // Pull collateral from borrower
        IERC20 collateralToken = IERC20(Currency.unwrap(key.currency1));
        require(
            collateralToken.transferFrom(msg.sender, address(this), collateralAmount),
            "Collateral transfer failed"
        );
        
        // Approve hook to pull collateral
        collateralToken.approve(address(hook), collateralAmount);
        
        // Create position (hook will pull collateral and send borrowed tokens)
        positionId = hook.createPosition(
            key,
            msg.sender,
            collateralAmount,
            borrowAmount,
            liquidationThreshold
        );
        
        emit LoanCreated(msg.sender, positionId, collateralAmount, borrowAmount);
    }

    /**
     * @notice Check position status
     */
    function getPositionStatus(bytes32 positionId) external view returns (
        bool isActive,
        bool needsLiquidation,
        uint256 collateralRemaining,
        uint256 debtRepaid
    ) {
        TrueLendHook.BorrowPosition memory pos = hook.getPosition(positionId);
        return (
            pos.isActive,
            pos.needsLiquidation,
            pos.collateralRemaining,
            pos.debtRepaid
        );
    }
}
