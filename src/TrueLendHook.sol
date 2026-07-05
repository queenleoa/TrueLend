// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {LendingVault} from "./LendingVault.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {LiqRangeMath} from "./libraries/LiqRangeMath.sol";
import {ChunkMath} from "./libraries/ChunkMath.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {TriggerIndex} from "./libraries/TriggerIndex.sol";

/// @title TrueLendHook
/// @notice Oracleless lending on Uniswap v4 with gradual, reversible, chunked
/// liquidations. See DESIGN.md. One hook instance serves many pools; every pool
/// initialized with this hook automatically becomes a lending market with two
/// LendingVaults (one per currency).
contract TrueLendHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeTransferLib for ERC20;
    using TruncatedOracle for TruncatedOracle.State;
    using TriggerIndex for TriggerIndex.State;

    // ------------------------------------------------------------------ constants

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_CHUNKS_PER_SWAP = 2;
    uint256 internal constant MAX_CHUNKS_PER_POKE = 10;
    uint256 internal constant MAX_TRIGGERS_PER_WALK = 8;
    uint256 internal constant MAX_REFRESHES_PER_WALK = 32;
    // max adverse price movement a forceClose sale may cause (~10.5%); unfilled
    // remainder stays as collateral and the close is retried later
    int24 internal constant FC_MAX_SLIPPAGE_TICKS = 1000;
    uint16 internal constant MIN_LT_BPS = 5000;
    // open-time LTV must sit below the chosen LT by this factor (95%)
    uint256 internal constant OPEN_LTV_HEADROOM_BPS = 9500;

    uint8 internal constant ACTION_POKE = 1;
    uint8 internal constant ACTION_FORCE_CLOSE = 2;

    // ------------------------------------------------------------------ types

    struct Config {
        int24 rangeWidth; // liquidation range width in ticks (pre-alignment)
        int24 minGapTicks; // min distance from filtered price to range start
        uint16 maxLtBps;
        uint16 basePenaltyBps;
        uint16 slippageBufferBps; // coverage haircut for chunk slippage
        uint16 maxChunkDepthBps; // per-chunk cap as bps of in-range depth tokens
        uint16 targetChunks;
        uint32 chunkInterval;
        uint8 timeCapX;
        uint32 termSeconds;
        uint16 rewardBps; // forceClose caller reward, taken out of the penalty
        uint128 minBorrow; // dust floor, in debt-asset units
    }

    struct PoolState {
        PoolKey key;
        LendingVault vault0;
        LendingVault vault1;
        int24 processedTick; // triggers walked up to here
        bool enabled;
    }

    struct Position {
        address borrower;
        PoolId poolId;
        bool collateralIs0;
        bool inQueue;
        uint128 collateral; // remaining collateral held by the hook
        uint128 debtShares; // vault debt shares outstanding
        int24 tickStart;
        int24 tickEnd;
        uint16 ltBps;
        uint40 expiry;
        uint40 lastChunkAt;
        uint40 liqStartedAt; // 0 when not in liquidation
        uint40 timeInLiqAccrued; // completed episodes, seconds
    }

    // ------------------------------------------------------------------ storage

    address public owner;
    VaultFactory public immutable vaultFactory;

    mapping(PoolId => PoolState) internal pools;
    mapping(PoolId => Config) internal configs; // read via getConfig()
    mapping(PoolId => TruncatedOracle.State) internal oracles;
    mapping(PoolId => TriggerIndex.State) internal triggers;
    mapping(PoolId => bytes32[]) internal liqQueue;
    mapping(PoolId => uint256) internal queueCursor;
    mapping(bytes32 => Position) internal positions; // read via getPosition()
    uint256 internal positionNonce;
    uint256 internal locked = 1;

    // ------------------------------------------------------------------ events / errors

    event PoolEnabled(PoolId indexed poolId, address vault0, address vault1);
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed borrower,
        PoolId indexed poolId,
        bool collateralIs0,
        uint256 collateral,
        uint256 debt,
        uint16 ltBps,
        int24 tickStart,
        int24 tickEnd,
        uint40 expiry
    );
    event LiquidationStarted(bytes32 indexed positionId, int24 tick);
    event LiquidationPaused(bytes32 indexed positionId, int24 tick, uint256 episodeSeconds);
    event ChunkExecuted(
        bytes32 indexed positionId, uint256 collateralSold, uint256 proceeds, uint256 penalty, uint256 debtRepaid
    );
    event Repaid(bytes32 indexed positionId, address indexed payer, uint256 assetsUsed);
    event PositionClosed(bytes32 indexed positionId, uint256 collateralReturned, uint256 shortfallWrittenOff);
    event ForceClosed(bytes32 indexed positionId, address indexed caller, uint8 reason, uint256 reward);

    error NotOwner();
    error Reentrancy();
    error NativeNotSupported();
    error PoolNotEnabled();
    error OracleNotReady();
    error LtOutOfBounds();
    error AmountTooSmall();
    error AmountTooLarge();
    error LtvTooHigh();
    error GapTooSmall();
    error CoverageInsufficient();
    error PositionNotActive();
    error NotEligibleForForceClose();
    error UnknownAction();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _poolManager, VaultFactory _factory) BaseHook(_poolManager) {
        owner = msg.sender;
        vaultFactory = _factory;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ hook callbacks

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        if (key.currency0.isAddressZero()) revert NativeNotSupported();
        PoolId poolId = key.toId();

        ERC20 asset0 = ERC20(Currency.unwrap(key.currency0));
        ERC20 asset1 = ERC20(Currency.unwrap(key.currency1));
        LendingVault v0 = vaultFactory.deploy(asset0, address(this));
        LendingVault v1 = vaultFactory.deploy(asset1, address(this));
        asset0.safeApprove(address(v0), type(uint256).max);
        asset1.safeApprove(address(v1), type(uint256).max);

        pools[poolId] = PoolState({key: key, vault0: v0, vault1: v1, processedTick: tick, enabled: true});
        configs[poolId] = Config({
            rangeWidth: 3466, // price factor ~sqrt(2)
            minGapTicks: 100,
            maxLtBps: 9900,
            basePenaltyBps: 50,
            slippageBufferBps: 200,
            maxChunkDepthBps: 100,
            targetChunks: 100,
            chunkInterval: 60,
            timeCapX: 5,
            termSeconds: 180 days,
            rewardBps: 10,
            minBorrow: 0
        });
        oracles[poolId].initialize(tick, uint32(block.timestamp));

        emit PoolEnabled(poolId, address(v0), address(v1));
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // record the PRE-swap tick: a single swap can never write its own price
        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        oracles[poolId].observe(tick, uint32(block.timestamp));
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        _walkTriggers(key, poolId);
        _processQueue(key, poolId, MAX_CHUNKS_PER_SWAP);
        _walkTriggers(key, poolId); // chunks move the tick; pick up newly crossed triggers
        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------ borrower entrypoints

    /// @notice Open a loan: deposit collateral in one pool currency, borrow the other.
    function open(
        PoolKey calldata key,
        bool collateralIs0,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint16 ltBps
    ) external nonReentrant returns (bytes32 positionId) {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];
        Config memory cfg = configs[poolId];
        if (!pool.enabled) revert PoolNotEnabled();
        if (!oracles[poolId].ready()) revert OracleNotReady();
        if (ltBps < MIN_LT_BPS || ltBps > cfg.maxLtBps) revert LtOutOfBounds();
        if (collateralAmount == 0 || borrowAmount == 0 || borrowAmount < cfg.minBorrow) revert AmountTooSmall();
        if (collateralAmount > type(uint128).max) revert AmountTooLarge();

        (, int24 spotTick,,) = poolManager.getSlot0(poolId);

        // 1. initial LTV at the manipulation-resistant, borrower-adverse price,
        //    with headroom below the chosen LT so interest accrual doesn't
        //    immediately erode the position into its range
        {
            int24 worstTick = oracles[poolId].borrowTick(spotTick, collateralIs0);
            uint160 worstSqrtP = TickMath.getSqrtPriceAtTick(worstTick);
            uint256 collValueInDebt = LiqRangeMath.convertAtSqrtPrice(collateralAmount, worstSqrtP, collateralIs0);
            if (
                collValueInDebt == 0
                    || FullMath.mulDiv(borrowAmount, BPS * BPS, collValueInDebt)
                        > uint256(ltBps) * OPEN_LTV_HEADROOM_BPS
            ) revert LtvTooHigh();
        }

        // 2. place the liquidation range
        (int24 tickStart, int24 tickEnd) = LiqRangeMath.liquidationRange(
            collateralIs0, collateralAmount, borrowAmount, ltBps, cfg.rangeWidth, key.tickSpacing
        );
        if (collateralIs0) {
            if (tickStart > spotTick - cfg.minGapTicks) revert GapTooSmall();
        } else {
            if (tickStart < spotTick + cfg.minGapTicks) revert GapTooSmall();
        }

        // 3. move funds and register
        LendingVault vault = collateralIs0 ? pool.vault1 : pool.vault0;
        ERC20(Currency.unwrap(collateralIs0 ? key.currency0 : key.currency1))
            .safeTransferFrom(msg.sender, address(this), collateralAmount);
        uint256 debtShares = vault.borrow(borrowAmount, msg.sender);
        if (debtShares > type(uint128).max) revert AmountTooLarge();

        positionId = keccak256(abi.encodePacked(msg.sender, PoolId.unwrap(poolId), positionNonce++));
        positions[positionId] = Position({
            borrower: msg.sender,
            poolId: poolId,
            collateralIs0: collateralIs0,
            inQueue: false,
            collateral: uint128(collateralAmount),
            debtShares: uint128(debtShares),
            tickStart: tickStart,
            tickEnd: tickEnd,
            ltBps: ltBps,
            expiry: uint40(block.timestamp + cfg.termSeconds),
            lastChunkAt: 0,
            liqStartedAt: 0,
            timeInLiqAccrued: 0
        });
        triggers[poolId].register(tickStart, key.tickSpacing, positionId);
        triggers[poolId].register(tickEnd, key.tickSpacing, positionId);

        emit PositionOpened(
            positionId,
            msg.sender,
            poolId,
            collateralIs0,
            collateralAmount,
            borrowAmount,
            ltBps,
            tickStart,
            tickEnd,
            uint40(block.timestamp + cfg.termSeconds)
        );

        // safety: opening straight into the range is prevented by the gap check,
        // but refresh anyway so state can never desync
        _refreshPosition(positionId, spotTick);
    }

    /// @notice Repay debt (anyone can pay for any position). Full repayment closes
    /// the position and returns remaining collateral to the borrower.
    function repay(bytes32 positionId, uint256 assets) external nonReentrant {
        Position storage pos = positions[positionId];
        if (pos.borrower == address(0)) revert PositionNotActive();
        if (assets == 0) revert AmountTooSmall();
        LendingVault vault = _debtVault(pos);

        ERC20 debtAsset = vault.asset();
        debtAsset.safeTransferFrom(msg.sender, address(this), assets);
        (uint256 burned, uint256 used) = vault.repay(assets, pos.debtShares);
        pos.debtShares -= uint128(burned);
        if (assets > used) debtAsset.safeTransfer(msg.sender, assets - used); // refund excess

        emit Repaid(positionId, msg.sender, used);
        if (pos.debtShares == 0) _closePosition(positionId, 0);
    }

    /// @notice Execute pending liquidation chunks without waiting for a swap.
    function poke(PoolKey calldata key) external nonReentrant {
        if (!pools[key.toId()].enabled) revert PoolNotEnabled();
        poolManager.unlock(abi.encode(ACTION_POKE, bytes32(0), key.toId(), msg.sender));
    }

    /// @notice Hard backstop: close a position whose soft treatment has ended.
    /// Eligible when (1) price passed the far end of the range with collateral
    /// left, (2) the term expired, or (3) interest outgrew worst-case coverage.
    function forceClose(bytes32 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        if (pos.borrower == address(0)) revert PositionNotActive();
        if (_forceCloseReason(positionId) == 0) revert NotEligibleForForceClose();
        poolManager.unlock(abi.encode(ACTION_FORCE_CLOSE, positionId, pos.poolId, msg.sender));
    }

    /// @notice Force-close eligibility: 0 = not eligible, 1 = range exhausted,
    /// 2 = expired, 3 = coverage breached.
    function forceCloseReason(bytes32 positionId) external view returns (uint8) {
        return _forceCloseReason(positionId);
    }

    // ------------------------------------------------------------------ unlock callback

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes32 positionId, PoolId poolId, address caller) =
            abi.decode(data, (uint8, bytes32, PoolId, address));
        PoolState storage pool = pools[poolId];

        if (action == ACTION_POKE) {
            _walkTriggers(pool.key, poolId);
            _processQueue(pool.key, poolId, MAX_CHUNKS_PER_POKE);
            _walkTriggers(pool.key, poolId);
        } else if (action == ACTION_FORCE_CLOSE) {
            _executeForceClose(pool.key, positionId, caller);
        } else {
            revert UnknownAction();
        }
        return "";
    }

    // ------------------------------------------------------------------ trigger walking

    function _walkTriggers(PoolKey memory key, PoolId poolId) internal {
        PoolState storage pool = pools[poolId];
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 from = pool.processedTick;
        if (tick == from) return;
        bool up = tick > from;

        (int24[] memory crossed, uint256 n, int24 walkedTo) =
            triggers[poolId].crossedTriggers(from, tick, key.tickSpacing, MAX_TRIGGERS_PER_WALK);
        uint256 budget = MAX_REFRESHES_PER_WALK;
        for (uint256 i = 0; i < n; i++) {
            bytes32[] storage ids = triggers[poolId].idsAtTick(crossed[i]);
            uint256 m = ids.length;
            if (m > budget) {
                // gas bound hit mid-tick (dust-position pileup): stop before this
                // trigger; the next swap or poke resumes here. _refreshPosition is
                // idempotent, so partially re-processing a tick later is safe.
                pool.processedTick = up ? crossed[i] - 1 : crossed[i] + 1;
                return;
            }
            for (uint256 j = 0; j < m; j++) {
                _refreshPosition(ids[j], tick);
            }
            budget -= m;
        }
        pool.processedTick = walkedTo;
    }

    /// @dev Recompute a position's liquidation status from the current tick.
    /// Idempotent; safe to call for any active position at any time.
    function _refreshPosition(bytes32 positionId, int24 tick) internal {
        Position storage pos = positions[positionId];
        if (pos.borrower == address(0)) return;

        bool inR = LiqRangeMath.inRange(pos.collateralIs0, tick, pos.tickStart, pos.tickEnd);
        if (inR && pos.liqStartedAt == 0) {
            pos.liqStartedAt = uint40(block.timestamp);
            // first chunk becomes due immediately
            pos.lastChunkAt = uint40(block.timestamp - configs[pos.poolId].chunkInterval);
            if (!pos.inQueue) {
                pos.inQueue = true;
                liqQueue[pos.poolId].push(positionId);
            }
            emit LiquidationStarted(positionId, tick);
        } else if (!inR && pos.liqStartedAt != 0) {
            uint256 episode = block.timestamp - pos.liqStartedAt;
            pos.timeInLiqAccrued += uint40(episode);
            pos.liqStartedAt = 0;
            emit LiquidationPaused(positionId, tick, episode);
            // stays in the queue; removed lazily by _processQueue
        }
    }

    // ------------------------------------------------------------------ chunk engine

    function _processQueue(PoolKey memory key, PoolId poolId, uint256 maxChunks) internal {
        bytes32[] storage queue = liqQueue[poolId];
        uint256 executed;
        uint256 scanned;
        uint256 maxScan = maxChunks * 3 + 2;

        while (executed < maxChunks && scanned < maxScan && queue.length > 0) {
            uint256 cursor = queueCursor[poolId];
            if (cursor >= queue.length) {
                cursor = 0;
            }
            bytes32 positionId = queue[cursor];
            Position storage pos = positions[positionId];
            scanned++;

            // lazy removal: closed or currently out of range -> drop from queue
            if (pos.borrower == address(0) || pos.liqStartedAt == 0) {
                pos.inQueue = false;
                queue[cursor] = queue[queue.length - 1];
                queue.pop();
                continue; // same cursor now holds a different entry (or shrank)
            }

            if (_executeChunk(key, positionId)) executed++;
            queueCursor[poolId] = cursor + 1;
        }
    }

    /// @dev Sell one due chunk of collateral into the pool. Returns true if a
    /// chunk was executed. Assumes unlocked PoolManager context.
    function _executeChunk(PoolKey memory key, bytes32 positionId) internal returns (bool) {
        Position storage pos = positions[positionId];
        PoolId poolId = pos.poolId;
        Config memory cfg = configs[poolId];
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        // depth of in-range liquidity across this position's own range, measured
        // in collateral-token units: pressure metric + per-chunk impact cap
        uint256 depthTokens = _rangeDepthTokens(poolId, pos);
        if (depthTokens == 0) return false; // no liquidity to sell into

        uint256 chunk = ChunkMath.chunkSize(
            ChunkMath.Params({
                remaining: pos.collateral,
                targetChunks: cfg.targetChunks,
                elapsed: block.timestamp - pos.lastChunkAt,
                interval: cfg.chunkInterval,
                timeCapX: cfg.timeCapX,
                depthBps: LiqRangeMath.depthBps(pos.collateralIs0, tick, pos.tickStart, pos.tickEnd),
                pressureBps: FullMath.mulDiv(pos.collateral, BPS, depthTokens),
                minChunk: 0,
                maxChunk: FullMath.mulDiv(depthTokens, cfg.maxChunkDepthBps, BPS)
            })
        );
        if (chunk == 0) return false;

        // effects before interactions: a reentrant afterSwap during settlement
        // must see this chunk as already taken
        pos.collateral -= uint128(chunk);
        pos.lastChunkAt = uint40(block.timestamp);

        (uint256 consumed, uint256 proceeds, uint256 penalty) =
            _swapCollateral(key, pos, chunk, _currentPenaltyBps(pos, cfg), 0);
        if (consumed < chunk) pos.collateral += uint128(chunk - consumed); // unbounded limit: only at pool edge

        // repay the vault with net proceeds
        LendingVault vault = _debtVault(pos);
        uint256 net = proceeds - penalty;
        uint256 used;
        uint256 burned;
        if (net > 0) {
            (burned, used) = vault.repay(net, pos.debtShares);
            pos.debtShares -= uint128(burned);
            if (net > used) {
                // debt fully repaid mid-chunk: excess proceeds belong to the borrower
                vault.asset().safeTransfer(pos.borrower, net - used);
            }
        }
        emit ChunkExecuted(positionId, consumed, proceeds, penalty, used);

        if (pos.debtShares == 0) {
            _closePosition(positionId, 0);
        } else if (pos.collateral == 0) {
            _closePosition(positionId, pos.debtShares); // bad debt: write off remainder
        }
        return true;
    }

    /// @dev Swap up to `amount` of the position's collateral into the debt
    /// currency (bounded by `sqrtPriceLimit`; 0 = unbounded) and donate the
    /// penalty to in-range LPs. Settles all deltas. Returns the collateral
    /// actually consumed (partial when the price limit is hit), gross proceeds,
    /// and the penalty actually donated.
    function _swapCollateral(
        PoolKey memory key,
        Position storage pos,
        uint256 amount,
        uint256 penaltyBps_,
        uint160 sqrtPriceLimit
    ) internal returns (uint256 consumed, uint256 proceeds, uint256 penalty) {
        bool zeroForOne = pos.collateralIs0;
        if (sqrtPriceLimit == 0) {
            sqrtPriceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount), // exact input
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            ""
        );
        consumed = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        proceeds = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));

        // pay the consumed collateral in
        if (consumed > 0) {
            (zeroForOne ? key.currency0 : key.currency1).settle(poolManager, address(this), consumed, false);
        }

        // donate penalty to in-range LPs (skip if pool momentarily has no active liquidity)
        penalty = FullMath.mulDiv(proceeds, penaltyBps_, BPS);
        if (penalty > 0 && poolManager.getLiquidity(pos.poolId) > 0) {
            if (zeroForOne) poolManager.donate(key, 0, penalty, "");
            else poolManager.donate(key, penalty, 0, "");
        } else {
            penalty = 0;
        }

        // take net proceeds
        if (proceeds > penalty) {
            (zeroForOne ? key.currency1 : key.currency0).take(poolManager, address(this), proceeds - penalty, false);
        }
    }

    // ------------------------------------------------------------------ force close

    function _executeForceClose(PoolKey memory key, bytes32 positionId, address caller) internal {
        Position storage pos = positions[positionId];
        uint8 reason = _forceCloseReason(positionId);
        Config memory cfg = configs[pos.poolId];

        // close out any running liquidation episode for penalty accounting
        (, int24 tick,,) = poolManager.getSlot0(pos.poolId);
        _refreshPosition(positionId, tick);

        uint256 collateralToSell = pos.collateral;
        uint256 reward;
        uint256 used;
        if (collateralToSell > 0) {
            pos.collateral = 0; // effects before interactions

            // execution is slippage-bounded: in a drained or manipulated pool the
            // sale fills only within FC_MAX_SLIPPAGE_TICKS of the current price;
            // whatever doesn't fill stays as collateral and forceClose is retried
            // later — never a fire sale into an empty book.
            uint160 limit;
            {
                int24 limitTick = pos.collateralIs0 ? tick - FC_MAX_SLIPPAGE_TICKS : tick + FC_MAX_SLIPPAGE_TICKS;
                if (limitTick < TickMath.MIN_TICK) limitTick = TickMath.MIN_TICK + 1;
                if (limitTick > TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK - 1;
                limit = TickMath.getSqrtPriceAtTick(limitTick);
            }
            (uint256 consumed, uint256 proceeds, uint256 penalty) =
                _swapCollateral(key, pos, collateralToSell, _currentPenaltyBps(pos, cfg), limit);
            if (consumed < collateralToSell) pos.collateral = uint128(collateralToSell - consumed);

            // caller reward comes out of the penalty flow, not the borrower's hide
            reward = FullMath.mulDiv(proceeds, cfg.rewardBps, BPS);
            if (reward > proceeds - penalty) reward = proceeds - penalty;

            LendingVault vault = _debtVault(pos);
            uint256 net = proceeds - penalty - reward;
            if (net > 0) {
                uint256 burned;
                (burned, used) = vault.repay(net, pos.debtShares);
                pos.debtShares -= uint128(burned);
                if (net > used) vault.asset().safeTransfer(pos.borrower, net - used);
            }
            if (reward > 0) vault.asset().safeTransfer(caller, reward);
        }

        emit ForceClosed(positionId, caller, reason, reward);
        if (pos.debtShares == 0) {
            _closePosition(positionId, 0); // debt cleared; leftovers go home
        } else if (pos.collateral == 0) {
            _closePosition(positionId, pos.debtShares); // nothing left to sell: bad debt
        }
        // else: partial fill under the slippage bound — position stays open and
        // remains forceClose-eligible; keepers retry as liquidity returns
    }

    function _forceCloseReason(bytes32 positionId) internal view returns (uint8) {
        Position storage pos = positions[positionId];
        if (pos.borrower == address(0)) return 0;
        (, int24 tick,,) = poolManager.getSlot0(pos.poolId);
        if (LiqRangeMath.pastRange(pos.collateralIs0, tick, pos.tickEnd)) return 1;
        if (block.timestamp > pos.expiry) return 2;

        // health breach: at the CURRENT price, remaining collateral (after the
        // slippage buffer) no longer covers the debt — interest erosion or a
        // partial gap-through has made waiting strictly worse for lenders
        uint256 debt = _debtVault(pos).debtAssetsForShares(pos.debtShares);
        uint256 collValue =
            LiqRangeMath.convertAtSqrtPrice(pos.collateral, TickMath.getSqrtPriceAtTick(tick), pos.collateralIs0);
        uint256 usable = FullMath.mulDiv(collValue, BPS - configs[pos.poolId].slippageBufferBps, BPS);
        if (usable < debt) return 3;
        return 0;
    }

    // ------------------------------------------------------------------ closing & accounting

    /// @dev Close a position: return remaining collateral to the borrower, write
    /// off `writeOffShares` of unrecoverable debt, deregister triggers.
    function _closePosition(bytes32 positionId, uint256 writeOffShares) internal {
        Position storage pos = positions[positionId];
        PoolState storage pool = pools[pos.poolId];
        PoolKey memory key = pool.key;

        uint256 collateralBack = pos.collateral;
        uint256 shortfall;
        if (writeOffShares > 0) {
            LendingVault vault = pos.collateralIs0 ? pool.vault1 : pool.vault0;
            shortfall = vault.writeOff(writeOffShares);
        }

        triggers[pos.poolId].deregister(pos.tickStart, key.tickSpacing, positionId);
        triggers[pos.poolId].deregister(pos.tickEnd, key.tickSpacing, positionId);

        address borrower = pos.borrower;
        bool collateralIs0 = pos.collateralIs0;
        delete positions[positionId]; // also drops it from the queue lazily

        if (collateralBack > 0) {
            ERC20(Currency.unwrap(collateralIs0 ? key.currency0 : key.currency1)).safeTransfer(borrower, collateralBack);
        }
        emit PositionClosed(positionId, collateralBack, shortfall);
    }

    // ------------------------------------------------------------------ views & helpers

    function _currentPenaltyBps(Position storage pos, Config memory cfg) internal view returns (uint256) {
        uint256 timeInLiq = pos.timeInLiqAccrued;
        if (pos.liqStartedAt != 0) timeInLiq += block.timestamp - pos.liqStartedAt;
        return ChunkMath.penaltyBps(cfg.basePenaltyBps, pos.ltBps, timeInLiq, cfg.timeCapX);
    }

    /// @dev Token depth of current in-range liquidity spread across the position's
    /// range, in collateral-token units. Rough but cheap and monotone.
    function _rangeDepthTokens(PoolId poolId, Position storage pos) internal view returns (uint256) {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return 0;
        (uint160 lo, uint160 hi) = pos.tickStart < pos.tickEnd
            ? (TickMath.getSqrtPriceAtTick(pos.tickStart), TickMath.getSqrtPriceAtTick(pos.tickEnd))
            : (TickMath.getSqrtPriceAtTick(pos.tickEnd), TickMath.getSqrtPriceAtTick(pos.tickStart));
        return pos.collateralIs0
            ? SqrtPriceMath.getAmount0Delta(lo, hi, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(lo, hi, liquidity, false);
    }

    function _debtVault(Position storage pos) internal view returns (LendingVault) {
        PoolState storage pool = pools[pos.poolId];
        return pos.collateralIs0 ? pool.vault1 : pool.vault0;
    }

    function getConfig(PoolId poolId) external view returns (Config memory) {
        return configs[poolId];
    }

    function getPosition(bytes32 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getPool(PoolId poolId)
        external
        view
        returns (LendingVault vault0, LendingVault vault1, int24 processedTick, bool enabled)
    {
        PoolState storage p = pools[poolId];
        return (p.vault0, p.vault1, p.processedTick, p.enabled);
    }

    function queueLength(PoolId poolId) external view returns (uint256) {
        return liqQueue[poolId].length;
    }

    /// @notice Current debt of a position in debt-asset units.
    function debtOf(bytes32 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        if (pos.borrower == address(0)) return 0;
        return _debtVault(pos).debtAssetsForShares(pos.debtShares);
    }

    // ------------------------------------------------------------------ admin

    function setConfig(PoolId poolId, Config calldata cfg) external onlyOwner {
        configs[poolId] = cfg;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
