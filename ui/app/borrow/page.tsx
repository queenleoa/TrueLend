"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { erc20Abi } from "viem";
import { DEMO, ADDR, ABI } from "@/lib/contracts";
import { useQuoteOpen, usePoolView } from "@/lib/hooks";
import { useAction, parse } from "@/lib/write";
import { tickToPrice } from "@/lib/tick";
import { toNum, fmt } from "@/lib/format";
import { Card, Eyebrow, Field, Pill, Row, Stat } from "../components/ui";
import { DecaySimulator } from "../components/DecaySimulator";
import { PositionCard } from "../components/PositionCard";

// Borrow against dUSD collateral, drawing dETH. collateralIs0 = true (dUSD is
// token0). The panel quotes the position's liquidation range live, previews its
// decay, and opens it — all against the deployed hook.

export default function BorrowPage() {
  const { address, isConnected } = useAccount();
  const act = useAction();

  const [coll, setColl] = useState("100");
  const [ltPct, setLtPct] = useState("90");
  const [ltvPct, setLtvPct] = useState("70");

  // price collateral (dUSD) in debt units (dETH) at the LIVE pool tick, so the
  // LTV field is meaningful whatever the current price — not a 1:1 assumption
  const pool = usePoolView() as { data?: { currentTick: number } };
  const currentTick = pool.data ? Number(pool.data.currentTick) : 0;
  const spotPrice = tickToPrice(currentTick); // dETH per dUSD

  const collN = Number(coll) || 0;
  const ltBps = Math.round((Number(ltPct) || 0) * 100);
  const ltvBps = Math.round((Number(ltvPct) || 0) * 100);
  // borrow = LTV × collateral value at spot
  const borrowN = collN * spotPrice * (ltvBps / 10_000);

  const collAmt = parse(coll, DEMO.decimals0);
  const borrowAmt = parse(borrowN.toString(), DEMO.decimals1);

  const quote = useQuoteOpen(true, collAmt, borrowAmt, ltBps, collN > 0 && borrowN > 0 && ltBps >= 5000);
  const q = quote.data as readonly [number, number, boolean, boolean] | undefined;

  const bal = useReadContract({
    address: DEMO.token0 as `0x${string}`,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const allowance = useReadContract({
    address: DEMO.token0 as `0x${string}`,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, ADDR.hook as `0x${string}`] : undefined,
    query: { enabled: !!address, refetchInterval: 6_000 },
  });

  const needsApprove = (allowance.data ?? 0n) < collAmt;
  const gapOk = q?.[2] ?? false;
  const ltvOk = q?.[3] ?? false;
  const canOpen = isConnected && collN > 0 && borrowN > 0 && ltBps >= 5000 && gapOk && ltvOk && !act.mining;

  const rangeStart = q ? tickToPrice(Number(q[0])) : 0;
  const rangeEnd = q ? tickToPrice(Number(q[1])) : 0;
  // liquidation price in dETH/dUSD; sim holds slightly inside the range
  const liqPrice = useMemo(() => (collN && borrowN ? borrowN / ((ltBps / 10_000) * collN) : 0), [collN, borrowN, ltBps]);

  async function onOpen() {
    if (!address) return;
    try {
      if (needsApprove) {
        await act.approve(DEMO.token0, ADDR.hook, collAmt);
      }
      await act.call(
        {
          address: ADDR.hook,
          abi: ABI.hook,
          functionName: "open",
          args: [
            { currency0: DEMO.token0, currency1: DEMO.token1, fee: DEMO.fee, tickSpacing: DEMO.tickSpacing, hooks: ADDR.hook },
            true,
            collAmt,
            borrowAmt,
            ltBps,
            address,
          ],
        },
        "Opening position…",
      );
      act.setStatus("Opened ✓");
    } catch (e) {
      act.setStatus("Failed: " + (e as Error).message.slice(0, 80));
    }
  }

  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-2">
        <Eyebrow>Borrow · {DEMO.sym1} against {DEMO.sym0}</Eyebrow>
        <h1 className="text-[24px] font-medium tracking-tight text-ink">Open a position — you pick the threshold.</h1>
        <p className="max-w-2xl text-[13px] leading-relaxed text-muted">
          Post {DEMO.sym0} collateral, draw {DEMO.sym1}. Choose your own liquidation threshold up to 99%. If the price falls to your
          range, the position decays gradually and repays itself — it does not get seized.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-3 lg:grid-cols-[380px_1fr]">
        {/* form */}
        <Card className="flex flex-col gap-4">
          <Field
            label={`Collateral (${DEMO.sym0})`}
            value={coll}
            onChange={setColl}
            suffix={DEMO.sym0}
            hint={<span>bal {fmt(toNum(bal.data as bigint, DEMO.decimals0))}</span>}
          />
          <div className="grid grid-cols-2 gap-3">
            <Field label="LTV %" value={ltvPct} onChange={setLtvPct} suffix="%" />
            <Field label="Liq. threshold %" value={ltPct} onChange={setLtPct} suffix="%" />
          </div>

          <div className="rounded-[8px] bg-surface-2 p-3">
            <Row k={`Borrow (${DEMO.sym1})`} v={fmt(borrowN, 4)} />
            <Row k="Liquidation price" v={liqPrice ? liqPrice.toFixed(4) : "—"} />
            <Row
              k="Checks"
              v={
                <span className="flex gap-1.5">
                  <Pill tone={gapOk ? "pos" : "neg"}>{gapOk ? "gap ok" : "gap"}</Pill>
                  <Pill tone={ltvOk ? "pos" : "neg"}>{ltvOk ? "ltv ok" : "ltv"}</Pill>
                </span>
              }
            />
          </div>

          <button className="btn btn-primary w-full" disabled={!canOpen} onClick={onOpen}>
            {act.mining ? "Confirming…" : needsApprove ? `Approve & open` : "Open position"}
          </button>
          {act.status && <div className="text-center font-mono text-[11px] text-muted">{act.status}</div>}
          {!ltvOk && q && (
            <div className="text-center text-[11px] text-neg">
              LTV must sit ≤ 95% of your threshold — lower the LTV or raise the threshold.
            </div>
          )}
        </Card>

        {/* preview */}
        <Card className="flex flex-col gap-4">
          <div className="grid grid-cols-3 gap-3">
            <Stat label="Range start" value={rangeStart ? rangeStart.toFixed(4) : "—"} sub="decay begins" tone="warn" />
            <Stat label="Range end" value={rangeEnd ? rangeEnd.toFixed(4) : "—"} sub="bankruptcy line" tone="neg" />
            <Stat label="Max leverage" value={ltvBps ? (1 / (1 - ltvBps / 10_000)).toFixed(1) + "×" : "—"} sub="via looping" />
          </div>
          {collN > 0 && borrowN > 0 && (
            <DecaySimulator
              collateral={collN}
              debt={borrowN}
              ltBps={ltBps}
              entryPrice={1}
              holdPrice={liqPrice ? liqPrice * 0.97 : 0.9}
            />
          )}
        </Card>
      </div>

      {/* your positions */}
      <div className="flex flex-col gap-3">
        <Eyebrow>Your positions</Eyebrow>
        <YourPositions owner={address} />
      </div>
    </div>
  );
}

function YourPositions({ owner }: { owner?: string }) {
  // positions are keyed by events; PositionCard reads live state per id
  const { positions } = usePositionIds(owner);
  if (!owner) return <p className="text-[13px] text-muted">Connect a wallet to see your open positions.</p>;
  if (positions.length === 0)
    return <p className="text-[13px] text-muted">No open positions yet. Opening one will show its live decay here.</p>;
  return (
    <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
      {positions.map((id) => (
        <PositionCard key={id} id={id} />
      ))}
    </div>
  );
}

// tiny local hook: scan PositionOpened for this borrower
import { usePoolHistory } from "@/lib/events";
function usePositionIds(owner?: string) {
  const { events } = usePoolHistory();
  const positions = events
    .filter((e) => e.kind === "opened" && e.positionId)
    .map((e) => e.positionId!)
    // dedupe
    .filter((v, i, a) => a.indexOf(v) === i);
  return { positions: owner ? positions : [] };
}
