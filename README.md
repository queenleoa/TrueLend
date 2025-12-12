# TrueLend: Oracleless AMM-Native Lending Protocol

## 🎯 Problem Statement
Billions of dollars in DeFi lending failures stem from oracle dependence:
- **Latency** : External price feeds lag behind market reality
- **Manipulation Risk** : Oracle price feeds can be attacked or manipulated
- **Asset Listing Constraints** : Only assets with reliable oracles can be listed
- **Conservative LTs** : Protocols must maintain low liquidation thresholds (50-80%) to compensate for oracle uncertainty
- **Binary Liquidations**: All-or-nothing liquidations cause cascading deleveraging "death spirals"

## 💡 TrueLend's Solution

TrueLend eliminates oracles entirely by embedding liquidation logic directly into Uniswap v4 AMM dynamics:
### AMM-Native Liquidations

Instead of external oracles, TrueLend uses:
- **Tick Movement** : Price is defined by AMM tick position
- **Gradual Liquidation**: TWAMM-style incremental swaps replace binary liquidations
- **Reversible Process**: If price moves back, liquidation pauses/reverses
- **Higher LTs**: Support liquidation thresholds up to 99


## Architecture
![alt text](https://github.com/queenleoa/TrueLend/blob/fd3a6489316b7bd34bb41c5fa43b1b57dfe74c0f/architecture.png)

### Hook Functions

#### `beforeSwap()`
**Purpose**: Detect liquidation range crossing
**Flow**:
1. Get current tick and estimate new tick after swap
2. Check if crossing into any position's liquidation range (tickLower)
3. Mark positions for liquidation if threshold crossed
4. Return zero delta - user's swap proceeds unaffected

```solidity
function _beforeSwap(
    PoolKey calldata key,
    SwapParams calldata params
) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    int24 currentTick = getCurrentTick(key);
    int24 estimatedNewTick = _estimateNewTick(key, params, currentTick);
    _checkAndActivateLiquidations(key, currentTick, estimatedNewTick);
    return (selector, ZERO_DELTA, 0);
}
```

#### `afterSwap()`
**Purpose**: Execute TWAMM-style liquidation chunks
**Flow**:
1. For each position needing liquidation:
   - Calculate chunk size based on time, depth, liquidity pressure
   - Execute chunk via `unlock()` callback
   - Update position accounting
2. Check if position fully liquidated or safe

```solidity
function _afterSwap(
    PoolKey calldata key
) internal override returns (bytes4, int128) {
    _executeLiquidationChunks(key);
    return (selector, 0);
}
```

#### `unlockCallback()`
**Purpose**: Execute single liquidation chunk
**Flow**:
1. Settle borrower's USDC collateral to PoolManager
2. Execute swap: USDC → ETH
3. Calculate penalty based on LT, time in liquidation, amount
4. Donate penalty to LPs via `donate()`
5. Apply remaining ETH to debt repayment
6. Update position accounting

```solidity
function unlockCallback(bytes calldata data) external onlyPoolManager {
    // Settle collateral to PM
    currency1.settle(poolManager, address(this), amount, false);
    
    // Execute swap
    BalanceDelta delta = poolManager.swap(poolKey, swapParams, "");
    
    // Take received ETH
    uint256 ethReceived = uint256(uint128(-delta.amount0()));
    currency0.take(poolManager, address(this), ethReceived, false);
    
    // Calculate and donate penalty
    uint256 penalty = _calculatePenalty(pos, amount, ethReceived);
    poolManager.donate(poolKey, penalty, 0, "");
    currency0.settle(poolManager, address(this), penalty, false);
    
    // Update position
    pos.collateralRemaining -= amount;
    pos.debtRepaid += (ethReceived - penalty);
}
```

### Position Management

#### `createPosition()`
Creates new borrow position with:
- Collateral transfer from router to hook
- Liquidation tick calculation using TickMath
- Position tracking in mapping and tick arrays
- Borrowed token transfer to borrower

```solidity
function createPosition(
    PoolKey calldata key,
    address borrower,
    uint256 collateralAmount,
    uint256 debtAmount,
    uint8 liquidationThreshold
) external onlyLendingRouter returns (bytes32 positionId) {
    // Calculate liquidation ticks
    (int24 tickLower, int24 tickUpper) = _calculateLiquidationTicks(...);
    
    // Transfer collateral from router
    IERC20(currency1).transferFrom(msg.sender, address(this), collateralAmount);
    
    // Create position
    positions[positionId] = BorrowPosition({...});
    
    // Track position
    activePositions[poolId].push(positionId);
    positionsAtTick[poolId][tickLower].push(positionId);
    
    // Send borrowed tokens to borrower
    IERC20(currency0).transfer(borrower, debtAmount);
}
```

### Key Data Structures

```solidity
struct BorrowPosition {
    address borrower;
    uint256 collateralAmount;      // Original USDC deposited
    uint256 collateralRemaining;   // USDC not yet liquidated
    uint256 debtAmount;            // Original ETH borrowed
    uint256 debtRepaid;            // ETH repaid via liquidation
    int24 tickLower;               // Liquidation start tick
    int24 tickUpper;               // Liquidation end tick
    uint8 liquidationThreshold;    // LT as percentage (90 = 90%)
    bool needsLiquidation;         // Currently in liquidation range
    bool isActive;                 // Position is open
}
```

### Liquidation Tick Calculation

Given current price, liquidation threshold, collateral, and debt:

```solidity
function _calculateLiquidationTicks(
    uint160 sqrtPriceX96Current,
    uint8 liquidationThreshold,
    uint256 collateralAmount,
    uint256 debtAmount
) internal pure returns (int24 tickLower, int24 tickUpper) {
    // Liquidation price: (LT * collateral) / (debt * 100)
    uint256 liquidationPrice = FullMath.mulDiv(
        liquidationThreshold * collateralAmount,
        1,
        debtAmount * 100
    );
    
    // Convert to sqrtPriceX96
    uint160 sqrtPriceLiquidation = uint160(
        FixedPointMathLib.sqrt(liquidationPrice) << 96
    );
    
    // Get tick from sqrtPrice
    tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLiquidation);
    
    // Upper tick: ~sqrt(2) * liquidation price
    uint160 sqrtPriceUpper = uint160(
        (uint256(sqrtPriceLiquidation) * 14142) / 10000
    );
    tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpper);
}
```

### Chunk Size Formula

```solidity
chunkSize = baseChunk 
          * (timeSinceLastChunk / CHUNK_INTERVAL)
          * (1 + depthIntoRange / rangeWidth)
          * (1 + positionSize / poolLiquidity)
```

Bounded by MIN_CHUNK_SIZE (10 USDC), MAX_CHUNK_SIZE (1000 USDC).

### Penalty Calculation

```solidity
penalty = ethReceived
        * BASE_PENALTY_RATE (5%)
        * (LT / 100)
        * (1 + timeInLiquidation / 1 hour)
```

## Benefits

**For Borrowers**:
- Higher LTs: Up to 99% vs 50-80% in oracle-based systems
- Gradual liquidation: No instant wipeout
- Reversible: Price moves back = liquidation pauses

**For LPs**:
- New revenue stream: Earn penalties from liquidations
- No keeper needed: Embedded in swap flow

**For Protocol**:
- No oracle risk: Eliminates entire attack surface
- Simpler: No oracle integration or maintenance
- More assets: List any token pair with AMM liquidity

## Setup

### Build

```bash
forge build
```

### Test

```bash
forge test -vv
```

### Test Scenarios

1. **test_NoLiquidation_PriceBelowThreshold**: Position created, small swap executed, price stays below threshold, no liquidation occurs

2. **test_PartialLiquidation_PriceEntersRange**: Position created, large swap crosses into liquidation range, incremental liquidation begins, multiple chunks executed over time

3. **test_FullLiquidation_PriceThroughRange**: Position created, multiple swaps drive price through entire range, all collateral liquidated, position closed

### Deploy

```bash
forge script script/DeployTrueLend.s.sol:DeployTrueLend --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
```
