# TrueLend Parameter Modelling

**Methodology, mathematics, and derivations for every tunable number in the protocol.**

This document does three things. §1–2 state *what* is being chosen and *what "correct" means* — the objective and the constraints, formally. §3–6 build the risk model piece by piece and derive closed-form first cuts for every parameter, with worked numbers. §7 specifies the Monte-Carlo methodology that refines those first cuts into production values, including calibration data, validation targets, and acceptance criteria. A reader who has been through [DESIGN.md](DESIGN.md) §0–§4 has all the vocabulary needed.

---

## 1. What is being modelled, and why

Most of TrueLend's parameters are mechanical (gas bounds, oracle window) and need no modelling. Seven are **risk parameters**: their values trade borrower cost against lender safety, and picking them requires a model of how prices move while a position decays.

| Parameter | Symbol | Default today | What it trades off |
|---|---|---|---|
| Target chunk count | $N$ | 100 | finer slices (less price impact) vs. slower decay (more price risk) |
| Chunk interval | $\tau$ | 60 s | same tradeoff, other axis |
| Liquidation range width | $w$ | 3,466 ticks (√2 in price) | recovery window for the borrower vs. distance risk to the bankruptcy line |
| Base penalty | $p_0$ | 0.5% | LP compensation vs. borrower cost |
| Maximum LT per pool tier | $\mathrm{LT}_{max}$ | 99% | borrower capital efficiency vs. lender tail risk |
| Per-chunk depth cap | — | 1% of in-range depth | execution quality vs. decay speed in thin books |
| Minimum borrow | — | 0 (owner must set) | dust-position DoS and keeper economics |

The central quantity throughout is the **decay episode**: the period from the tick entering a position's range to the position's debt being repaid (or the backstop firing). Everything the lender risks and everything the borrower pays happens inside episodes.

---

## 2. The objective, formally

Choose parameters to **minimize the borrower's expected excess cost per episode** subject to **lender-safety constraints**:

$$
\min_{N,\,\tau,\,w,\,p_0,\,\mathrm{LT}_{max}} \; \mathbb{E}\big[\,s + \pi \mid \text{episode}\,\big]
$$

subject to, per pool tier:

$$
\Pr[\text{shortfall} > 0] \le \varepsilon_1, \qquad
\mathbb{E}[\text{shortfall} \mid \text{shortfall}>0] \le \varepsilon_2 \cdot D, \qquad
\Pr[\text{range exhaustion}] \le \varepsilon_3
$$

where $s$ is execution cost (slippage + swap fees on the chunks), $\pi$ the penalty paid to LPs, $D$ the position's debt, and *shortfall* the bad debt reaching the waterfall. Proposed tolerances: $\varepsilon_1 = 1\%$ of episodes, $\varepsilon_2 = 5\%$, $\varepsilon_3 = 0.5\%$, all at the 99th-percentile volatility for the tier. These are policy choices, not derivations — they say "one episode in a hundred may produce any bad debt at all, and when it does, lenders lose at most 5% of that loan, pre-reserves."

The reason this is an optimization and not a solve: lender safety could be achieved trivially (LT 50%, instant decay), but every unit of safety is bought with borrower cost, and TrueLend's product *is* high-LT borrowing. The model finds the frontier.

---

## 3. The price model

### 3.1 Diffusion plus jumps

Price during an episode is modelled as a jump-diffusion (Merton):

$$
\frac{dS_t}{S_t} = \sigma\, dW_t + \big(e^{J} - 1\big)\, dq_t,
\qquad J \sim \mathcal{N}(\mu_J, \sigma_J^2),\quad dq_t \sim \text{Poisson}(\lambda\, dt)
$$

with drift set to zero (episodes last hours; drift is second-order at that horizon and assuming it downward would double-count the stress already in the volatility percentile). The two components matter for *different parameters*:

