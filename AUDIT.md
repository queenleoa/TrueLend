# TrueLend — Internal Audit

**Scope:** the full TrueLend repository at the current `main` commit — core contracts
(`TrueLendHook`, `LendingVault`, `VaultFactory`), the four linked libraries
(`LiqRangeMath`, `ChunkMath`, `TruncatedOracle`, `TriggerIndex`), the two periphery
contracts (`TrueLendLens`, `LeverageRouter`), the deploy script, the whole test suite,
the parameter-model notebooks (`engine.py`, `parameters.py`, `calibrate.py`,
`backtest.py`), and all prose docs (`DESIGN.md`, `PARAMETERS.md`, `RESEARCH.md`,
`WHITEPAPER.md`, `README.md`, `notebooks/RESULTS.md`, `notebooks/BACKTEST.md`).

**Method:** manual line-by-line review of every source and test file, cross-checking the
implementation against the specification, tracing token/value flow through each entry
point, and reconciling the numeric claims in the docs against the code and build
artifacts. No fuzzing or symbolic execution beyond what the existing suite runs. This is
a *pre-external-audit* internal review: it is thorough but is not a substitute for a
professional third-party audit.

**Verified facts (build artifacts):**
- Test function count: **97** (matches every doc claim). Breakdown: `TrueLendHook.t.sol`
  28, `LendingVault.t.sol` 18, `libraries/*` 13+10+10, `Periphery.t.sol` 9,
  `TrueLendInvariants.t.sol` 5, `NativePool.t.sol` 4.
- Deployed `TrueLendHook` bytecode: **24,457 bytes**, **119 under** the 24,576 EIP-170
  limit (from `out/TrueLendHook.sol/TrueLendHook.json`).
- The Python engine replica's Solidity-vector assertions in `engine.py`
  (`_check_solidity_vectors`) match the vectors in `test/libraries/ChunkMath.t.sol`.

---

## 1. Overall assessment

The protocol is **coherently designed and, for the mechanism itself, carefully
implemented.** The central thesis (oracle-free lending via the pool's own tick, with
gradual chunked liquidation) is sound, the impossibility argument that motivates it is
correct, and the code faithfully realizes the specification in most places. Several
things stand out as genuinely well done:

