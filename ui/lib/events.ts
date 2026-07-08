"use client";

import { useEffect, useState } from "react";
import { createPublicClient, http, parseAbiItem } from "viem";
import { ADDR, DEMO, RPC_URL } from "./contracts";
import { unichainSepolia } from "@/app/providers";

const client = createPublicClient({ chain: unichainSepolia, transport: http(RPC_URL) });

const EV = {
  opened: parseAbiItem(
    "event PositionOpened(bytes32 indexed positionId, address indexed borrower, bytes32 indexed poolId, bool collateralIs0, uint256 collateral, uint256 debt, uint16 ltBps, int24 tickStart, int24 tickEnd, uint40 expiry)",
  ),
  started: parseAbiItem("event LiquidationStarted(bytes32 indexed positionId, int24 tick)"),
  paused: parseAbiItem("event LiquidationPaused(bytes32 indexed positionId, int24 tick, uint256 episodeSeconds)"),
  chunk: parseAbiItem(
    "event ChunkExecuted(bytes32 indexed positionId, uint256 collateralSold, uint256 proceeds, uint256 penalty, uint256 debtRepaid)",
  ),
  closed: parseAbiItem(
    "event PositionClosed(bytes32 indexed positionId, uint256 collateralReturned, uint256 shortfallWrittenOff)",
  ),
  swap: parseAbiItem(
    "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
  ),
};

export type TimelineEvent = {
  kind: "opened" | "started" | "paused" | "chunk" | "closed" | "price";
  block: bigint;
  ts: number;
  tick?: number;
  positionId?: string;
  penalty?: bigint;
  collateralSold?: bigint;
  debtRepaid?: bigint;
  episodeSeconds?: bigint;
  shortfall?: bigint;
};

const DEPLOY_BLOCK = 56_570_000n; // near the demo pool init; bounds the scan

export function usePoolHistory() {
  const [events, setEvents] = useState<TimelineEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;

    // some public RPCs cap getLogs at ~10k blocks per call; scan in chunks.
    /* eslint-disable @typescript-eslint/no-explicit-any */
    async function getLogsChunked(params: { address: `0x${string}`; event: ReturnType<typeof parseAbiItem>; args?: object; from: bigint; to: bigint }): Promise<any[]> {
      const STEP = 9_500n;
      const out: any[] = [];
      for (let start = params.from; start <= params.to; start += STEP + 1n) {
        const end = start + STEP > params.to ? params.to : start + STEP;
        try {
          const seg = await client.getLogs({ address: params.address, event: params.event as never, args: params.args as never, fromBlock: start, toBlock: end });
          out.push(...(seg as any[]));
        } catch {
          /* skip a bad segment rather than fail the whole view */
        }
      }
      return out;
    }
    /* eslint-enable @typescript-eslint/no-explicit-any */

    async function load() {
      try {
        const latest = await client.getBlockNumber();
        const from = latest > 60_000n ? latest - 60_000n : 0n; // covers the demo history
        const poolTopic = DEMO.poolId as `0x${string}`;

        const [swaps, started, paused, chunks, closed, opened] = await Promise.all([
          getLogsChunked({ address: ADDR.poolManager as `0x${string}`, event: EV.swap, args: { id: poolTopic }, from, to: latest }),
          getLogsChunked({ address: ADDR.hook as `0x${string}`, event: EV.started, from, to: latest }),
          getLogsChunked({ address: ADDR.hook as `0x${string}`, event: EV.paused, from, to: latest }),
          getLogsChunked({ address: ADDR.hook as `0x${string}`, event: EV.chunk, from, to: latest }),
          getLogsChunked({ address: ADDR.hook as `0x${string}`, event: EV.closed, from, to: latest }),
          getLogsChunked({ address: ADDR.hook as `0x${string}`, event: EV.opened, args: { poolId: poolTopic }, from, to: latest }),
        ]);

        // timestamps: batch unique blocks
        const blocks = new Set<bigint>();
        [...swaps, ...started, ...paused, ...chunks, ...closed, ...opened].forEach((l) => blocks.add(l.blockNumber!));
        const tsMap = new Map<bigint, number>();
        await Promise.all(
          [...blocks].map(async (b) => {
            const blk = await client.getBlock({ blockNumber: b });
            tsMap.set(b, Number(blk.timestamp));
          }),
        );

        const out: TimelineEvent[] = [];
        for (const l of swaps)
          out.push({ kind: "price", block: l.blockNumber!, ts: tsMap.get(l.blockNumber!) ?? 0, tick: Number((l.args as { tick: number }).tick) });
        for (const l of opened)
          out.push({ kind: "opened", block: l.blockNumber!, ts: tsMap.get(l.blockNumber!) ?? 0, positionId: (l.args as { positionId: string }).positionId, tick: Number((l.args as { tickStart: number }).tickStart) });
        for (const l of started)
          out.push({ kind: "started", block: l.blockNumber!, ts: tsMap.get(l.blockNumber!) ?? 0, positionId: (l.args as { positionId: string }).positionId, tick: Number((l.args as { tick: number }).tick) });
        for (const l of paused)
          out.push({ kind: "paused", block: l.blockNumber!, ts: tsMap.get(l.blockNumber!) ?? 0, positionId: (l.args as { positionId: string }).positionId, tick: Number((l.args as { tick: number }).tick), episodeSeconds: (l.args as { episodeSeconds: bigint }).episodeSeconds });
        for (const l of chunks)
          out.push({ kind: "chunk", block: l.blockNumber!, ts: tsMap.get(l.blockNumber!) ?? 0, positionId: (l.args as { positionId: string }).positionId, penalty: (l.args as { penalty: bigint }).penalty, collateralSold: (l.args as { collateralSold: bigint }).collateralSold, debtRepaid: (l.args as { debtRepaid: bigint }).debtRepaid });
        for (const l of closed)
          out.push({ kind: "closed", block: l.blockNumber!, ts: tsMap.get(l.blockNumber!) ?? 0, positionId: (l.args as { positionId: string }).positionId, shortfall: (l.args as { shortfallWrittenOff: bigint }).shortfallWrittenOff });

        out.sort((a, b) => (a.block === b.block ? 0 : a.block < b.block ? -1 : 1));
        if (live) {
          setEvents(out);
          setLoading(false);
        }
      } catch (e) {
        if (live) {
          setError(String(e));
          setLoading(false);
        }
      }
    }
    load();
    const t = setInterval(load, 30_000);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, []);

  return { events, loading, error };
}

export { DEPLOY_BLOCK };
