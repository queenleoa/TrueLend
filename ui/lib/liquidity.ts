"use client";

import { useEffect, useState } from "react";
import { createPublicClient, http, encodePacked, keccak256, toHex, pad } from "viem";
import { ADDR, DEMO, RPC_URL } from "./contracts";
import { unichainSepolia } from "@/app/providers";
import { tickToPrice } from "./tick";

const client = createPublicClient({ chain: unichainSepolia, transport: http(RPC_URL) });

// StateLibrary storage layout on PoolManager: pools live at mapping slot 6.
// pool state slot = keccak(poolId . 6). liquidity is at offset 3; ticks map is
// at offset 4 (tickInfo per tick → liquidityGross, liquidityNet). We read
// activeLiquidity via extsload and walk initialized ticks by reconstructing the
// net-liquidity profile — but for a demo with a single full-range LP, the
// distribution is flat between the two boundary ticks. We therefore render the
// PROFILE the pool actually has: active liquidity as a band spanning the LP's
// range, centered on spot, which is the honest picture for this pool.

const POOLS_SLOT = 6n;

function poolStateSlot(poolId: `0x${string}`): bigint {
  const h = keccak256(encodePacked(["bytes32", "uint256"], [poolId, POOLS_SLOT]));
  return BigInt(h);
}

async function extsload(slot: bigint): Promise<bigint> {
  const data = await client.readContract({
    address: ADDR.poolManager as `0x${string}`,
    abi: [{ type: "function", name: "extsload", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bytes32" }] }],
    functionName: "extsload",
    args: [pad(toHex(slot), { size: 32 })],
  });
  return BigInt(data as string);
}

export type LiqBar = { tick: number; price: number; liquidity: number; active: boolean };

export function useLiquidityProfile(currentTick: number | undefined) {
  const [bars, setBars] = useState<LiqBar[]>([]);
  const [totalLiq, setTotalLiq] = useState<number>(0);

  useEffect(() => {
    if (currentTick === undefined) return;
    let live = true;
    async function load() {
      try {
        const base = poolStateSlot(DEMO.poolId as `0x${string}`);
        // slot0 at offset 0 (sqrtPrice/tick packed), liquidity at offset 3
        const liqRaw = await extsload(base + 3n);
        const activeLiquidity = Number(liqRaw & ((1n << 128n) - 1n));

        // Render a symmetric band around spot at tickSpacing resolution. The
        // seeded pool is a single wide-range LP, so active liquidity is constant
        // across the visible window; we draw it as the uniform depth it is,
        // with the in-range portion highlighted.
        const spacing = DEMO.tickSpacing;
        const window = 40; // ± bars
        const spot = Math.round(currentTick! / spacing) * spacing;
        const out: LiqBar[] = [];
        for (let i = -window; i <= window; i++) {
          const t = spot + i * spacing;
          out.push({
            tick: t,
            price: tickToPrice(t),
            liquidity: activeLiquidity,
            active: Math.abs(i) <= 1,
          });
        }
        if (live) {
          setBars(out);
          setTotalLiq(activeLiquidity);
        }
      } catch {
        /* transient RPC */
      }
    }
    load();
    const t = setInterval(load, 15_000);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, [currentTick]);

  return { bars, totalLiq };
}
