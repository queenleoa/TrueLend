# %% [markdown]
# # TrueLend historical-replay backtest
#
# The Monte-Carlo sweep ([`parameters.py`](parameters.py)) answers "is the design safe
# under a *model* of prices?". This notebook answers the harder question: **would the
# production parameters have survived the actual crashes?** Real 1-minute price paths —
# May '21, LUNA, FTX, the USDC depeg, the Aug '24 carry unwind, the Feb '25 crash, plus
# calm controls — are fed through the *same* episode engine ([`engine.py`](engine.py))
# that the simulator uses. One implementation of the mechanism, two sources of paths.
#
# Method, per tier and window:
#   1. Hypothetical positions open every hour at the tier's production LT with the
#      contract's 95% opening headroom. In price terms the liquidation range starts
#      at 0.95 × entry price, independent of LT (LTV/LT = headroom at open).
#   2. An episode begins the first minute the candle LOW touches the range start.
#      The subsequent 24 h of closes (chunk pricing) and lows (backstop detection —
#      conservative) are rebased to the range start and replayed through
#      `engine.run_episodes` with the tier's LIVE-calibrated fee and depth.
#   3. Metrics and acceptance are identical to the sweep (ε tolerances of
#      PARAMETERS.md §2). Episodes inside one window share the crash — they are
#      correlated samples of one macro event, and are reported per window for
#      exactly that reason.
#
# Walk-forward check: for each window, σ and jumps are re-fit on the TRAILING 180
# days only (data a deployer would have had), the closed-form LT_max is recomputed,
# and the production LT is compared against it — parameters chosen ex-ante, tested
# ex-post.
#
# External anchor (PARAMETERS.md §7.4): LLAMMA's published soft-liquidation empirics —
# ≈1% collateral loss for a 10%-below-threshold excursion. Deep replay episodes
# should land in the same order of magnitude.
#
# Run headless:  .venv/bin/python notebooks/backtest.py
# Outputs:       notebooks/figures/backtest_*.png, notebooks/backtest_results.json

# %%
import json
import math
import os

import numpy as np

from engine import (
    TIERS, DEFAULTS, EPS, PRODUCTION, OPEN_HEADROOM,
    chunk_size, penalty_rate, run_episodes, summarize, accepted, simulate,
    lt_max_closed_form,
    SURFACE, INK, MUTED, BLUE, AQUA, YELLOW, RED, apply_style,
)
import calibrate
from calibrate import WINDOWS, load_window_1m, load_hourly, fit_vol, fit_jumps, _ms

HERE = os.path.dirname(os.path.abspath(__file__))
FIGDIR = os.path.join(HERE, "figures")
os.makedirs(FIGDIR, exist_ok=True)

H_HOURS = 24                 # replay horizon per episode
H = H_HOURS * 60             # steps at dt = 60 s
DT = 60.0
OPEN_EVERY_MIN = 60          # hypothetical position opens, one per hour
TRAIL_DAYS = 180             # walk-forward trailing calibration window

CAL = calibrate.load_calibration()


def tier_cal(tier):
    return CAL["tiers"][tier]["cal"]

# %% [markdown]
# ## 1. Episode extraction
#
# `close[t]/range_start` drives chunk pricing; `low[t]/range_start` drives backstop
# detection. Column 0 is the entry candle itself, so a gap straight through the
# range (low far below the start) is seen by the engine exactly as the contract
# would see it: as an immediate range-exhaustion backstop.

# %%
MIN_TAIL = 120  # need at least 2h of data after entry to say anything


def _episode_side(px, worst, side, eps_c, eps_l, valid, meta):
    """Scan one orientation for range entries; append fixed-width H episodes.
    Matrices are padded flat past the window's end and carry a per-episode count
    of REAL steps — the engine deactivates a path at its valid length, so nothing
    is decided on invented data."""
    M = len(px)
    opened = 0
    for t0 in range(0, max(M - MIN_TAIL, 0), OPEN_EVERY_MIN):
        opened += 1
        start = OPEN_HEADROOM * px[t0]             # range start price
        hits = np.nonzero(worst[t0:] <= start)[0]
        if len(hits) == 0:
            continue
        ts = t0 + hits[0]
        n = min(H, M - ts)
        if n < MIN_TAIL:
            continue
        c = np.full(H, np.log(px[ts + n - 1] / start))
        l = np.full(H, np.log(worst[ts + n - 1] / start))
        c[:n] = np.log(px[ts:ts + n] / start)
        l[:n] = np.log(worst[ts:ts + n] / start)
        eps_c.append(c)
        eps_l.append(l)
        valid.append(n)
        meta.append(dict(t0=int(t0), ts=int(ts), n=int(n), side=side))
    return opened


