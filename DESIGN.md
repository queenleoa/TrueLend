# TrueLend v2 — Design Document

**Oracleless lending on Uniswap v4 with TWAMM-style gradual, reversible liquidations — the v1 mechanism, made correct and complete.**

The mechanism is unchanged from the hackathon design: a borrower picks a liquidation threshold (up to 99%); the position gets a liquidation tick range; while the pool price is inside that range the position decays in small time-paced chunks sold via the pool itself; a penalty per chunk is donated to LPs; if price exits the range, decay pauses. v2 fixes the execution bugs, adds the missing lender side, bounds gas, and hardens origination — it does not change the liquidation model.

---

## 1. What was broken in v1 (fix list, not a redesign)

| # | Defect | Fix in v2 |
|---|--------|-----------|
| 1 | `poolManager.unlock()` called inside `afterSwap` → reverts `AlreadyUnlocked` (PoolManager.sol:105), so chunks never executed during real swaps | Call `poolManager.swap()` **directly** inside `afterSwap` — the manager is already unlocked. Current `Hooks.sol` has `noSelfCall`: hook-initiated calls skip the hook's own callbacks, so the `_inLiquidationSwap` flag is deleted too. `unlock()` is used only in hook-initiated external entrypoints (open/repay/close). |
| 2 | No lender side — hook lends tokens it was pre-minted in tests | `LendingVault` (ERC-4626, one per pool currency) with utilization-kinked interest. Borrowed funds come from lenders; chunk proceeds repay the vault. |
| 3 | `repayDebt()` credits repayment without pulling tokens, callable by anyone | Repay transfers debt tokens to the vault; access control throughout. |
| 4 | Unbounded loops over all positions/ticks every swap | Trigger-tick bitmap + bounded chunk execution per swap (§4). |
| 5 | Decimals-unsafe liquidation-tick math (`sqrt(rawRatio) << 96`) | Proper Q96 math via `FullMath`/`TickMath`/`SqrtPriceMath`; works for any decimals pair, both directions. |
| 6 | `_estimateNewTick` price-impact heuristic in `beforeSwap` | Deleted (v1 already abandoned it — detection uses the actual post-swap tick). `beforeSwap` is kept only to write the manipulation-resistant oracle observation (§6). |
| 7 | Chunk executor and penalty flow untested end-to-end; `console.log` in prod; unauthenticated `setLendingRouter` | Full test suite incl. invariants; hygiene pass. |

---

## 2. Mechanism (v1 semantics, restated precisely)

### Liquidation range
At `open`, compute the **liquidation start tick** `tickStart` — the price where `debtValue / collateralValue = LT` — and the **range end** `tickEnd` (default width: one octave factor √2 in price, ≈ 3466 ticks, configurable per pool). Direction-aware:
- collateral = currency1, debt = currency0 → range sits **above** spot, entered as tick rises;
- collateral = currency0, debt = currency1 → range sits **below** spot, entered as tick falls.

### In-range decay (the core idea)
While `tickStart ≤ tick ≤ tickEnd` (direction-adjusted), the position is in liquidation and decays chunk by chunk. Chunk pace (v1 formula, cleaned up in bps math):

```
chunk = (collateralRemaining / TARGET_CHUNKS)
      × min(timeSinceLastChunk / CHUNK_INTERVAL, TIME_CAP)      // time pacing
      × (1 + depthIntoRange)                                    // deeper → faster
      × (1 + positionSize / activeLiquidity)                    // thinner pool → faster
bounded by [MIN_CHUNK, MAX_CHUNK] and collateralRemaining
```

Each chunk: sell `chunk` collateral into the pool (direct `swap` in `afterSwap`), take proceeds, subtract penalty, repay vault debt, update position. **This is deliberately rate-limited selling — the anti-cascade property**: no moment ever sees more than a bounded fraction of any position hit the book, unlike binary liquidations.

### Reversibility (pause)
Tick exits the range → `inLiquidation = false`, decay stops, the position keeps its remaining collateral and reduced debt. Time-in-liquidation is accumulated for penalty scaling.

### Penalty → LPs
Per chunk: `penalty = proceeds × BASE_PENALTY × ltFactor × timeFactor` (v1 formula; capped), sent to in-range LPs via `donate()`. This pays LPs for absorbing liquidation flow — keeper work priced into ordinary LPing. (Known caveat: `donate` pays whoever is in range at that instant and is JIT-frontrunnable; acceptable because the penalty is an incentive stream, not a solvency component. A per-pool config can route a share to the vault instead.)

