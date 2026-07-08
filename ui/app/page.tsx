"use client";

import { usePoolView, useVault, useVaultRate } from "@/lib/hooks";
import { usePoolHistory } from "@/lib/events";
import { DEMO, EXPLORER, ADDR } from "@/lib/contracts";
import { toNum, fmt, bps, timeAgo, shortId } from "@/lib/format";
import { Card, Eyebrow, Stat, Pill, Row } from "./components/ui";
import { LiquidityDepth } from "./components/LiquidityDepth";
import { LiquidationTimeline } from "./components/LiquidationTimeline";

export default function PoolPage() {
  const pool = usePoolView();
  const v0 = useVault(DEMO.vault0);
  const v1 = useVault(DEMO.vault1);
  const { events } = usePoolHistory();

  const p = pool.data as
    | {
        enabled: boolean;
        currentTick: number;
        activeLiquidity: bigint;
        queueLength: bigint;
        totalDebt0: bigint;
        totalDebt1: bigint;
        utilizationBps0: bigint;
        utilizationBps1: bigint;
        reserves0: bigint;
        reserves1: bigint;
      }
    | undefined;

  const rate0 = useVaultRate(DEMO.vault0, p?.utilizationBps0);
  const rate1 = useVaultRate(DEMO.vault1, p?.utilizationBps1);

  const currentTick = p ? Number(p.currentTick) : undefined;

  // liquidation ranges from opened positions still on chain (for depth overlay)
  const ranges = events
    .filter((e) => e.kind === "opened" && e.positionId && e.tick !== undefined)
    .map((e) => ({ start: e.tick!, end: e.tick! - 3466, id: e.positionId! }));

  const chunkCount = events.filter((e) => e.kind === "chunk").length;
  const penaltyTotal = events.filter((e) => e.kind === "chunk").reduce((a, e) => a + toNum(e.penalty), 0);
  const lastEvent = events[events.length - 1];

  return (
    <div className="flex flex-col gap-8">
      {/* hero strip */}
      <div className="flex flex-col gap-3">
        <Eyebrow>Demo market · {DEMO.sym0} / {DEMO.sym1}</Eyebrow>
        <h1 className="max-w-2xl text-[26px] font-medium leading-tight tracking-tight text-ink">
          Liquidation as a process, on the pool&apos;s own tick.
        </h1>
        <div className="flex flex-wrap items-center gap-2">
          <Pill tone={p?.enabled ? "pos" : "muted"}>{p?.enabled ? "market live" : "loading"}</Pill>
          <Pill tone={p && p.queueLength > 0n ? "neg" : "muted"}>
            {p ? `${p.queueLength} in liquidation` : "queue —"}
          </Pill>
          <a
            className="font-mono text-[11px] text-muted underline decoration-line-strong underline-offset-2 hover:text-ink"
            href={`${EXPLORER}/address/${ADDR.hook}`}
            target="_blank"
            rel="noreferrer"
          >
            hook {shortId(ADDR.hook)} ↗
          </a>
        </div>
      </div>

      {/* headline stats */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Card>
          <Stat label="Active liquidity" value={fmt(toNum(p?.activeLiquidity))} sub="in-range depth" />
        </Card>
        <Card>
          <Stat label="Chunks executed" value={chunkCount} sub="paced liquidation steps" tone={chunkCount > 0 ? "neg" : "muted"} />
        </Card>
        <Card>
          <Stat label="LP penalties paid" value={fmt(penaltyTotal, 4)} sub={`${DEMO.sym1} to in-range LPs`} tone="pos" />
        </Card>
        <Card>
          <Stat label="Last activity" value={lastEvent ? timeAgo(lastEvent.ts) : "—"} sub={lastEvent?.kind ?? ""} tone="muted" />
        </Card>
      </div>

      {/* the two flagship charts */}
      <Card>
        <LiquidationTimeline />
      </Card>
      <Card>
        <LiquidityDepth currentTick={currentTick} ranges={ranges} />
      </Card>

      {/* vault / LP reward panels */}
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <VaultPanel
          title={`${DEMO.sym0} vault`}
          sub="lenders supply dUSD · borrowers of dUSD pay interest"
          data={v0.data}
          util={p?.utilizationBps0}
          rate={rate0.data as bigint | undefined}
          debt={p?.totalDebt0}
          reserves={p?.reserves0}
          sym={DEMO.sym0}
        />
        <VaultPanel
          title={`${DEMO.sym1} vault`}
          sub="lenders supply dETH · absorbs chunk penalties as LPs"
          data={v1.data}
          util={p?.utilizationBps1}
          rate={rate1.data as bigint | undefined}
          debt={p?.totalDebt1}
          reserves={p?.reserves1}
          sym={DEMO.sym1}
        />
      </div>

      <p className="text-center text-[12px] text-muted">
        Everything above is read live from the deployed contracts on Unichain Sepolia. No indexer, no backend.
      </p>
    </div>
  );
}

function VaultPanel({
  title,
  sub,
  data,
  util,
  rate,
  debt,
  reserves,
  sym,
}: {
  title: string;
  sub: string;
  data: readonly { result?: unknown }[] | undefined;
  util: bigint | undefined;
  rate: bigint | undefined;
  debt: bigint | undefined;
  reserves: bigint | undefined;
  sym: string;
}) {
  const totalAssets = data?.[0]?.result as bigint | undefined;
  const cash = data?.[2]?.result as bigint | undefined;

  return (
    <Card>
      <div className="mb-3 flex items-start justify-between">
        <div>
          <div className="text-[15px] font-medium text-ink">{title}</div>
          <div className="mt-0.5 text-[12px] text-muted">{sub}</div>
        </div>
        <Stat label="Borrow APR" value={bps(rate)} tone="pos" />
      </div>
      <Row k="Total supplied" v={`${fmt(toNum(totalAssets))} ${sym}`} />
      <Row k="Available (cash)" v={`${fmt(toNum(cash))} ${sym}`} />
      <Row k="Borrowed" v={`${fmt(toNum(debt))} ${sym}`} />
      <Row k="Utilization" v={bps(util)} />
      <Row k="Reserves (first-loss)" v={`${fmt(toNum(reserves), 4)} ${sym}`} />
    </Card>
  );
}
