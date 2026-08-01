/**
 * Sequencer entry point: batching loop plus a Merkle-path HTTP endpoint.
 *
 * The HTTP surface is deliberately tiny and read-only. The sequencer holds no user
 * secrets and can produce no proofs -- a client asks for the path to a commitment and
 * builds its own proof locally. Anything more here would be a place for secrets to end
 * up on a server.
 *
 * Run: node --experimental-strip-types src/main.ts
 */
import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { Sequencer } from "./sequencer.ts";
import { chainFor } from "./chains.ts";
import type { Address } from "viem";

/** The subset of Sequencer the HTTP surface touches, so the handler can be tested alone. */
interface PathSource {
  tree: { size: number; root(): bigint };
  pathFor(commitment: bigint): {
    index: number;
    root: bigint;
    path: { pathElements: bigint[]; pathIndices: bigint[] };
  };
}

/**
 * The read-only HTTP surface, extracted so it can be tested without an RPC connection, a
 * mnemonic, or a running chain. Previously this lived inline in `main` and the only way to
 * exercise it was to boot the whole sequencer.
 *
 * CORS: the browser client is served from a different origin, so without these headers every
 * Merkle-path fetch fails in the browser while working perfectly from curl -- a genuinely
 * confusing way to lose an afternoon.
 *
 * `*` is right for testnet: every value served here is already public on chain, and this
 * service holds no credentials or cookies to protect. Set CORS_ORIGIN to lock it down.
 *
 * NOTE: headers alone suffice only while the client sends NO custom request headers. A plain
 * `fetch(url)` GET is a "simple request" and skips preflight. The moment anyone adds an
 * Authorization or Content-Type header the browser sends an OPTIONS preflight, which is why
 * OPTIONS is answered explicitly below rather than falling through to 404.
 */
export function createPathHandler(sequencer: PathSource, corsOrigin = "*") {
  const json = {
    "content-type": "application/json",
    "access-control-allow-origin": corsOrigin,
  };

  return (req: IncomingMessage, res: ServerResponse): void => {
    const url = new URL(req.url ?? "/", "http://localhost");

    if (req.method === "OPTIONS") {
      res
        .writeHead(204, {
          ...json,
          "access-control-allow-methods": "GET, OPTIONS",
          "access-control-allow-headers": "content-type",
          "access-control-max-age": "86400",
        })
        .end();
      return;
    }

    // Liveness. Exists because every other route answers 404 or 400 by design, so an
    // uptime monitor pointed at this service would report it permanently DOWN -- and on a
    // host that sleeps idle services, the monitor is what keeps it awake.
    //
    // Returns only values that are already public on-chain. A health endpoint is the
    // easiest place to leak state by accident.
    if (url.pathname === "/health") {
      res.writeHead(200, json).end(
        JSON.stringify({
          status: "ok",
          leaves: sequencer.tree.size,
          root: sequencer.tree.root().toString(),
        }),
      );
      return;
    }

    if (url.pathname !== "/path") {
      res
        .writeHead(404, json)
        .end('{"error":"only /health and /path?commitment=0x... are served"}');
      return;
    }

    try {
      const commitment = BigInt(url.searchParams.get("commitment") ?? "");
      const { index, path, root } = sequencer.pathFor(commitment);

      res.writeHead(200, json).end(
        JSON.stringify({
          index,
          root: root.toString(),
          pathElements: path.pathElements.map(String),
          pathIndices: path.pathIndices.map(String),
        }),
      );
    } catch (error) {
      res.writeHead(400, json).end(JSON.stringify({ error: (error as Error).message }));
    }
  };
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing required env var ${name}`);
  return value;
}

async function main(): Promise<void> {
  const chain = chainFor(process.env.NETWORK);

  const sequencer = new Sequencer({
    rpcUrl: process.env.RPC_URL ?? chain.rpcUrls.default.http[0]!,
    chain,
    poolAddress: required("POOL_ADDRESS") as Address,
    mnemonic: required("RELAYER_MNEMONIC"),
    maxBatchDelayMs: Number(process.env.MAX_BATCH_DELAY_MS ?? 60_000),
  });

  await sequencer.init();
  console.log(`sequencer up on ${chain.name}, mirror holds ${sequencer.tree.size} leaves`);

  const port = Number(process.env.PORT ?? 8080);

  createServer(createPathHandler(sequencer, process.env.CORS_ORIGIN ?? "*")).listen(
    port,
    () => console.log(`merkle path endpoint on :${port}`),
  );

  // Poll rather than subscribe. A dropped websocket that silently stops delivering
  // events would stall the queue indefinitely and look healthy; a poll loop that fails
  // is visible on the next tick.
  for (;;) {
    try {
      const submitted = await sequencer.tick();
      if (submitted) {
        console.log(`grafted a batch, mirror now ${sequencer.tree.size} leaves`);
      }
    } catch (error) {
      // A diverged mirror is fatal on purpose -- serving paths from a wrong tree is
      // worse than serving none, because the failures land on users as unexplained
      // proof rejections.
      console.error("sequencer tick failed:", error);
      if ((error as Error).message.includes("MIRROR DIVERGED")) process.exit(1);
    }

    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
