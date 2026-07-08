"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { ADDR, DEMO, ABI } from "./contracts";

const hookC = { address: ADDR.hook as `0x${string}`, abi: ABI.hook as never };
const lensC = { address: ADDR.lens as `0x${string}`, abi: ABI.lens as never };

export function usePoolView() {
  return useReadContract({
    ...lensC,
    functionName: "pool",
    args: [DEMO.poolId as `0x${string}`],
    query: { refetchInterval: 10_000 },
  });
}

export function useConfig() {
  return useReadContract({
    ...hookC,
    functionName: "getConfig",
    args: [DEMO.poolId as `0x${string}`],
  });
}

export function useSlot0() {
  // StateLibrary.getSlot0 via the PoolManager: read through the lens' pool() tick
  // (kept simple — pool() returns currentTick). Separate hook so charts can poll.
  return usePoolView();
}

export function vaultContract(addr: string) {
  return { address: addr as `0x${string}`, abi: ABI.vault as never };
}

export function useVault(addr: string) {
  const c = vaultContract(addr);
  return useReadContracts({
    contracts: [
      { ...c, functionName: "totalAssets" },
      { ...c, functionName: "totalDebtAssets" },
      { ...c, functionName: "cash" },
      { ...c, functionName: "utilizationBps" },
      { ...c, functionName: "reserves" },
      { ...c, functionName: "totalSupply" },
    ],
    query: { refetchInterval: 10_000 },
  });
}

export function useVaultRate(addr: string, utilBps: bigint | undefined) {
  return useReadContract({
    ...vaultContract(addr),
    functionName: "rateBps",
    args: [utilBps ?? 0n],
    query: { enabled: utilBps !== undefined },
  });
}

export function useLensPosition(id: string | undefined) {
  return useReadContract({
    ...lensC,
    functionName: "position",
    args: id ? [id as `0x${string}`] : undefined,
    query: { enabled: !!id, refetchInterval: 8_000 },
  });
}

export function useQuoteOpen(
  collateralIs0: boolean,
  collateral: bigint,
  borrow: bigint,
  ltBps: number,
  enabled: boolean,
) {
  return useReadContract({
    ...lensC,
    functionName: "quoteOpen",
    args: [
      {
        currency0: DEMO.token0,
        currency1: DEMO.token1,
        fee: DEMO.fee,
        tickSpacing: DEMO.tickSpacing,
        hooks: ADDR.hook,
      },
      collateralIs0,
      collateral,
      borrow,
      ltBps,
    ] as never,
    query: { enabled },
  });
}
