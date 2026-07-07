# TrueLend model core — shared by parameters.py (Monte-Carlo sweep),
# calibrate.py (live calibration), and backtest.py (historical replay).
#
# Everything here mirrors the contracts. The chunk engine replica is asserted
# against the Solidity unit-test vectors at import time; a change on-chain that
# is not reflected here fails loudly the next time any model script runs.

import math

import numpy as np

# ---------------------------------------------------------------- protocol constants
# Mirror src/TrueLendHook.sol + VaultFactory.sol. Change here only to model a change there.
YEAR = 365 * 24 * 3600
BASE_PENALTY = 0.005          # 0.5% of proceeds
PENALTY_TIME_CAP = 5.0        # ×5 after 4h in liquidation
TIME_CATCHUP_CAP = 5.0        # pacing catch-up multiplier cap
CHUNK_DEPTH_CAP = 0.01        # one chunk ≤ 1% of in-range depth
HEALTH_BUFFER_CFG = 0.02      # forceClose reason-3 buffer config (slippageBufferBps)
FC_IMPACT_CAP = 0.10          # contract: forceClose slippage bound (FC_MAX_SLIPPAGE_TICKS)
FC_IMPACT_FLOOR = 0.001       # crossing any live book costs something


def fc_impact(collateral, depth_units):
    """Backstop-sale price impact: linear in position/depth like the chunk model,
    floored at 10 bps and capped at the contract's 10% slippage bound."""
    return np.clip(collateral / (2 * depth_units), FC_IMPACT_FLOOR, FC_IMPACT_CAP)
OPEN_HEADROOM = 0.95          # opening LTV ≤ 95% of LT
R_MAX_APR = 0.54              # vault rate at the 90% utilization hard cap


def health_buffer(lt):
    """Contract: buffer capped at half the position's LT gap (TrueLendHook)."""
    return min(HEALTH_BUFFER_CFG, (1 - lt) / 2)


# ---------------------------------------------------------------- tier calibration
# Static first-cut constants (PARAMETERS.md §3.2). calibrate.py produces a live
# counterpart (calibration.json) with the same keys; anything accepting a tier
# name also accepts a `cal` dict override so calibrated values flow through.
TIERS = {
    "stable":   dict(sigma=0.02, lam=2,  muJ=-0.005, sJ=0.003, fee=0.0005, depth=100.0),
    "major":    dict(sigma=0.80, lam=20, muJ=-0.08,  sJ=0.06,  fee=0.0030, depth=20.0),
    "longtail": dict(sigma=1.50, lam=60, muJ=-0.15,  sJ=0.10,  fee=0.0100, depth=5.0),
}
# depth = one-sided in-range book depth in units of the position's collateral (position = 1)

DEFAULTS = dict(N=100, tau=60.0, f=math.sqrt(2), kappa=0.9)
EPS = dict(shortfall_freq=0.01, shortfall_sev=0.05, exhaustion=0.005)  # §2 tolerances

# production per-tier recommendations (RESULTS.md) — used by the backtest
PRODUCTION = {
    "stable":   dict(lt=0.99, N=100, tau=60.0),
    "major":    dict(lt=0.95, N=50,  tau=60.0),
    "longtail": dict(lt=0.90, N=100, tau=60.0),
}


# ---------------------------------------------------------------- engine replica
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


def _check_solidity_vectors():
    """The exact vectors from test/libraries/ChunkMath.t.sol (scaled 1e18 -> 1.0)."""
    def vec(**kw):
        p = dict(remaining=100.0, target_chunks=100, elapsed=60, interval=60, time_cap=5,
                 depth01=0.0, pressure01=0.0, min_chunk=0.001, max_chunk=50.0)
        p.update(kw)
        return chunk_size(p["remaining"], p["target_chunks"], p["elapsed"], p["interval"],
                          p["time_cap"], p["depth01"], p["pressure01"], p["min_chunk"], p["max_chunk"])

    assert vec() == 1.0                                   # test_baseChunk_noMultipliers
    assert vec(elapsed=59) == 0.0                         # test_zeroBeforeInterval
    assert vec(remaining=0) == 0.0                        # test_zeroWhenNothingRemains
    assert vec(elapsed=180) == 3.0                        # test_timeMultiplier catch-up
    assert vec(elapsed=6000) == 5.0                       # ...capped
    assert vec(depth01=1.0) == 2.0                        # test_depthAndPressure
    assert vec(pressure01=1.0) == 2.0
    assert vec(depth01=1.0, pressure01=1.0) == 4.0
    assert vec(depth01=0.5) == 1.5                        # test_halfDepth
    assert vec(max_chunk=0.5) == 0.5                      # test_maxChunkClamp
    assert abs(penalty_rate(0.90, 0) - 0.0045) < 1e-12    # test_penalty_knownValues (45 bps)
    assert abs(penalty_rate(0.90, 3600) - 0.0090) < 1e-12
    assert abs(penalty_rate(0.90, 36000) - 0.0225) < 1e-12


