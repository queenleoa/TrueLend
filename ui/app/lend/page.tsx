"use client";

import { useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { erc20Abi } from "viem";
import { DEMO, ADDR, ABI } from "@/lib/contracts";
import { useVault, useVaultRate, usePoolView } from "@/lib/hooks";
import { useAction, parse } from "@/lib/write";
import { toNum, fmt, bps } from "@/lib/format";
import { Card, Eyebrow, Field, Row, Stat, Pill } from "../components/ui";

// Simple lender interface for the two vaults: deposit to earn the utilization
// rate, redeem shares. One vault highlighted at a time.

export default function LendPage() {
  const pool = usePoolView();
  const p = pool.data as { utilizationBps0: bigint; utilizationBps1: bigint } | undefined;
  const [side, setSide] = useState<0 | 1>(0);
  const vaultAddr = side === 0 ? DEMO.vault0 : DEMO.vault1;
  const token = side === 0 ? DEMO.token0 : DEMO.token1;
  const sym = side === 0 ? DEMO.sym0 : DEMO.sym1;
  const util = side === 0 ? p?.utilizationBps0 : p?.utilizationBps1;
  const rate = useVaultRate(vaultAddr, util);

  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-2">
        <Eyebrow>Lend · earn the borrow rate</Eyebrow>
        <h1 className="text-[24px] font-medium tracking-tight text-ink">Supply a vault, earn utilization interest.</h1>
        <p className="max-w-2xl text-[13px] leading-relaxed text-muted">
          Deposit into a per-currency vault and receive shares over its assets. Borrowers pay a kinked rate; a tenth of the interest
          builds reserves that absorb the first loss. Chunk penalties also land here as an LP.
        </p>
      </div>

      <div className="seg w-fit">
        <button data-active={side === 0} onClick={() => setSide(0)}>
          {DEMO.sym0} vault
        </button>
        <button data-active={side === 1} onClick={() => setSide(1)}>
          {DEMO.sym1} vault
        </button>
      </div>

      <div className="grid grid-cols-1 gap-3 lg:grid-cols-[380px_1fr]">
        <VaultAction key={side} vaultAddr={vaultAddr} token={token} sym={sym} rate={rate.data as bigint | undefined} />
        <VaultStats vaultAddr={vaultAddr} sym={sym} util={util} rate={rate.data as bigint | undefined} />
      </div>
    </div>
  );
}

function VaultAction({
  vaultAddr,
  token,
  sym,
  rate,
}: {
  vaultAddr: string;
  token: string;
  sym: string;
  rate: bigint | undefined;
}) {
  const { address, isConnected } = useAccount();
  const act = useAction();
  const [mode, setMode] = useState<"deposit" | "redeem">("deposit");
  const [amt, setAmt] = useState("1000");

  const shares = useReadContract({
    address: vaultAddr as `0x${string}`,
    abi: ABI.vault as never,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 8_000 },
  });
  const shareAssets = useReadContract({
    address: vaultAddr as `0x${string}`,
    abi: ABI.vault as never,
    functionName: "convertToAssets",
    args: [(shares.data as bigint | undefined) ?? 0n],
    query: { enabled: shares.data !== undefined },
  });
  const bal = useReadContract({
    address: token as `0x${string}`,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const allowance = useReadContract({
    address: token as `0x${string}`,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, vaultAddr as `0x${string}`] : undefined,
    query: { enabled: !!address, refetchInterval: 6_000 },
  });

  const amtWei = parse(amt, 18);
  const needsApprove = mode === "deposit" && (allowance.data ?? 0n) < amtWei;

  async function go() {
    if (!address) return;
    try {
      if (mode === "deposit") {
        if (needsApprove) await act.approve(token, vaultAddr, amtWei);
        await act.call({ address: vaultAddr, abi: ABI.vault, functionName: "deposit", args: [amtWei, address] }, "Depositing…");
        act.setStatus("Deposited ✓");
      } else {
        await act.call({ address: vaultAddr, abi: ABI.vault, functionName: "redeem", args: [amtWei, address] }, "Redeeming…");
        act.setStatus("Redeemed ✓");
      }
    } catch (e) {
      act.setStatus("Failed: " + (e as Error).message.slice(0, 70));
    }
  }

  return (
    <Card className="flex flex-col gap-4">
      <div className="seg w-full">
        <button className="flex-1" data-active={mode === "deposit"} onClick={() => setMode("deposit")}>
          Deposit
        </button>
        <button className="flex-1" data-active={mode === "redeem"} onClick={() => setMode("redeem")}>
          Redeem
        </button>
      </div>

      <Field
        label={mode === "deposit" ? `Amount (${sym})` : "Shares"}
        value={amt}
        onChange={setAmt}
        suffix={mode === "deposit" ? sym : "shares"}
        hint={
          mode === "deposit" ? (
            <span>bal {fmt(toNum(bal.data as bigint | undefined))}</span>
          ) : (
            <span>you hold {fmt(toNum(shares.data as bigint | undefined))}</span>
          )
        }
      />

      <div className="rounded-[8px] bg-surface-2 p-3">
        <Row k="Your supplied" v={`${fmt(toNum(shareAssets.data as bigint | undefined))} ${sym}`} />
        <Row k="Current APR" v={<span style={{ color: "var(--pos)" }}>{bps(rate)}</span>} />
      </div>

      <button className="btn btn-primary w-full" disabled={!isConnected || act.mining || Number(amt) <= 0} onClick={go}>
        {act.mining ? "Confirming…" : needsApprove ? `Approve & ${mode}` : mode === "deposit" ? "Deposit" : "Redeem"}
      </button>
      {act.status && <div className="text-center font-mono text-[11px] text-muted">{act.status}</div>}
      {!isConnected && <div className="text-center text-[11px] text-muted">Connect a wallet to supply.</div>}
    </Card>
  );
}

function VaultStats({
  vaultAddr,
  sym,
  util,
  rate,
}: {
  vaultAddr: string;
  sym: string;
  util: bigint | undefined;
  rate: bigint | undefined;
}) {
  const v = useVault(vaultAddr);
  const d = v.data;
  const totalAssets = d?.[0]?.result as bigint | undefined;
  const totalDebt = d?.[1]?.result as bigint | undefined;
  const cash = d?.[2]?.result as bigint | undefined;
  const reserves = d?.[4]?.result as bigint | undefined;

  return (
    <Card className="flex flex-col gap-4">
      <div className="grid grid-cols-3 gap-3">
        <Stat label="Supply APR" value={bps(rate)} tone="pos" sub="at current util" />
        <Stat label="Utilization" value={bps(util)} sub="borrowed / supplied" />
        <Stat label="Reserves" value={fmt(toNum(reserves), 4)} sub="first-loss capital" tone="muted" />
      </div>
      <div>
        <Row k="Total supplied" v={`${fmt(toNum(totalAssets))} ${sym}`} />
        <Row k="Available to withdraw" v={`${fmt(toNum(cash))} ${sym}`} />
        <Row k="Out on loan" v={`${fmt(toNum(totalDebt))} ${sym}`} />
      </div>
      <div className="flex items-center gap-2">
        <Pill tone="pos">kinked IRM</Pill>
        <Pill tone="muted">80% kink · 90% cap</Pill>
        <Pill tone="muted">10% reserve factor</Pill>
      </div>
      <p className="text-[12px] leading-relaxed text-muted">
        Rate rises gently to the 80% utilization kink, then steeply — the steep zone protects a cash buffer, because chunk proceeds
        repay through this vault and withdrawals must always clear.
      </p>
    </Card>
  );
}
