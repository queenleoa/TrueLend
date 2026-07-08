"use client";

import { useAccount, useReadContract } from "wagmi";
import { erc20Abi } from "viem";
import { useLensPosition } from "@/lib/hooks";
import { useAction, parse } from "@/lib/write";
import { DEMO, ADDR, ABI } from "@/lib/contracts";
import { toNum, fmt, bps, shortId } from "@/lib/format";
import { tickToPrice } from "@/lib/tick";
import { Card, Pill, Row, Stat } from "./ui";

// One borrower position, live: health from the Lens, current tick vs range,
// force-close reason, and a repay action. The health bar is the emotional core.

type LensPos = {
  borrower: string;
  collateral: bigint;
  ltBps: number;
  debt: bigint;
  ltvBps: bigint;
  healthBps: bigint;
  inRange: boolean;
  currentTick: number;
  tickStart: number;
  tickEnd: number;
  currentPenaltyBps: bigint;
  forceCloseReason: number;
};

export function PositionCard({ id }: { id: string }) {
  const { address } = useAccount();
  const pos = useLensPosition(id);
  const act = useAction();
  const p = pos.data as LensPos | undefined;

  const allowance = useReadContract({
    address: DEMO.token1 as `0x${string}`,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, ADDR.hook as `0x${string}`] : undefined,
    query: { enabled: !!address, refetchInterval: 6_000 },
  });

  if (!p || p.borrower === "0x0000000000000000000000000000000000000000") return null;
  if (address && p.borrower.toLowerCase() !== address.toLowerCase()) return null;

  const health = Number(p.healthBps) / 100; // % ; 100 = force-close line
  const healthTone = health >= 130 ? "pos" : health >= 105 ? "warn" : "neg";
  const debt = toNum(p.debt, DEMO.decimals1);
  const state = p.forceCloseReason > 0 ? "backstop-eligible" : p.inRange ? "liquidating" : "healthy";
  const stateTone = p.forceCloseReason > 0 ? "neg" : p.inRange ? "neg" : "pos";

  async function repay() {
    if (!address || !p) return;
    try {
      const amt = p.debt + p.debt / 1000n; // small buffer over debt to fully close
      if ((allowance.data ?? 0n) < amt) await act.approve(DEMO.token1, ADDR.hook, amt * 2n);
      await act.call({ address: ADDR.hook, abi: ABI.hook, functionName: "repay", args: [id, amt] }, "Repaying…");
      act.setStatus("Repaid ✓");
    } catch (e) {
      act.setStatus("Failed: " + (e as Error).message.slice(0, 60));
    }
  }

  return (
    <Card className="flex flex-col gap-3">
      <div className="flex items-start justify-between">
        <div>
          <div className="font-mono text-[11px] text-muted">{shortId(id)}</div>
          <div className="mt-1 text-[15px] font-medium text-ink">
            {fmt(toNum(p.collateral, DEMO.decimals0))} {DEMO.sym0} · LT {(p.ltBps / 100).toFixed(0)}%
          </div>
        </div>
        <Pill tone={stateTone as "pos" | "neg"}>{state}</Pill>
      </div>

      {/* health bar */}
      <div>
        <div className="mb-1 flex items-baseline justify-between">
          <span className="font-mono text-[10px] uppercase tracking-[0.12em] text-muted">Health</span>
          <span className="tnum text-[12px]" style={{ color: `var(--${healthTone})` }}>
            {isFinite(health) ? health.toFixed(0) + "%" : "∞"}
          </span>
        </div>
        <div className="h-[6px] w-full overflow-hidden rounded-full" style={{ background: "var(--surface-2)" }}>
          <div
            className="h-full rounded-full transition-all"
            style={{
              width: `${Math.max(4, Math.min(100, (health - 100) / 1.0))}%`,
              background: `var(--${healthTone})`,
            }}
          />
        </div>
        <div className="mt-1 font-mono text-[9.5px] text-muted">100% = force-close line</div>
      </div>

      <div>
        <Row k="Debt" v={`${fmt(debt, 4)} ${DEMO.sym1}`} />
        <Row k="LTV now" v={bps(p.ltvBps)} />
        <Row k="Current tick" v={`${p.currentTick} (${tickToPrice(Number(p.currentTick)).toFixed(4)})`} />
        <Row k="Range" v={`${tickToPrice(Number(p.tickEnd)).toFixed(3)} – ${tickToPrice(Number(p.tickStart)).toFixed(3)}`} />
        <Row k="Penalty now" v={bps(p.currentPenaltyBps)} />
      </div>

      <button className="btn btn-ghost w-full" onClick={repay} disabled={act.mining}>
        {act.mining ? "Confirming…" : "Repay & close"}
      </button>
      {act.status && <div className="text-center font-mono text-[11px] text-muted">{act.status}</div>}
    </Card>
  );
}
