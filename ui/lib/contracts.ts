// Deployed TrueLend stack on Unichain Sepolia (chain 1301) + the demo pool the
// dashboard reads. Addresses are the audited build (hook 0xa731…, router 0xB359…).

import hookAbi from "./abi/TrueLendHook.json";
import vaultAbi from "./abi/LendingVault.json";
import lensAbi from "./abi/TrueLendLens.json";

export const CHAIN_ID = 1301;
export const RPC_URL = "https://sepolia.unichain.org";
export const EXPLORER = "https://sepolia.uniscan.xyz";

export const ADDR = {
  poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
  hook: "0xa731511a83D523A1df04e988873725BEE7cA90c0",
  factory: "0x2aAF432336Ea0D8b91398D32D0898317EfB6b420",
  lens: "0xa8ed6128aD792485F6F5E9490C3dE630870e0cF4",
  router: "0xB359c6a4b7A07f4944438d8e5d2FeC9e8E4aaCBc",
  // demo market operator (script/DemoDriver.sol) — seeds and drives the demo pool
  driver: "0xe116078ca72B5DF26256755f8D3385e1aE969fC6",
} as const;

// The seeded demo market.
export const DEMO = {
  poolId: "0x2e53957ec37ecb3f0dd15e6aea41d21e04ee38135c905e60df30f3a51537ed0e",
  token0: "0x27b02edbE6169BAA508320233AB0449DB73ceFc3", // dUSD
  token1: "0xA95375167adC440E1E5eee57992B3df98eB0959E", // dETH
  vault0: "0xfD3F9bE67ae10d041Df4dBB25350AbA07613703e", // lends dUSD
  vault1: "0xc74Ad5Ec8b300FD8eC9fD1C8c7C4a8a77e4dAC41", // lends dETH
  sym0: "dUSD",
  sym1: "dETH",
  decimals0: 18,
  decimals1: 18,
  tickSpacing: 60,
  fee: 3000,
} as const;

export const ABI = { hook: hookAbi, vault: vaultAbi, lens: lensAbi } as const;

export const BPS = 10_000n;
export const WAD = 10n ** 18n;
export const YEAR = 365n * 24n * 3600n;
