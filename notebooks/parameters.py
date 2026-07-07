# %% [markdown]
# # TrueLend parameter model
#
# Implements PARAMETERS.md §7: closed-form first cuts, a faithful Python replica of the
# on-chain chunk engine (cross-checked against the Solidity unit-test vectors), a
# jump-diffusion episode simulator with antithetic variates, the Monte-Carlo sweep,
# and the acceptance report.
#
# The engine itself lives in [`engine.py`](engine.py) and is shared verbatim with the
# historical-replay backtest ([`backtest.py`](backtest.py)) — one implementation of the
# episode semantics, two path sources (simulated and real).
#
# Run headless:  .venv/bin/python notebooks/parameters.py
# Outputs:       notebooks/figures/*.png, notebooks/results.json

# %%
import json
import math
import os

import numpy as np

from engine import (
    TIERS, DEFAULTS, EPS, YEAR, CHUNK_DEPTH_CAP,
    chunk_size, penalty_rate, closed_forms, simulate, accepted,
    SURFACE, INK, MUTED, BLUE, AQUA, YELLOW, RED, apply_style,
)

FIGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "figures")
os.makedirs(FIGDIR, exist_ok=True)
print("engine replica: all Solidity test vectors reproduced (asserted on import)")

# %% [markdown]
# ## 1. Closed-form first cuts (PARAMETERS.md §4–6)

# %%
print(f"{'tier':<10}{'LT':>5}{'T (h)':>8}{'s':>8}{'π':>8}{'i':>9}{'μ':>8}{'RHS':>8}{'1-LT':>7}")
first_cut = {}
for tier in TIERS:
    for lt in (0.90, 0.95, 0.97, 0.99):
        cf = closed_forms(tier, lt)
        ok = "ok" if 1 - lt >= cf["rhs"] else "--"
        first_cut[(tier, lt)] = cf
        print(f"{tier:<10}{lt:>5.2f}{cf['T_h']:>8.2f}{cf['s']:>8.2%}{cf['pi']:>8.2%}"
              f"{cf['i']:>9.3%}{cf['mu']:>8.2%}{cf['rhs']:>8.2%}{1-lt:>6.0%} {ok}")

# %% [markdown]
# ## 2. Monte-Carlo sweep
#
# Episodes start at range entry (price = range start, debt = LT × collateral value —
# the definition of the range start). Chunks execute once per interval while in range
# (poke-backstopped); pause on exit; recovery = 1h continuously above the range start;
# backstops per the contract: range exhaustion and the current-price health check.
# 4,000 antithetic jump-diffusion paths per grid point at 12-second steps.

# %%
results = []
print("\nsweep: tier × LT at protocol defaults")
for tier in TIERS:
    for lt in (0.90, 0.95, 0.97, 0.99):
        m = simulate(tier, lt, seed=hash((tier, lt)) % 2**31, **DEFAULTS)
        results.append(m)
        print(f"  {tier:<9} LT{lt:.0%}: sfFreq {m['shortfall_freq']:.2%} sev {m['shortfall_sev']:.2%} "
              f"exh {m['exhaustion']:.2%} cost {m['cost_med_bps']:.0f}/{m['cost_p95_bps']:.0f}bps "
              f"dur {m['dur_med_h']:.1f}h {'ACCEPT' if accepted(m) else 'reject'}")

print("\nsweep: pacing grid (major tier, LT 95%)")
pacing = []
for N in (50, 100, 200):
    for tau in (30.0, 60.0, 120.0):
        m = simulate("major", 0.95, N=N, tau=tau, f=DEFAULTS["f"], kappa=DEFAULTS["kappa"],
                     seed=hash((N, tau)) % 2**31)
        pacing.append(m)
        print(f"  N={N:<4} τ={tau:>5.0f}s: sfFreq {m['shortfall_freq']:.2%} "
              f"cost {m['cost_med_bps']:.0f}bps dur {m['dur_med_h']:.1f}h "
              f"{'ACCEPT' if accepted(m) else 'reject'}")