_check_solidity_vectors()


# ---------------------------------------------------------------- closed forms
def closed_forms(tier_name, lt, N=None, tau=None, f=None, cal=None):
    """PARAMETERS.md §4–6 first cuts. `cal` overrides the static tier calibration
    (same keys as a TIERS entry) — this is how live-calibrated inputs flow in."""
    t = cal if cal is not None else TIERS[tier_name]
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


def lt_max_closed_form(tier_name, cal=None, grid=None):
    """Largest LT on `grid` whose buffer inequality 1−LT ≥ s+π+i+μ holds."""
    grid = grid if grid is not None else np.arange(0.50, 0.996, 0.005)
    best = None
    for lt in grid:
        if 1 - lt >= closed_forms(tier_name, float(lt), cal=cal)["rhs"]:
            best = float(lt)
    return best


# ---------------------------------------------------------------- path generation
def jd_paths(t, n_paths, n_steps, dt, seed, antithetic=True):
    """Jump-diffusion exogenous log-price paths relative to the range start
    (log P[0] = 0 at range entry). Antithetic pairing mirrors the diffusion
    normals and the jump sizes around their mean while sharing jump times —
    textbook variance reduction for compound-Poisson jump-diffusions."""
    r = np.random.default_rng(seed)
    sig_dt = t["sigma"] * math.sqrt(dt / YEAR)
    jump_p = t["lam"] * dt / YEAR
    half = (n_paths + 1) // 2 if antithetic else n_paths
    z = r.standard_normal((half, n_steps))
    u = r.random((half, n_steps))
    jn = r.standard_normal((half, n_steps))
    if antithetic:
        z = np.vstack([z, -z])[:n_paths]
        u = np.vstack([u, u])[:n_paths]
        jn = np.vstack([jn, -jn])[:n_paths]
    inc = sig_dt * z - 0.5 * sig_dt ** 2
    inc = inc + np.where(u < jump_p, t["muJ"] + t["sJ"] * jn, 0.0)
    return np.cumsum(inc, axis=1)


# ---------------------------------------------------------------- episode engine
def run_episodes(logP_exo, fee, depth_units, lt, N, tau, kappa, dt, f=None,
                 logP_worst=None, valid_steps=None):
    """Path-agnostic episode engine — full contract semantics over a matrix of
    EXOGENOUS log prices relative to the range start (shape n_paths × n_steps;
    column k is the price at time (k+1)·dt). Own-market impact of the engine's
    chunks is applied on top of the exogenous path via the (1−κ) persistent share,
    so historical paths replay as "what the pool price would have been had these
    chunks also been selling into it".

    logP_worst: optional per-step worst price (e.g. candle lows in a replay),
    used for backstop DETECTION and backstop sale pricing — conservative. The
    gradual-chunk pricing always uses the main path.

    valid_steps: optional per-path count of real data steps (replay windows can
    end mid-episode); a path past its valid length deactivates as outcome 0
    ("live"), never inventing decisions on data that does not exist.

    Backstop sales pay a position/depth-scaled impact (fc_impact), matching the
    contract's slippage-bounded forceClose rather than a flat worst case.

    Episodes start at range entry: price = range start = 1, debt = LT·collateral.
    Outcomes: 0 live · 1 repaid · 2 recovered · 3 backstop-clean · 4 backstop-shortfall.
    """
    f = f or DEFAULTS["f"]
    n_paths, n_steps = logP_exo.shape
    if logP_worst is None:
        logP_worst = logP_exo
    X = depth_units
    P_end = 1.0 / f

    C = np.ones(n_paths)                 # collateral
    D = np.full(n_paths, lt)             # debt = LT · C · P_start
    impact = np.zeros(n_paths)           # persistent own-impact displacement (1-κ share)
    last_chunk = np.full(n_paths, -tau)  # first chunk due immediately
    t_in_liq = np.zeros(n_paths)
    t_above = np.zeros(n_paths)
    cost = np.zeros(n_paths)             # borrower execution+penalty cost, value units
    shortfall = np.zeros(n_paths)
    duration = np.full(n_paths, np.nan)
    max_depth = np.zeros(n_paths)        # deepest price seen below range start (fraction)
    outcome = np.zeros(n_paths, dtype=np.int8)

    active = np.ones(n_paths, dtype=bool)
    for step in range(1, n_steps + 1):
        now = step * dt
        if valid_steps is not None:
            ended = active & (valid_steps < step)
            if ended.any():
                duration[ended] = valid_steps[ended] * dt   # truncated: stays outcome 0
                active &= ~ended
        idx = active
        if not idx.any():
            break
        P = np.exp(logP_exo[:, step - 1]) * (1 - impact)
        Pw = np.exp(logP_worst[:, step - 1]) * (1 - impact)
        np.maximum(max_depth, np.where(idx, 1.0 - Pw, 0.0), out=max_depth)

        in_range = idx & (P <= 1.0) & (P >= P_end)
        above = idx & (P > 1.0)
        t_in_liq[in_range] += dt
        t_above[above] += dt
        t_above[in_range] = 0.0

        # --- backstops: range exhaustion, health breach (at the worst price) ---------
        breach = idx & ((Pw < P_end) | (C * Pw * (1 - health_buffer(lt)) < D))
        if breach.any():
            imp = fc_impact(C[breach], X)
            proceeds = C[breach] * Pw[breach] * (1 - fee - imp)
            pen = proceeds * penalty_rate(lt, t_in_liq[breach])
            net = proceeds - pen
            cost[breach] += C[breach] * Pw[breach] * (fee + imp) + pen
            sf = np.maximum(D[breach] - net, 0.0)
            shortfall[breach] = sf
            duration[breach] = now
            outcome[breach] = np.where(sf > 1e-12, 4, 3)
            C[breach] = 0.0
            D[breach] = 0.0
            active &= ~breach

        # --- due chunks ---------------------------------------------------------------
        due = in_range & active & (now - last_chunk >= tau)
        if due.any():
            depth01 = np.clip(-logP_exo[due, step - 1] / math.log(f), 0, 1)
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
            duration[repaid] = now
            outcome[repaid] = 1
            active &= ~repaid
        recovered = active & (t_above >= 3600.0)
        if recovered.any():
            duration[recovered] = now
            outcome[recovered] = 2
            active &= ~recovered

    still = (outcome == 0) & np.isnan(duration)
    duration[still] = n_steps * dt
    return dict(shortfall=shortfall, cost=cost, duration=duration, outcome=outcome,
                max_depth=max_depth, lt=lt)


