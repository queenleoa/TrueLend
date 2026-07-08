"use client";

import { useMemo } from "react";
import { useLiquidityProfile } from "@/lib/liquidity";
import { tickToPrice } from "@/lib/tick";
import { Eyebrow } from "./ui";
import { fmt } from "@/lib/format";

// Liquidity distribution across ticks — the classic Uniswap depth chart, drawn
// in the TrueLend palette. Overlaid with the open positions' liquidation ranges
// so an LP can see exactly where liquidation flow would land against their book.

const W = 900;
const H = 240;
const PAD = { t: 16, r: 16, b: 30, l: 16 };

type Range = { start: number; end: number; id: string };

export function LiquidityDepth({
  currentTick,
  ranges = [],
}: {
  currentTick: number | undefined;
  ranges?: Range[];
}) {
  const { bars } = useLiquidityProfile(currentTick);

  const model = useMemo(() => {
    if (bars.length === 0 || currentTick === undefined) return null;
    const maxL = Math.max(...bars.map((b) => b.liquidity), 1);
    const tickMin = bars[0].tick;
    const tickMax = bars[bars.length - 1].tick;
    const x = (t: number) => PAD.l + ((t - tickMin) / (tickMax - tickMin || 1)) * (W - PAD.l - PAD.r);
    const bw = (W - PAD.l - PAD.r) / bars.length;
    const h = (l: number) => (l / maxL) * (H - PAD.t - PAD.b);
    return { bars, maxL, x, bw, h, tickMin, tickMax, spotX: x(currentTick) };
  }, [bars, currentTick]);

  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <Eyebrow>Liquidity across ticks</Eyebrow>
        <span className="font-mono text-[10px] text-muted">
          spot {currentTick ?? "—"} · price {currentTick !== undefined ? tickToPrice(currentTick).toFixed(4) : "—"}
        </span>
      </div>

      {!model ? (
        <div className="flex h-[240px] items-center justify-center rounded-[10px] border-[0.5px] border-line bg-surface text-[13px] text-muted">
          Reading pool liquidity…
        </div>
      ) : (
        <div className="overflow-x-auto rounded-[10px] border-[0.5px] border-line bg-surface">
          <svg viewBox={`0 0 ${W} ${H}`} width="100%" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Liquidity distribution across ticks">
            {/* liquidation ranges as red bands behind the bars */}
            {ranges.map((r, i) => {
              const x0 = model.x(Math.min(r.start, r.end));
              const x1 = model.x(Math.max(r.start, r.end));
              return <rect key={i} x={x0} y={PAD.t} width={Math.max(2, x1 - x0)} height={H - PAD.t - PAD.b} fill="var(--neg)" opacity={0.08} />;
            })}
            {/* depth bars */}
            {model.bars.map((b, i) => {
              const bh = model.h(b.liquidity);
              return (
                <rect
                  key={i}
                  x={model.x(b.tick) - model.bw / 2 + 0.5}
                  y={H - PAD.b - bh}
                  width={model.bw - 1}
                  height={bh}
                  rx={1}
                  fill={b.active ? "var(--accent)" : "var(--ink)"}
                  opacity={b.active ? 0.75 : 0.14}
                />
              );
            })}
            {/* spot marker */}
            <line x1={model.spotX} x2={model.spotX} y1={PAD.t - 2} y2={H - PAD.b} stroke="var(--ink)" strokeWidth={1} strokeDasharray="3 3" />
            <text x={model.spotX} y={PAD.t - 5} textAnchor="middle" fontSize={9} fontFamily="var(--font-mono)" fill="var(--ink)">
              spot
            </text>
            <text x={PAD.l} y={H - 8} fontSize={9} fontFamily="var(--font-mono)" fill="var(--muted)">
              ← lower price · tick · higher price →
            </text>
          </svg>
        </div>
      )}
      <p className="mt-2 text-[12px] text-muted">
        In-range liquidity (blue) is what a chunk sells into. Red bands are open positions&apos; liquidation ranges — where decay would
        execute if the price falls to them. Active liquidity: <span className="tnum text-ink">L {fmt((model?.maxL ?? 0) / 1e18)}</span>.
      </p>
    </div>
  );
}
