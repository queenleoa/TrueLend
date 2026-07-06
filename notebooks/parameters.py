# %% [markdown]
# # TrueLend parameter model
#
# Implements PARAMETERS.md §7: closed-form first cuts, a faithful Python replica of the
# on-chain chunk engine (cross-checked against the Solidity unit-test vectors), a
# jump-diffusion episode simulator, the Monte-Carlo sweep, and the acceptance report.
#
# Run headless:  .venv/bin/python notebooks/parameters.py
# Outputs:       notebooks/figures/*.png, notebooks/results.json

# %%
import json
import math
import os
import numpy as np

rng = np.random.default_rng(20260706)
FIGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "figures")
os.makedirs(FIGDIR, exist_ok=True)

# ---------------------------------------------------------------- protocol constants
# Mirror src/TrueLendHook.sol + VaultFactory.sol. Change here only to model a change there.
YEAR = 365 * 24 * 3600
BASE_PENALTY = 0.005          # 0.5% of proceeds
PENALTY_TIME_CAP = 5.0        # ×5 after 4h in liquidation
TIME_CATCHUP_CAP = 5.0        # pacing catch-up multiplier cap
CHUNK_DEPTH_CAP = 0.01        # one chunk ≤ 1% of in-range depth
HEALTH_BUFFER_CFG = 0.02      # forceClose reason-3 buffer config (slippageBufferBps)

def health_buffer(lt):
    """Contract: buffer capped at half the position's LT gap (TrueLendHook fix)."""
    return min(HEALTH_BUFFER_CFG, (1 - lt) / 2)
FC_IMPACT = 0.02              # modeled avg execution impact of a backstop sale (≤10% bound)
OPEN_HEADROOM = 0.95          # opening LTV ≤ 95% of LT
R_MAX_APR = 0.54              # vault rate at the 90% utilization hard cap

# ---------------------------------------------------------------- tier calibration (PARAMETERS.md §3.2)
TIERS = {
    "stable":   dict(sigma=0.02, lam=2,  muJ=-0.005, sJ=0.003, fee=0.0005, depth=100.0),
    "major":    dict(sigma=0.80, lam=20, muJ=-0.08,  sJ=0.06,  fee=0.0030, depth=20.0),
    "longtail": dict(sigma=1.50, lam=60, muJ=-0.15,  sJ=0.10,  fee=0.0100, depth=5.0),
}
# depth = one-sided in-range book depth in units of the position's collateral (position = 1)

DEFAULTS = dict(N=100, tau=60.0, f=math.sqrt(2), kappa=0.9)
EPS = dict(shortfall_freq=0.01, shortfall_sev=0.05, exhaustion=0.005)  # §2 tolerances

# %% [markdown]
# ## 1. Engine replica — `ChunkMath` port, cross-checked against the Solidity test vectors

# %%
def chunk_size(remaining, target_chunks, elapsed, interval, time_cap, depth01, pressure01,
               min_chunk, max_chunk):
    """Float port of ChunkMath.chunkSize (test/libraries/ChunkMath.t.sol semantics)."""
    if np.isscalar(remaining):
        remaining = np.asarray([remaining], dtype=float)
        scalar = True
    else:
        scalar = False
    remaining = np.asarray(remaining, dtype=float)
    elapsed = np.broadcast_to(np.asarray(elapsed, dtype=float), remaining.shape).copy()
    depth01 = np.clip(np.broadcast_to(np.asarray(depth01, dtype=float), remaining.shape), 0, 1)
    pressure01 = np.clip(np.broadcast_to(np.asarray(pressure01, dtype=float), remaining.shape), 0, 1)

    due = (remaining > 0) & (elapsed >= interval)
    base = remaining / target_chunks
    timex = np.minimum(np.floor(elapsed / interval), time_cap)  # Solidity: integer division
    size = base * timex * (1 + depth01) * (1 + pressure01)
    size = np.minimum(size, max_chunk)
    size = np.maximum(size, min_chunk)
    size = np.minimum(size, remaining)
    size = np.where(due, size, 0.0)
    return float(size[0]) if scalar else size


def penalty_rate(lt, t_in_liq):
    """Hook's effective penalty: ChunkMath.penaltyBps capped at a quarter of the LT gap."""
    timex = np.minimum(1.0 + t_in_liq / 3600.0, PENALTY_TIME_CAP)
    return np.minimum(BASE_PENALTY * lt * timex, (1 - lt) / 4)


