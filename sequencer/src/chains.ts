/**
 * Chain definitions, shared by both runners.
 *
 * Extracted from `main.ts` because importing them from there would execute the sequencer's
 * `main()` as a side effect of starting the publisher -- two processes competing for the
 * same relayer nonces, which fails intermittently and looks like an RPC problem.
 */
import { defineChain } from "viem";

export const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://testnet-rpc.monad.xyz"] } },
});

export const monadMainnet = defineChain({
  id: 143,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.monad.xyz"] } },
});

export function chainFor(network: string | undefined) {
  return network === "mainnet" ? monadMainnet : monadTestnet;
}
