# TrueLend live calibration — PARAMETERS.md §7.4 made executable.
#
# Produces notebooks/calibration.json: per-tier {sigma, lam, muJ, sJ, fee, depth}
# in exactly the shape of an engine.TIERS entry, so calibrated values flow into
# the closed forms, the Monte-Carlo sweep, and the backtest via the `cal=` hook.
#
#   1. Volatility  — 1h OHLCV since 2020-11 (ccxt, exchange fallback chain),
#                    30-day rolling realized vol, annualized; σ = its 99th pct.
#   2. Jumps       — returns beyond 4× a 7-day rolling σ are jumps; intensity =
#                    count / observed years; (muJ, sJ) = mean/std of jump sizes.
#   3. Depth       — live Uniswap v3 mainnet pools (deepest venue per tier):
#                    slot0 + active liquidity via raw eth_call, projected over a
#                    √2 range, valued in USD, expressed in units of a $100k
#                    reference position (the same convention as engine.TIERS).
#   4. κ (refill)  — left at the static 0.9: estimating arbitrage refill needs
#                    trade-level data; flagged in the output.
#
# Run:  .venv/bin/python notebooks/calibrate.py
# Data cache: notebooks/data/*.csv.gz (committed — reruns are offline-stable;
# delete a file to force a refetch).

import gzip
import io
import json
import math
import os
import time
from datetime import datetime, timezone

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATADIR = os.path.join(HERE, "data")
os.makedirs(DATADIR, exist_ok=True)

HOURS_PER_YEAR = 24 * 365
VOL_WINDOW_H = 24 * 30          # 30-day realized-vol window
JUMP_LOCAL_H = 24 * 7           # local-σ window for jump detection
JUMP_K = 4.0                    # |r| > K·σ_local ⇒ jump
HISTORY_SINCE = "2020-11-01"    # covers trailing windows for every backtest episode
REF_POSITION_USD = 100_000.0

# tier -> (preferred symbol, [(exchange, symbol), ...fallbacks])
MARKETS = {
    # coinbase carries USDT/USDC (inverse orientation — harmless: fits are
    # two-sided and the backtest replays both sides) through the six months
    # binance had USDC delisted, including the March 2023 depeg itself
    "stable": [("binance", "USDC/USDT"), ("okx", "USDC/USDT"),
               ("coinbase", "USDT/USDC"), ("kraken", "USDT/USD")],
    "major": [("binance", "ETH/USDT"), ("okx", "ETH/USDT"), ("kraken", "ETH/USD")],
    "longtail": [("binance", "PEPE/USDT"), ("okx", "PEPE/USDT"), ("kraken", "PEPE/USD")],
}

# historical replay windows (UTC date spans). Stress selections follow
# PARAMETERS.md §7.4: the named crash weeks; two calm controls.
WINDOWS = [
    ("may21-crash", "2021-05-16", "2021-05-23"),
    ("luna", "2022-05-08", "2022-05-15"),
    ("ftx", "2022-11-06", "2022-11-13"),
    ("usdc-depeg", "2023-03-09", "2023-03-16"),
    ("carry-unwind", "2024-08-02", "2024-08-09"),
    ("feb25-crash", "2025-02-01", "2025-02-08"),
    ("calm-jul23", "2023-07-10", "2023-07-17"),
    ("calm-oct24", "2024-10-07", "2024-10-14"),
]

# Uniswap v3 mainnet pools (deepest venue per tier). Addresses are resolved from
# the v3 factory at run time (getPool) — only tokens and fee are pinned.
V3_FACTORY = "0x1F98431c8aD98523631AE4a59f267346ea31F984"
TOKENS = dict(
    USDC="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    USDT="0xdAC17F958D2ee523a2206206994597C13D831ec7",
    WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    PEPE="0x6982508145454Ce325dDbE47a25d4ec3d2311933",
)
POOLS = {
    "stable": dict(t0="USDC", t1="USDT", fee_ppm=100, dec0=6, dec1=6, fee=0.0001,
                   risky_is0=False, name="USDC/USDT 1bp"),
    "major": dict(t0="USDC", t1="WETH", fee_ppm=500, dec0=6, dec1=18, fee=0.0005,
                  risky_is0=False, name="USDC/WETH 5bp"),
    # long-tail liquidity migrates between fee tiers; scan both and use the deeper
    "longtail": dict(t0="PEPE", t1="WETH", fee_ppm=(3000, 10000), dec0=18, dec1=18,
                     fee=0.003, risky_is0=True, name="PEPE/WETH"),
}
RPCS = [
    "https://ethereum-rpc.publicnode.com",
    "https://eth.drpc.org",
    "https://1rpc.io/eth",
    "https://eth.llamarpc.com",
    "https://cloudflare-eth.com",
]
Q96 = 2 ** 96