def summarize(raw, meta=None):
    """Acceptance metrics over an episode batch (same definitions as the MC sweep)."""
    shortfall, cost, duration, outcome, lt = (
        raw["shortfall"], raw["cost"], raw["duration"], raw["outcome"], raw["lt"])
    sf_pos = shortfall > 1e-12
    live = outcome == 0
    m = dict(
        n_episodes=int(len(outcome)),
        shortfall_freq=float(sf_pos.mean()) if len(outcome) else 0.0,
        shortfall_sev=float((shortfall[sf_pos] / lt).mean()) if sf_pos.any() else 0.0,
        exhaustion=float((outcome >= 3).mean()) if len(outcome) else 0.0,
        cost_med_bps=float(np.median(cost) * 1e4) if len(outcome) else 0.0,
        cost_p95_bps=float(np.percentile(cost, 95) * 1e4) if len(outcome) else 0.0,
        dur_med_h=float(np.median(duration) / 3600) if len(outcome) else 0.0,
        frac=dict(repaid=float((outcome == 1).mean()), recovered=float((outcome == 2).mean()),
                  backstop=float((outcome >= 3).mean()), live=float(live.mean()))
        if len(outcome) else {},
    )
    if meta:
        m.update(meta)
    return m


def accepted(m):
    return (m["shortfall_freq"] <= EPS["shortfall_freq"]
            and m["shortfall_sev"] <= EPS["shortfall_sev"]
            and m["exhaustion"] <= EPS["exhaustion"])


def simulate(tier_name, lt, N, tau, f, kappa, n_paths=4000, dt=12.0, horizon_h=12.0,
             seed=0, cal=None):
    """Monte-Carlo episodes: jump-diffusion paths → engine → metrics (+ samples)."""
    t = cal if cal is not None else TIERS[tier_name]
    n_steps = int(horizon_h * 3600 / dt)
    paths = jd_paths(t, n_paths, n_steps, dt, seed)
    raw = run_episodes(paths, t["fee"], t["depth"], lt, N, tau, kappa, dt, f=f)
    m = summarize(raw, meta=dict(tier=tier_name, lt=lt, N=N, tau=tau, f=f, kappa=kappa))
    m["shortfall_samples"] = raw["shortfall"]
    m["cost_samples"] = raw["cost"]
    m["outcome"] = raw["outcome"]
    return m


# ---------------------------------------------------------------- shared plot style
SURFACE, INK, MUTED = "#fcfcfb", "#0b0b0b", "#52514e"
BLUE, AQUA, YELLOW, RED = "#2a78d6", "#1baf7a", "#eda100", "#e34948"
GRID = "#e4e3df"


def apply_style(plt):
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "text.color": INK, "axes.edgecolor": MUTED, "axes.labelcolor": MUTED,
        "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
        "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 150,
    })
