// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {LendingVault} from "../src/LendingVault.sol";

/// @notice Owns a self-contained TrueLend demo pool on a live testnet and drives
/// it step by step via cast calls spaced over real wall-clock time — the only
/// way to warm the 60s-interval oracle and produce genuine decay/pause history
/// for the dashboard. Not production code; a scripted market operator.
contract DemoDriver is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeTransferLib for ERC20;

    IPoolManager public immutable manager;
    TrueLendHook public immutable hook;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public key;
    address public owner;

    // action tags for the unlock callback
    uint8 constant ADD_LIQ = 1;
    uint8 constant SWAP = 2;

    constructor(IPoolManager _manager, TrueLendHook _hook) {
        manager = _manager;
        hook = _hook;
        owner = msg.sender;
    }

    /// Deploy the pair, initialize the pool with the hook, seed deep full-range
    /// liquidity, and fund both lending vaults. One call; everything after is
    /// timed. tickSpacing 60, fee 0.30%, price 1:1.
    function setup() external returns (address t0, address t1, PoolId poolId) {
        require(msg.sender == owner, "owner");
        MockERC20 a = new MockERC20("Demo USD", "dUSD", 18);
        MockERC20 b = new MockERC20("Demo ETH", "dETH", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        token0.mint(address(this), 100_000_000e18);
        token1.mint(address(this), 100_000_000e18);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0)); // 1:1

        manager.unlock(abi.encode(ADD_LIQ, int256(50_000e18), int24(0), int24(0)));

        (LendingVault v0, LendingVault v1,,) = hook.getPool(key.toId());
        token0.approve(address(v0), type(uint256).max);
        token1.approve(address(v1), type(uint256).max);
        v0.deposit(2_000_000e18, owner); // lender shares to the deployer
        v1.deposit(2_000_000e18, owner);

        return (address(token0), address(token1), key.toId());
    }

    /// One oracle-warming step: a tiny round-trip that records an observation.
    /// Call 9+ times, ≥61s apart, before any position can open.
    function warm() external {
        manager.unlock(abi.encode(SWAP, int256(1e15), int24(0), int24(0)));
        manager.unlock(abi.encode(SWAP, -int256(1e15), int24(0), int24(0)));
    }

    /// Push the pool price to a target tick (signed): positive = up, negative =
    /// down. Drives collateral positions into and out of their liquidation ranges.
    function swapToTick(int24 targetTick) external {
        (, int24 cur,,) = manager.getSlot0(key.toId());
        bool zeroForOne = targetTick < cur; // token0 cheaper => tick down
        manager.unlock(abi.encode(SWAP, zeroForOne ? -int256(5_000_000e18) : int256(5_000_000e18), targetTick, int24(1)));
    }

    /// Open a demo borrower position: `collAmt` token0 collateral, borrow token1.
    function openDemo(uint256 collAmt, uint256 borrowAmt, uint16 ltBps, address onBehalf)
        external
        returns (bytes32 id)
    {
        token0.approve(address(hook), collAmt);
        id = hook.open(key, true, collAmt, borrowAmt, ltBps, onBehalf);
    }

    function poke() external {
        hook.poke(key);
    }

    function faucet(address to, uint256 amt) external {
        token0.mint(to, amt);
        token1.mint(to, amt);
    }

    function poolId() external view returns (PoolId) {
        return key.toId();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (uint8 action, int256 amt, int24 tick, int24 flag) = abi.decode(data, (uint8, int256, int24, int24));

        if (action == ADD_LIQ) {
            (BalanceDelta delta,) = manager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: amt, salt: 0}),
                ""
            );
            _settle(delta);
        } else if (action == SWAP) {
            bool zeroForOne = amt < 0;
            uint160 limit = flag == 1
                ? TickMath.getSqrtPriceAtTick(tick)
                : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            BalanceDelta delta = manager.swap(
                key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit}), ""
            );
            _settle(delta);
        }
        return "";
    }

    function _settle(BalanceDelta delta) internal {
        if (delta.amount0() < 0) key.currency0.settle(manager, address(this), uint256(uint128(-delta.amount0())), false);
        if (delta.amount1() < 0) key.currency1.settle(manager, address(this), uint256(uint128(-delta.amount1())), false);
        if (delta.amount0() > 0) key.currency0.take(manager, address(this), uint256(uint128(delta.amount0())), false);
        if (delta.amount1() > 0) key.currency1.take(manager, address(this), uint256(uint128(delta.amount1())), false);
    }
}