# ---------------------------------------------------------------- OHLCV fetch + cache
def _cache_path(tier, timeframe, tag):
    return os.path.join(DATADIR, f"{tier}_{timeframe}_{tag}.csv.gz")


def _save_ohlcv(path, rows):
    buf = io.StringIO()
    for r in rows:
        buf.write(",".join(str(x) for x in r[:6]) + "\n")
    with gzip.open(path, "wt") as fh:
        fh.write(buf.getvalue())


def _load_ohlcv(path):
    with gzip.open(path, "rt") as fh:
        rows = [line.strip().split(",") for line in fh if line.strip()]
    return np.array([[float(x) for x in r] for r in rows])  # ts, o, h, l, c, v


def _ms(datestr):
    return int(datetime.strptime(datestr, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp() * 1000)


def fetch_ohlcv(tier, timeframe, since_ms, until_ms, tag):
    """Paginated fetch with an exchange fallback chain, cached to data/.

    Venues are tried in order, but partial listings matter (Binance delisted
    USDC/USDT for six months around the very depeg being studied): the first
    venue covering ≥90% of the requested span wins immediately; otherwise the
    fullest coverage across the chain is kept."""
    path = _cache_path(tier, timeframe, tag)
    if os.path.exists(path):
        return _load_ohlcv(path)

    import ccxt
    tf_ms = 60_000 if timeframe == "1m" else 3_600_000
    expected = max((until_ms - since_ms) / tf_ms, 1)
    best, best_src = None, None
    last_err = None
    for exch_name, symbol in MARKETS[tier]:
        try:
            ex = getattr(ccxt, exch_name)({"enableRateLimit": True})
            ex.load_markets()
            if symbol not in ex.markets:
                continue
            rows, cursor = [], since_ms
            while cursor < until_ms:
                batch = ex.fetch_ohlcv(symbol, timeframe, since=cursor, limit=1000)
                if not batch:
                    break
                rows.extend(b for b in batch if b[0] < until_ms)
                nxt = batch[-1][0] + 1
                if nxt <= cursor:
                    break
                cursor = nxt
                if len(batch) < 2:
                    break
            if rows and (best is None or len(rows) > len(best)):
                best, best_src = rows, f"{exch_name} {symbol}"
            if rows and len(rows) >= 0.9 * expected:
                break
        except Exception as e:  # noqa: BLE001 — try the next venue
            last_err = e
            continue
    if best:
        print(f"  {tier}/{timeframe}/{tag}: {len(best)} candles from {best_src} "
              f"({len(best) / expected:.0%} coverage)")
        _save_ohlcv(path, best)
        return _load_ohlcv(path)
    raise RuntimeError(f"no venue served {tier} {timeframe} {tag}: {last_err}")


def load_hourly(tier):
    now_ms = int(time.time() * 1000)
    return fetch_ohlcv(tier, "1h", _ms(HISTORY_SINCE), now_ms, "full")


def load_window_1m(tier, name, start, end):
    try:
        data = fetch_ohlcv(tier, "1m", _ms(start), _ms(end), name)
    except RuntimeError:
        return None
    # symbol not listed yet (e.g. PEPE pre-2023-05): sparse/empty ⇒ skip
    expected = (_ms(end) - _ms(start)) / 60000
    if len(data) < expected * 0.6:
        return None
    return data


# ---------------------------------------------------------------- vol & jump fits
def realized_vol_series(close, window_h=VOL_WINDOW_H):
    """Rolling annualized realized vol over hourly closes."""
    r = np.diff(np.log(close))
    if len(r) < window_h + 1:
        return np.array([])
    sq = np.convolve(r ** 2, np.ones(window_h), "valid") / window_h
    return np.sqrt(sq * HOURS_PER_YEAR)


def fit_vol(close):
    rv = realized_vol_series(close)
    return dict(sigma_p99=float(np.percentile(rv, 99)), sigma_med=float(np.median(rv)),
                n_windows=int(len(rv)))


def fit_jumps(close, hours_observed):
    """Threshold detector: |r| beyond JUMP_K × a 7-day local σ is a jump.

    The calibration constants (muJ, sJ) reflect every detected jump into the
    ADVERSE direction: a pool serves borrowers on both sides, so a +10% pump is
    a −10% move for whoever borrowed the pumping token. Signed statistics are
    kept in the detail block for reference."""
    r = np.diff(np.log(close))
    if len(r) < JUMP_LOCAL_H + 1:
        return dict(lam=0.0, muJ=0.0, sJ=0.0, n_jumps=0)
    sq = np.convolve(r ** 2, np.ones(JUMP_LOCAL_H), "valid") / JUMP_LOCAL_H
    local = np.sqrt(sq)
    rr = r[JUMP_LOCAL_H:]
    local = local[: len(rr)]
    jumps = rr[np.abs(rr) > JUMP_K * np.maximum(local, 1e-9)]
    years = hours_observed / HOURS_PER_YEAR
    adverse = -np.abs(jumps)
    return dict(lam=float(len(jumps) / max(years, 1e-9)),
                muJ=float(adverse.mean()) if len(jumps) else 0.0,
                sJ=float(adverse.std()) if len(jumps) > 1 else 0.0,
                muJ_signed=float(jumps.mean()) if len(jumps) else 0.0,
                sJ_signed=float(jumps.std()) if len(jumps) > 1 else 0.0,
                n_jumps=int(len(jumps)))


# ---------------------------------------------------------------- on-chain depth
def _eth_call(rpc, to, selector):
    import requests
    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
               "params": [{"to": to, "data": selector}, "latest"]}
    resp = requests.post(rpc, json=payload, timeout=10)
    resp.raise_for_status()
    out = resp.json()
    if "result" not in out or out["result"] in (None, "0x"):
        raise RuntimeError(f"empty eth_call result: {out}")
    return out["result"]


