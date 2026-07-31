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
import { defineChain } from "viem";
import { Sequencer } from "./sequencer.ts";
import type { Address } from "viem";

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

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing required env var ${name}`);
  return value;
}

async function main(): Promise<void> {
  const chain = process.env.NETWORK === "mainnet" ? monadMainnet : monadTestnet;

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
  createServer((req, res) => {
    const url = new URL(req.url ?? "/", `http://localhost:${port}`);

    if (url.pathname !== "/path") {
      res.writeHead(404).end('{"error":"only /path?commitment=0x... is served"}');
      return;
    }

    try {
      const commitment = BigInt(url.searchParams.get("commitment") ?? "");
      const { index, path, root } = sequencer.pathFor(commitment);

      res.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({
          index,
          root: root.toString(),
          pathElements: path.pathElements.map(String),
          pathIndices: path.pathIndices.map(String),
        }),
      );
    } catch (error) {
      res
        .writeHead(400, { "content-type": "application/json" })
        .end(JSON.stringify({ error: (error as Error).message }));
    }
  }).listen(port, () => console.log(`merkle path endpoint on :${port}`));

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