# Cross-check: the exact vectors from test/libraries/ChunkMath.t.sol (scaled 1e18 -> 1.0)
def _vec(**kw):
    p = dict(remaining=100.0, target_chunks=100, elapsed=60, interval=60, time_cap=5,
             depth01=0.0, pressure01=0.0, min_chunk=0.001, max_chunk=50.0)
    p.update(kw)
    return chunk_size(p["remaining"], p["target_chunks"], p["elapsed"], p["interval"],
                      p["time_cap"], p["depth01"], p["pressure01"], p["min_chunk"], p["max_chunk"])

assert _vec() == 1.0                                   # test_baseChunk_noMultipliers
assert _vec(elapsed=59) == 0.0                         # test_zeroBeforeInterval
assert _vec(remaining=0) == 0.0                        # test_zeroWhenNothingRemains
assert _vec(elapsed=180) == 3.0                        # test_timeMultiplier catch-up
assert _vec(elapsed=6000) == 5.0                       # ...capped
assert _vec(depth01=1.0) == 2.0                        # test_depthAndPressure
assert _vec(pressure01=1.0) == 2.0
assert _vec(depth01=1.0, pressure01=1.0) == 4.0
assert _vec(depth01=0.5) == 1.5                        # test_halfDepth
assert _vec(max_chunk=0.5) == 0.5                      # test_maxChunkClamp
assert abs(penalty_rate(0.90, 0) - 0.0045) < 1e-12     # test_penalty_knownValues (45 bps)
assert abs(penalty_rate(0.90, 3600) - 0.0090) < 1e-12  # 90 bps after 1h
assert abs(penalty_rate(0.90, 36000) - 0.0225) < 1e-12 # capped at 225 bps
print("engine replica: all Solidity test vectors reproduced")

# %% [markdown]
# ## 2. Closed-form first cuts (PARAMETERS.md §4–6)

# %%
def closed_forms(tier_name, lt, N=None, tau=None, f=None):
    t = TIERS[tier_name]
    N = N or DEFAULTS["N"]; tau = tau or DEFAULTS["tau"]; f = f or DEFAULTS["f"]
    mbar = 1.5                                   # episode-average pacing multiplier
    q = mbar / N
    phi = min(lt * 1.02, 0.995)                  # sold fraction needed (2% avg discount)
    k = math.log(1 - phi) / math.log(1 - q)      # intervals to repay
    T = k * tau                                  # episode duration, seconds
    sigT = t["sigma"] * math.sqrt(T / YEAR)
    mu = 2.33 * sigT                             # 99th-pct adverse drift
    s = CHUNK_DEPTH_CAP / 2 + t["fee"]           # per-chunk execution shortfall bound
    i = R_MAX_APR * T / YEAR
    pi = min(BASE_PENALTY * lt * min(1 + (T / 2) / 3600, PENALTY_TIME_CAP), (1 - lt) / 4)
    return dict(T_h=T / 3600, mu=mu, s=s, i=i, pi=pi, rhs=s + pi + i + mu)

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
# ## 3. Episode simulator — jump-diffusion price, full engine semantics
#
# Episodes start at range entry (price = range start, debt = LT × collateral value —
# the definition of the range start). Chunks execute once per interval while in range
# (poke-backstopped); pause on exit; recovery = 1h continuously above the range start;
# backstops per the contract: range exhaustion and the current-price health check.

