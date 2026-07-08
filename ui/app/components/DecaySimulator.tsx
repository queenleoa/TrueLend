"use client";

import { useMemo } from "react";
import { chunkSize, tickToPrice, depthFraction, priceToTick } from "@/lib/tick";
import { Eyebrow } from "./ui";
import { fmt } from "@/lib/format";

// Projects a position's chunk-by-chunk decay path if the price HELD at a chosen
// level inside its range — using the exact ChunkMath port. This turns the
// whitepaper's "gradual and self-repaying" claim into something you can drag.

const W = 820;
const H = 220;
const PAD = { t: 14, r: 14, b: 28, l: 46 };

export function DecaySimulator({
  collateral,
  debt,
  ltBps,
  holdPrice,
  entryPrice,
}: {
  collateral: number;
  debt: number;
  ltBps: number;
  holdPrice: number; // price the sim holds the pool at
  entryPrice: number;
}) {
  const path = useMemo(() => {
    if (collateral <= 0 || debt <= 0) return null;
    const startPrice = debt / ((ltBps / 10_000) * collateral); // P_liq
    const endPrice = startPrice / Math.SQRT2; // ~√2 range
    const startTick = priceToTick(startPrice);
    const endTick = priceToTick(endPrice);
    const holdTick = priceToTick(holdPrice);

    // simulate: 60s interval, 100 target chunks, cap 1% of a nominal deep book
    let coll = collateral;
    let d = debt;
    let penaltyPaid = 0;
    const pts: { step: number; coll: number; debt: number }[] = [{ step: 0, coll, debt: d }];
    const depth = depthFraction(holdTick, startTick, endTick); // constant while price holds
    const pressure = 0.02; // small position vs deep demo book
    for (let step = 1; step <= 240 && coll > 1e-9 && d > 1e-9; step++) {
      const c = chunkSize({
        remaining: coll,
        targetChunks: 100,
        elapsedSec: 60,
        intervalSec: 60,
        timeCapX: 5,
        depthBps: depth * 10_000,
        pressureBps: pressure * 10_000,
        maxChunk: coll, // demo book deep enough that the cap doesn't bind
      });
      if (c <= 0) break;
      const proceeds = c * holdPrice; // sell collateral at the held price
      const penaltyRate = Math.min(0.005 * (ltBps / 10_000) * 1, (1 - ltBps / 10_000) / 4);
      const penalty = proceeds * penaltyRate;
      penaltyPaid += penalty;
      const net = proceeds - penalty;
      d = Math.max(0, d - net);
      coll = Math.max(0, coll - c);
      pts.push({ step, coll, debt: d });
    }
    const minutes = pts.length - 1;
    const repaid = d <= 1e-6;
    return { pts, minutes, repaid, penaltyPaid, collLeft: coll, debtLeft: d, startPrice, endPrice };
  }, [collateral, debt, ltBps, holdPrice]);

  if (!path) return null;

  const maxColl = collateral;
  const maxDebt = debt;
  const n = path.pts.length;
  const x = (i: number) => PAD.l + (i / (n - 1 || 1)) * (W - PAD.l - PAD.r);
  const yC = (v: number) => PAD.t + (1 - v / maxColl) * (H - PAD.t - PAD.b);
  const yD = (v: number) => PAD.t + (1 - v / maxDebt) * (H - PAD.t - PAD.b);
  const collLine = path.pts.map((p, i) => `${x(i)},${yC(p.coll)}`).join(" ");
  const debtLine = path.pts.map((p, i) => `${x(i)},${yD(p.debt)}`).join(" ");

  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <Eyebrow>Decay preview · price holds at {holdPrice.toFixed(4)}</Eyebrow>
        <span className="font-mono text-[10px] text-muted">exact ChunkMath</span>
      </div>
      <div className="overflow-x-auto rounded-[10px] border-[0.5px] border-line bg-surface">
        <svg viewBox={`0 0 ${W} ${H}`} width="100%" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Projected collateral and debt decay">
          <polyline points={collLine} fill="none" stroke="var(--accent)" strokeWidth={1.6} />
          <polyline points={debtLine} fill="none" stroke="var(--pos)" strokeWidth={1.6} strokeDasharray="4 3" />
          <text x={x(n - 1)} y={yC(path.collLeft) - 6} textAnchor="end" fontSize={9.5} fontFamily="var(--font-mono)" fill="var(--accent)">
            collateral
          </text>
          <text x={x(n - 1)} y={yD(path.debtLeft) + 12} textAnchor="end" fontSize={9.5} fontFamily="var(--font-mono)" fill="var(--pos)">
            debt
          </text>
          <text x={PAD.l} y={H - 8} fontSize={9} fontFamily="var(--font-mono)" fill="var(--muted)">
            minutes in range →
          </text>
        </svg>
      </div>
      <div className="mt-2 grid grid-cols-3 gap-3 text-[12px]">
        <div>
          <div className="font-mono text-[10px] uppercase tracking-[0.12em] text-muted">Outcome</div>
          <div className="tnum mt-0.5 text-[13px]" style={{ color: path.repaid ? "var(--pos)" : "var(--warn)" }}>
            {path.repaid ? "fully repaid" : "range exhausts first"}
          </div>
        </div>
        <div>
          <div className="font-mono text-[10px] uppercase tracking-[0.12em] text-muted">Time to clear</div>
          <div className="tnum mt-0.5 text-[13px] text-ink">~{path.minutes} min</div>
        </div>
        <div>
          <div className="font-mono text-[10px] uppercase tracking-[0.12em] text-muted">Penalty cost</div>
          <div className="tnum mt-0.5 text-[13px] text-ink">{fmt(path.penaltyPaid, 4)}</div>
        </div>
      </div>
    </div>
  );
}