lt_max = {}
for tier in TIERS:
    acc = [m["lt"] for m in results if m["tier"] == tier and accepted(m)]
    lt_max[tier] = max(acc) if acc else None
print("\nsimulated LT_max per tier (defaults):", lt_max)

# %% [markdown]
# ## 3. Visualizations
#
# Palette: validated categorical slots (blue #2a78d6, aqua #1baf7a, yellow #eda100,
# red #e34948) on light surface #fcfcfb; sequential = single-hue blue ramp; all
# series direct-labeled (aqua/yellow sit below 3:1 → relief via labels).

# %%
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

apply_style(plt)

def _save(fig, name):
    fig.tight_layout()
    fig.savefig(os.path.join(FIGDIR, name), bbox_inches="tight")
    plt.close(fig)
    print("wrote figures/" + name)

# --- Figure A: one sample episode (price + position, stacked panels, shared time) ----
def fig_episode():
    t = TIERS["major"]; lt, N, tau, f, kappa = 0.95, 100, 60.0, DEFAULTS["f"], 0.9
    r = np.random.default_rng(11)
    dt, hours = 12.0, 6
    steps = int(hours * 3600 / dt)
    sig_dt = t["sigma"] * math.sqrt(dt / YEAR)
    # a path engineered to dip, decay, recover: seed chosen for a re-entry story
    logP = np.zeros(steps + 1)
    for k in range(1, steps + 1):
        logP[k] = logP[k - 1] + sig_dt * r.standard_normal() - 0.5 * sig_dt**2
    logP -= np.linspace(0, 0.02, steps + 1)          # gentle adverse drift for the story
    P = np.exp(logP)
    C = np.ones(steps + 1); D = np.full(steps + 1, lt)
    last, til = -tau, 0.0
    X = t["depth"]
    for k in range(1, steps + 1):
        C[k], D[k] = C[k - 1], D[k - 1]
        p = P[k]; now = k * dt
        if D[k] <= 0: continue
        if 1 / f <= p <= 1.0:
            til += dt
            if now - last >= tau:
                d01 = min(max(-math.log(p) / math.log(f), 0), 1)
                x = chunk_size(C[k], N, now - last, tau, 5, d01, min(C[k] / X, 1), 0, 0.01 * X)
                slip = x / (2 * X) + t["fee"]
                proc = x * p * (1 - slip)
                D[k] -= proc * (1 - penalty_rate(lt, til))
                C[k] -= x
                last = now
    tt = np.arange(steps + 1) * dt / 3600
    fig, (a, b) = plt.subplots(2, 1, figsize=(7.2, 4.6), sharex=True,
                               gridspec_kw=dict(height_ratios=[1.1, 1]))
    a.axhspan(0.9, 1.0, color=RED, alpha=0.08, lw=0)
    a.axhline(1.0, color=RED, lw=1, ls=(0, (4, 3)))
    a.plot(tt, P, color=BLUE, lw=1.6)
    a.set_ylim(0.955, 1.022)
    a.set_ylabel("price / range start")
    a.text(hours * 0.99, 1.002, "range start — in the liquidation range below this line",
           ha="right", va="bottom", fontsize=8.5, color=RED)
    a.text(hours * 0.99, 0.9575, "bankruptcy line far below at 0.71 ↓",
           ha="right", fontsize=8, color=MUTED)
    a.text(0.12, P[0] + 0.012, "pool price", fontsize=8.5, color=BLUE)
    # call out the pause: longest flat stretch of collateral
    flat = np.where(np.diff(C) == 0)[0]
    if len(flat):
        runs = np.split(flat, np.where(np.diff(flat) != 1)[0] + 1)
        run = max(runs, key=len)
        mid = tt[run[len(run) // 2]]
        b.annotate("price above range —\ndecay paused", (mid, C[run[0]] / C[0]),
                   textcoords="offset points", xytext=(6, 22), fontsize=8, color=INK,
                   arrowprops=dict(arrowstyle="-", color=MUTED, lw=0.8))
    b.plot(tt, C / C[0], color=BLUE, lw=1.8)
    b.plot(tt, D / D[0], color=AQUA, lw=1.8)
    b.set_ylim(-0.04, 1.06)
    b.set_ylabel("fraction of initial")
    b.set_xlabel("hours since range entry")
    b.text(tt[-1] * 0.99, C[-1] / C[0] + 0.05, "collateral", ha="right", fontsize=8.5, color=BLUE)
    k46 = int(len(tt) * 0.72)
    b.text(tt[k46], D[k46] / D[0] - 0.07, "debt", ha="center", va="top", fontsize=8.5, color=AQUA)
    a.set_title("One simulated episode — decay only while in range (major tier, LT 95%)",
                fontsize=10.5, color=INK, loc="left")
    _save(fig, "episode.png")

# --- Figure B: buffer decomposition per tier vs available gap -------------------------
def fig_buffer():
    tiers = list(TIERS)
    lts = {"stable": 0.99, "major": 0.95, "longtail": 0.90}
    comps = [("execution s", "s", BLUE), ("penalty π", "pi", AQUA),
             ("interest i", "i", YELLOW), ("drift μ (99th pct)", "mu", RED)]
    fig, ax = plt.subplots(figsize=(7.2, 3.4))
    y = np.arange(len(tiers))[::-1]
    for yi, tier in zip(y, tiers):
        cf = closed_forms(tier, lts[tier])
        left = 0.0
        for label, key, colr in comps:
            v = cf[key] * 100
            ax.barh(yi, v, left=left, height=0.52, color=colr, edgecolor=SURFACE, lw=2)
            if v > 0.35:
                ax.text(left + v / 2, yi, f"{v:.1f}", ha="center", va="center",
                        fontsize=8, color=SURFACE if colr in (BLUE, RED) else INK)
            left += v
        gap = (1 - lts[tier]) * 100
        ax.plot([gap, gap], [yi - 0.38, yi + 0.38], color=INK, lw=1.6)
        ax.text(gap, yi + 0.44, f"gap at LT {lts[tier]:.0%} → {gap:.0f}%",
                ha="center", fontsize=8, color=INK)
    ax.set_yticks(y, [f"{t}\n(LT {lts[t]:.0%})" for t in tiers])
    ax.set_xlabel("% of position value")
    ax.set_title("The buffer inequality per tier: required (stacked) vs available (marker)",
                 fontsize=10.5, loc="left")
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, _, c in comps]
    ax.legend(handles, [l for l, _, _ in comps], loc="lower right", frameon=False, fontsize=8)
    _save(fig, "buffer_terms.png")

# --- Figure C: pacing grid heatmap (major tier) ---------------------------------------
def fig_pacing():
    Ns, taus = (50, 100, 200), (30, 60, 120)
    med = np.zeros((3, 3)); acc = np.zeros((3, 3), dtype=bool)
    for m in pacing:
        i, j = Ns.index(m["N"]), taus.index(int(m["tau"]))
        med[i, j] = m["cost_med_bps"]; acc[i, j] = accepted(m)
    seq = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95"]
    cmap = matplotlib.colors.LinearSegmentedColormap.from_list("blueseq", seq)
    fig, ax = plt.subplots(figsize=(5.6, 3.6))
    im = ax.imshow(med, cmap=cmap)
    for i in range(3):
        for j in range(3):
            dark = im.norm(med[i, j]) > 0.55
            ax.text(j, i, f"{med[i,j]:.0f}\n{'✓' if acc[i,j] else '✗'}", ha="center",
                    va="center", fontsize=9, color=SURFACE if dark else INK)
    ax.set_xticks(range(3), [f"τ={t}s" for t in taus])
    ax.set_yticks(range(3), [f"N={n}" for n in Ns])
    ax.set_title("Median borrower cost (bps) and acceptance — major tier, LT 95%",
                 fontsize=10.5, loc="left")
    ax.grid(False)
    fig.colorbar(im, ax=ax, shrink=0.85, label="bps")
    _save(fig, "pacing_grid.png")

# --- Figure D: shortfall exceedance curves per LT (major tier) -------------------------
def fig_shortfall():
    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    colors = {0.90: BLUE, 0.95: AQUA, 0.97: YELLOW, 0.99: RED}
    for m in results:
        if m["tier"] != "major":
            continue
        sf = np.sort(m["shortfall_samples"] / m["lt"]) * 100
        exceed = 1 - np.arange(1, len(sf) + 1) / len(sf)
        ax.plot(sf, exceed * 100, color=colors[m["lt"]], lw=1.8)
        ax.text(max(sf[-1], 0.1), max(exceed[-1] * 100, 0.02), f"LT {m['lt']:.0%}",
                fontsize=8.5, color=colors[m["lt"]], va="bottom", ha="right")
    ax.axhline(EPS["shortfall_freq"] * 100, color=MUTED, lw=1, ls=(0, (4, 3)))
    ax.text(0.02, EPS["shortfall_freq"] * 100 * 1.15, "ε₁ tolerance: 1% of episodes",
            fontsize=8, color=MUTED)
    ax.set_yscale("log"); ax.set_ylim(0.01, 100)
    ax.set_xlabel("lender shortfall, % of debt")
    ax.set_ylabel("% of episodes exceeding (log)")
    ax.set_title("Shortfall exceedance by chosen LT — major tier, defaults",
                 fontsize=10.5, loc="left")
    _save(fig, "shortfall_exceedance.png")

# --- Figure E: the s+μ tradeoff --------------------------------------------------------
def fig_tradeoff():
    T = np.linspace(0.25, 8, 200) * 3600
    t = TIERS["major"]
    mu = 2.33 * t["sigma"] * np.sqrt(T / YEAR) * 100
    # faster decay = more/larger chunks per unit time = higher realized impact share
    s = (t["fee"] + CHUNK_DEPTH_CAP / 2 * np.sqrt((2.7 * 3600) / T)) * 100
    tot = mu + s
    fig, ax = plt.subplots(figsize=(7.2, 3.4))
    ax.plot(T / 3600, mu, color=RED, lw=1.8)
    ax.plot(T / 3600, s, color=BLUE, lw=1.8)
    ax.plot(T / 3600, tot, color=INK, lw=2.2)
    k = tot.argmin()
    ax.plot(T[k] / 3600, tot[k], "o", color=INK, ms=7, mfc=SURFACE, mew=1.6)
    ax.annotate(f"optimum ≈ {T[k]/3600:.1f} h", (T[k] / 3600, tot[k]),
                textcoords="offset points", xytext=(10, 10), fontsize=9, color=INK)
    ax.text(7.9, mu[-1], "drift risk μ", ha="right", va="bottom", fontsize=8.5, color=RED)
    ax.text(7.9, s[-1] + 0.08, "execution cost s", ha="right", fontsize=8.5, color=BLUE)
    ax.text(7.9, tot[-1] + 0.1, "total", ha="right", fontsize=8.5, color=INK)
    ax.set_xlabel("episode duration T (hours) — set by pacing (N, τ)")
    ax.set_ylabel("% of position value")
    ax.set_title("Why pacing has an interior optimum (major tier): μ ∝ √T vs s ∝ 1/√T",
                 fontsize=10.5, loc="left")
    _save(fig, "pacing_tradeoff.png")

fig_episode(); fig_buffer(); fig_pacing(); fig_shortfall(); fig_tradeoff()

# %% [markdown]
# ## 4. Persist results

# %%
out = {
    "lt_max_simulated": lt_max,
    "tolerances": EPS,
    "grid": [{k: v for k, v in m.items() if not isinstance(v, np.ndarray) and k != "frac"}
             | {"frac": m["frac"], "accepted": accepted(m)} for m in results + pacing],
}
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.json"), "w") as fh:
    json.dump(out, fh, indent=2)
print("wrote notebooks/results.json")
