"use client";

import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { erc20Abi, parseUnits } from "viem";
import { useCallback, useState } from "react";
import { ADDR, DEMO, ABI } from "./contracts";

// A small action runner: approve-if-needed then the call, with a status string
// the UI can show. Kept intentionally minimal — one pending tx at a time.
export function useAction() {
  const { writeContractAsync } = useWriteContract();
  const [status, setStatus] = useState<string>("");
  const [hash, setHash] = useState<`0x${string}` | undefined>();
  const { isLoading: mining, isSuccess } = useWaitForTransactionReceipt({ hash });

  const approve = useCallback(
    async (token: string, spender: string, amount: bigint) => {
      setStatus("Approving…");
      const h = await writeContractAsync({
        address: token as `0x${string}`,
        abi: erc20Abi,
        functionName: "approve",
        args: [spender as `0x${string}`, amount],
      });
      setHash(h);
      return h;
    },
    [writeContractAsync],
  );

  const call = useCallback(
    async (opts: { address: string; abi: unknown; functionName: string; args: unknown[]; value?: bigint }, label: string) => {
      setStatus(label);
      const h = await writeContractAsync({
        address: opts.address as `0x${string}`,
        abi: opts.abi as never,
        functionName: opts.functionName,
        args: opts.args as never,
        value: opts.value,
      });
      setHash(h);
      return h;
    },
    [writeContractAsync],
  );

  return { approve, call, status, setStatus, hash, mining, isSuccess };
}

export function parse(v: string, decimals = 18): bigint {
  if (!v || isNaN(Number(v))) return 0n;
  return parseUnits(v as `${number}`, decimals);
}

export { ADDR, DEMO, ABI };
