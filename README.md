# TrueLend - Oracleless Lending Protocol

**Eliminate oracle risk. Enable 99% LTV. Reward LPs for liquidations.**

Built on Uniswap v4 hooks using inverse range orders for AMM-native liquidation.

---

## 🎯 Problem

- **$1B+ lost to oracle exploits.** Traditional lending protocols (Aave, Compound, Maker) depend on external price oracles, creating:
- **Single point of failure**: Oracle manipulation → protocol drain (Mango Markets: $116M, Cream Finance: $130M)
- **Liquidation death spirals**: Cascading liquidations during volatility crash prices further
- **High liquidation penalties**: 5-13% penalty + MEV extraction punishes borrowers
- **Conservative LTV caps**: 70-80% maximum due to oracle lag and manipulation risk

**Core issue**: Price feeds are external, delayed, and manipulatable. Liquidations rely on keeper bots racing for profit selling to externl markets.

---

## ✨ Solution

**Use Uniswap v4 AMM as the price feed.** Liquidations happen automatically when price enters the position's liquidation range—no oracles, no keeper bots, just AMM mechanics.

### Inverse Range Orders

Borrower's collateral creates a "claim" on LP liquidity in a specific tick range `[tickLower, tickUpper]`. When AMM price enters this range, position liquidates proportionally via the `beforeSwap()` hook.

```
Price moves → Swap occurs → Hook detects tick in range → Liquidates proportionally
```

### Key Innovations

**1. Oracleless**: AMM tick price IS the liquidation trigger. No external dependencies.

**2. Transient Liquidations**: Positions decay gradually, not instantly. If price recovers before full liquidation → borrower keeps remaining collateral.

**3. Dynamic Penalty Pricing**: Higher LT = riskier = higher penalty rate. Fair market pricing for risk.
```
penaltyRate = 10% + (LT - 50%) × 1.0
Examples: 60% LT → 20% APR, 80% LT → 40% APR, 95% LT → 55% APR
```

**4. LP Rewards**: 90% of penalties → LPs, 10% → swapper triggering liquidation. Passive income for providing liquidity.

**5. Flexible LTV**: 50-99% liquidation threshold. Borrowers choose their risk/reward profile.

| Feature | Traditional | TrueLend |
|---------|------------|----------|
| Oracle Dependency | Chainlink required | None |
| Max LT | 70-80% | 99% |
| Liquidation Type | Instant at threshold | Proportional decay |
| Penalty | 5-13% flat + MEV | Time-based accrual |
| Death Spirals | Yes | No |
| LP Rewards | Swap fees only | Swap fees + penalties |

---

## 🏗️ Architecture

Two-contract system integrated with Uniswap v4:

```
┌────────────────────────────────────────────────────────┐
│  TrueLendRouter (Periphery)                           │
│  • Manages lending pools (token0/token1)              │
│  • Share-based accounting (like Compound)             │
│  • 5% fixed APR interest                              │
│  • Validates initial LTV                              │
│  • Processes liquidation callbacks                    │
└────────────────────────────────────────────────────────┘
                        │
                        ↓
┌────────────────────────────────────────────────────────┐
│  TrueLendHook (Core)                                  │
│  • Holds borrower collateral                          │
│  • Calculates tick ranges [tickLower, tickUpper]      │
│  • Detects liquidations in beforeSwap()               │
│  • Executes proportional liquidations                 │
│  • Distributes penalties (90% LP, 10% swapper)        │
└────────────────────────────────────────────────────────┘
                        │
                        ↓
┌────────────────────────────────────────────────────────┐
│  Uniswap v4 PoolManager                               │
│  • Singleton architecture (all pools)                 │
│  • Flash accounting (transient storage)               │
│  • Native hook integration                            │
└────────────────────────────────────────────────────────┘
```

### Position Lifecycle

**Opening:**
```
1. User deposits collateral → Router
2. Router transfers collateral → Hook
3. Hook calculates tick range accounting for 1-year debt growth
4. Router mints debt token → User
5. Position tracked in both contracts
```

**Liquidation:**
```
1. Swap occurs → Hook.beforeSwap() triggered
2. Current tick checked against position ranges
3. If in range: accrue penalty, liquidate proportionally
4. Deduct penalty (90% LP, 10% swapper)
5. Swap remaining collateral → debt token
6. Send debt to Router → Router.onLiquidation()
7. Update position state
```

**Repayment:**
```
1. User repays debt + interest → Router
2. Router requests collateral → Hook
3. Hook transfers collateral → Router → User
4. Position closed
```

---

## 📐 Mathematical Formulas

### 1. Tick Range Calculation

Calculate liquidation range accounting for 1 year of debt growth:

```solidity
maxDebt = initialDebt × 1.07  // 5% interest + 2% fee buffer

// For token0 collateral (ETH), borrowing token1 (USDC):
collateralValue = collateral × currentPrice

// Liquidation starts when LTV = LT
triggerPrice = maxDebt / (collateral × LT)
tickUpper = priceToTick(triggerPrice)

// Full liquidation when debt = collateral value
fullPrice = maxDebt / collateral
tickLower = priceToTick(fullPrice)

// Align to 60-tick spacing (conservative rounding)
tickLower = floor(tickLower / 60) × 60
tickUpper = floor(tickUpper / 60) × 60
```

