// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {TrueLendHook} from "../TrueLendHook.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title LeverageRouter
/// @notice The "perp extension" over TrueLend (RESEARCH.md appendix, path 1):
/// leveraged spot positions built as ONE ordinary TrueLend loan via v4 flash
/// accounting, liquidated by the existing chunk engine with no new mechanism.
///
/// Open: inside a PoolManager unlock, the router flash-takes the debt token,
/// swaps it into collateral through the same pool, opens a single hook position
/// owned by the trader (`onBehalfOf`) with margin + swapped collateral, and
/// settles the flash with the loan the hook disburses. Exposure = margin ×
/// λ where λ = 1/(1 − LTV); the borrower-chosen LT bounds λ via the opening
/// headroom (WHITEPAPER §9).
///
/// Close: flash-take the exact debt, repay in full (the hook returns all
/// remaining collateral straight to the trader), then pull just enough of that
/// collateral back from the trader — who must have approved this router — to
/// buy the debt back through the pool. The router never holds a surplus.
///
/// Native pools: the pool's native side is handled in WETH at the router, matching
/// the hook's own bridging convention; raw ETH margin is accepted and wrapped.
contract LeverageRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using SafeTransferLib for ERC20;

    IPoolManager public immutable poolManager;
    TrueLendHook public immutable hook;
    address public immutable WETH;

    uint8 internal constant ACTION_OPEN = 1;
    uint8 internal constant ACTION_CLOSE = 2;

    error NotPoolManager();
    error TooLittleCollateralFromSwap();
    error TooMuchCollateralForBuyback();
    error PositionNotClosed();
    error NativeValueMismatch();

    struct OpenParams {
        PoolKey key;
        bool collateralIs0; // margin + position collateral side
        uint256 margin; // trader-supplied collateral
        uint256 flashBorrow; // debt-token amount flashed, swapped, and borrowed
        uint16 ltBps;
        uint256 minCollateralOut; // slippage guard on the flash swap
        uint160 sqrtPriceLimitX96; // 0 = unbounded
    }

    struct CloseParams {
        PoolKey key;
        bytes32 positionId;
        uint160 sqrtPriceLimitX96; // 0 = unbounded (buying debt back)
        uint256 maxCollateralIn; // slippage guard on the buy-back; 0 = unlimited
    }

    constructor(IPoolManager _poolManager, TrueLendHook _hook, address _weth) {
        poolManager = _poolManager;
        hook = _hook;
        WETH = _weth;
    }

    /// raw ETH enters only from the PoolManager (native take) and WETH9.withdraw
    receive() external payable {}

    // ------------------------------------------------------------------ entrypoints

    /// @notice Open a leveraged position owned by msg.sender. Pull `margin` of the
    /// collateral asset (or accept it as msg.value on a native-collateral pool),
    /// flash `flashBorrow` of the debt asset into extra collateral, and open one
    /// hook position of size margin + swapped collateral against flashBorrow debt.
    function openLeveraged(OpenParams calldata p) external payable returns (bytes32 positionId) {
        ERC20 collAsset = _asset(p.collateralIs0 ? p.key.currency0 : p.key.currency1);
        if (msg.value > 0) {
            if (
                !(p.collateralIs0 && p.key.currency0.isAddressZero()) || msg.value != p.margin
            ) revert NativeValueMismatch();
            IWETH9(WETH).deposit{value: msg.value}();
        } else {
            collAsset.safeTransferFrom(msg.sender, address(this), p.margin);
        }
        bytes memory result = poolManager.unlock(abi.encode(ACTION_OPEN, msg.sender, abi.encode(p)));
        positionId = abi.decode(result, (bytes32));
    }

    /// @notice Fully close msg.sender's leveraged position. The trader must have
    /// approved this router for the collateral asset: the hook pays the position's
    /// collateral to the trader, and the router pulls back only what the debt
    /// buy-back consumes. Requires msg.sender to own the position.
    function closeLeveraged(CloseParams calldata p) external {
        TrueLendHook.Position memory pos = hook.getPosition(p.positionId);
        require(pos.borrower == msg.sender, "not position owner");
        poolManager.unlock(abi.encode(ACTION_CLOSE, msg.sender, abi.encode(p)));
    }

    // ------------------------------------------------------------------ callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, address trader, bytes memory inner) = abi.decode(data, (uint8, address, bytes));
        if (action == ACTION_OPEN) {
            return abi.encode(_open(trader, abi.decode(inner, (OpenParams))));
        }
        _close(trader, abi.decode(inner, (CloseParams)));
        return "";
    }

    function _open(address trader, OpenParams memory p) internal returns (bytes32 positionId) {
        Currency collCur = p.collateralIs0 ? p.key.currency0 : p.key.currency1;
        Currency debtCur = p.collateralIs0 ? p.key.currency1 : p.key.currency0;

        // 1. flash swap: debt token -> collateral token through the same pool
        bool zeroForOne = !p.collateralIs0; // selling the debt side
        BalanceDelta delta = poolManager.swap(
            p.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(p.flashBorrow),
                sqrtPriceLimitX96: p.sqrtPriceLimitX96 != 0
                    ? p.sqrtPriceLimitX96
                    : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            }),
            ""
        );
        uint256 swappedColl = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        if (swappedColl < p.minCollateralOut) revert TooLittleCollateralFromSwap();

        // 2. take the collateral out (wrap if the pool side is native)
        collCur.take(poolManager, address(this), swappedColl, false);
        if (collCur.isAddressZero()) IWETH9(WETH).deposit{value: swappedColl}();

        // 3. one position, owned by the trader; the hook disburses the loan here
        ERC20 collAsset = _asset(collCur);
        uint256 totalCollateral = p.margin + swappedColl;
        collAsset.safeApprove(address(hook), totalCollateral);
        positionId = hook.open(p.key, p.collateralIs0, totalCollateral, p.flashBorrow, p.ltBps, trader);

        // 4. settle the flash with the borrowed funds (unwrap if native)
        if (debtCur.isAddressZero()) IWETH9(WETH).withdraw(p.flashBorrow);
        debtCur.settle(poolManager, address(this), p.flashBorrow, false);
    }

    function _close(address trader, CloseParams memory p) internal {
        TrueLendHook.Position memory pos = hook.getPosition(p.positionId);
        Currency collCur = pos.collateralIs0 ? p.key.currency0 : p.key.currency1;
        Currency debtCur = pos.collateralIs0 ? p.key.currency1 : p.key.currency0;

        // 1. flash ONE WEI MORE than the live debt and repay with it. The vault
        //    burns floor(assets·WAD/index) shares, so repaying the exact debt can
        //    leave one dust share — position open, collateral never returned to
        //    the trader, buy-back still charged. (debt+1)·WAD/index strictly
        //    exceeds the share count, so the burn caps at ALL shares; the vault
        //    refunds whatever the extra wei didn't consume.
        uint256 flashDebt = hook.debtOf(p.positionId) + 1;
        ERC20 debtAsset = _asset(debtCur);
        debtCur.take(poolManager, address(this), flashDebt, false);
        if (debtCur.isAddressZero()) {
            // raw ETH from the manager: repay through the hook's payable path;
            // the refund arrives as WETH per the protocol's payout convention
            hook.repay{value: flashDebt}(p.positionId, flashDebt);
        } else {
            debtAsset.safeApprove(address(hook), flashDebt);
            hook.repay(p.positionId, flashDebt);
        }
        if (hook.getPosition(p.positionId).borrower != address(0)) revert PositionNotClosed();
        uint256 leftover = debtAsset.balanceOf(address(this)); // vault refund, ≤ 1 wei + rounding
        uint256 used = flashDebt - leftover;

        // 2. buy back exactly what the repayment consumed
        bool zeroForOne = pos.collateralIs0;
        BalanceDelta delta = poolManager.swap(
            p.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(used), // exact output of the debt token
                sqrtPriceLimitX96: p.sqrtPriceLimitX96 != 0
                    ? p.sqrtPriceLimitX96
                    : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            }),
            ""
        );
        uint256 collNeeded = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        if (p.maxCollateralIn != 0 && collNeeded > p.maxCollateralIn) revert TooMuchCollateralForBuyback();

        // 3. settle: the refunded leftover closes the flash gap (flashDebt =
        //    used + leftover), and the trader supplies only the buy-back cost —
        //    the router ends every close with zero balances
        if (leftover > 0) {
            if (debtCur.isAddressZero()) IWETH9(WETH).withdraw(leftover);
            debtCur.settle(poolManager, address(this), leftover, false);
        }
        _asset(collCur).safeTransferFrom(trader, address(this), collNeeded);
        if (collCur.isAddressZero()) IWETH9(WETH).withdraw(collNeeded);
        collCur.settle(poolManager, address(this), collNeeded, false);
    }

    function _asset(Currency c) internal view returns (ERC20) {
        return c.isAddressZero() ? ERC20(WETH) : ERC20(Currency.unwrap(c));
    }
}
