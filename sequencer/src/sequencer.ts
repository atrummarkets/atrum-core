/**
 * The Atrum sequencer.
 *
 * Responsibilities, in order of how badly they break things when wrong:
 *
 *   1. Keep a mirror of the commitment tree and serve Merkle paths. Without this no
 *      user can build a bet or redeem proof, because the contract stores only a root.
 *   2. Graft queued commitments in fixed batches of 64. Unbatched insertion costs
 *      ~1,107,646 gas against a 2,000,000 envelope that already holds a ~1,029,454
 *      verify -- it does not fit. Batching is a correctness requirement of the gas
 *      budget, not an optimisation.
 *   3. Submit partial batches; the CONTRACT pads them with derived fillers.
 *   4. Rotate relayer accounts so batches do not all trace to one address.
 *
 * What the sequencer CANNOT do, by construction:
 *   - Learn which note a bet spent. It sees the same public signals as everyone else.
 *   - Graft a commitment nobody queued. `flushBatch` compares the submitted leaves
 *     against the on-chain queue.
 *   - Choose a padding leaf. Fillers are derived on-chain from
 *     keccak256(PAD_DOMAIN, treeStart, slot), so it cannot author a spendable one.
 *     A sequencer-chosen filler used to be a full vault drain -- see
 *     contracts/test/PaddingExploit.t.sol.
 *
 * What it CAN do: stall. It is trusted for liveness and ordering only.
 */
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";
import {
  CommitmentTree,
  BATCH_SIZE,
  rebuildBatches,
  type GraftedBatch,
  FIELD_SIZE,
  initHasher,
  derivedFiller,
  type MerklePath,
} from "./tree.ts";
import { RelayerPool } from "./relayers.ts";

export const POOL_ABI = parseAbi([
  "event CommitmentQueued(uint256 indexed commitment, uint256 queueIndex)",
  "event BatchInserted(uint256 startIndex, uint256 count, uint256 newRoot)",
  "function queuedCount() view returns (uint256)",
  "function insertedCount() view returns (uint256)",
  "function pendingCommitments(uint256) view returns (uint256)",
  "function flushBatch(uint256[] calldata leaves)",
  "function BATCH_SIZE() view returns (uint256)",
  "function batchCount() view returns (uint256)",
  "function batchRealCounts(uint256) view returns (uint32)",
]);

/**
 * The declared gas limit for a batch transaction.
 *
 * Measured: a 64-leaf graft costs ~2,791,576. This is NOT the uniform action envelope --
 * that rule applies to USER actions, where a snug limit would leak which private action
 * was taken. A sequencer batch is public by nature and reveals nothing, so it is sized
 * normally.
 */
export const BATCH_GAS_LIMIT = 4_000_000n;

export interface SequencerConfig {
  rpcUrl: string;
  chain: Parameters<typeof createWalletClient>[0]["chain"];
  poolAddress: Address;
  mnemonic: string;
  /** Graft a padded batch after this long, even if fewer than 64 are queued. */
  maxBatchDelayMs?: number;
  /**
   * Block the pool was deployed at. Without it `resync` scans logs from genesis, which
   * public RPC endpoints rate-limit or refuse outright.
   */
  deployBlock?: bigint;
}

export class Sequencer {
  readonly tree = new CommitmentTree();
  private readonly publicClient: PublicClient;
  private readonly relayers: RelayerPool;
  private readonly config: SequencerConfig;
  private firstPendingSeenAt: number | null = null;

  constructor(config: SequencerConfig) {
    this.config = config;
    this.relayers = new RelayerPool(config.mnemonic);
    this.publicClient = createPublicClient({
      chain: config.chain,
      transport: http(config.rpcUrl),
    }) as PublicClient;
  }

  async init(): Promise<void> {
    await initHasher();
    await this.resync();
  }

