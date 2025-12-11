// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITrueLendHook {
    function openPosition(
        uint256 positionId,
        address owner,
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (int24 tickLower, int24 tickUpper);
    
    function withdrawCollateral(uint256 positionId, address recipient) 
        external 
        returns (uint128);
}

contract DummyRouter {
    using SafeERC20 for IERC20;

    ITrueLendHook public hook;
    uint256 public nextPositionId = 1;
    
    mapping(uint256 => address) public positionOwners;
    mapping(uint256 => uint128) public debtReceived;

    event PositionOpened(uint256 positionId, address owner);
    event LiquidationReceived(uint256 positionId, uint128 debtAmount);
    event CollateralWithdrawn(uint256 positionId, uint128 amount);

    function setHook(address _hook) external {
        hook = ITrueLendHook(_hook);
    }

    function openPosition(
        address collateralToken,
        uint128 collateralAmount,
        uint128 debtAmount,
        bool zeroForOne,
        uint16 ltBps
    ) external returns (uint256 positionId) {
        positionId = nextPositionId++;
        positionOwners[positionId] = msg.sender;

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).approve(address(hook), collateralAmount);

        hook.openPosition(
            positionId,
            msg.sender,
            collateralAmount,
            debtAmount,
            zeroForOne,
            ltBps
        );

        emit PositionOpened(positionId, msg.sender);
    }

    function onLiquidation(
        uint256 positionId,
        uint128 debtRepaid,
        bool /* isFullyLiquidated */
    ) external {
        require(msg.sender == address(hook), "Only hook");
        debtReceived[positionId] += debtRepaid;
        emit LiquidationReceived(positionId, debtRepaid);
    }

    function withdrawCollateral(uint256 positionId) external {
        require(positionOwners[positionId] == msg.sender, "Not owner");
        uint128 amount = hook.withdrawCollateral(positionId, address(this));
        emit CollateralWithdrawn(positionId, amount);
    }

    function getDebtReceived(uint256 positionId) external view returns (uint128) {
        return debtReceived[positionId];
    }
}
