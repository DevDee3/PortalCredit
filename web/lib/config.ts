import { defineChain, type Address } from "viem";

const env = (v: string | undefined, fallback = "") => (v && v.length > 0 ? v : fallback);

export const CHAIN_ID = Number(env(process.env.NEXT_PUBLIC_CHAIN_ID, "31337"));
export const RPC_URL = env(process.env.NEXT_PUBLIC_RPC_URL, "http://127.0.0.1:8545");
export const EXPLORER_URL = env(process.env.NEXT_PUBLIC_EXPLORER_URL);

export const chain = defineChain({
  id: CHAIN_ID,
  name: env(process.env.NEXT_PUBLIC_CHAIN_NAME, "Portaldot"),
  nativeCurrency: { name: "POT", symbol: env(process.env.NEXT_PUBLIC_NATIVE_SYMBOL, "POT"), decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  ...(EXPLORER_URL ? { blockExplorers: { default: { name: "Explorer", url: EXPLORER_URL } } } : {}),
});

const zero = "0x0000000000000000000000000000000000000000" as Address;
export const ADDR = {
  stable: env(process.env.NEXT_PUBLIC_STABLE, zero) as Address,
  nft: env(process.env.NEXT_PUBLIC_NFT, zero) as Address,
  vault: env(process.env.NEXT_PUBLIC_VAULT, zero) as Address,
  engine: env(process.env.NEXT_PUBLIC_ENGINE, zero) as Address,
  arbiter: env(process.env.NEXT_PUBLIC_ARBITER, zero) as Address,
};

export const CONFIGURED = Object.values(ADDR).every((a) => a !== zero);
export const STABLE_DECIMALS = 6;

export const STATUS = [
  "None",
  "Performing",
  "Overdue",
  "Disputed",
  "Seized",
  "Liquidated",
  "Recovered",
  "Written off",
  "Repaid",
] as const;
export type StatusName = (typeof STATUS)[number];

export function txUrl(hash: string) {
  return EXPLORER_URL ? `${EXPLORER_URL.replace(/\/$/, "")}/tx/${hash}` : undefined;
}