### Completion / closure
- `collateralRemaining == 0` → position closed; shortfall (if any) → bad-debt waterfall (§7).
- `debtRepaid ≥ totalDebt` mid-decay → close, return remaining collateral to borrower.
- Borrower may repay any time (pulling tokens!), including while in liquidation — repayment instantly de-risks or closes.

---

## 3. System architecture

```
 borrowers ──open/repay/close──► ┌─────────────────────────────┐ ◄── swappers
                                 │        TrueLendHook         │
 lenders ──deposit/redeem──►     │ • lending core + positions  │
        ┌───────────────┐        │ • beforeSwap: oracle obs    │
        │ LendingVault0 │◄──────►│ • afterSwap: range toggles  │
        │ LendingVault1 │ borrow │   + bounded chunk execution │
        │  (ERC-4626)   │ repay  │ • poke(): permissionless    │
        └───────────────┘        │   extra chunk progress      │
                                 └────────────┬────────────────┘
                                              │ swap / donate (direct, no unlock)
                                        ┌─────▼──────┐
                                        │ PoolManager│
                                        └────────────┘
```

- **`TrueLendHook`** — hook + lending core. Permissions: `afterInitialize` (init oracle, lastTick), `beforeSwap` (oracle observation of pre-swap tick), `afterSwap` (range entry/exit toggles + chunk execution). User entrypoints `open`/`repay`/`close` run through the hook's own `unlock()`.
- **`LendingVault`** — ERC-4626 per pool currency; only the hook borrows/repays. Kinked IRM, hard utilization cap, reserve factor accumulating a first-loss buffer.
- **Libraries** — `LiqRangeMath` (decimals-safe range computation, both directions), `ChunkMath` (pacing formula), `TruncatedOracle` (§6).
- No separate router: the v1 router added an extra hop and an unauthenticated registry; hook entrypoints + permit2 cover it.

---

## 4. Bounded execution (fixing the gas bombs without changing behavior)

**Range entry/exit detection** — the limit-order-hook pattern: store `lastTick` per pool; in `afterSwap` read the new tick (`StateLibrary.getSlot0`) and walk only the trigger ticks crossed in `(lastTick, newTick]` using a hook-side tick bitmap. Positions register two triggers: `tickStart` (toggle in) and `tickEnd` (mark range-exhausted). Work is O(triggers actually crossed), not O(positions).

**Chunk execution** — an in-liquidation ring queue per pool with a round-robin cursor. Each `afterSwap` advances the cursor and executes at most `MAX_CHUNKS_PER_SWAP` (default 2) due chunks. A permissionless `poke(poolId)` executes up to `MAX_CHUNKS_PER_POKE` more, paying the caller a sliver of the penalty — this also covers the quiet-market case (no swaps → `afterSwap` never fires → decay would stall; v1 had the same latent issue).

**Chunk swaps don't recurse**: `noSelfCall` in current v4-core means the hook's own `swap`/`donate` calls skip its callbacks entirely.

**Settlement**: chunk proceeds held as ERC-6909 claims (`CurrencySettler`), converted to ERC-20 only when repaying the vault or paying out; `clear()` for dust.

---

## 5. The lender side and interest

- Two vaults per pool (either currency is borrowable; collateral is always the other one).
- IRM: `rate = base + slope1·U` to kink, then `+ slope2·(U − kink)`. Defaults: base 0%, slope1 4%, kink 80%, slope2 100%, **hard borrow cap at 90% utilization** (repayments and withdrawals must always clear). Reserve factor 10% of interest → insurance buffer.
- Debt tracked as shares against a borrow index (accrued on every vault touch).
- Interest accrual slowly moves a position's true break-even price toward spot; positions carry a **term** (default 180d) and an interest reserve in the coverage check at open (§7). Past expiry or past coverage, anyone may `forceClose` (single bounded swap of remaining collateral, reward from penalty).

---

## 6. Oracle-free ≠ defenseless: origination hardening

Liquidation needs no price input (the pool tick *is* the trigger). The attackable moment is **borrow time**: pump the pool one block, borrow against inflated collateral, dump. Defenses (all internal, no external feed):