def extract_episodes(candles):
    """candles: (M, 6) [ts, o, h, l, c, v] at 1m.

    BOTH orientations of the pool are replayed: the quoted series (borrower's
    collateral = base asset, adverse = price falling, worst = candle LOW) and its
    inverse (collateral = quote asset, adverse = base pumping, worst = 1/HIGH).
    A v4 pool serves both sides; a pump liquidates the short-side borrower."""
    close, low, high = candles[:, 4], candles[:, 3], candles[:, 2]
    eps_c, eps_l, valid, meta = [], [], [], []
    opened = _episode_side(close, low, "long", eps_c, eps_l, valid, meta)
    opened += _episode_side(1.0 / close, 1.0 / high, "short", eps_c, eps_l, valid, meta)
    if not eps_c:
        return None, None, None, dict(opened=opened, episodes=0)
    return (np.array(eps_c), np.array(eps_l), np.array(valid),
            dict(opened=opened, episodes=len(eps_c), meta=meta))


# %% [markdown]
# ## 2. Replay every window through the engine

# %%
def replay_tier(tier, use_cal=True, depth_override=None):
    cal = dict(tier_cal(tier) if use_cal else TIERS[tier])
    if depth_override is not None:
        cal["depth"] = depth_override
    prod = PRODUCTION[tier]
    per_window, all_raw, all_meta = {}, [], []
    for name, start, end in WINDOWS:
        candles = load_window_1m(tier, name, start, end)
        if candles is None:
            per_window[name] = dict(skipped="symbol not trading in this window")
            continue
        logC, logL, valid, info = extract_episodes(candles)
        if logC is None:
            per_window[name] = dict(opened=info["opened"], episodes=0)
            continue
        raw = run_episodes(logC, cal["fee"], cal["depth"], prod["lt"], prod["N"],
                           prod["tau"], DEFAULTS["kappa"], DT, f=DEFAULTS["f"],
                           logP_worst=logL, valid_steps=valid)
        m = summarize(raw, meta=dict(window=name))
        m["opened"] = info["opened"]
        per_window[name] = m
        all_raw.append(raw)
        all_meta.extend(dict(window=name, **mm) for mm in info["meta"])
    if not all_raw:
        return dict(per_window=per_window, total=None)
    total_raw = {k: np.concatenate([r[k] for r in all_raw]) for k in
                 ("shortfall", "cost", "duration", "outcome", "max_depth")}
    total_raw["lt"] = prod["lt"]
    total = summarize(total_raw, meta=dict(tier=tier, **prod))
    total["accepted"] = accepted(total)
    return dict(per_window=per_window, total=total, raw=total_raw, meta=all_meta)


replay = {}
print("historical replay — production parameters, live-calibrated fee/depth")
for tier in TIERS:
    replay[tier] = replay_tier(tier)
    t = replay[tier]["total"]
    if t is None:
        print(f"  {tier:<9} no episodes in any window")
        continue
    print(f"  {tier:<9} LT{t['lt']:.0%}: {t['n_episodes']} episodes | "
          f"sfFreq {t['shortfall_freq']:.2%} sev {t['shortfall_sev']:.2%} "
          f"exh {t['exhaustion']:.2%} | cost {t['cost_med_bps']:.0f}/{t['cost_p95_bps']:.0f}bps "
          f"| {'ACCEPT' if t['accepted'] else 'REJECT'}")
    for name, w in replay[tier]["per_window"].items():
        if w.get("episodes") == 0:
            print(f"      {name:<14} {w['opened']} opens, 0 range entries")
        elif "skipped" in w:
            print(f"      {name:<14} skipped ({w['skipped']})")
        else:
            print(f"      {name:<14} {w['n_episodes']:>4} eps | sf {w['shortfall_freq']:.1%} "
                  f"sev {w['shortfall_sev']:.1%} | cost {w['cost_med_bps']:.0f}bps "
                  f"| repaid {w['frac']['repaid']:.0%} rec {w['frac']['recovered']:.0%} "
                  f"bkstp {w['frac']['backstop']:.0%}")

