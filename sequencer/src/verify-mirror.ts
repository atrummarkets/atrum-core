/**
 * Rebuild the tree mirror from a live chain and assert it matches the on-chain root.
 *
 * WHY THIS IS WORTH A DEDICATED TOOL
 *
 * A diverged mirror is the worst failure this system has, because it is SILENT. Every gas
 * number stays right, every transaction succeeds, and users simply get Merkle paths for a
 * tree shape that never existed -- so their proofs fail on-chain with `UnknownRoot` and no
 * indication of why. Nothing else in the stack notices.
 *
 * The reconstruction is also the least obvious part of the sequencer. `insertedCount` counts
 * real commitments, but every graft inserts exactly 64 leaves and pads the remainder with
 * fillers derived on-chain from that batch's own `treeStart`. A market with light traffic is
 * almost entirely filler: measured on testnet, five batches held 6 real commitments and 314
 * fillers. Slicing the queue into 64s -- the obvious approach, and what this code used to do
 * -- throws on the first partial batch and the sequencer never boots.
 *
 * So: run this after any deployment, after any restart you are unsure about, and in CI
 * against a long-lived address. It is one RPC round trip per batch and takes about a second.
 *
 * Run: POOL=0x.. MONAD_RPC_URL=.. node --experimental-strip-types src/verify-mirror.ts
 */
import { createPublicClient, http, parseAbi, type Address } from "viem";
import { Sequencer } from "./sequencer.ts";
import { initHasher } from "./tree.ts";
import { chainFor } from "./chains.ts";
import { rpcTransport } from "./rpc.ts";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing required env var ${name}`);
  return value;
}

async function main(): Promise<void> {
  const chain = chainFor(process.env.NETWORK);
  const rpcUrl = process.env.RPC_URL ?? process.env.MONAD_RPC_URL ?? chain.rpcUrls.default.http[0]!;
  const pool = required("POOL") as Address;

  await initHasher();

  const started = Date.now();
  const sequencer = new Sequencer({
    rpcUrl,
    chain,
    poolAddress: pool,
    // Never used. `resync` only reads, so rebuilding needs no signing key -- which is the
    // point: this can be run by anyone, including from CI, without a funded account.
    mnemonic: "test test test test test test test test test test test junk",
  });
  await sequencer.init();
  const elapsed = Date.now() - started;

  const client = createPublicClient({ chain, transport: rpcTransport(rpcUrl) });
  const tree = (await client.readContract({
    address: pool,
    abi: parseAbi(["function tree() view returns (address)"]),
    functionName: "tree",
  })) as Address;
  const onchainRoot = (await client.readContract({
    address: tree,
    abi: parseAbi(["function root() view returns (uint256)"]),
    functionName: "root",
  })) as bigint;

  const mirrorRoot = sequencer.tree.root();

  console.log(`rebuilt ${sequencer.tree.size} leaves in ${elapsed}ms`);
  console.log(`mirror root   : ${mirrorRoot}`);
  console.log(`on-chain root : ${onchainRoot}`);

  if (mirrorRoot !== onchainRoot) {
    console.error("MIRROR DIVERGED -- this sequencer would serve paths for a tree that never existed");
    process.exit(1);
  }
  console.log("MIRROR OK");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