- **Diffusion** ($\sigma$) sets how far price wanders during a decay — it drives the adverse-drift term $\mu$ in the buffer inequality (§6) and therefore $\mathrm{LT}_{max}$.
- **Jumps** ($\lambda, \mu_J, \sigma_J$) set the probability of *skipping* — price crossing a large part of the range between two chunks — and therefore drive range width $w$ and the exhaustion probability $\varepsilon_3$. A pure-diffusion model would conclude exhaustion is impossible (§5.2) and dangerously undersize $w$.

### 3.2 Calibration

Per asset tier, estimate from history (2+ years, hourly closes for $\sigma$; 1-second/1-block data over stress weeks for jumps):

- $\hat\sigma$: annualized realized volatility, taken at the **99th percentile of rolling 30-day windows** — the parameterization must hold in bad months, not average ones.
- $\hat\lambda, \hat\mu_J, \hat\sigma_J$: fit jumps as returns exceeding $4\hat\sigma_{\text{local}}$ per block-interval; stress weeks (e.g., the March 2020, May 2021, Nov 2022, Oct 2025 drawdowns) weighted fully, not down-weighted as outliers.

Representative tier values used in the worked examples below:

| Tier | Example pair | $\sigma$ (99th-pct ann.) | Jump profile |
|---|---|---|---|
| Stable | USDC/USDT | 2% | rare, small (depeg tail handled separately) |
| Major | ETH/USDC | 80% | $\lambda \approx 20$/yr, $\mu_J = -8\%$, $\sigma_J = 6\%$ |
| Long-tail | new token/ETH | 150%+ | frequent, fat: $\lambda \approx 60$/yr, $\mu_J = -15\%$ |

---

## 4. The decay model

### 4.1 Closed-form decay path

Let $q$ be the fraction of *remaining* collateral sold per interval. From the pacing formula (DESIGN.md §4.2), $q = \bar m / N$ where $\bar m \in [1, 4]$ is the episode-average product of the depth and pressure multipliers ($\bar m \approx 1.5$ is typical: modest depth, small position). Remaining collateral after $k$ intervals:

$$
C_k = C_0\,(1-q)^k
\qquad\Longrightarrow\qquad
k_\phi = \frac{\ln(1-\phi)}{\ln(1-q)} \;\;\text{intervals to sell fraction } \phi.
$$

### 4.2 Episode duration

The episode ends when cumulative proceeds repay the debt. At range entry, debt equals $\mathrm{LT}$ × collateral value, and chunks execute at prices slightly below the range-start price (average discount $\delta$, a few percent for in-range execution). So the sold *fraction* must reach approximately $\phi^\star = \mathrm{LT}\,(1+\delta)$, giving the **repayment time**:

$$
T \;=\; \tau \cdot \frac{\ln\!\big(1-\mathrm{LT}(1+\delta)\big)}{\ln(1-q)}
$$

**Worked example (major tier, defaults).** $\mathrm{LT}=90\%$, $\delta\approx 2\%$, $q = 1.5/100$: $k = \ln(0.082)/\ln(0.985) \approx 165$ intervals → $T \approx \mathbf{2.7\ hours}$. At LT 99% (and $\bar m$ nearer 2 since the position enters deeper): $T \approx 2$–4 h. This $T$ is the exposure window every risk term below is integrated over — the single most consequential derived quantity in the model.

---

## 5. The cost and risk terms

The buffer inequality (derived in §6) needs four terms. Each gets its own model.

### 5.1 Execution cost $s$

A chunk of size $x$ sells against the pool's in-range liquidity. For constant-product execution against effective one-sided depth $X$ (the token amount of in-range liquidity across the position's range — exactly what the contract measures for its cap), the average execution shortfall is approximately half the price impact:

$$
s_{\text{chunk}} \;\approx\; \frac{x}{2X} + f
$$

where $f$ is the pool's LP fee tier. The engine caps $x \le 1\%\,X$, so $s_{\text{chunk}} \le 0.5\% + f$ **regardless of pool** — the cap converts pool-depth risk into decay-speed variation, which is the intended design. What the cap cannot decide alone is whether impacts *accumulate*: if arbitrage restores the price between chunks (refill factor $\kappa = 1$), per-chunk costs are independent and $s \approx \overline{s_{\text{chunk}}}$; with no refill ($\kappa = 0$) the position's own selling walks the price down and $s$ grows toward $\Phi/2X$ where $\Phi$ is the total sold. Reality sits near $\kappa \approx 1$ for pools with any arbitrage connectivity — the Monte Carlo sweeps $\kappa \in \{0.5, 0.9, 1\}$ and thin-tier parameters must hold at the pessimistic end.

