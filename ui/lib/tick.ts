// Tick / sqrt-price math mirrored from Uniswap v4 TickMath, plus TrueLend's own
// chunk formula (a faithful TS port of ChunkMath.chunkSize) so the borrow panel
// and decay simulator preview EXACTLY what the on-chain engine would do.

const Q96 = 2n ** 96n;
const MIN_TICK = -887272;
const MAX_TICK = 887272;

// price of token1 per token0 at a tick (human units, decimals-adjusted outside)
export function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

export function priceToTick(price: number): number {
  return Math.round(Math.log(price) / Math.log(1.0001));
}

export function sqrtPriceX96ToTick(sqrtPriceX96: bigint): number {
  const ratio = Number(sqrtPriceX96) / Number(Q96);
  const price = ratio * ratio;
  return priceToTick(price);
}

export function alignTick(tick: number, spacing: number): number {
  return Math.floor(tick / spacing) * spacing;
}

export function clampTick(t: number): number {
  return Math.max(MIN_TICK, Math.min(MAX_TICK, t));
}

// --- ChunkMath.chunkSize port (bps units in, token units out) -----------------
// chunk = base·timeX·(1+depth)·(1+pressure), clamped to [0, min(maxChunk, rem)]
export function chunkSize(p: {
  remaining: number;
  targetChunks: number;
  elapsedSec: number;
  intervalSec: number;
  timeCapX: number;
  depthBps: number; // 0..10000
  pressureBps: number; // 0..10000
  maxChunk: number;
}): number {
  if (p.remaining <= 0 || p.elapsedSec < p.intervalSec) return 0;
  let base = p.remaining / p.targetChunks;
  if (base === 0) base = p.remaining;
  const timeX = Math.min(Math.floor(p.elapsedSec / p.intervalSec), p.timeCapX);
  const depth = Math.min(p.depthBps, 10_000) / 10_000;
  const pressure = Math.min(p.pressureBps, 10_000) / 10_000;
  let size = base * timeX * (1 + depth) * (1 + pressure);
  size = Math.min(size, p.maxChunk);
  size = Math.min(size, p.remaining);
  return size;
}

// depth into a collateral-is-0 range (0 at tickStart, 1 at tickEnd)
export function depthFraction(tick: number, tickStart: number, tickEnd: number): number {
  const width = tickStart - tickEnd;
  if (width <= 0) return 1;
  const d = tickStart - tick;
  return Math.max(0, Math.min(1, d / width));
}

// where a loan's liquidation range starts, in price terms: P_liq = debt/(LT·coll)
export function liqStartPrice(debt: number, collateral: number, ltBps: number): number {
  return debt / ((ltBps / 10_000) * collateral);
}

export { MIN_TICK, MAX_TICK, Q96 };