- `TruncatedOracle`: ring buffer of tick observations written in `beforeSwap` with the **pre-swap tick**, per-update movement clamped (±9116 ticks, Uniswap's truncated-oracle constant), read as median-of-N; plus a widen-only per-interval min/max tick record (a spike-and-revert still widens the borrow-side bound).
- Borrow checks value collateral at **worse-of(spot, truncated median)** and require a minimum gap between that price and `tickStart`.
- New pools cannot originate until the observation window has filled.
- Origination fee = max(1 week of interest, 5 bps); minimum position size; per-block borrow cap per pool.

---

## 7. Solvency, parameters, backstop

Chunks execute at market prices during traversal, so solvency is probabilistic, not closed-form — the buffer between LT and 100% must absorb: expected adverse movement while decaying through the range + chunk slippage + penalty + interest reserve. Consequences:

| Parameter | Default | Notes |
|---|---|---|
| Max LT | tiered by pool depth: 99% only where `MAX_CHUNK ≪` active liquidity at the range; else 90/95% | the "up to 99" promise holds for deep pools; thin pools get honest caps |
| Range width | √2 in price (≈3466 ticks), per-pool config | wider = slower decay per tick of adversity, more time to recover |
| TARGET_CHUNKS / CHUNK_INTERVAL | 100 / 60 s | full decay ≥ ~100 min even if price camps in range |
| MIN/MAX_CHUNK | per-pool, value-denominated (not hardcoded 1e18s) | MAX_CHUNK also ≤ x bps of active liquidity |
| BASE_PENALTY | 0.5%, × ltFactor × timeFactor (cap 5×) | v1 shape, capped |
| Term | 180 d; interest reserve at rate ceiling in the open-check | forceClose after expiry/coverage breach, rewarded |
| Bad-debt waterfall | vault reserve buffer → interest haircut → pro-rata share haircut | explicit, priced ex ante by lenders |
| Dust minimum | ~$1k-equivalent per pool | dust positions rot |
| MAX_CHUNKS_PER_SWAP / PER_POKE | 2 / 10 | bounded swap-path gas |

**Backstop**: if tick passes `tickEnd` with collateral remaining (price outran the pacing), the position is range-exhausted: decay pacing no longer protects anyone, so `forceClose` becomes permissionless immediately (single swap, penalty applies). This is the hard floor under the soft mechanism.

**Invariants for the test suite**: (a) vault assets + hook-held claims + Σ position collateral value at range-end price ≥ Σ liabilities − declared waterfall capacity; (b) chunk execution never exceeds pacing bounds; (c) pause-on-exit always holds; (d) no path strands funds in the hook.

---

## 8. v4 implementation notes (verified against pinned v4-core)

- `swap`/`modifyLiquidity`/`donate`/`mint`/`burn`/`take`/`settle` are callable directly inside hook callbacks (`onlyWhenUnlocked`); `unlock()` from a callback reverts `AlreadyUnlocked`.
- `noSelfCall` (current Hooks.sol) skips the hook's own callbacks on self-initiated pool calls.
- `afterSwap` does not receive the pre-swap tick — keep `lastTick` in hook storage.
- ERC-6909 claims (`mint`/`burn` on PoolManager) as the hook's working balance; `CurrencySettler` wraps both modes; `clear()` waives dust deltas.
- `donate()` pays only currently-in-range liquidity and reverts if none; callable from `afterSwap`.
- Deps: pin a tagged v4-periphery release (current main dropped `BaseHook`; OZ `uniswap-hooks` is the maintained home). `lib/v4-periphery` is currently a broken submodule (files on disk, not tracked) — re-pin in Phase 0. Cancun+ only (EIP-1153).
- Deploy: flags in low 14 bits of hook address, `HookMiner` + CREATE2 factory; constructor args are part of the init-code hash. Tests: `deployCodeTo`.

---

## 9. Build plan

- **Phase 0 — hygiene**: fix submodules/pins, strip `console.log`, delete dead estimation code, CI green.
- **Phase 1 — `LiqRangeMath` + `ChunkMath` + `TruncatedOracle`** with fuzz tests (decimals 6/8/18, both directions).
- **Phase 2 — `LendingVault`** (4626 + IRM + caps + index) unit tests.
- **Phase 3 — hook skeleton**: open/repay/close happy path against a live local pool (no chunking yet).
- **Phase 4 — liquidation engine**: trigger bitmap, in-liquidation queue, direct-swap chunk execution in `afterSwap`, `poke()`, penalty donation. Scenario tests: enter/decay/pause/resume/full-decay, multi-position, quiet-market poke.
- **Phase 5 — backstops & waterfall**: range-exhausted/expiry/coverage `forceClose`, bad-debt waterfall, invariant + fuzz suite.
- **Phase 6 — deploy + demo + docs**: HookMiner script, demo scenario, README rewrite, parameter-modeling notebook (chunk pacing & LT tiers vs simulated volatility — the "financial modelling" workstream).