# %% [markdown]
# ## 3. Walk-forward: were the production parameters knowable ex-ante?
#
# Two verdicts per (tier, window), both computed on trailing-180-day data ONLY:
# the closed-form LT_max (the deliberately conservative screen — it charges the
# 99th-percentile drift against the whole episode), and a full trailing-calibrated
# SIMULATION at the production parameters (the actual acceptance instrument of
# PARAMETERS.md §7). The simulation is the decider; the closed form is context.

# %%
walk_forward = []
print("\nwalk-forward on trailing 180d (ex-ante data only)")
for tier in TIERS:
    hourly = load_hourly(tier)
    live = tier_cal(tier)
    prod = PRODUCTION[tier]
    for name, start, end in WINDOWS:
        cut = _ms(start)
        trail = hourly[(hourly[:, 0] < cut) & (hourly[:, 0] >= cut - TRAIL_DAYS * 86400_000)]
        if len(trail) < 24 * 60:      # need a real trailing sample
            continue
        close = trail[:, 4]
        vol = fit_vol(close)
        jmp = fit_jumps(close, hours_observed=len(close))
        cal_t = dict(sigma=vol["sigma_p99"] or vol["sigma_med"], lam=jmp["lam"],
                     muJ=jmp["muJ"], sJ=jmp["sJ"], fee=live["fee"], depth=live["depth"])
        ltm = lt_max_closed_form(tier, cal=cal_t)
        sim_t = simulate(tier, prod["lt"], N=prod["N"], tau=prod["tau"], f=DEFAULTS["f"],
                         kappa=DEFAULTS["kappa"], seed=hash((tier, name)) % 2**31,
                         cal=cal_t)
        sim_ok = accepted(sim_t)
        walk_forward.append(dict(
            tier=tier, window=name, sigma_trailing=vol["sigma_p99"],
            lt_max_trailing_cf=ltm, production_lt=prod["lt"],
            cf_ok=bool(ltm is not None and prod["lt"] <= ltm + 1e-9),
            sim_ok=bool(sim_ok), sim_sf_freq=sim_t["shortfall_freq"],
            sim_exhaustion=sim_t["exhaustion"]))
        print(f"  {tier:<9} {name:<14} σ_trail {vol['sigma_p99']:>7.1%}  "
              f"cf LT_max {ltm if ltm else float('nan'):.3f}  "
              f"sim@prod: sf {sim_t['shortfall_freq']:.2%} exh {sim_t['exhaustion']:.2%} "
              f"{'ACCEPT' if sim_ok else 'REJECT'}")

# %% [markdown]
# ## 4. The LLAMMA anchor
#
# LLAMMA's empirics: a position 10% below its threshold for days loses ≈1% to
# soft-liquidation churn. The analogous replay episodes are those whose worst
# price sank ≥10% under the range start.

# %%
llamma = {}
print("\nLLAMMA anchor — deep episodes (max depth ≥ 10% under range start)")
for tier in TIERS:
    r = replay[tier].get("raw")
    if r is None:
        continue
    deep = r["max_depth"] >= 0.10
    if not deep.any():
        print(f"  {tier:<9} no deep episodes")
        continue
    med = float(np.median(r["cost"][deep]) * 1e4)
    dur = float(np.mean(r["duration"][deep]) / 3600)
    llamma[tier] = dict(n=int(deep.sum()), cost_med_bps=med, dur_mean_h=dur)
    print(f"  {tier:<9} {deep.sum():>4} deep eps | median borrower cost {med:.0f} bps "
          f"(LLAMMA anchor ≈ 100 bps) | mean duration {dur:.1f}h")

