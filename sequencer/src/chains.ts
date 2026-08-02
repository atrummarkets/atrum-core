/**
 * Chain definitions, shared by both runners.
 *
 * Extracted from `main.ts` because importing them from there would execute the sequencer's
 * `main()` as a side effect of starting the publisher -- two processes competing for the
 * same relayer nonces, which fails intermittently and looks like an RPC problem.
 */
import { defineChain } from "viem";

/**
 * ⚠️ THE DEFAULT PUBLIC RPC LIES ABOUT BALANCES. Set RPC_URL to something else for writes.
 *
 * MEASURED 2026-08-02: `testnet-rpc.monad.xyz` rejected every `flushBatch` with
 * "Signer had insufficient balance" while the signer held 8.368 MON against a 0.488 MON
 * requirement (4,000,000 gas x 122 gwei) -- a 17x margin. Ruled out, one at a time:
 *
 *   - balance      8.368 MON on chain, confirmed by that same endpoint
 *   - authorization  pool's `sequencer()` matched the signing account exactly
 *   - call validity  `eth_call` simulation of the IDENTICAL call succeeded
 *   - stale client   a fresh client in a separate process failed the same way
 *   - mempool backlog  latest nonce == pending nonce, nothing stuck
 *
 * The same transaction, same account, same balance, submitted through
 * `rpc.ankr.com/monad_testnet`, succeeded immediately (tx 0xdb551b14…, block 50249190).
 *
 * The endpoint also returns HTTP 429 under modest read load and intermittent bare
 * CALL_EXCEPTIONs with no revert data. It is fine for casual reads; it is not fine for
 * submitting transactions, and its error messages point at the wrong layer when it fails.
 */
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
