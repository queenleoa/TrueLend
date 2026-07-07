# TrueLend — Lending-Borrowing Protocol with AMM Native Liquidations on Uniswap v4

TrueLend is a lending protocol built as a Uniswap v4 hook. It uses **no price oracle**: the pool's own tick decides everything, and liquidation is a **process** over a liquidation range as opposed to a single event triggered at the liquidation threshold.

While the price sits inside a position's liquidation range, the hook sells the collateral in small, time-paced chunks into the pool; if the price recovers, the decay pauses. A penalty per chunk is donated to the pool's LPs, who replace keepers as the compensated absorbers of liquidation flow.

Because selling is rate-limited (≈1% of a position per minute, scaled by range depth and pool thinness), no liquidation can crater the price and cascade into the next one — and because the trigger is the pool's own tick, there is no oracle to lag, spoof, or de-list. That is what makes liquidation thresholds up to 99% possible.

🏆 This hook has been awarded first place in the Uniswap Hook Incubator cohort 7 Hookathon

- **[DESIGN.md](DESIGN.md)** — the full specification: a loan walked end-to-end, architecture, the chunk engine, parameters.
- **[RESEARCH.md](RESEARCH.md)** — why chunked *active* conversion is the only AMM-native way to do this (passive "inverse range orders" are provably impossible on v4), prior art (LLAMMA, Ajna, Ammalgam, …), manipulation economics, and the math.
- **[PARAMETERS.md](PARAMETERS.md)** — the parameter-modelling methodology: risk model, derivations, first-cut LT tiers, Monte-Carlo specification. Results: [notebooks/RESULTS.md](notebooks/RESULTS.md); live calibration and the historical-replay backtest across six historic crash weeks: [notebooks/BACKTEST.md](notebooks/BACKTEST.md).
- **[WHITEPAPER.md](WHITEPAPER.md)** / [docs/TrueLend-Whitepaper.pdf](docs/TrueLend-Whitepaper.pdf) — the formal paper.

## How it works

```
lenders ──deposit──► LendingVault0/1 ──borrow/repay──► TrueLendHook ◄──open/repay── borrowers
                                                            │
                                        beforeSwap: manipulation-resistant oracle obs
                                        afterSwap:  trigger-tick walk + ≤2 liquidation
                                                    chunks (direct swap + donate)
```

1. **Open**: borrower deposits one pool currency as collateral, borrows the other from that side's vault. Collateral is valued at the *worse of* spot and a truncated median of the pool's own recent ticks (single-block price pumps don't raise borrow limits). The position gets a liquidation range starting at its LT price, ~√2 wide.
2. **Decay**: when the pool tick is inside the range, each swap's `afterSwap` (or a permissionless `poke`, which pays its caller from the penalty flow) sells a paced chunk of collateral, donates a penalty to in-range LPs via `donate()`, and repays the vault. Price leaves the range → decay pauses; re-enters → resumes.
3. **Backstop**: past the range end, past the term (180d), or health-breached, anyone may `forceClose` for a reward — a slippage-bounded sale that partially fills against thin books and retries. Shortfalls hit vault reserves first, then socialize pro-rata — a declared waterfall, not an implicit one.

## Contracts

| Contract | Role |
|---|---|
| [`TrueLendHook`](src/TrueLendHook.sol) | hook + lending core; one instance serves many pools — initializing any pool with this hook (ERC-20 pairs and native-ETH pools, the latter WETH-bridged at the hook boundary) makes it a lending market |
| [`LendingVault`](src/LendingVault.sol) | per-currency lender vault: shares, borrow index, kinked IRM (kink 80%, hard cap 90%), 10% reserve factor |
| [`VaultFactory`](src/VaultFactory.sol) | deploys the two vaults per pool at initialization |
| [`libraries/LiqRangeMath`](src/libraries/LiqRangeMath.sol) | decimals-safe Q96 liquidation-range placement (both borrow directions), open-LTV check, force-close eligibility |
| [`libraries/ChunkMath`](src/libraries/ChunkMath.sol) | the pacing formula (time × depth × pressure, clamped) |
| [`libraries/TruncatedOracle`](src/libraries/TruncatedOracle.sol) | ±9,116-tick truncation, median-of-9, widen-only extremes, bootstrap gate |
| [`libraries/TriggerIndex`](src/libraries/TriggerIndex.sol) | tick bitmap so `afterSwap` only touches positions whose boundaries were crossed |
| [`periphery/TrueLendLens`](src/periphery/TrueLendLens.sol) | stateless read aggregation: position health/LTV, chunk preview, pool lending state, open quotes |
| [`periphery/LeverageRouter`](src/periphery/LeverageRouter.sol) | leveraged spot ("perp extension"): flash-constructs one λ = 1/(1−LTV) position owned by the trader; liquidated by the ordinary chunk engine |

## Build & test

```bash
git clone --recursive <repo>
forge build
forge test          # 94 tests: unit + fuzz (libraries, vault), integration
                    # scenarios (full liquidation lifecycle), native-ETH pools,
                    # periphery (lens + leverage router), invariants
```

Test map: [`test/libraries/`](test/libraries/) (fuzzed math + oracle), [`test/LendingVault.t.sol`](test/LendingVault.t.sol) (IRM, accrual, write-off waterfall), [`test/TrueLendHook.t.sol`](test/TrueLendHook.t.sol) (open/repay/decay/pause/resume/forceClose, manipulation defense, drained-pool safety, 6-vs-18-decimals pair), [`test/TrueLendInvariants.t.sol`](test/TrueLendInvariants.t.sol) (conservation under random action sequences).

## Deploy

```bash
POOL_MANAGER=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Mines a hook address carrying the `afterInitialize | beforeSwap | afterSwap` flags via CREATE2, deploys hook + factory + linked libraries, and prints addresses. Any pool then initialized with this hook is automatically a lending market (loans open only after the pool's 9-minute oracle window fills).

## Deployments

| Network | Contract | Address |
|---|---|---|
| Unichain Sepolia (1301) | TrueLendHook | [`0xa731511a83D523A1df04e988873725BEE7cA90c0`](https://sepolia.uniscan.xyz/address/0xa731511a83D523A1df04e988873725BEE7cA90c0) |
| Unichain Sepolia (1301) | VaultFactory | `0x2aAF432336Ea0D8b91398D32D0898317EfB6b420` |
| Unichain Sepolia (1301) | TrueLendLens | `0xa8ed6128aD792485F6F5E9490C3dE630870e0cF4` |
| Unichain Sepolia (1301) | LeverageRouter | `0xEc3aD4b2C872602F648F65B73a00fD3f45DCA082` |
| Unichain Sepolia (1301) | PoolManager (canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |

## Status & roadmap

Working v2 with full test coverage of the mechanism; deployed to testnet; internally audited (three findings — forceClose reward accounting, a trigger-tick registration cap, config validation — fixed with regression tests), not yet externally audited. The parameter model is calibrated from live data ([notebooks/calibrate.py](notebooks/calibrate.py)) and validated by historical replay of the May '21, LUNA, FTX, USDC-depeg, Aug '24 and Feb '25 weeks with walk-forward acceptance ([notebooks/BACKTEST.md](notebooks/BACKTEST.md)). Next: per-position size caps against measured in-range depth (the backtest's main finding for long-tail listings), per-block borrow caps, aggregate tick-region exposure caps, external audit.