# %%
def simulate(tier_name, lt, N, tau, f, kappa, n_paths=4000, dt=12.0, horizon_h=12.0,
             seed=0):
    t = TIERS[tier_name]
    r = np.random.default_rng(seed)
    n_steps = int(horizon_h * 3600 / dt)
    sig_dt = t["sigma"] * math.sqrt(dt / YEAR)
    jump_p = t["lam"] * dt / YEAR
    X = t["depth"]                       # in-range depth, collateral units
    fee = t["fee"]
    P_end = 1.0 / f

    logP = np.zeros(n_paths)             # price starts at range start = 1.0
    C = np.ones(n_paths)                 # collateral
    D = np.full(n_paths, lt)             # debt = LT · C · P_start
    impact = np.zeros(n_paths)           # persistent own-impact displacement (1-κ share)
    last_chunk = np.full(n_paths, -tau)  # first chunk due immediately
    t_in_liq = np.zeros(n_paths)
    t_above = np.zeros(n_paths)
    cost = np.zeros(n_paths)             # borrower execution+penalty cost, value units
    shortfall = np.zeros(n_paths)
    duration = np.full(n_paths, np.nan)
    outcome = np.zeros(n_paths, dtype=np.int8)   # 0 live · 1 repaid · 2 recovered · 3 backstop-clean · 4 backstop-shortfall

    active = np.ones(n_paths, dtype=bool)
    for step in range(1, n_steps + 1):
        now = step * dt
        idx = active
        if not idx.any():
            break
        z = r.standard_normal(idx.sum())
        logP[idx] += sig_dt * z - 0.5 * sig_dt**2
        jumps = r.random(idx.sum()) < jump_p
        if jumps.any():
            j = r.normal(t["muJ"], t["sJ"], jumps.sum())
            tmp = logP[idx]; tmp[jumps] += j; logP[idx] = tmp

        P = np.exp(logP) * (1 - impact)
        in_range = idx & (P <= 1.0) & (P >= P_end)
        above = idx & (P > 1.0)
        t_in_liq[in_range] += dt
        t_above[above] += dt
        t_above[in_range] = 0.0

        # --- backstops: range exhaustion, health breach ------------------------------
        breach = idx & ((P < P_end) | (C * P * (1 - health_buffer(lt)) < D))
        if breach.any():
            proceeds = C[breach] * P[breach] * (1 - fee - FC_IMPACT)
            pen = proceeds * penalty_rate(lt, t_in_liq[breach])
            net = proceeds - pen
            cost[breach] += C[breach] * P[breach] * (fee + FC_IMPACT) + pen
            sf = np.maximum(D[breach] - net, 0.0)
            shortfall[breach] = sf
            duration[breach] = now
            outcome[breach] = np.where(sf > 1e-12, 4, 3)
            C[breach] = 0.0; D[breach] = 0.0
            active &= ~breach

        # --- due chunks ---------------------------------------------------------------
        due = in_range & active & (now - last_chunk >= tau)
        if due.any():
            depth01 = np.clip(-logP[due] / math.log(f), 0, 1)
            pressure01 = np.clip(C[due] / X, 0, 1)
            x = chunk_size(C[due], N, now - last_chunk[due], tau, TIME_CATCHUP_CAP,
                           depth01, pressure01, 0.0, CHUNK_DEPTH_CAP * X)
            slip = x / (2 * X) + fee
            proceeds = x * P[due] * (1 - slip)
            pen = proceeds * penalty_rate(lt, t_in_liq[due])
            D[due] -= proceeds - pen
            C[due] -= x
            cost[due] += x * P[due] * slip + pen
            impact[due] += (1 - kappa) * x / X
            last_chunk[due] = now

        # --- closures -------------------------------------------------------------------
        repaid = active & (D <= 1e-12)
        if repaid.any():
            duration[repaid] = now; outcome[repaid] = 1; active &= ~repaid
        recovered = active & (t_above >= 3600.0)
        if recovered.any():
            duration[recovered] = now; outcome[recovered] = 2; active &= ~recovered

    live = outcome == 0
    duration[live] = n_steps * dt
    sf_pos = shortfall > 1e-12
    return dict(
        tier=tier_name, lt=lt, N=N, tau=tau, f=f, kappa=kappa,
        shortfall_freq=float(sf_pos.mean()),
        shortfall_sev=float((shortfall[sf_pos] / lt).mean()) if sf_pos.any() else 0.0,
        exhaustion=float((outcome >= 3).mean()),
        cost_med_bps=float(np.median(cost) * 1e4),
        cost_p95_bps=float(np.percentile(cost, 95) * 1e4),
        dur_med_h=float(np.median(duration) / 3600),
        frac=dict(repaid=float((outcome == 1).mean()), recovered=float((outcome == 2).mean()),
                  backstop=float((outcome >= 3).mean()), live=float(live.mean())),
        shortfall_samples=shortfall, cost_samples=cost, outcome=outcome,
    )


def accepted(m):
    return (m["shortfall_freq"] <= EPS["shortfall_freq"]
            and m["shortfall_sev"] <= EPS["shortfall_sev"]
            and m["exhaustion"] <= EPS["exhaustion"])

# %% [markdown]
# ## 4. Sweep

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
# ## 5. Visualizations
#
# Palette: validated categorical slots (blue #2a78d6, aqua #1baf7a, yellow #eda100,
# red #e34948) on light surface #fcfcfb; sequential = single-hue blue ramp; all
# series direct-labeled (aqua/yellow sit below 3:1 → relief via labels).

# %%
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SURFACE, INK, MUTED = "#fcfcfb", "#0b0b0b", "#52514e"
BLUE, AQUA, YELLOW, RED = "#2a78d6", "#1baf7a", "#eda100", "#e34948"
GRID = "#e4e3df"
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "text.color": INK, "axes.edgecolor": MUTED, "axes.labelcolor": MUTED,
    "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
    "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 150,
})

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
        k = max((sf > 0).argmax(), 1)
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
# ## 6. Persist results

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
