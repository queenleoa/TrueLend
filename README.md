# TrueLend 🔄

## Oracleless Lending via Uniswap v4 Inverse Range Orders

TrueLend enables **reversible liquidations** without price oracles by using AMM mechanics.

---

## 📐 How Tick Ranges Are Calculated

### The Setup

```
ETH/USDC Pool (ETH = token0, USDC = token1)
Current ETH price: $2000
User deposits: 1 ETH as collateral
User borrows: 1000 USDC
LT (Liquidation Threshold): 80%
```

### Key Formulas

```
LTV (Loan-to-Value) = debt / collateralValue
                    = 1000 / 2000 = 50%

LIQUIDATION TRIGGERS when LTV reaches LT:
  triggerPrice = debt / (collateral × LT)
               = 1000 / (1 × 0.8)
               = $1250

FULL LIQUIDATION when LTV = 100%:
  fullPrice = debt / collateral
            = $1000
```

### Effect of Different LTs (same 50% starting LTV)

| LT | Trigger Price | Full Liquidation | Range Width | Behavior |
|----|---------------|------------------|-------------|----------|
| 60% | $1667 | $1000 | $667 | Triggers CLOSER, WIDER range (gradual) |
| 80% | $1250 | $1000 | $250 | Medium |
| 95% | $1053 | $1000 | $53 | Triggers FURTHER, NARROW range (fast) |

**Key Insight:**
- **Lower LT** = Less buffer = Triggers sooner, but gradual liquidation
- **Higher LT** = More buffer = Triggers later, but fast once triggered

---

## 💰 Penalty System

When a position is **underwater** (in liquidation range), penalties accrue to compensate liquidity providers and incentivize liquidations.

### Penalty Rate: 30% APR

```
While position is in liquidation range:
  penalty_per_second = collateral × (30% / year) / 1e18
  
Example: 1 ETH underwater for 1 day
  penalty = 1 ETH × 0.30 / 365 ≈ 0.00082 ETH
```

### Distribution: 95% LPs / 5% Swappers

```
┌─────────────────────────────────────────────────────────────┐
│              PENALTY DISTRIBUTION                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   Position underwater → 30% APR penalty accrues             │
│                                                              │
│   On liquidation:                                            │
│   ├── 95% → Lenders (increases pool.totalDeposits)          │
│   │         LPs earn yield for providing liquidity          │
│   │                                                          │
│   └── 5%  → Swappers (reward for executing liquidation)     │
│             Incentivizes liquidations during swaps          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Why This Matters

1. **LPs earn penalty yield** on top of interest
   - Compensation for having liquidity "reserved" for liquidations
   - Higher yield than just borrow interest

2. **Swappers are incentivized** to execute liquidations
   - 5% of accrued penalty as reward
   - Natural market mechanism - no need for bots

3. **Borrowers have incentive** to repay quickly
   - 30% APR is expensive while underwater
   - But still better than 5-15% instant liquidation penalty

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER FLOWS                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  LENDERS                          BORROWERS         SWAPPERS    │
│     │                                 │                 │        │
│     │ deposit(USDC)                   │ borrow()        │ swap() │
│     │ withdraw(USDC)                  │ repay()         │        │
│     │                                 │                 │        │
│     │ Earn:                           │ Pay:            │ Earn:  │
│     │ • Borrow interest               │ • Interest      │ • 5%   │
│     │ • 95% of penalties              │ • Penalties     │   of   │
│     │                                 │   (if underwater)│  penalty│
│     ▼                                 ▼                 ▼        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    TrueLendRouter                        │   │
│  │                                                          │   │
│  │  pool0 (ETH)              pool1 (USDC)                  │   │
│  │  ├─ totalDeposits         ├─ totalDeposits ← penalties  │   │
│  │  ├─ totalBorrows          ├─ totalBorrows               │   │
│  │  └─ totalShares           └─ totalShares                │   │
│  └────────────────────────────┬─────────────────────────────┘   │
│                               │                                  │
│                               ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    TrueLendHook                          │   │
│  │                                                          │   │
│  │  • Holds collateral                                      │   │
│  │  • Tracks penalty accrual (lastPenaltyTime)              │   │
│  │  • beforeSwap(): process liquidations                    │   │
│  │  • Distributes: 95% to Router, 5% to swapper             │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🎮 Demo Scenarios

### Setup
```
Pool: ETH/USDC
ETH Price: $2000
Position: 1 ETH collateral, 1000 USDC debt, 80% LT
Liquidation Range: $1000 - $1250
```

### Case 1: Price Stays at $2000 (No Liquidation)
```
Current tick > tickUpper
→ Position HEALTHY
→ No penalty accrues
→ Borrower repays debt only
```

### Case 2: Price Drops to $1150 (Partial Liquidation)
```
tickLower < current tick < tickUpper
→ Position IN RANGE (underwater)
→ Penalty accruing at 30% APR

