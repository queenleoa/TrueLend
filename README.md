# TrueLend — Lending-Borrowing Protocol with AMM Native Liquidations on Uniswap v4

🏆 This hook has been awarded first place in the Uniswap Hook Incubator cohort 7 Hookathon

## What this is, in plain terms

TrueLend lets people **lend** one token of a Uniswap pool to earn interest, and lets others **borrow** it by locking up the pool's *other* token as **collateral** (a security deposit the protocol can sell if the loan goes bad).

Two things make it different from Aave-style lending:

1. **It has no price oracle.** Ordinary lending protocols rely on an external price feed to decide when a loan is undercollateralized — a feed that can lag, be manipulated, or simply not exist for a given token. TrueLend never asks anyone what the price is: the Uniswap pool it lives in *is* the price. The pool tracks price as a **tick** (a fine-grained step on a price ladder — each tick is a 0.01% price move), and the tick is the only trigger the protocol uses.
2. **Liquidation is a process, not an event.** In other protocols, crossing the liquidation price means your entire position is seized at once by a bot ("keeper") for a bonus — and that forced sale pushes the price down, which liquidates the next borrower, and so on (a *cascade*). In TrueLend, each loan instead gets a **liquidation range**: a band of prices starting at the loan's liquidation threshold. While the pool price sits inside that band, the protocol sells the collateral in **small timed chunks** — about 1% of the position per minute — using each sale to pay down the debt. If the price recovers and leaves the band, the selling *pauses* and the borrower keeps everything that remains.

Because the selling is rate-limited, no liquidation can crater the price and set off the next one. Because the trigger is the pool's own tick, there is nothing external to lag, spoof, or de-list. And because the process is gradual and reversible rather than all-or-nothing, borrowers can safely choose **liquidation thresholds up to 99%** — meaning they can borrow up to ~94% of their collateral's value, versus 50–80% elsewhere.

The people who absorb the chunk sales are the pool's ordinary **liquidity providers (LPs)** — and each chunk pays them a small **penalty fee** for it. LPs replace keepers, and get paid for the role.

## Where to read more

| Document | What it covers |
|---|---|
| **[DESIGN.md](DESIGN.md)** | The specification: every concept defined in order (§0), one loan walked end-to-end with real numbers, the architecture, the liquidation engine internals, all parameters. **Start here.** |
| **[RESEARCH.md](RESEARCH.md)** | The "why": a proof that no *passive* AMM mechanism can liquidate a loan (which is why every alternative either needs an oracle or a new AMM), lessons from every prior protocol, manipulation economics, and the math. |
| **[WHITEPAPER.md](WHITEPAPER.md)** / [docs/TrueLend-Whitepaper.pdf](docs/TrueLend-Whitepaper.pdf) | The formal paper — same content, publication form. |
| **[PARAMETERS.md](PARAMETERS.md)** | How the protocol's numeric parameters are derived: the risk model, formulas, and the simulation methodology. |

## How a loan works (60-second version)

1. **Lenders** deposit a token into that token's **vault** (a pooled deposit account, one per pool currency). Their deposits are what borrowers draw from; they earn interest that rises as more of the vault is borrowed ("utilization").
2. A **borrower** deposits collateral and picks two numbers: how much to borrow (their **LTV**, loan-to-value — debt as a fraction of collateral value) and their **liquidation threshold** (**LT** — the LTV at which liquidation should begin). The protocol computes the price where the loan hits its LT and places the liquidation range there.
3. Nothing happens while the price stays on the safe side — the loan costs the pool zero ongoing work.
4. If trading pushes the tick into the range, each subsequent swap's hook callback (or a public `poke()` call) sells one paced chunk, pays the LP penalty, and repays debt. Price exits the range → pause. Debt fully repaid → position closes, remaining collateral returns to the borrower.
5. If the price blows through the *entire* range, the term (180 days) expires, or interest erodes the position's health, anyone may call `forceClose` for a reward — a slippage-bounded final sale. Any shortfall is absorbed by vault reserves first, then shared pro-rata by lenders — an explicit, on-chain-recorded loss waterfall rather than an implicit one.

## Contracts

| Contract | Role |
|---|---|
| [`TrueLendHook`](src/TrueLendHook.sol) | The core: hook callbacks + positions + the chunk liquidation engine. One deployment serves many pools; initializing any ERC20/ERC20 pool with this hook makes it a lending market. |
| [`LendingVault`](src/LendingVault.sol) | Per-currency lender vault: deposit shares, a borrow index that accrues interest, utilization-based rates (kink at 80%, hard cap at 90%), 10% of interest kept as a first-loss reserve. |
| [`VaultFactory`](src/VaultFactory.sol) | Deploys the two vaults for each new pool. |
| [`libraries/LiqRangeMath`](src/libraries/LiqRangeMath.sol) | Computes where a loan's liquidation range sits, exactly, for any token-decimal pair and both borrow directions. |
| [`libraries/ChunkMath`](src/libraries/ChunkMath.sol) | The pacing formula: how large the next chunk is (time × range-depth × pool-thinness, clamped). |
| [`libraries/TruncatedOracle`](src/libraries/TruncatedOracle.sol) | The internal manipulation-resistant price used only at loan opening: per-minute observations with movement clamped, read as a median, plus widen-only extremes. |
| [`libraries/TriggerIndex`](src/libraries/TriggerIndex.sol) | A tick bitmap so swaps only pay for positions whose range boundaries they actually crossed. |

## Build & test

```bash
git clone --recursive <repo>
forge build
forge test    # 78 tests: fuzzed unit tests (math, oracle), vault accounting,
              # 24 full-lifecycle scenarios, randomized invariants
```

Test map: [`test/libraries/`](test/libraries/) · [`test/LendingVault.t.sol`](test/LendingVault.t.sol) · [`test/TrueLendHook.t.sol`](test/TrueLendHook.t.sol) (open/decay/pause/resume/forceClose, manipulation rejection, drained-pool safety, 6-vs-18-decimals) · [`test/TrueLendInvariants.t.sol`](test/TrueLendInvariants.t.sol).

## Deploy

```bash
POOL_MANAGER=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Mines a hook address carrying the required permission flags, deploys hook + factory + linked libraries, and prints addresses. Any pool then initialized with this hook becomes a lending market (loans open only after its 9-minute oracle warm-up window fills).

## Deployments

| Network | Contract | Address |
|---|---|---|
| Unichain Sepolia (1301) | TrueLendHook | [`0x23B8aa9A6aF46d1d56090cb4A500EB0f2C2b10C0`](https://sepolia.uniscan.xyz/address/0x23B8aa9A6aF46d1d56090cb4A500EB0f2C2b10C0) |
| Unichain Sepolia (1301) | VaultFactory | `0x29076c8Bf089Ab07A146d3fc528A1CF3F4b2CB2b` |
| Unichain Sepolia (1301) | PoolManager (canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |

## Status & roadmap

Working v2 with full test coverage of the mechanism; deployed to testnet; **not audited**. Next: parameter modelling per [PARAMETERS.md](PARAMETERS.md), per-block borrow caps, aggregate tick-region exposure caps, audit.