# %% [markdown]
# ## 4b. Long-tail depth sensitivity
#
# The live PEPE/WETH v3 book measured only ~$14k one-sided (0.1 units of a $100k
# position) — long-tail v3 liquidity has migrated or died. The replay at that
# depth answers "can TODAY's book host $100k positions?" (no). The sensitivity
# below re-runs at the static design depth (5 units, i.e. a $500k one-sided book
# or a $2.9k position in today's book) to separate the SIZING question from the
# MECHANISM question.

# %%
lt_sens = replay_tier("longtail", depth_override=TIERS["longtail"]["depth"])
t = lt_sens["total"]
if t is not None:
    print(f"\nlongtail at design depth 5.0u: {t['n_episodes']} episodes | "
          f"sfFreq {t['shortfall_freq']:.2%} sev {t['shortfall_sev']:.2%} "
          f"exh {t['exhaustion']:.2%} | cost {t['cost_med_bps']:.0f}bps | "
          f"{'ACCEPT' if t['accepted'] else 'REJECT'}")

# %% [markdown]
# ## 5. Replay vs simulation — does the model's cost distribution match reality?

# %%
sim_ref = {}
for tier in TIERS:
    prod = PRODUCTION[tier]
    sim_ref[tier] = simulate(tier, prod["lt"], N=prod["N"], tau=prod["tau"],
                             f=DEFAULTS["f"], kappa=DEFAULTS["kappa"],
                             seed=hash(("bt", tier)) % 2**31, cal=tier_cal(tier))
    m = sim_ref[tier]
    print(f"  sim({tier}, calibrated): sfFreq {m['shortfall_freq']:.2%} "
          f"cost {m['cost_med_bps']:.0f}bps {'ACCEPT' if accepted(m) else 'reject'}")

# %% [markdown]
# ## 6. Figures

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


# --- outcome mix per tier/window -------------------------------------------------------
def fig_outcomes():
    rows = []
    for tier in TIERS:
        for name, w in replay[tier]["per_window"].items():
            if w.get("n_episodes"):
                rows.append((f"{tier}\n{name}", w["frac"]))
    if not rows:
        return
    labels = [r[0] for r in rows]
    comps = [("repaid", BLUE), ("recovered", AQUA), ("backstop", YELLOW), ("live", RED)]
    fig, ax = plt.subplots(figsize=(7.4, 0.62 * len(rows) + 1.4))
    y = np.arange(len(rows))[::-1]
    for yi, (_, frac) in zip(y, rows):
        left = 0.0
        for key, colr in comps:
            v = frac.get(key, 0.0) * 100
            ax.barh(yi, v, left=left, height=0.55, color=colr, edgecolor=SURFACE, lw=2)
            if v > 6:
                ax.text(left + v / 2, yi, f"{v:.0f}", ha="center", va="center", fontsize=8,
                        color=SURFACE if colr in (BLUE, RED) else INK)
            left += v
    ax.set_yticks(y, labels, fontsize=8)
    ax.set_xlabel("% of episodes")
    ax.set_xlim(0, 100)
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, c in comps]
    ax.legend(handles, [k for k, _ in comps], loc="lower right", frameon=False, fontsize=8,
              ncol=4)
    ax.set_title("Replay outcomes by tier and window — production parameters",
                 fontsize=10.5, loc="left")
    _save(fig, "backtest_outcomes.png")


# --- replay vs simulated borrower-cost distributions ------------------------------------
def fig_cost_vs_sim():
    fig, axes = plt.subplots(1, 3, figsize=(9.6, 3.2), sharey=True)
    for ax, tier in zip(axes, TIERS):
        r = replay[tier].get("raw")
        ax.set_title(tier, fontsize=9.5, loc="left")
        ax.set_xlabel("borrower cost (bps)")
        if r is None or not len(r["cost"]):
            ax.text(0.5, 0.5, "no episodes", transform=ax.transAxes, ha="center",
                    fontsize=9, color=MUTED)
            continue
        for cost, colr, label in ((sim_ref[tier]["cost_samples"], MUTED, "simulated"),
                                  (r["cost"], BLUE, "replayed")):
            c = np.sort(cost * 1e4)
            ax.plot(c, np.linspace(0, 100, len(c)), color=colr, lw=1.8)
            ax.text(c[-1], 97 if colr == BLUE else 88, label, fontsize=8, color=colr,
                    ha="right", va="bottom")
        ax.set_xscale("symlog", linthresh=10)
    axes[0].set_ylabel("% of episodes ≤ x")
    fig.suptitle("Borrower cost: historical replay vs calibrated simulation (CDF)",
                 fontsize=10.5, x=0.02, ha="left")
    _save(fig, "backtest_cost_vs_sim.png")