Swap occurs:
→ 43% of collateral liquidated (0.43 ETH)
→ 43% of debt repaid (430 USDC)
→ Penalty distributed: 95% to lenders, 5% to swapper
```

### Case 3: Price Drops to $900 (Full Liquidation)
```
Current tick < tickLower
→ Position FULLY LIQUIDATED
→ All 1 ETH taken
→ All 1000 USDC repaid
→ All accrued penalty distributed
→ Position closed
```

---

## 📁 Contract Structure

### TrueLendRouter.sol

```solidity
// Lender functions
deposit(token, amount) → shares        // Earn interest + 95% penalties
withdraw(token, shares) → amount

// Borrower functions
borrow(collateral, debt, zeroForOne, ltBps) → positionId
repay(positionId)                      // Pay debt + any accrued penalty

// Hook callback
onLiquidation(positionId, debtToken, debtRepaid, penaltyToLPs)
```

### TrueLendHook.sol

```solidity
// Position management
openPosition(id, owner, collateral, debt, zeroForOne, ltBps)
closePosition(id) → (collateralBack, debtRemaining, penaltyOwed)

// Swap hook
beforeSwap() → processes liquidations, distributes penalties

// View functions
getPosition(id) → Position
getPositionInfo(id) → (collateral, debt, penalty, isActive, inLiquidation)
isInLiquidationRange(id) → bool
getLiquidationProgress(id) → progressBps (0-10000)
```

---

## 🧪 Testing Guide

### Test 1: Healthy Position
1. Lender deposits 10000 USDC
2. Borrower opens: 1 ETH, 1000 USDC, 80% LT
3. Verify `isInLiquidationRange()` = false
4. Borrower repays → gets all 1 ETH back
5. Verify no penalty paid

### Test 2: Partial Liquidation with Penalty
1. Same setup
2. Move tick into liquidation range
3. Wait some time (penalty accrues)
4. Execute swap in matching direction
5. Verify:
   - Partial collateral liquidated
   - Router received 95% of penalty (increases totalDeposits)
   - Swapper received 5% reward

### Test 3: Full Liquidation
1. Same setup
2. Move tick below tickLower
3. Execute swap
4. Verify position fully liquidated
5. Verify all penalty distributed

---

## 🔑 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **30% APR penalty** | High enough to compensate LPs, incentivize repayment |
| **95/5 split** | LPs bear most risk, deserve most reward. 5% enough to incentivize swappers |
| **Penalty on collateral** | Proportional to risk exposure |
| **Accrual while underwater** | Only charge when actually at risk |
| **Separate pools** | Each token's supply/demand is independent |

---

## 📊 Rate Summary

| Rate | Value | Who Pays | Who Receives |
|------|-------|----------|--------------|
| Borrow interest | Variable | Borrowers | Lenders |
| Penalty (underwater) | 30% APR | Borrowers | 95% Lenders, 5% Swappers |

---

## 📜 License

MIT