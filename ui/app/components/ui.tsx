"use client";

import { ReactNode } from "react";

export function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`card p-5 ${className}`}>{children}</div>;
}

export function Eyebrow({ children }: { children: ReactNode }) {
  return <div className="eyebrow">{children}</div>;
}

export function Stat({
  label,
  value,
  sub,
  tone = "ink",
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  tone?: "ink" | "pos" | "neg" | "warn" | "muted";
}) {
  const color =
    tone === "pos" ? "var(--pos)" : tone === "neg" ? "var(--neg)" : tone === "warn" ? "var(--warn)" : tone === "muted" ? "var(--muted)" : "var(--ink)";
  return (
    <div>
      <div className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">{label}</div>
      <div className="tnum mt-1 text-[22px] font-medium leading-tight" style={{ color }}>
        {value}
      </div>
      {sub && <div className="mt-0.5 text-[12px] text-muted">{sub}</div>}
    </div>
  );
}

export function Pill({ tone, children }: { tone: "pos" | "neg" | "warn" | "muted"; children: ReactNode }) {
  const map = {
    pos: ["var(--pos)", "var(--pos-soft)"],
    neg: ["var(--neg)", "var(--neg-soft)"],
    warn: ["var(--warn)", "color-mix(in srgb, var(--warn) 14%, transparent)"],
    muted: ["var(--muted)", "var(--surface-2)"],
  }[tone];
  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-mono text-[10.5px] font-medium uppercase tracking-[0.1em]"
      style={{ color: map[0], background: map[1] }}
    >
      <span className="h-[5px] w-[5px] rounded-full" style={{ background: map[0] }} />
      {children}
    </span>
  );
}

export function Row({ k, v }: { k: ReactNode; v: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b-[0.5px] border-line py-2 last:border-0">
      <span className="text-[13px] text-muted">{k}</span>
      <span className="tnum text-[13.5px] text-ink">{v}</span>
    </div>
  );
}

export function Field({
  label,
  value,
  onChange,
  suffix,
  hint,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  suffix?: string;
  hint?: ReactNode;
}) {
  return (
    <label className="block">
      <div className="mb-1.5 flex items-baseline justify-between">
        <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">{label}</span>
        {hint && <span className="text-[11px] text-muted">{hint}</span>}
      </div>
      <div className="relative">
        <input
          className="field"
          inputMode="decimal"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="0.0"
        />
        {suffix && (
          <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 font-mono text-[12px] text-muted">
            {suffix}
          </span>
        )}
      </div>
    </label>
  );
}