_pool_addr_cache = {}


def resolve_pool(tier, fee_ppm):
    """Ask the v3 factory for the pool address (getPool selector 0x1698ee82)."""
    key = (tier, fee_ppm)
    if key in _pool_addr_cache:
        return _pool_addr_cache[key]
    p = POOLS[tier]
    data = ("0x1698ee82"
            + TOKENS[p["t0"]][2:].lower().rjust(64, "0")
            + TOKENS[p["t1"]][2:].lower().rjust(64, "0")
            + hex(fee_ppm)[2:].rjust(64, "0"))
    last_err = None
    for rpc in RPCS:
        try:
            out = _eth_call(rpc, V3_FACTORY, data)
            addr = "0x" + out[-40:]
            if int(addr, 16) == 0:
                raise RuntimeError(f"factory has no {p['name']} pool at {fee_ppm}")
            _pool_addr_cache[key] = addr
            return addr
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    raise RuntimeError(f"pool resolution failed for {tier}: {last_err}")


def read_pool(addr):
    """slot0.sqrtPriceX96 + active liquidity, first RPC that answers."""
    last_err = None
    for rpc in RPCS:
        try:
            slot0 = _eth_call(rpc, addr, "0x3850c7bd")
            liq = _eth_call(rpc, addr, "0x1a686502")
            sqrt_p = int(slot0[2:66], 16)
            liquidity = int(liq, 16)
            return sqrt_p, liquidity, rpc
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    raise RuntimeError(f"all RPCs failed for {addr}: {last_err}")


