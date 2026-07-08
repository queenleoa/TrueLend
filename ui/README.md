# TrueLend UI

A Next.js dashboard for the TrueLend protocol on Unichain Sepolia. It reads
**live from the deployed contracts** — no indexer, no backend — and shows the
one thing a conventional lending UI cannot: **liquidation as a gradual process
on the pool's own tick.**

## Pages

- **Pool** (`/`) — the observatory. A liquidation *timeline* (the pool's tick
  over time, with liquidation episodes shaded and each paced chunk marked), a
  liquidity-across-ticks depth chart with positions' liquidation ranges overlaid,
  LP-penalty totals, and both lending vaults' live state.
- **Borrow** (`/borrow`) — open a position: pick your own liquidation threshold,
  see the range your margin implies, and preview the exact chunk-by-chunk decay
  path (a faithful TypeScript port of the on-chain `ChunkMath`). Manage open
  positions with a live health bar.
- **Lend** (`/lend`) — supply either vault, earn the utilization-priced rate,
  redeem shares; live reserves, utilization, and the kinked-IRM parameters.

## Design

Ported from the fullmetal.finance visual language: warm paper surfaces, near-black
ink, hairline rules, mono eyebrows, Geist Sans/Mono, a reserved green for healthy
figures and red for liquidating. Fully theme-aware (light/dark via CSS tokens).

## Run

```bash
npm install
npm run dev        # http://localhost:3000
```

Connect an injected wallet (MetaMask) on Unichain Sepolia (chain 1301). The demo
market (`dUSD/dETH`) is seeded with liquidity, lenders, and a real liquidation
episode — its addresses are in [`lib/contracts.ts`](lib/contracts.ts).

## How the data flows

- Live reads: `TrueLendLens.pool()` / `.position()`, `LendingVault` views, and
  the PoolManager tick — via wagmi/viem multicall, polled.
- History: `LiquidationStarted` / `ChunkExecuted` / `LiquidationPaused` /
  `PositionClosed` from the hook and `Swap` from the PoolManager, scanned in
  block chunks in [`lib/events.ts`](lib/events.ts).
- The decay simulator and chunk preview use [`lib/tick.ts`](lib/tick.ts) — the
  `ChunkMath` port — so what the UI shows is exactly what the engine would do.
