export function fmt(v: number, dp = 2): string {
  if (!isFinite(v)) return "—";
  if (Math.abs(v) >= 1e9) return (v / 1e9).toFixed(dp) + "B";
  if (Math.abs(v) >= 1e6) return (v / 1e6).toFixed(dp) + "M";
  if (Math.abs(v) >= 1e3) return v.toLocaleString(undefined, { maximumFractionDigits: dp });
  return v.toLocaleString(undefined, { maximumFractionDigits: dp });
}

export function toNum(v: bigint | undefined, decimals = 18): number {
  if (v === undefined) return 0;
  return Number(v) / 10 ** decimals;
}

export function bps(v: bigint | number | undefined): string {
  if (v === undefined) return "—";
  return (Number(v) / 100).toFixed(2) + "%";
}

export function shortAddr(a?: string): string {
  if (!a) return "—";
  return a.slice(0, 6) + "…" + a.slice(-4);
}

export function shortId(id?: string): string {
  if (!id) return "—";
  return id.slice(0, 8) + "…" + id.slice(-6);
}

export function timeAgo(sec: number): string {
  const d = Math.max(0, Math.floor(Date.now() / 1000) - sec);
  if (d < 60) return d + "s ago";
  if (d < 3600) return Math.floor(d / 60) + "m ago";
  if (d < 86400) return Math.floor(d / 3600) + "h ago";
  return Math.floor(d / 86400) + "d ago";
}