def pool_depth(tier, eth_usd=None):
    """One-sided token depth across a √2 range at constant active liquidity —
    the same approximation the hook itself uses (LiqRangeMath.rangeDepthTokens).
    When a tier lists several fee tiers, the deepest pool wins."""
    p = POOLS[tier]
    fee_tiers = p["fee_ppm"] if isinstance(p["fee_ppm"], tuple) else (p["fee_ppm"],)
    best = None
    for fee_ppm in fee_tiers:
        try:
            sqrt_p, L, rpc = read_pool(resolve_pool(tier, fee_ppm))
        except RuntimeError:
            continue
        sp = sqrt_p / Q96
        price_1per0 = sp ** 2 * 10 ** (p["dec0"] - p["dec1"])  # token1 per token0, human
        root = 2 ** 0.25                                       # price factor √2 in sqrt terms

        if p["risky_is0"]:
            # selling token0 as price falls: token0 absorbed between P/√2 and P
            lo = sp / root
            amt = L * (sp - lo) / (lo * sp)                    # raw token0
            tokens = amt / 10 ** p["dec0"]
            usd = tokens * price_1per0 * (eth_usd if eth_usd else 1.0)  # token1 is WETH
        else:
            # selling token1 as price rises: token1 absorbed between P and P·√2
            hi = sp * root
            amt = L * (hi - sp)                                # raw token1
            tokens = amt / 10 ** p["dec1"]
            usd = tokens * (eth_usd if tier == "major" else 1.0)
        cand = dict(pool=f"{p['name']} {fee_ppm/1e6:.2%}", rpc=rpc, price_1per0=price_1per0,
                    depth_tokens=tokens, depth_usd=usd,
                    depth_units_100k=usd / REF_POSITION_USD)
        if best is None or cand["depth_usd"] > best["depth_usd"]:
            best = cand
    if best is None:
        raise RuntimeError(f"no pool answered for {tier}")
    return best


# ---------------------------------------------------------------- assembly
def calibrate(offline_ok=True):
    from engine import TIERS, lt_max_closed_form

    out = {"generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "history_since": HISTORY_SINCE, "kappa": dict(value=0.9, source="static — "
           "arbitrage-refill estimation needs trade-level data; not yet calibrated"),
           "tiers": {}}

    # ETH/USD from the major pool for USD-valuing WETH/PEPE depth
    eth_usd = None
    try:
        sqrt_p, _, _ = read_pool(resolve_pool("major", 500))
        sp = sqrt_p / Q96
        eth_usd = 1.0 / (sp ** 2 * 10 ** (6 - 18))  # USDC per WETH
        print(f"ETH/USD from pool: {eth_usd:,.0f}")
    except Exception as e:  # noqa: BLE001
        print(f"ETH/USD unavailable ({e}); depth will fall back to static")

    for tier in MARKETS:
        print(f"[{tier}]")
        hourly = load_hourly(tier)
        close = hourly[:, 4]
        vol = fit_vol(close)
        jumps = fit_jumps(close, hours_observed=len(close))

        depth = None
        try:
            depth = pool_depth(tier, eth_usd=eth_usd)
            print(f"  depth: {depth['depth_usd']:,.0f} USD one-sided over √2 range "
                  f"({depth['pool']})")
        except Exception as e:  # noqa: BLE001
            if not offline_ok:
                raise
            print(f"  depth unavailable ({e}); using static")
            depth = dict(pool="offline-fallback", depth_usd=None,
                         depth_units_100k=TIERS[tier]["depth"])

        cal = dict(sigma=vol["sigma_p99"], lam=jumps["lam"], muJ=jumps["muJ"],
                   sJ=jumps["sJ"], fee=POOLS[tier]["fee"],
                   depth=depth["depth_units_100k"])
        static = TIERS[tier]
        out["tiers"][tier] = dict(
            cal=cal,
            detail=dict(vol=vol, jumps=jumps, depth=depth),
            static=static,
            lt_max_closed_form=dict(
                static=round(lt_max_closed_form(tier), 3),
                calibrated=round(lt_max_closed_form(tier, cal=cal), 3),
            ),
        )
        print(f"  σ_p99 {vol['sigma_p99']:.1%} (static {static['sigma']:.0%})   "
              f"λ {jumps['lam']:.0f}/yr (static {static['lam']})   "
              f"jump μ {jumps['muJ']:+.2%} s {jumps['sJ']:.2%}   "
              f"depth {cal['depth']:.1f}u (static {static['depth']})")
        print(f"  closed-form LT_max: static {out['tiers'][tier]['lt_max_closed_form']['static']}"
              f" → calibrated {out['tiers'][tier]['lt_max_closed_form']['calibrated']}")

    with open(os.path.join(HERE, "calibration.json"), "w") as fh:
        json.dump(out, fh, indent=2)
    print("wrote notebooks/calibration.json")
    return out


def load_calibration():
    path = os.path.join(HERE, "calibration.json")
    with open(path) as fh:
        return json.load(fh)


if __name__ == "__main__":
    calibrate()
