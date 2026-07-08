"use client";

import { createConfig, http, WagmiProvider } from "wagmi";
import { defineChain } from "viem";
import { injected } from "wagmi/connectors";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { CHAIN_ID, RPC_URL } from "@/lib/contracts";

export const unichainSepolia = defineChain({
  id: CHAIN_ID,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
  testnet: true,
});

const config = createConfig({
  chains: [unichainSepolia],
  connectors: [injected()],
  transports: { [CHAIN_ID]: http(RPC_URL) },
  ssr: true,
});

const queryClient = new QueryClient({
  defaultOptions: { queries: { refetchInterval: 12_000, staleTime: 8_000 } },
});

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
