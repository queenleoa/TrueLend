"use client";

import { useMemo } from "react";
import { usePoolHistory, TimelineEvent } from "@/lib/events";
import { tickToPrice } from "@/lib/tick";
import { Eyebrow, Pill } from "./ui";

// The signature view: price over time as the pool's tick, with each position's
// liquidation EPISODE (started → paused/closed) shaded, and chunk executions
// marked. This is "liquidation as a process" made visible — the thing no
// conventional lending UI can show.

const W = 900;
const H = 300;
const PAD = { t: 20, r: 16, b: 34, l: 56 };

export function LiquidationTimeline() {
  const { events, loading } = usePoolHistory();

  const model = useMemo(() => {
    const priced = events.filter((e) => e.tick !== undefined && (e.kind === "price" || e.kind === "started"));
    if (priced.length < 2) return null;

    const t0 = priced[0].ts;
    const t1 = priced[priced.length - 1].ts || t0 + 1;
    const prices = priced.map((e) => tickToPrice(e.tick!));
    let pMin = Math.min(...prices);
    let pMax = Math.max(...prices);
    const span = pMax - pMin || pMax * 0.02;
    pMin -= span * 0.12;
    pMax += span * 0.12;

    const x = (ts: number) => PAD.l + ((ts - t0) / (t1 - t0 || 1)) * (W - PAD.l - PAD.r);
    const y = (p: number) => PAD.t + (1 - (p - pMin) / (pMax - pMin || 1)) * (H - PAD.t - PAD.b);

    // price polyline from price+started ticks in time order
    const line = priced.map((e) => `${x(e.ts)},${y(tickToPrice(e.tick!))}`).join(" ");

    // episodes: pair each `started` with the next `paused`/`closed` for the same id
    const byId: Record<string, TimelineEvent[]> = {};
    events.forEach((e) => {
      if (e.positionId) (byId[e.positionId] ??= []).push(e);
    });
    const episodes: { x0: number; x1: number }[] = [];
    Object.values(byId).forEach((list) => {
      let openTs: number | null = null;
      list.forEach((e) => {
        if (e.kind === "started") openTs = e.ts;
        else if ((e.kind === "paused" || e.kind === "closed") && openTs !== null) {
          episodes.push({ x0: x(openTs), x1: x(e.ts) });
          openTs = null;
        }
      });
      if (openTs !== null) episodes.push({ x0: x(openTs), x1: x(t1) }); // still liquidating
    });

    const chunks = events
      .filter((e) => e.kind === "chunk")
      .map((e) => {
        const near = priced.reduce((a, b) => (Math.abs(b.ts - e.ts) < Math.abs(a.ts - e.ts) ? b : a));
        return { cx: x(e.ts), cy: y(tickToPrice(near.tick!)) };
      });

    const closes = events.filter((e) => e.kind === "closed");

    // y gridlines
    const ticks = 4;
    const grid = Array.from({ length: ticks + 1 }, (_, i) => {
      const p = pMin + ((pMax - pMin) * i) / ticks;
      return { yy: y(p), label: p.toFixed(4) };
    });

    return { line, episodes, chunks, grid, x, t0, t1, closes: closes.length };
  }, [events]);

  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <Eyebrow>Liquidation timeline</Eyebrow>
        <div className="flex items-center gap-2">
          <Pill tone="neg">liquidating</Pill>
          <Pill tone="muted">chunk</Pill>
        </div>
      </div>

      {!model ? (
        <div className="flex h-[300px] items-center justify-center rounded-[10px] border-[0.5px] border-line bg-surface text-[13px] text-muted">
          {loading ? "Reading pool history…" : "No price history in the recent window yet — swaps will populate this."}
        </div>
      ) : (
        <div className="overflow-x-auto rounded-[10px] border-[0.5px] border-line bg-surface">
          <svg viewBox={`0 0 ${W} ${H}`} width="100%" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Pool price and liquidation episodes over time">
            {model.grid.map((g, i) => (
              <g key={i}>
                <line x1={PAD.l} x2={W - PAD.r} y1={g.yy} y2={g.yy} stroke="var(--line)" strokeWidth={0.5} />
                <text x={PAD.l - 8} y={g.yy + 3} textAnchor="end" fontSize={9} fontFamily="var(--font-mono)" fill="var(--muted)">
                  {g.label}
                </text>
              </g>
            ))}
            {/* liquidation episodes as shaded bands */}
            {model.episodes.map((ep, i) => (
              <rect key={i} x={ep.x0} y={PAD.t} width={Math.max(2, ep.x1 - ep.x0)} height={H - PAD.t - PAD.b} fill="var(--neg)" opacity={0.09} />
            ))}
            {/* price line */}
            <polyline points={model.line} fill="none" stroke="var(--ink)" strokeWidth={1.4} strokeLinejoin="round" />
            {/* chunk marks */}
            {model.chunks.map((c, i) => (
              <circle key={i} cx={c.cx} cy={c.cy} r={2.6} fill="var(--surface)" stroke="var(--neg)" strokeWidth={1.2} />
            ))}
            <text x={PAD.l} y={H - 8} fontSize={9} fontFamily="var(--font-mono)" fill="var(--muted)">
              price (dETH per dUSD) · time →
            </text>
          </svg>
        </div>
      )}

      <p className="mt-2 text-[12px] leading-relaxed text-muted">
        The dark line is the pool&apos;s own tick over time. Shaded spans are live liquidation episodes — a position inside its range,
        decaying. Each ring is one paced chunk selling collateral to repay debt. When the price climbs out of a range, the shading stops:
        decay pauses, and resumes only if the price falls back in.
      </p>
    </div>
  );
}
