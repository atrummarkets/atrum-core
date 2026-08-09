import { fallback, http, type Transport } from "viem";

/**
 * RPC endpoint handling, shared by every service in this package.
 *
 * WHY THIS EXISTS: `RPC_URL` may hold a comma-separated LIST. The app reads it that way so one
 * exhausted provider costs a retry instead of an outage -- public Monad endpoints rate-limit,
 * and a single one running out of quota took `/api/atrum/markets` down with a 500.
 *
 * Everything that reads `RPC_URL` therefore has to split it. Handing the raw comma string to
 * `http()` builds one unreachable URL and fails every call, which is exactly how the sequencer
 * broke: viem reported `Must be au...is not valid JSON` -- an auth error page from the first
 * provider, because the whole list had been glued onto its path.
 *
 * A single URL still works unchanged, so nothing that sets one needs to change.
 */

/** Split a raw `RPC_URL` value into endpoints, preference order preserved. */
export function rpcList(raw: string | undefined, fallbackUrl: string): string[] {
  const parsed = (raw ?? "")
    .split(",")
    .map((u) => u.trim())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : [fallbackUrl];
}

/**
 * A transport over every endpoint in `raw`, in preference order.
 *
 * `rank` re-orders by observed latency and success rate, so a provider that starts erroring is
 * demoted rather than retried at the front of the queue forever. Ranking is disabled for a
 * single endpoint -- there is nothing to rank, and the sampling traffic would be pure waste.
 */
export function rpcTransport(raw: string | undefined, fallbackUrl?: string): Transport {
  const urls = rpcList(raw, fallbackUrl ?? "https://testnet-rpc.monad.xyz");
  return fallback(
  // A 10s cap per endpoint. Without it a provider that ACCEPTS the connection and never answers
  // -- which is how a bad Alchemy key behaves, rather than returning an error -- holds the whole
  // request open and rotation never gets its turn.
    urls.map((url) => http(url, { retryCount: 2, retryDelay: 300, timeout: 10_000 })),
    { rank: urls.length > 1 ? { interval: 30_000, sampleCount: 3 } : false },
  );
}
