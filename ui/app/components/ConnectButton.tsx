"use client";

import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { CHAIN_ID } from "@/lib/contracts";
import { shortAddr } from "@/lib/format";

export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  if (isConnected && address) {
    if (chainId !== CHAIN_ID) {
      return (
        <button className="btn btn-ghost" onClick={() => switchChain({ chainId: CHAIN_ID })}>
          Switch to Unichain Sepolia
        </button>
      );
    }
    return (
      <button className="btn btn-ghost tnum" onClick={() => disconnect()} title="Disconnect">
        {shortAddr(address)}
      </button>
    );
  }

  const injected = connectors.find((c) => c.type === "injected") ?? connectors[0];
  return (
    <button className="btn btn-primary" disabled={isPending} onClick={() => injected && connect({ connector: injected })}>
      {isPending ? "Connecting…" : "Connect wallet"}
    </button>
  );
}