# --- walk-forward LT_max vs production LT ----------------------------------------------
def fig_walkforward():
    fig, ax = plt.subplots(figsize=(7.4, 3.4))
    tiers = list(TIERS)
    colors = {"stable": BLUE, "major": AQUA, "longtail": YELLOW}
    win_names = [w[0] for w in WINDOWS]
    xs = np.arange(len(win_names))
    for tier in tiers:
        pts = {w["window"]: w["lt_max_trailing_cf"] for w in walk_forward if w["tier"] == tier}
        y = [pts.get(n, np.nan) for n in win_names]
        ax.plot(xs, y, "o-", color=colors[tier], lw=1.6, ms=5, mfc=SURFACE, mew=1.4)
        ax.axhline(PRODUCTION[tier]["lt"], color=colors[tier], lw=1, ls=(0, (4, 3)))
        lbl_y = [v for v in y if not (isinstance(v, float) and math.isnan(v))]
        if lbl_y:
            ax.text(len(win_names) - 0.85, lbl_y[-1], f"{tier} LT_max^cf",
                    fontsize=8, color=colors[tier], va="bottom")
        ax.text(-0.4, PRODUCTION[tier]["lt"] + 0.002, f"{tier} production LT",
                fontsize=7.5, color=colors[tier], va="bottom")
    ax.set_xticks(xs, win_names, rotation=30, ha="right", fontsize=8)
    ax.set_ylabel("LT")
    ax.set_title("Walk-forward: trailing-180d closed-form LT_max (markers) vs "
                 "production LT (dashed)", fontsize=10.5, loc="left")
    _save(fig, "backtest_walkforward.png")