**Working band:** $s \in [0.15\%, 0.8\%]$ for stable/major tiers (fee 0.01–0.3%), up to $1.5\%$ long-tail.

### 5.2 Adverse drift $\mu$ — and why exhaustion is a jump phenomenon

While the position decays over window $T$, the price keeps moving. The lender's risk is the *adverse* tail of that motion. For diffusion at the tier's stress volatility:

$$
\mu \;=\; z_{\alpha}\,\sigma\sqrt{T}, \qquad z_{0.99} = 2.33.
$$

**Worked example (major):** $\sigma = 80\%$, $T = 2.7\,\text{h}$: $\sigma\sqrt{T} = 0.80\sqrt{2.7/8760} = 1.40\%$, so $\mu \approx \mathbf{3.3\%}$. For stables: $\mu \approx 0.08\%$. Long-tail at $T = 4\,\text{h}$: $\mu \approx 7.5\%$.

For **range exhaustion** (price crossing the entire remaining range before decay completes), the relevant probability is a first-passage. For a driftless GBM and barrier $B$ below entry $S_0$:

$$
\Pr\Big[\min_{t \le T} S_t \le B\Big] \;=\; 2\,\Phi\!\left(\frac{\ln(B/S_0)}{\sigma\sqrt{T}}\right).
$$

With the default width ($B/S_0 = 2^{-1/2}$, $\ln = -0.347$) and $\sigma\sqrt{T} = 1.4\%$, the argument is $-24.8$ standard deviations: **diffusion essentially never exhausts a √2-wide range.** Exhaustion happens through *jumps* — a single block gapping a large fraction of the range — which is why $w$ is sized from the jump distribution: pick $w$ such that $\Pr[\text{jump} > w \text{ within } T] = \lambda T \cdot \Pr[|J| > \ln f] \le \varepsilon_3$. With the major-tier jump fit, a √2 range gives $\Pr[|J| > 34.7\%] \approx \Phi((-34.7+8)/6) \approx 4\times10^{-6}$ per jump — comfortably inside tolerance; the long-tail fit ($\mu_J=-15\%$) gives $\approx 5\times10^{-3}$ per jump, marginal — long-tail pools should widen $w$ or cap LT harder, and the simulation decides which is cheaper.

### 5.3 Interest during the episode $i(T)$

Debt accrues at the vault rate during decay. The worst *sustainable* rate is the curve at the utilization hard cap: $r(90\%) = 4\% + 100\%\cdot(90{-}80)/(100{-}80) = 54\%$ APR. Over hours it is negligible:

$$
i(T) = r_{max}\frac{T}{\text{year}} \;\approx\; 54\% \times \frac{2.7}{8760} \;=\; \mathbf{0.017\%}.
$$

This is a genuine modelling *finding*: interest is irrelevant on episode timescales and matters only through the term/expiry mechanism. It should not be double-counted in the episode buffer.

### 5.4 Penalty $\pi$

From the penalty formula, per chunk: $\pi_{\text{chunk}} = p_0 \cdot \mathrm{LT} \cdot \min(1 + t/1\text{h},\,5)$. Averaged over a $T$-hour episode ($p_0 = 0.5\%$): $\bar\pi = p_0\,\mathrm{LT}\,(1 + T/2\text{h})$ capped — for the 2.7 h major example, $\bar\pi \approx 0.5\% \times 0.9 \times 2.35 \approx \mathbf{1.1\%}$. Note the design consequence: $\pi$ is a *transfer* (borrower → LPs), not a system loss, but it consumes buffer all the same, so $p_0$ trades LP compensation directly against $\mathrm{LT}_{max}$.

---

