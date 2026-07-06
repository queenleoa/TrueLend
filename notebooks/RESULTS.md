# Parameter model — results

Produced by [`parameters.py`](parameters.py) / [`parameters.ipynb`](parameters.ipynb) implementing the methodology of [PARAMETERS.md](../PARAMETERS.md). 4,000 jump-diffusion paths per grid point, 12-second steps, engine replica cross-checked against the Solidity unit-test vectors at import time. Raw metrics: [`results.json`](results.json).

## Headline: simulated LT_max per tier

| Tier | σ (99th-pct ann.) | LT 90% | LT 95% | LT 97% | LT 99% | **LT_max (simulated)** | First cut (closed form) |
|---|---|---|---|---|---|---|---|
| Stable | 2% | ✓ | ✓ | ✓ | ✓ | **99%** | 99% |
| Major | 80% | ✓ | ✓ | ✗ (freq 3.1%) | ✗ | **95%** | 94–95% |
| Long-tail | 150% | ✗ (sev 6.1%) | ✗ | ✗ | ✗ | **≈88–90%*** | 89–90% |

Acceptance = shortfall frequency ≤ 1% of episodes ∧ conditional severity ≤ 5% of debt ∧ exhaustion ≤ 0.5%, at each tier's stress calibration. *Long-tail LT 90 fails only the severity tolerance (6.1% vs 5%), and only through the backstop-execution assumption (2% average impact + 1% fee on the closing sale) — it passes at a slightly wider range or LT 88; live pool-depth calibration decides.

The closed-form first cuts and the simulation agree — the simulation is the more permissive of the two exactly where it should be (the closed form charges 99th-percentile drift against the *entire* episode; the simulation lets episodes recover), which is the expected direction of the conservatism, not a discrepancy.

## Two contract changes this model forced

The first full sweep produced 100%-instant-backstop rows at high LT — not price risk, but two **fixed parameters silently contradicting borrower-chosen LT**. Both are now fixed in `TrueLendHook` with the same shape of fix (per-position scaling), both regression-tested:

1. **Health buffer vs LT** (`_forceCloseReason`): the reason-3 check used the fixed 2% config buffer, but a position *enters its range* at LTV = LT — so any LT > 98% was forceCloseable the moment its gradual liquidation should have started. Fix: `buffer = min(config, (1 − LT)/2)`. Test: `test_forceClose_healthBufferScalesWithLT`.
2. **Penalty vs LT** (`_currentPenaltyBps`): the time-scaled penalty (up to 2.25% of proceeds) exceeded the 1% gap of an LT-99 position, making full repayment through decay arithmetically impossible — positions decayed to dust with residual debt, then booked the residue as shortfall. Fix: effective penalty capped at `(1 − LT)/4`. With it, stable LT-99 episodes repay cleanly (shortfall frequency 0.03%, median borrower cost 30 bps).

The general lesson both instances teach: **every fixed economic parameter must be checked against the smallest LT gap it can meet** — the model's job is to find exactly these interactions before an auditor or an attacker does.

## Figures

**One episode, end to end** — decay only while the tick is in range; the pause is visible as the plateau; every step down in collateral is a step down in debt:

![episode](figures/episode.png)

**The buffer inequality per tier** — required buffer (stacked: execution, penalty, interest, 99th-pct drift) against the available gap (marker). Drift dominates everywhere except stables; interest is invisible at episode timescales — the two structural findings of the closed-form analysis, drawn:

![buffer](figures/buffer_terms.png)

**Pacing grid (major tier, LT 95%)** — median borrower cost with acceptance marks. Slow pacing (bottom-right) is cheap *when it works* and rejected because it doesn't: drift outruns it. The accepted-cheapest cell is N=50, τ=30s:

![pacing](figures/pacing_grid.png)

**Why pacing has an interior optimum** — μ grows as √T while s shrinks as ~1/√T; their sum has a minimum, and everything that shortens episodes (deeper pools, faster pacing, active poking) buys LT headroom:

![tradeoff](figures/pacing_tradeoff.png)

**Shortfall exceedance by LT (major tier)** — the lender's actual tail, against the ε₁ tolerance line:

![shortfall](figures/shortfall_exceedance.png)

## Recommended per-tier configs (v1 production values)

| Parameter | Stable | Major | Long-tail |
|---|---|---|---|
| `maxLtBps` | 9900 | 9500 | 8800–9000 (pending live calibration) |
| `targetChunks` / `chunkInterval` | 100 / 60 s | **50 / 30–60 s** | 100 / 60 s |
| `rangeWidth` | 3466 (√2) — 1733 viable | 3466 | ≥ 3466; widen if jump fit demands |
| `basePenaltyBps` | 25–50 | 50 | 75–100 |
| `minBorrow` | per chain: ~$40-eq (L2) / ~$4k (L1) | same | same |

## Known model limitations (inputs to the next iteration)

Static calibration constants stand in for live data (realized vol, tick-level depth snapshots); arbitrage refill fixed at κ = 0.9 rather than swept; backstop execution modeled as a flat 2% impact within the 10% bound; quiet-market execution gaps not yet simulated (the catch-up multiplier is exercised only implicitly); antithetic variates not yet enabled (raw MC error at 4,000 paths is ±0.16% on a 1% frequency — adequate for tiering, not for fine acceptance calls near the boundary, which is why long-tail LT 90 is reported as a band).