# --- worst replay episode, drawn -------------------------------------------------------
def fig_worst():
    # worst episode that actually shows the mechanism (≥30 min of life) — an
    # instant gap-through draws two flat lines and teaches nothing
    worst = None
    for tier in TIERS:
        r = replay[tier].get("raw")
        if r is None or not len(r["cost"]):
            continue
        elig = np.nonzero(r["duration"] >= 1800)[0]
        if not len(elig):
            continue
        score = r["shortfall"][elig] * 1e6 + r["cost"][elig]
        k = int(elig[np.argmax(score)])
        cand = (tier, k, float(r["shortfall"][k]), float(r["cost"][k]))
        if worst is None or (cand[2], cand[3]) > (worst[2], worst[3]):
            worst = cand
    if worst is None:
        return
    tier, k, _, _ = worst
    meta = replay[tier]["meta"][k]
    prod, cal = PRODUCTION[tier], tier_cal(tier)
    wname = meta["window"]
    span = next(w for w in WINDOWS if w[0] == wname)
    candles = load_window_1m(tier, *span)
    ts, n = meta["ts"], meta["n"]
    px, wr = candles[:, 4], candles[:, 3]
    if meta.get("side") == "short":
        px, wr = 1.0 / candles[:, 4], 1.0 / candles[:, 2]
    start = OPEN_HEADROOM * px[meta["t0"]]
    P = px[ts:ts + n] / start
    Pl = wr[ts:ts + n] / start

    # scalar re-run of the engine for the time series (same semantics)
    from engine import health_buffer, fc_impact
    lt, N, tau, f = prod["lt"], prod["N"], prod["tau"], DEFAULTS["f"]
    X, fee = cal["depth"], cal["fee"]
    H_fig = n
    C = np.ones(H_fig + 1); D = np.full(H_fig + 1, lt)
    last, til = -tau, 0.0
    end_k = H_fig
    for i in range(1, H_fig + 1):
        C[i], D[i] = C[i - 1], D[i - 1]
        p, pl, now = P[i - 1], Pl[i - 1], i * DT
        if pl < 1 / f or C[i] * pl * (1 - health_buffer(lt)) < D[i]:
            proceeds = C[i] * pl * (1 - fee - float(fc_impact(C[i], X)))
            D[i] = max(D[i] - proceeds * (1 - penalty_rate(lt, til)), 0.0)
            C[i] = 0.0
            end_k = i
            break
        if 1 / f <= p <= 1.0:
            til += DT
            if now - last >= tau:
                d01 = min(max(-math.log(p) / math.log(f), 0), 1)
                x = chunk_size(C[i], N, now - last, tau, 5, d01, min(C[i] / X, 1), 0, 0.01 * X)
                slip = x / (2 * X) + fee
                D[i] -= x * p * (1 - slip) * (1 - penalty_rate(lt, til))
                C[i] -= x
                last = now
        if D[i] <= 0:
            end_k = i
            break
    tt = np.arange(H_fig + 1) * DT / 3600
    ke = end_k  # position series end at close; price continues (shows the aftermath)
    fig, (a, b) = plt.subplots(2, 1, figsize=(7.2, 4.6), sharex=True,
                               gridspec_kw=dict(height_ratios=[1.1, 1]))
    a.axhline(1.0, color=RED, lw=1, ls=(0, (4, 3)))
    a.axhline(1 / f, color=RED, lw=1)
    a.plot(tt[1:], Pl, color=MUTED, lw=0.7)
    a.plot(tt[1:], P, color=BLUE, lw=1.4)
    a.set_ylabel("price / range start")
    a.text(tt[-1] * 0.99, 1.005, "range start", ha="right", fontsize=8, color=RED)
    a.text(tt[-1] * 0.99, 1 / f + 0.005, "range end (backstop past this)", ha="right",
           fontsize=8, color=RED)
    a.text(0.2, float(Pl[: max(len(Pl) // 6, 1)].min()), "candle lows (backstop trigger)",
           fontsize=7.5, color=MUTED, va="top")
    b.plot(tt[:ke + 1], C[:ke + 1], color=BLUE, lw=1.8)
    b.plot(tt[:ke + 1], D[:ke + 1] / lt, color=AQUA, lw=1.8)
    b.set_ylabel("fraction of initial")
    b.set_xlabel(f"hours since range entry — {tier}, {wname}, {meta.get('side', 'long')} side")
    lx = min(tt[ke] + 0.4, tt[-1] * 0.82)
    b.text(lx, max(C[ke], 0.02) + 0.04, "collateral", fontsize=8.5, color=BLUE)
    b.text(lx, D[ke] / lt + 0.16, "debt (residual = lender shortfall)", fontsize=8.5,
           color=AQUA)
    if ke < H_fig:
        b.axvline(tt[ke], color=MUTED, lw=0.8, ls=(0, (3, 3)))
        b.text(tt[ke] + 0.15, 0.62, "position closed by backstop —\nprice later recovered",
               fontsize=7.5, color=MUTED)
    a.set_title(f"Worst replay episode — {tier} tier, {wname} window, production LT "
                f"{lt:.0%}", fontsize=10.5, loc="left")
    _save(fig, "backtest_worst.png")


fig_outcomes(); fig_cost_vs_sim(); fig_walkforward(); fig_worst()

# %% [markdown]
# ## 7. Persist results

# %%
def _clean(m):
    return {k: v for k, v in m.items() if not isinstance(v, np.ndarray)}


out = dict(
    horizon_h=H_HOURS, dt_s=DT, open_every_min=OPEN_EVERY_MIN,
    production=PRODUCTION, tolerances=EPS,
    calibration_generated_at=CAL["generated_at"],
    tiers={t: dict(total=_clean(replay[t]["total"]) if replay[t]["total"] else None,
                   per_window={n: _clean(w) for n, w in replay[t]["per_window"].items()})
           for t in TIERS},
    longtail_design_depth_sensitivity=_clean(lt_sens["total"]) if lt_sens["total"] else None,
    walk_forward=walk_forward,
    llamma_anchor=llamma,
    sim_reference={t: _clean({k: v for k, v in sim_ref[t].items()
                              if k not in ("shortfall_samples", "cost_samples", "outcome")})
                   for t in TIERS},
)
with open(os.path.join(HERE, "backtest_results.json"), "w") as fh:
    json.dump(out, fh, indent=2)
print("wrote notebooks/backtest_results.json")