- **Checks-effects-interactions is respected on every selling path.** Position collateral
  and `lastChunkAt` are written *before* the swap/donate/settle in
  [`_executeChunk`](src/TrueLendHook.sol#L548-L551), and `pos.collateral = 0` is set
  before the forceClose sale ([`_executeForceClose`](src/TrueLendHook.sol#L657)).
- **The two model-forced economic caps are actually present in the code**, not just the
  docs: the per-position penalty cap at ¼ of the LT gap
  ([`ChunkMath.penaltyBps`](src/libraries/ChunkMath.sol#L68-L69)) and the health buffer
  cap at ½ of the LT gap
  ([`LiqRangeMath.forceCloseReason`](src/libraries/LiqRangeMath.sol#L152-L153)), each
  with a dedicated regression test.
- **The resumable, capped trigger walk** has a real invariant behind it:
  `MAX_IDS_PER_TICK (32) == MAX_REFRESHES_PER_WALK (32)`, which guarantees any single
  trigger tick is always processable in one fresh walk. The registration cap that
  enforces it is tested.
- **The `LeverageRouter` close path** correctly handles the floor∘floor share-rounding
  hazard with the one-wei over-flash and a hard closure guard, with a fuzz test proving
  the invariant.
- **Native-ETH bridging** consistently keeps raw ETH out of vault accounting and out of
  callback payouts (all payouts are WETH), which correctly neutralizes the reverting
  `receive()` DoS surface.
- **The parameter model is honest.** `RESULTS.md`/`BACKTEST.md` disclose their
  limitations (κ not fitted, depeg data censored, stress windows are correlated single
  events), the engine is cross-checked against the Solidity vectors on every import, and
  the headline claims (LT-99 stable = "no-depeg bet", long-tail bounded by size-vs-depth)
  are stated plainly rather than oversold.

The findings below do not undermine that assessment; they are the gap between "passes its
own tests on the happy paths" and "safe against the adversarial and long-tail edges an
external auditor will probe." The most important is **M-1**, a real break of the
advertised "pause on range exit" guarantee under trigger congestion.

Severity key: **High** = loss of funds / broken core invariant on a realistic path ·
**Medium** = bounded loss, degraded guarantee, or footgun that funds/liveness depend on ·
**Low** = limited/griefing-only impact or requires trusted-role abuse · **Info** =
correctness-neutral observation or hardening opportunity.

---

## 2. Findings — code / logic

### M-1 · A liquidation chunk can execute *after* a position has left its range (Medium)

**Where:** [`_drive`](src/TrueLendHook.sol#L429-L433),
[`_walkTriggers`](src/TrueLendHook.sol#L435-L461),
[`_processQueue`](src/TrueLendHook.sol#L490-L516),
[`_executeChunk`](src/TrueLendHook.sol#L520-L580).

**The invariant it breaks:** the protocol's headline promise — "price leaves the range →
decay pauses; the borrower keeps whatever remains" (DESIGN §2.4, WHITEPAPER §4.2). This
is supposed to be unconditional.

**The bug:** `_drive` runs `_walkTriggers → _processQueue → _walkTriggers`. A position is
excluded from chunking only by `_processQueue`'s lazy-removal check
`pos.liqStartedAt == 0` ([line 506](src/TrueLendHook.sol#L506)). That flag is cleared
only by `_refreshPosition` when a walk actually reaches the position's boundary tick. But
`_walkTriggers` is **capped**: `MAX_TRIGGERS_PER_WALK = 8` ticks and
`MAX_REFRESHES_PER_WALK = 32` position updates per walk
([lines 442-459](src/TrueLendHook.sol#L442-L459)). When a swap crosses more than 8
boundary ticks (or would refresh more than 32 positions), the walk **defers** the
remainder, persisting a resume cursor and returning early.

If the swap that pushes the tick *out of* a position's range is the one that gets
deferred, that position's `liqStartedAt` is still non-zero when `_processQueue` runs in
the *same* `_drive`. `_executeChunk` performs **no `inRange` check of its own** — it only
guards on `depthTokens == 0` and `chunk == 0`
([lines 531, 546](src/TrueLendHook.sol#L531-L546)) — so it sizes and sells a chunk on a
position whose price has already recovered above `tickStart` (or gapped below `tickEnd`).

- On the **recovery side** (tick back above `tickStart`, `collateralIs0`),
  [`depthBps`](src/libraries/LiqRangeMath.sol#L93-L101) returns 0, so the chunk is
  base-sized and **sells collateral from a position that is healthy again** — a direct
  violation of pause-on-exit.
- On the **exhaustion side** (tick below `tickEnd`), `depthBps` returns `BPS`, doubling
  the chunk, selling into a crashed price instead of routing to `forceClose`.

The second `_walkTriggers` in `_drive` (or the next swap/poke) eventually reconciles the
state, but only *after* the erroneous chunk has already fired.

**Impact:** bounded (one chunk, ≤1% of measured in-range depth, penalized, rate-limited),
and it self-heals on the next walk — but it is a real break of a guarantee the whole
product is sold on, and it silently charges a recovered borrower. It also causes the
mirror problem in the safety direction: a *liquidation start* crossing that is deferred
delays the first chunk until a later walk (bounded by `forceClose` reason 3).

**Reachability:** requires >8 registered boundary ticks (or >32 positions) to be crossed
in a single price move that also carries a position out of its range — i.e. a busy pool
during a sharp reversal. Not exotic under stress; not reachable by the current tests,
which never build that congestion.

**Recommendation:** make `_executeChunk` self-guarding. Before sizing, recompute
`inRange` at the current tick; if the position is not in range, call `_refreshPosition`
(which will set `liqStartedAt = 0` and let `_processQueue` drop it) and `return false`.
This is a few lines, cheap, and closes the window regardless of walk-cap timing.

---

### M-2 · Interest accrual is never re-anchored into the liquidation range (Medium)

**Where:** range placed once at open from the *initial* borrow amount —
[`open`](src/TrueLendHook.sol#L310-L312) →
[`liquidationRange`](src/libraries/LiqRangeMath.sol#L58-L80); `tickStart`/`tickEnd` are
immutable thereafter.

**The issue:** `P_liq = debt / (LT·collateral)` is computed with `debt = borrowAmount` at
open. As interest accrues, the live debt grows (`debtShares × borrowIndex`), so the
*true* LT-crossing price rises, but the recorded `tickStart` stays at the opening price.
The gradual mechanism is therefore anchored to a price that becomes progressively stale.

For `collateralIs0` (danger as price falls), once interest has grown the debt, the
position can sit at a true LTV **above** its chosen LT while the price is still above the
stale `tickStart` — so no chunk fires. The position is only caught by:
1. price falling further to the *stale* (lower) `tickStart`, or
2. `forceClose` reason 3 (health), which fires at LTV ≈ `1/(1 − buffer)` (≈98% for an
   LT-90 position with the 2% buffer), or
3. `forceClose` reason 2 (expiry, 180 d).

**Consequence:** the borrower-chosen LT is the effective *gradual-liquidation* point only
at open. Over a long-lived, interest-heavy loan the effective floor drifts up to the
reason-3 health line, and when the position is finally caught it is caught by a one-shot
(slippage-bounded) `forceClose`, **not** by the gradual, reversible decay that is the
product's selling point. Lenders remain protected (reason-3 uses live debt and live
price), so this is not a solvency hole; it is a **degradation of the core UX guarantee**
that the docs do not flag. The docs frame the range as "starting at the LT price" without
noting it is anchored to *opening* debt only.

The opening headroom (LTV ≤ 95% of LT) and the 180-day term bound how far this can drift,
and at high LT the band between LT and the reason-3 line is thin, so the effect is largest
for *low*-LT, long-held positions — exactly the ones marketed as "safe and gradual."

**Recommendation:** either (a) document explicitly that the gradual range tracks opening
debt and that interest-drifted positions exit via `forceClose`, not decay; or (b) consider
periodically re-deriving `tickStart` from live debt (more complex, costs storage/gas), or
(c) tighten the term / headroom for low-LT tiers so the drift window is small. At minimum,
(a).

---

### M-3 · Exact-debt `repay` can strand a dust share and fail to close (Medium)

**Where:** [`repay`](src/TrueLendHook.sol#L365-L385) →
[`LendingVault.repay`](src/LendingVault.sol#L214-L228).

**The issue:** `LendingVault.repay` burns `sharesBurned = floor(assets·WAD/borrowIndex)`,
capped at the position's shares. Because `debtOf` itself floors
(`floor(shares·index/WAD)`), the composition `floor∘floor` can lose one share: repaying
**exactly** `debtOf(id)` can burn `shares − 1`, leaving `pos.debtShares == 1`, so the
hook does **not** close the position ([line 384](src/TrueLendHook.sol#L384)) and the
collateral is not returned. The developers know this — it is exactly the hazard the
`LeverageRouter` defends against with its one-wei over-flash, and
`testFuzz_repay_debtPlusOneWei_alwaysClearsAllShares` proves `debt + 1` always clears.

But a **direct** caller of `hook.repay(id, debtOf(id))` (any integrator not going through
the router) hits the un-defended path. The position stays open with a dust share and the
collateral locked until a second repay. Since `repay` refunds any excess
([line 381](src/TrueLendHook.sol#L381)), overpaying is free — but nothing in the hook
signals that exact repayment is unsafe.

**Recommendation:** make the hook robust, so correctness does not depend on callers
knowing the trick. E.g. in `hook.repay`, when the caller's `assets` is intended as a full
repayment, internally target `debt + 1` (bounded by `assets`), or add a `repayAll(id)`
entry point that computes the closing amount and refunds the remainder. Document the
overpay requirement regardless.

---

### L-1 · `LeverageRouter.closeLeveraged` DoS via debt-token donation (Low)

**Where:** [`_close`](src/periphery/LeverageRouter.sol#L161-L213), specifically
`leftover = debtAsset.balanceOf(address(this))` then `used = flashDebt - leftover`
([lines 184-185](src/periphery/LeverageRouter.sol#L184-L185)).

The close path assumes the router holds no `debtAsset` except the vault's ≤1-wei refund.
An attacker can transfer `debtAsset` to the router before a victim's close: small
donations merely subsidize the trader (harmless, self-defeating), but a donation of
**more than `flashDebt`** makes `flashDebt - leftover` underflow and revert, and the
donated tokens then sit in the router blocking every retry of *that* close.

**Mitigation already present:** the trader is the position's `borrower`/`onBehalfOf` and
can always close directly via `hook.repay` (collateral returns to them), so this griefs
only the router convenience path, and the attacker must burn ≥ `flashDebt` of real
capital per griefed close. Low severity.

**Recommendation:** snapshot the debt balance before the flash and compute `leftover` as
the *delta*, so pre-existing/donated balances are ignored (`leftover = balanceAfter −
balanceBefore`).

---

### L-2 · No global pause / circuit breaker; pools cannot be disabled (Low)

`PoolState.enabled` is set `true` in [`_afterInitialize`](src/TrueLendHook.sol#L224) and
**never toggled** — there is no code path that sets it false. Owner powers are limited to
`setConfig` and `setOwner`; there is no emergency stop for new borrows, liquidations, or a
specific pool. If a live bug is discovered, the only levers are indirect (e.g. raising
`minBorrow` to choke new borrows on a pool). Existing positions and the engine cannot be
halted.

**Recommendation:** add an owner-gated per-pool `enabled` toggle (at least blocking
`open`) and/or a global pause guarding `open`. Keep liquidation/`repay`/`forceClose`
un-pausable so users can always exit. Timelock as recommended.

---

### L-3 · Owner trust surface: `setConfig` under-validates non-load-bearing fields (Low)

[`setConfig`](src/TrueLendHook.sol#L795-L801) validates the fields that would *brick*
liquidation (zero pacing, non-positive width, LT gap) and caps `maxLtBps ≤ 9950`, but
leaves `basePenaltyBps`, `slippageBufferBps`, `rewardBps`, `minGapTicks`, and `minBorrow`
unbounded. Runtime caps contain most abuse (penalty is capped at ¼-gap, reward at the
penalty, buffer at ½-gap), so an adversarial owner cannot directly steal via these — but
`minGapTicks` is not sanity-checked (a negative value weakens the open-time gap guard),
and the owner is a single key with no in-code timelock. This is a **centralization /
trusted-role** note, consistent with the docs' "timelock it for production," not an
exploit by an untrusted party.

**Recommendation:** bound `minGapTicks ≥ 0` and document the trusted-owner assumptions in
one place; ship the recommended timelock.

---

### L-4 · `VaultFactory.deploy` is permissionless (Low)

[`deploy`](src/VaultFactory.sol#L20-L32) has no access control, so anyone can mint
`LendingVault` instances. These are **inert** (only vaults created by the hook in
`_afterInitialize` are wired into `pools`, and only the hook can borrow), so there is no
fund risk — but rogue vaults with the protocol's name/symbol can confuse indexers and
users. Low.

**Recommendation:** restrict `deploy` to the hook, or accept and document it.

---

### Info-1 · Hook swap callbacks are not covered by the reentrancy guard

The `nonReentrant` flag (`locked`) is set only by the external entry points
(`open`/`repay`/`poke`/`forceClose`). `afterSwap` (and thus `_drive`/`_executeChunk`) runs
with `locked == 1`. During a chunk's settlement a token callback could re-enter
`open`/`repay`. Safety here rests entirely on (a) the v4 PoolManager lock (which blocks
pool re-entry) and (b) the **standard-token scope** (no transfer hooks). Both hold under
the stated assumptions, and CEI ordering limits damage even so — but the guarantee is the
scope assumption, not the guard. Worth an explicit note; re-confirm if fee-on-transfer or
hook tokens are ever allowed.

### Info-2 · Dust chunk proceeds can round to the borrower instead of the vault

In [`_executeChunk`](src/TrueLendHook.sol#L564-L571), if a chunk's `net` proceeds are so
small that `floor(net·WAD/index) == 0` (possible once `index > WAD`), `burned = used = 0`
and the entire `net` is sent to the borrower rather than repaying debt. This is
sub-wei-to-few-wei scale, unprofitable to trigger (swap fees dwarf it), and only occurs
on a final dust chunk. Correctness-neutral in practice; noted for completeness.

### Info-3 · No add-collateral or partial-collateral-withdraw

A borrower cannot top up collateral to escape decay, nor withdraw excess collateral
without full repayment. Positions are fixed-size and isolated by design, but the only
defense against liquidation is repayment. Consider documenting, or adding an
`addCollateral` path, since "top up to avoid liquidation" is a standard borrower
expectation.

### Info-4 · Healthy expiry `forceClose` still charges the LP penalty

A perfectly healthy position that merely crosses its 180-day term is force-sold in full
(reason 2) and pays the penalty + reward + slippage even though it was never unhealthy
([`_executeForceClose`](src/TrueLendHook.sol#L644-L699), penalty via `_currentPenaltyBps`).
This is defensible (the term is a hard liquidity-reclamation deadline) but is a
borrower-cost surprise; `test_forceClose_expiry` confirms surplus returns, but the penalty
is still levied. Document it.

---

## 3. Findings — economic / systemic risk

These are not code bugs; they are the risks a reviewer should weigh before mainnet.

- **R-1 · Dust-position trigger-tick squatting (griefing liveness).** Registration reverts
  when a trigger tick already holds 32 ids
  ([`TriggerIndex.register`](src/libraries/TriggerIndex.sol#L29-L35)). With the default
  `minBorrow = 0`, an attacker can open 32 dust positions whose aligned `tickStart`/
  `tickEnd` land on a chosen tick and **permanently block** any honest borrower whose
  range boundary would fall on that tick. Because boundary ticks are quantized to
  `tickSpacing`, popular round-number price levels are natural collision points even
  without malice. The `minBorrow` knob is the intended defense but **defaults to 0** and
  "owner must set" — so a freshly initialized pool is exposed until the owner configures
  it. **Recommendation:** make a nonzero `minBorrow` mandatory (reject `open` when
  `minBorrow == 0`, or default it per deploy), and consider a per-owner or per-block cap
  on dust registrations. This is already the roadmap's "per-position size caps" item; it
  is more of a launch-blocker than the docs imply.

- **R-2 · The liquidity buffer is not an enforced invariant.** DESIGN §8 and WHITEPAPER
  §4.3 call free vault liquidity "an invariant of the design." The 90% utilization cap is
  enforced only on [`borrow`](src/LendingVault.sol#L198-L201); **`redeem` is not
  utilization-gated**. A lender redeeming down to the cash floor can drive utilization to
  100% (deposit 100, borrow 90, redeem the 10 cash → util 100%). Liquidation itself still
  works (chunk `repay` *adds* cash), so this is not a solvency hole, but the stated
  "invariant" is only a soft property, and the invariant test never redeems so it is
  **untested** (see §5). **Recommendation:** soften the wording, or add a redeem-side
  guard if a hard buffer is truly wanted.

- **R-3 · Liveness depends on `poke` in quiescent markets.** Decay only advances inside
  swaps or explicit `poke`s. In a thin market with no organic flow, a position can sit in
  its range un-decayed until someone pokes for the reward. The reward is real
  (carved from the penalty), but the incentive is bounded by penalty size and gas; for
  tiny positions the reward may not cover gas (this is exactly the `minBorrow` economics
  in PARAMETERS §6.3). Acknowledged in WHITEPAPER §11.

- **R-4 · Stablecoin LT-99 is a depeg bet (correctly disclosed).** `BACKTEST.md` finding
  2 shows LT-99 stable pools backstop ~99% of positions during a depeg because a
  multi-percent depeg gaps straight through a 1% cushion. The docs say this outright and
  recommend ≈96.5% depeg-aware sizing. No action beyond ensuring the *user-facing* UI
  surfaces it (the dashboard/README should carry the same warning the backtest does).

- **R-5 · Long-tail viability is a size-vs-depth constraint, deferred.** `BACKTEST.md`
  finding 3: against a $14k PEPE/WETH book, chunks cap at 1% of a book smaller than the
  position and 80%+ of episodes backstop even in calm windows. The mitigation
  (per-position cap ∝ measured in-range depth) is designed but **not implemented**. Until
  it is, long-tail pools are unsafe at meaningful size. This is the single highest-value
  roadmap item and should gate long-tail launches.

- **R-6 · `forceClose` slippage bound vs. genuine gap risk.** The ±1000-tick (~10.5%)
  bound makes fire-sales into empty books impossible (good, tested), but it also means a
  position that has genuinely gapped >10% past coverage can only be closed in ~10% slices
  as liquidity returns, accruing more adverse drift between retries. The waterfall
  ultimately absorbs the residual; this is the intended "price the tail" tradeoff, but it
  concentrates realized bad debt exactly in the fast-crash scenarios. Ensure reserve
  sizing (10% of lifetime interest) is communicated to lenders as thin relative to a tail
  event.

---

## 4. Documentation consistency

Cross-checking the prose against the code turned up the following. Most are cosmetic; they
are listed because a spec that disagrees with itself erodes reviewer trust.

| # | Issue | Detail | Fix |
|---|---|---|---|
| D-1 | **Bytecode size contradiction** | [DESIGN.md §3.1](DESIGN.md) says the hook is "132 bytes under the EIP-170 limit (24,444 of 24,576)"; [WHITEPAPER §10](WHITEPAPER.md) says "24,457 bytes — 119 under." The build artifact confirms **24,457 / 119 under** — DESIGN is stale/wrong. | Correct DESIGN to 24,457 / 119. |
| D-2 | **Max-LT ceiling** | Docs (DESIGN §7, WHITEPAPER §7) present max LT as **99%**, but [`setConfig`](src/TrueLendHook.sol#L798) permits `maxLtBps` up to **9950 (99.5%)**. | Either lower the ceiling to 9900 or document that owners may configure up to 99.5%. |
| D-3 | **"Utilization never exceeds its cap"** | Stated as a held invariant (DESIGN §8, WHITEPAPER §6). True only on the borrow path; redemptions can exceed it (R-2). | Qualify: "borrowing cannot push utilization above the cap." |
| D-4 | **forceClose impact "~10%"** | Docs say ~10%; `FC_MAX_SLIPPAGE_TICKS = 1000` is ~10.5% (the code comment even says "~10.5%"). Trivial. | Say ~10.5% or "≈10%". |
| D-5 | **Range-anchoring wording** | DESIGN/WHITEPAPER describe the range as "starting at the LT price" without noting it is fixed to *opening* debt (see M-2). | Add one sentence that the range is anchored at origination. |
| D-6 | **"reward carved from the penalty, never on top"** | Accurate on the happy path, but when the pool has no in-range liquidity the penalty donation is skipped and the reward is effectively taken from proceeds that would otherwise repay debt (still never *more* than the penalty would have cost the borrower). Worth a footnote for precision. | Optional footnote. |

The following doc claims were checked and are **correct**: √2 ≈ 3466 ticks
(1.0001^3466 ≈ 1.414); ±9,116 ticks ≈ 2.49×; rate curve 0/4%@80%/54%@90%/104%@100% vs
ceiling 400% (matches `test_rateCurve`); 97 tests and their per-file breakdown; the
penalty and chunk formulas as written; the reserve factor 10% and kink/cap 80%/90%; the
`onBehalfOf` accommodation; the native-ETH bridging description; the invariant list.

---

## 5. Test-coverage gaps

The suite is strong on the happy paths and the specific fixes it was written around, but
the following adversarial/edge cases are **not exercised**, and each maps to a finding
above:

1. **Trigger-walk congestion (M-1).** No test crosses >8 boundary ticks (or >32 positions)
   in one swap while a position exits its range, so the deferred-refresh chunk is never
   observed. Add a scenario with ≥9 clustered positions and a single reversal swap;
   assert no chunk fires on a position whose price has recovered above `tickStart`.
2. **Exact-debt repay (M-3).** Every repay test overpays (`debt + 1e18`, `debt + 1`,
   `debt + 100e6`). None calls `repay(id, debtOf(id))` and asserts closure — precisely
   the case that can strand a share. Add it (it should currently be able to fail to
   close for adversarial index values).
3. **Utilization under redemption (R-2).** The invariant handler has no `redeem` action,
   so `invariant_utilizationWithinCap` never sees a redemption. Add a redeem action to
   the handler; the invariant will need re-stating (util *can* exceed the cap via redeem).
4. **`minBorrow`/dust squatting (R-1).** `test_open_revertsWhenTriggerTickCrowded` proves
   the cap reverts, but no test shows an attacker blocking an *honest* borrower's range
   boundary, nor that `minBorrow` mitigates it.
5. **Long-tail depth stress (R-5).** Covered in the Python backtest but not in Solidity;
   a hook-level test with a position larger than in-range depth would pin the behavior
   on-chain.
6. **Owner misconfiguration bounds (L-3).** No test for `minGapTicks < 0` or extreme
   `basePenaltyBps`/`slippageBufferBps` (to confirm the runtime caps truly contain them).

---

## 6. What is missing (feature/robustness, from the code and the docs' own roadmap)

The docs already list deferred items; consolidating with what the review surfaced, in
rough priority:

1. **Mandatory nonzero `minBorrow`** (or a per-deploy default) — closes R-1 dust squatting
   and the keeper-economics floor. Currently a launch hazard because it defaults to 0.
2. **Per-position size cap vs. measured in-range depth** — the backtest's #1 finding
   (R-5); the chunk engine already measures depth every sale, so the data is on hand.
3. **The M-1 in-range self-guard in `_executeChunk`** — small, high value.
4. **Emergency pause / per-pool disable** (L-2) and an in-code **timelock** on the owner.
5. **Robust `repay`/`repayAll`** so exact-debt closure cannot strand a share (M-3).
6. **Per-block borrow caps and aggregate per-tick-region exposure caps** — deferred in the
   docs; relevant to the two-block manipulation model in RESEARCH §4.
7. **External audit** — repeatedly and correctly flagged by the team as not yet done.

---

## 7. Bottom line

TrueLend is a well-conceived protocol with an implementation that matches its
specification closely and defends the *funds-safety* invariants (collateral conservation,
debt/share reconciliation, reserve backing, waterfall-only lender loss) — all of which the
randomized invariant suite exercises. The gaps are at the edges: one genuine break of the
"pause on exit" behavioral guarantee under trigger congestion (**M-1**), a slow structural
drift of the gradual-liquidation point as interest accrues (**M-2**), a repay footgun that
only the router currently handles (**M-3**), and a set of launch-configuration and
documentation issues (dust `minBorrow`, the utilization-buffer wording, the bytecode-size
contradiction). None is a standing theft-of-funds vector on the standard-token, honest-
owner assumptions the protocol declares; all are worth fixing before an external audit and
before mainnet, and M-1 and the `minBorrow` default should be fixed first.

*This internal review does not replace an independent external audit, which the protocol
has correctly not yet claimed.*
