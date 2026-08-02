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
import { pathToFileURL } from "node:url";
import { Sequencer } from "./sequencer.ts";
import { initHasher } from "./tree.ts";
import { chainFor } from "./chains.ts";
import { Relayer, RelayError, parseRelayRequest } from "./relay.ts";
import type { RelayableAction, RelayRequest, RelayResult } from "./relay.ts";
import { createPublicClient, http } from "viem";
import type { Address, PublicClient } from "viem";

/** The subset of Sequencer the HTTP surface touches, so the handler can be tested alone. */
interface PathSource {
  tree: { size: number; root(): bigint };
  pathFor(commitment: bigint): {
    index: number;
    root: bigint;
    path: { pathElements: bigint[]; pathIndices: bigint[] };
  };
}

/** The subset of Relayer the HTTP surface touches -- same reason as PathSource. */
interface RelaySink {
  submit(action: RelayableAction, args: readonly unknown[]): Promise<RelayResult>;
}

/**
 * Read a JSON body, with a hard size cap.
 *
 * There was no body parsing in this service before /relay -- every route was a GET. The cap
 * matters because this is the first endpoint an untrusted client can push bytes into, and an
 * unbounded read is a trivial memory exhaustion.
 */
const MAX_BODY_BYTES = 64 * 1024;

function readJsonBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new RelayError(`body exceeds ${MAX_BODY_BYTES} bytes`, 413));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new RelayError("body is not valid JSON"));
      }
    });
    req.on("error", reject);
  });
}

async function handleRelay(
  req: IncomingMessage,
  res: ServerResponse,
  json: Record<string, string>,
  relayer: RelaySink,
): Promise<void> {
  try {
    const body = (await readJsonBody(req)) as RelayRequest;
    const { action, args } = parseRelayRequest(body);
    const result = await relayer.submit(action, args);

    res.writeHead(200, json).end(
      JSON.stringify({
        hash: result.hash,
        blockNumber: Number(result.blockNumber),
        gasUsed: result.gasUsed.toString(),
        relayer: result.relayer,
      }),
    );
  } catch (error) {
    const status = error instanceof RelayError ? error.status : 500;
    res.writeHead(status, json).end(JSON.stringify({ error: (error as Error).message }));
  }
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
export function createPathHandler(
  sequencer: PathSource,
  corsOrigin = "*",
  relayer?: RelaySink,
) {
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
          // POST is here for /relay, which unlike every other route sends a body and
          // therefore a content-type header -- which is what triggers preflight at all.
          "access-control-allow-methods": "GET, POST, OPTIONS",
          "access-control-allow-headers": "content-type",
          "access-control-max-age": "86400",
        })
        .end();
      return;
    }

    // Submit a user's action from a relayer account, so their own address never appears on
    // chain. Only proof-gated actions are accepted; see relay.ts for why `deposit` is not one
    // and why a relayer cannot redirect a withdrawal it submits.
    if (url.pathname === "/relay") {
      if (req.method !== "POST") {
        res.writeHead(405, json).end('{"error":"POST only"}');
        return;
      }
      if (!relayer) {
        res.writeHead(503, json).end('{"error":"relaying is not enabled on this sequencer"}');
        return;
      }
      handleRelay(req, res, json, relayer);
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

  // MUST run before `new Sequencer(...)`: `Sequencer.tree` is a field initializer
  // (`readonly tree = new CommitmentTree()`), which runs synchronously during construction
  // and calls hash2 immediately to compute the empty-tree roots. `sequencer.init()` also
  // calls this, but by then the constructor has already thrown. verify-mirror.ts and every
  // test get this ordering right; this entrypoint -- the actual service -- did not, and
  // nothing caught it because nothing had run main() as a cold process before.
  await initHasher();

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

  // Relaying is opt-in: it spends the operator's own gas on users' behalf, so it must never
  // switch itself on by existing. RELAY_MNEMONIC is deliberately separate from
  // RELAYER_MNEMONIC -- the sequencer's batching account is authorised by `onlySequencer` and
  // should not also be the address every user action traces to.
  const relayMnemonic = process.env.RELAY_MNEMONIC;
  let relayer: Relayer | undefined;

  if (relayMnemonic) {
    const publicClient = createPublicClient({
      chain,
      transport: http(process.env.RPC_URL ?? chain.rpcUrls.default.http[0]!),
    }) as PublicClient;

    relayer = new Relayer({
      rpcUrl: process.env.RPC_URL ?? chain.rpcUrls.default.http[0]!,
      chain,
      poolAddress: required("POOL_ADDRESS") as Address,
      mnemonic: relayMnemonic,
      publicClient,
      relayerCount: Number(process.env.RELAY_ACCOUNTS ?? 5),
      releaseIntervalMs: Number(process.env.RELAY_RELEASE_INTERVAL_MS ?? 0),
    });
    console.log(`relaying enabled, ${relayer.addresses.length} account(s): ${relayer.addresses.join(", ")}`);
    console.log("fund these, or every relayed action fails with insufficient balance");
    if (relayer.releaseIntervalMs > 0) {
      console.log(
        `holding submissions ${relayer.releaseIntervalMs}ms and releasing them shuffled, so ` +
          "arrival order carries no information",
      );
    } else {
      console.log(
        "RELAY_RELEASE_INTERVAL_MS unset -- submissions forward immediately, so the order " +
          "they were requested in is the order they land in",
      );
    }
  } else {
    console.log("relaying DISABLED (set RELAY_MNEMONIC to enable) -- users submit their own txs,");
    console.log("which means their address is on chain next to every action they take");
  }

  createServer(createPathHandler(sequencer, process.env.CORS_ORIGIN ?? "*", relayer)).listen(
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

// Only boot when run as a program, not when imported.
//
// `createPathHandler` is exported so it can be tested without RPC, a mnemonic, or a chain --
// but an unguarded `main()` at module scope defeated that: importing the handler started the
// whole service, which then failed on missing env vars and called process.exit(1) from inside
// the test runner. The tests still passed, so it surfaced only as an "unhandled rejection"
// nobody had to act on.
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
