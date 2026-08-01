/**
 * Publisher entry point: a decrypt-and-publish loop plus a liveness endpoint.
 *
 * THIS PROCESS HOLDS THE COMMITTEE SECRET. It is the only thing in the system that can turn
 * the accumulated ciphertext into a number, which makes it the highest-value target here by a
 * wide margin: whoever obtains that key can decrypt every bet in every market, retroactively.
 *
 * Consequences for how it is run, not just how it is written:
 *   - It belongs in its own environment, separate from the sequencer. The sequencer is
 *     trusted for liveness only and cannot learn who bet what; co-locating them hands that
 *     property away for nothing.
 *   - `COMMITTEE_SECRET` is read once, into a bigint, and never logged. There is no debug
 *     flag that prints it, because a debug flag that prints it is how it reaches a log
 *     aggregator.
 *   - Nothing here prints a decrypted magnitude either -- see `publisher.ts`. Only the
 *     coarse ratio, which is public by design, is ever emitted.
 *
 * Run: node --experimental-strip-types src/publisher-main.ts
 */
import { createServer } from "node:http";
import type { Address } from "viem";
import { Publisher, type TickResult } from "./publisher.ts";
import { DEFAULT_POLICY } from "./ratio-policy.ts";
import { chainFor } from "./chains.ts";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing required env var ${name}`);
  return value;
}

/** Parse "8,10" into [8, 10]. */
function marketIds(raw: string): number[] {
  const ids = raw
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isInteger(n) && n >= 0);
  if (ids.length === 0) throw new Error("MARKET_IDS parsed to nothing");
  return ids;
}

async function main(): Promise<void> {
  const chain = chainFor(process.env.NETWORK);

  const publisher = new Publisher({
    rpcUrl: process.env.RPC_URL ?? chain.rpcUrls.default.http[0]!,
    chain,
    poolAddress: required("POOL_ADDRESS") as Address,
    accumulatorAddress: required("ACCUMULATOR_ADDRESS") as Address,
    encryptedPoolAddress: required("ENCRYPTED_POOL_ADDRESS") as Address,
    marketIds: marketIds(required("MARKET_IDS")),
    committeeSecret: BigInt(required("COMMITTEE_SECRET")),
    publisherPrivateKey: required("PUBLISHER_PRIVATE_KEY") as `0x${string}`,
    // Without this the first log scan starts at genesis, which public RPC endpoints
    // rate-limit or refuse outright.
    deployBlock: process.env.DEPLOY_BLOCK ? BigInt(process.env.DEPLOY_BLOCK) : undefined,
    policy: DEFAULT_POLICY,
  });

  await publisher.init();

  const ids = marketIds(required("MARKET_IDS"));
  console.log(`publisher up on ${chain.name}, markets [${ids.join(", ")}]`);
  console.log(
    `policy: ${DEFAULT_POLICY.quantiseBps}bps buckets, ` +
      `${DEFAULT_POLICY.minBetsBeforeFirstPublish} bets before first publish, ` +
      `${DEFAULT_POLICY.minBetsBetweenPublishes} between`,
  );

  let lastTickAt = 0;
  let lastResults: TickResult[] = [];

  // Liveness. Exists because a host that sleeps idle services needs something to ping, and
  // every other route would answer 404 -- an uptime monitor would report the service down
  // and the alerts would be ignored within a day.
  //
  // It reports the last decision per market, which is safe: a `TickResult` carries a coarse
  // ratio and a reason string, never a magnitude. That is checked in `ratio-policy.test.ts`
  // rather than assumed.
  const port = Number(process.env.PORT ?? 8081);
  createServer((req, res) => {
    if ((req.url ?? "/") .split("?")[0] !== "/health") {
      res.writeHead(404).end('{"error":"only /health is served"}');
      return;
    }
    res.writeHead(200, { "content-type": "application/json" }).end(
      JSON.stringify({
        status: "ok",
        chain: chain.name,
        markets: ids,
        lastTickAt,
        lastResults,
      }),
    );
  }).listen(port, () => console.log(`health endpoint on :${port}`));

  const intervalMs = Number(process.env.TICK_INTERVAL_MS ?? 60_000);

  for (;;) {
    try {
      const results = await publisher.tick();
      lastTickAt = Date.now();
      lastResults = results;

      for (const r of results) {
        if (r.published) {
          console.log(`market ${r.marketId}: published ${r.ratioBps} bps`);
        } else {
          // Logged at debug volume on purpose -- most ticks are a no-op by design, and a
          // line per market per minute would bury the publications that matter.
          if (process.env.VERBOSE === "1") {
            console.log(`market ${r.marketId}: skipped -- ${r.reason}`);
          }
        }
      }
    } catch (error) {
      // A failed tick is survivable: the odds simply stay stale, and no payout reads them.
      // So this logs and continues rather than exiting -- unlike the sequencer, where a
      // diverged mirror is fatal because it corrupts every proof built against it.
      console.error("publisher tick failed:", error instanceof Error ? error.message : error);
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
