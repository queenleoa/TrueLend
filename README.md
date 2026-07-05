# TrueLend — Oracleless Lending on Uniswap v4

TrueLend is a lending protocol built as a Uniswap v4 hook. It uses **no price oracle**: the pool's own tick decides everything, and liquidation is not an event but a **process** — while the price sits inside a position's liquidation range, the hook sells the collateral in small, time-paced chunks into the pool; if the price recovers, the decay pauses. A penalty per chunk is donated to the pool's LPs, who replace keepers as the compensated absorbers of liquidation flow.

Because selling is rate-limited (≈1% of a position per minute, scaled by range depth and pool thinness), no liquidation can crater the price and cascade into the next one — and because the trigger is the pool's own tick, there is no oracle to lag, spoof, or de-list. That is what makes liquidation thresholds up to 99% possible on deep pools.

🏆 First place, UHI hackathon (original concept & v1). This is v2: the same liquidation mechanism, made correct and complete.

- **[DESIGN.md](DESIGN.md)** — the full specification: a loan walked end-to-end, architecture, the chunk engine, parameters, build plan.
- **[RESEARCH.md](RESEARCH.md)** — why chunked *active* conversion is the only AMM-native way to do this (passive "inverse range orders" are provably impossible on v4), prior art (LLAMMA, Ajna, Ammalgam, …), manipulation economics, and all the math.

## How it works

```
lenders ──deposit──► LendingVault0/1 ──borrow/repay──► TrueLendHook ◄──open/repay── borrowers
                                                            │
                                        beforeSwap: manipulation-resistant oracle obs
                                        afterSwap:  trigger-tick walk + ≤2 liquidation
                                                    chunks (direct swap + donate)
```

1. **Open**: borrower deposits one pool currency as collateral, borrows the other from that side's vault. Collateral is valued at the *worse of* spot and a truncated median of the pool's own recent ticks (single-block price pumps don't raise borrow limits). The position gets a liquidation range starting at its LT price, ~√2 wide.
2. **Decay**: when the pool tick is inside the range, each swap's `afterSwap` (or a permissionless `poke`) sells a paced chunk of collateral, donates a penalty to in-range LPs via `donate()`, and repays the vault. Price leaves the range → decay pauses; re-enters → resumes.
3. **Backstop**: past the range end, past the term (180d), or health-breached, anyone may `forceClose` for a reward. Shortfalls hit vault reserves first, then socialize pro-rata — a declared waterfall, not an implicit one.

## Contracts

| Contract | Role |
|---|---|
| [`TrueLendHook`](src/TrueLendHook.sol) | hook + lending core; one instance serves many pools — initializing any ERC20/ERC20 pool with this hook makes it a lending market |
| [`LendingVault`](src/LendingVault.sol) | per-currency lender vault: shares, borrow index, kinked IRM (kink 80%, hard cap 90%), 10% reserve factor |
| [`VaultFactory`](src/VaultFactory.sol) | deploys the two vaults per pool at initialization |
| [`libraries/LiqRangeMath`](src/libraries/LiqRangeMath.sol) | decimals-safe Q96 liquidation-range placement, both borrow directions |
| [`libraries/ChunkMath`](src/libraries/ChunkMath.sol) | the pacing formula (time × depth × pressure, clamped) |
| [`libraries/TruncatedOracle`](src/libraries/TruncatedOracle.sol) | ±9,116-tick truncation, median-of-9, widen-only extremes, bootstrap gate |
| [`libraries/TriggerIndex`](src/libraries/TriggerIndex.sol) | tick bitmap so `afterSwap` only touches positions whose boundaries were crossed |

## Build & test

```bash
git clone --recursive <repo>
forge build
forge test          # 77 tests: unit + fuzz (libraries, vault), integration
                    # scenarios (full liquidation lifecycle), invariants
```

Test map: [`test/libraries/`](test/libraries/) (fuzzed math + oracle), [`test/LendingVault.t.sol`](test/LendingVault.t.sol) (IRM, accrual, write-off waterfall), [`test/TrueLendHook.t.sol`](test/TrueLendHook.t.sol) (open/repay/decay/pause/resume/forceClose, manipulation defense, 6-vs-18-decimals pair), [`test/TrueLendInvariants.t.sol`](test/TrueLendInvariants.t.sol) (conservation under random action sequences).

## Deploy

```bash
POOL_MANAGER=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Mines a hook address carrying the `afterInitialize | beforeSwap | afterSwap` flags via CREATE2, deploys, and prints addresses. Any pool then initialized with this hook is automatically a lending market (loans open only after the pool's 9-minute oracle window fills).

## Status & roadmap

Working v2 with full test coverage of the mechanism. Not audited. Next: the parameter-modeling notebook (chunk pacing constants, LT tiers vs pool depth, penalty curve — DESIGN.md §7 ★ rows), per-block borrow caps and aggregate tick-region exposure caps, and testnet deployment.