  /**
   * Rebuild the mirror from on-chain state.
   *
   * Always read the queue back from the chain rather than trusting local memory. A
   * restarted sequencer with a stale mirror hands out Merkle paths for a tree shape
   * that never existed, and every proof built from them fails.
   */
  async resync(): Promise<void> {
    const inserted = Number(await this.read("insertedCount"));
    this.tree.reset();
    if (inserted === 0) return;

    // Batch boundaries come from CONTRACT STORAGE, not from `BatchInserted` logs.
    //
    // NEITHER RPC will serve a log-based rebuild. Measured: Monad's public endpoint caps
    // `eth_getLogs` at a 100-block range (error -32614), and Alchemy's free tier at NINE. A
    // week-old market spans over a million blocks, so it would need six figures of requests
    // and be rate-limited long before finishing -- and a restart must complete before any
    // Merkle path can be served, so that is an outage, not a slow boot.
    //
    // `insertedCount` and `tree.nextIndex()` give the totals but not the DISTRIBUTION of
    // real leaves across batches -- and that distribution decides where every filler sits.
    // So the contract stores it.
    const batchTotal = Number(await this.read("batchCount"));

    const counts = await Promise.all(
      Array.from({ length: batchTotal }, (_, i) => this.read("batchRealCounts", [BigInt(i)])),
    );

    const batches: GraftedBatch[] = counts.map((count, i) => ({
      // Batches are always BATCH_SIZE leaves and always aligned, so the graft index is
      // implied by position -- it does not need storing.
      startIndex: BigInt(i * BATCH_SIZE),
      count: Number(count),
    }));

    const queued = await this.readQueued(inserted);
    for (const batch of rebuildBatches(batches, queued)) {
      this.tree.insertBatch(batch);
    }
  }

  /**
   * Read the first `count` queued commitments.
   *
   * Chunked and parallel rather than a serial `await` per leaf. The serial version cost one
   * RPC round-trip per commitment ever inserted, so a restart went as O(n) network calls --
   * minutes on a market of any size, during which no Merkle path can be served and
   * therefore no user can build a proof. A restart is not a rare event on a host that
   * sleeps idle services.
   */
  private async readQueued(count: number): Promise<bigint[]> {
    const CHUNK = 64;
    const out: bigint[] = [];
    for (let i = 0; i < count; i += CHUNK) {
      const end = Math.min(i + CHUNK, count);
      const chunk = await Promise.all(
        Array.from({ length: end - i }, (_, k) => this.read("pendingCommitments", [BigInt(i + k)])),
      );
      out.push(...chunk);
    }
    return out;
  }

  private async read(fn: string, args: readonly unknown[] = []): Promise<bigint> {
    return (await this.publicClient.readContract({
      address: this.config.poolAddress,
      abi: POOL_ABI,
      functionName: fn as never,
      args: args as never,
    })) as bigint;
  }

  /** Merkle path for a commitment, for a client building a bet or redeem proof. */
  pathFor(commitment: bigint): { index: number; path: MerklePath; root: bigint } {
    const index = this.tree.indexOf(commitment);
    if (index < 0) {
      throw new Error(
        "commitment is not in the tree yet -- it is queued but not grafted. " +
          "Wait for the next batch.",
      );
    }
    return { index, path: this.tree.path(index), root: this.tree.root() };
  }