## 6. The buffer inequality and $\mathrm{LT}_{max}$ tiers

### 6.1 Derivation

Lenders are whole if episode proceeds cover the debt. Value the collateral at range entry: $C \cdot P_{start} = D/\mathrm{LT}$. Proceeds lose $s$ to execution, $\pi$ to penalties, and the price itself walks $\mu$ against the position over the window (plus the episode's interest $i$ on the debt side). Requiring proceeds ≥ debt:

$$
\frac{D}{\mathrm{LT}}\,(1 - s - \pi)(1 - \mu) \;\ge\; D\,(1 + i)
$$

which to first order (all terms small) is the **buffer inequality**:

$$
\boxed{\;1 - \mathrm{LT} \;\gtrsim\; s + \pi + i(T) + \mu(T)\;}
$$

The gap between the borrower's chosen threshold and 100% must pay for execution, penalties, episode interest, and 99th-percentile price drift over the decay window. Everything in §3–5 exists to put numbers on the right-hand side.

### 6.2 First-cut $\mathrm{LT}_{max}$ table (to be confirmed by simulation)

| Tier | $s$ | $\bar\pi$ | $i$ | $\mu$ | RHS total | $\mathrm{LT}_{max}$ (first cut) |
|---|---|---|---|---|---|---|
| Stable ($\sigma$ 2%) | 0.15% | 0.5% | ~0 | 0.1% | **0.75%** | **99%** |
| Major ($\sigma$ 80%) | 0.8% | 1.1% | 0.02% | 3.3% | **5.2%** | **94–95%** |
| Long-tail ($\sigma$ 150%) | 1.5% | 1.5% | 0.03% | 7.5% | **10.5%** | **89–90%** |

Two readings of this table matter. First, it *justifies the headline*: LT 99 is sound where it should be (deep, stable pairs) and the protocol's own math says where it is not. Second, it shows the buffer is **dominated by $\mu$**, i.e. by $\sigma\sqrt{T}$ — so the highest-leverage improvement is *shortening the episode* (larger $q$: fewer target chunks or shorter intervals), bought at the price of higher $s$. That tradeoff has an interior optimum:

$$
\frac{\partial}{\partial T}\Big[s(T) + z\sigma\sqrt{T}\Big] = 0
\quad\Longrightarrow\quad
\text{decay just fast enough that marginal impact equals marginal drift risk,}
$$

which the simulation locates per tier by sweeping $(N, \tau)$; the closed forms say the optimum for majors sits near faster-than-default pacing ($N \approx 50$, $\tau = 60$ s halves $T$, adding ~0.1–0.2% to $s$ while cutting ~1% from $\mu$ — likely raising $\mathrm{LT}_{max}$ for majors toward 96%).

### 6.3 Minimum borrow

Keeper economics, not price risk: `forceClose` pays 0.1% of proceeds, and must beat gas. With $g$ = gas cost of a close (~350k gas):

$$
\text{minBorrow} \;\ge\; \frac{g \cdot \text{gasPrice} \cdot \text{ETHprice}}{0.1\%}
$$

≈ **$40-equivalent on an L2** at 0.05 gwei, ≈ **$4,000 on mainnet** at 5 gwei. Set per chain, not per pool.

---

## 7. Monte-Carlo methodology

The closed forms above make three simplifications the simulation removes: the multiplier $\bar m$ is path-dependent (depth changes as price moves through the range); pause/resume makes $T$ a random variable, not a constant; and jump-then-partial-recovery paths interact with the pacing in ways no closed form captures.

### 7.1 Simulator

1. **Paths**: jump-diffusion (§3.1) at 1-block (12 s / 1 s for L2) resolution, per tier calibration; 10,000 paths per grid point; antithetic variates for variance reduction.
2. **Engine replica**: a faithful Python port of `ChunkMath` + range logic: entry/exit detection, per-interval chunk sizing with live depth and pressure, penalty accrual with time-in-liquidation, pause on exit, resume on re-entry, `forceClose` at range exhaustion / health breach, waterfall on shortfall. (Port, not reimplementation-from-memory: cross-check against the Solidity unit-test vectors so the two cannot drift apart.)
3. **Market microstructure**: pool depth constant per run (swept as a parameter); arbitrage refill factor $\kappa \in \{0.5, 0.9, 1.0\}$ applied between intervals; organic volume irrelevant except as it triggers `afterSwap` — model chunk execution as available every $\tau$ (poke-backstopped), plus a "quiet market" variant with execution gaps of 5–30 min to stress the catch-up multiplier.
4. **Episode bootstrap**: positions initialized at LTV = 95% of candidate LT (the headroom boundary — worst legal entry), price started at the range boundary (episodes begin at entry by definition).

### 7.2 Sweep grid

| Axis | Values |
|---|---|
| Tier ($\sigma$, jumps) | stable / major / long-tail (§3.2) |
| $N$ | 50, 100, 200 |
| $\tau$ | 30 s, 60 s, 120 s |
| $w$ | 1,733 (⁴√2), 3,466 (√2), 6,932 (2×) ticks |
| candidate LT | 90, 95, 97, 99% |
| depth regime | chunk cap binding never / half the time / always |
| $\kappa$ | 0.5, 0.9, 1.0 |

### 7.3 Metrics and acceptance

Per grid point, over all episodes: shortfall frequency and conditional severity (vs. $\varepsilon_1, \varepsilon_2$); exhaustion frequency (vs. $\varepsilon_3$); borrower cost distribution ($s + \pi$, median and 95th percentile); episode duration distribution; fraction of episodes ending in recovery (pause-out) vs. repayment vs. backstop. **A parameter set is accepted for a tier iff all three $\varepsilon$ constraints hold at that tier's 99th-percentile calibration, and is preferred among accepted sets by lowest median borrower cost.**

### 7.4 Validation and calibration data

- **External anchor**: LLAMMA's published soft-liquidation empirics (≈1% collateral loss for a 10%-below-threshold excursion held ~3 days; losses scaling with realized variance). Our simulated borrower cost for the analogous episode should land in the same order of magnitude — materially lower is a red flag (missing cost term), materially higher means pacing is too slow.
- **Inputs**: per-pair realized vol series (exchange candles); tick-level pool depth snapshots from the target chain (the contract's own `_rangeDepthTokens` measure, sampled); L2 gas price history for §6.3.
- **Sensitivity report**: tornado chart of $\mathrm{LT}_{max}$ against ±50% perturbation of each calibrated input — any input whose perturbation moves $\mathrm{LT}_{max}$ by more than one tier gets a conservative haircut in production values.

### 7.5 Deliverables

1. `notebooks/parameters.ipynb` — calibration, closed-form first cuts (reproducing §4–6), simulator, sweep, acceptance report.
2. A per-tier config table (the production values for every §1 parameter) emitted as JSON, consumed by the deployment scripts' `setConfig` calls.
3. This document updated with the simulated values beside each first cut.

---

## 8. Summary of first-cut recommendations

| Parameter | Stable tier | Major tier | Long-tail tier |
|---|---|---|---|
| $\mathrm{LT}_{max}$ | 99% | 94–95% (≈96% with faster pacing) | 89–90% |
| $N$ / $\tau$ | 100 / 60 s | **50 / 60 s** (halve the episode) | 100 / 60 s (impact-bound) |
| Range width $w$ | 1,733 ticks may suffice | 3,466 ticks (√2) | ≥3,466; widen if jump fit demands |
| Base penalty $p_0$ | 0.25% (episodes benign) | 0.5% | 0.75–1% (LPs carry more) |
| minBorrow | per chain: ~$40 (L2) / ~$4k (L1) | same | same |

The single most important number to take away: **the buffer is drift-dominated** ($\mu = z\sigma\sqrt{T}$), so everything that shortens episodes — faster pacing, deeper pools, active poking — feeds directly into higher safe LT. That is the quantitative form of the protocol's thesis: gradual liquidation is safe exactly to the degree that it is *not too gradual*, and the model's job is to sit on the right side of that line per pool tier.