**Example:** 1 ETH collateral, 1000 USDC debt, 80% LT, current price $2000
```
maxDebt = 1000 × 1.07 = 1070 USDC
collateralValue = 1 ETH × $2000 = $2000

triggerPrice = 1070 / (1 × 0.8) = $1337.5 → tickUpper ≈ 1200
fullPrice = 1070 / 1 = $1070 → tickLower ≈ 540

Range: [540, 1200] = [$1070, $1337.5]
```

### 2. Penalty Rate (Dynamic Based on LT)

```solidity
penaltyRate = 10% + (LT - 50%) × 1.0

LT = 50% → 10% APR  (safe)
LT = 60% → 20% APR
LT = 80% → 40% APR  (moderate)
LT = 95% → 55% APR  (aggressive)
```

**Rationale:** Higher LT = less buffer = riskier for LPs → higher compensation.

### 3. Penalty Amount Calculation (Detailed)

**While position is underwater** (tick in liquidation range):

```solidity
penaltyAmount = collateral × penaltyRate × timeElapsed / SECONDS_PER_YEAR
```

**Complete Example:**
```
Position: 1 ETH collateral, 1000 USDC debt, 80% LT
Price: $2000 → $1200 (underwater)
Time underwater: 7 days
Penalty rate: 40% APR (from 80% LT)

Step 1: Calculate penalty amount
  penaltyAmount = 1 ETH × 0.40 × (7 × 86400) / 31536000
  penaltyAmount = 1 ETH × 0.40 × 604800 / 31536000
  penaltyAmount = 1 ETH × 0.40 × 0.01918
  penaltyAmount = 0.00767 ETH (~$15.34 at $2000)

Step 2: Distribute penalty
  LP share (90%):      0.00690 ETH → added to totalLPPenalties
  Swapper share (10%): 0.00077 ETH → direct transfer

Step 3: Liquidation execution (assume 45% progress)
  Collateral to liquidate: 0.45 ETH (based on tick depth)
  Penalty deducted: 0.00767 ETH (from total collateral)
  Net collateral swapped: 0.45 ETH - proportional penalty
  Swapped to: ~530 USDC → sent to Router
  
Step 4: Position update
  Remaining collateral: 0.55 ETH
  Remaining debt: 470 USDC (1000 - 530)
  Still active (not fully liquidated)

Step 5: If price recovers to $1800
  Borrower repays: 470 + interest ≈ 474 USDC
  Gets back: 0.55 ETH (worth ~$990)
  
Total cost: $1000 debt + $15 penalty + slippage = realistic loss
```

**Key insight:** Penalty accrues by time, deducted from collateral, distributed immediately on liquidation.

### 4. Proportional Liquidation

```solidity
progressBps = (ticksIntoRange / rangeWidth) × 10000

For zeroForOne (price dropping):
  ticksIntoRange = tickUpper - currentTick
  
collateralToLiquidate = initialCollateral × (progressBps / 10000)
```

**Example:** Range [540, 1200], current tick = 900
```
ticksIntoRange = 1200 - 900 = 300
rangeWidth = 1200 - 540 = 660
progressBps = (300 / 660) × 10000 = 4545  (45.45%)

If initialCollateral = 1 ETH:
  liquidate = 1 × 0.4545 = 0.4545 ETH
```

### 5. Interest Accrual - simplified fixed rate

```solidity
accruedInterest = principal × 0.05 × timeElapsed / SECONDS_PER_YEAR
currentDebt = initialDebt + accruedInterest
```

**Example:** 1000 USDC borrowed for 180 days
```
interest = 1000 × 0.05 × (180 × 86400) / 31536000
         = 1000 × 0.05 × 0.4932
         = 24.66 USDC

currentDebt = 1000 + 24.66 = 1024.66 USDC
```

---

## ⚡ Gas Optimizations

**Tick Bitmap**: O(1) position lookup at specific ticks. Only check positions in liquidation range during swaps.

**Share-Based Accounting**: Interest distributes automatically via exchange rate. No per-user accrual tracking.

**Fixed Interest**: Tick ranges never change post-creation. No dynamic recalculation.

**Packed Structs**: `uint128` for amounts, `uint40` for timestamps. Multiple values per storage slot.

**Minimal Cross-Contract Calls**: Router ↔ Hook only on open/close/liquidation. Self-contained operations.

---

## 🚀 Local Setup

### Prerequisites
```bash
forge install
```

### Run Tests
```bash
# Run all tests
forge test -vvv

# Run specific test
forge test --match-test testBorrowAndRepay -vvvv

# Gas report
forge test --gas-report
```

### Deploy Locally
```bash
# Start local node
anvil

# Deploy contracts
forge script script/00_DeployTrueLendHook.s.sol --broadcast --rpc-url http://localhost:8545

# Initialize pool
forge script script/01_DeployTrueLendRouter.s.sol --broadcast --rpc-url http://localhost:8545
```

### Frontend
```bash
cd frontend
npm install
npm run dev
# Open http://localhost:3000
```

---

## 📄 License

MIT