  /**
   * Graft one batch if there is work to do. Returns true if a batch was submitted.
   *
   * A batch is submitted when 64 real commitments are queued, or when the oldest
   * pending commitment has waited longer than `maxBatchDelayMs` -- in which case the
   * remainder is padded. Without the deadline a quiet market deadlocks: the last 63
   * users wait forever for a 64th.
   */
  async tick(): Promise<boolean> {
    const queued = await this.read("queuedCount");
    const inserted = await this.read("insertedCount");
    const pending = Number(queued - inserted);

    if (pending === 0) {
      this.firstPendingSeenAt = null;
      return false;
    }

    if (this.firstPendingSeenAt === null) this.firstPendingSeenAt = Date.now();

    const delay = this.config.maxBatchDelayMs ?? 60_000;
    const deadlineHit = Date.now() - this.firstPendingSeenAt >= delay;

    if (pending < BATCH_SIZE && !deadlineHit) return false;

    // Submit only the REAL queued commitments. `flushBatch` pads the rest of the
    // subtree with fillers it derives itself, so there is nothing here to choose --
    // a sequencer-chosen filler was a full vault drain (PaddingExploit.t.sol).
    const real = Math.min(pending, BATCH_SIZE);
    const treeStart = await this.readTreeNextIndex();

    const realLeaves: bigint[] = [];
    for (let i = 0; i < real; i++) {
      realLeaves.push(await this.read("pendingCommitments", [inserted + BigInt(i)]));
    }

    await this.submit("flushBatch", [realLeaves]);

    // Mirror the same padding the contract applied, or the next Merkle path served
    // from here is built against a root the chain does not have.
    const leaves = [...realLeaves];
    for (let slot = real; slot < BATCH_SIZE; slot++) {
      leaves.push(derivedFiller(treeStart, BigInt(slot)));
    }
    this.tree.insertBatch(leaves);
    this.firstPendingSeenAt = null;

    const onChainRoot = await this.readRoot();
    if (onChainRoot !== this.tree.root()) {
      throw new Error(
        `MIRROR DIVERGED: on-chain root ${onChainRoot} != mirror ${this.tree.root()}. ` +
          "Every Merkle path served from here would be wrong -- refusing to continue.",
      );
    }

    return true;
  }

  /** Read the tree's root -- two hops, because the pool holds the tree by address. */
  private async readRoot(): Promise<bigint> {
    const treeAddress = (await this.publicClient.readContract({
      address: this.config.poolAddress,
      abi: parseAbi(["function tree() view returns (address)"]),
      functionName: "tree",
    })) as Address;

    return (await this.publicClient.readContract({
      address: treeAddress,
      abi: parseAbi(["function root() view returns (uint256)"]),
      functionName: "root",
    })) as bigint;
  }

  /** The tree position the next batch will graft at -- the nonce for derived padding. */
  private async readTreeNextIndex(): Promise<bigint> {
    const treeAddress = (await this.publicClient.readContract({
      address: this.config.poolAddress,
      abi: parseAbi(["function tree() view returns (address)"]),
      functionName: "tree",
    })) as Address;

    return (await this.publicClient.readContract({
      address: treeAddress,
      abi: parseAbi(["function nextIndex() view returns (uint256)"]),
      functionName: "nextIndex",
    })) as bigint;
  }

  private async submit(fn: string, args: readonly unknown[]): Promise<void> {
    const account = this.relayers.next();
    const wallet: WalletClient = createWalletClient({
      account,
      chain: this.config.chain,
      transport: http(this.config.rpcUrl),
    });

    const hash = await wallet.writeContract({
      address: this.config.poolAddress,
      abi: POOL_ABI,
      functionName: fn as never,
      args: args as never,
      // Declared explicitly, never estimated. `eth_estimateGas` is banned on user
      // actions because a per-action estimate leaks which action was taken; here it is
      // declared for the unrelated reason that Monad charges the declared limit and a
      // failed estimate makes wallets pick absurd values.
      gas: BATCH_GAS_LIMIT,
      chain: this.config.chain,
      account,
    });

    // `waitForTransactionReceipt` resolves once the transaction is INCLUDED, not once it
    // SUCCEEDS -- viem never inspects `status`, by design, because "did it revert" is a
    // separate question from "did it land." A caller that skips this check treats every
    // revert as a success.
    //
    // That is exactly how this was found: with the deployed `sequencer` address pointed at
    // a different account than this pool's relayers, every `flushBatch` reverted with
    // `NotSequencer()`, and this function returned normally anyway -- so `tick()` went on to
    // update the in-memory mirror as if the leaves it just tried to graft were really on
    // chain. The result was not an immediate error. It was "MIRROR DIVERGED" one tick later,
    // once a fresh on-chain root stopped matching -- the right failure, a whole tick late,
    // for a reason that had nothing to do with a diverged mirror and everything to do with
    // an unchecked receipt.
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new Error(`${fn} reverted on chain (tx ${hash}, relayer ${account.address})`);
    }
  }
}
