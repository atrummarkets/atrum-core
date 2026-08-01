/**
 * The Atrum publisher.
 *
 * The only process that holds the committee secret, and therefore the only one that can
 * turn the accumulated ciphertext into a number. It exists so a market can show odds while
 * betting is open, without anyone -- including the contract -- learning the pool's size.
 *
 * What it does, once per tick, per market:
 *   1. Read the accumulated YES and NO ciphertexts from `ElGamalAccumulator`.
 *   2. Decrypt both locally (BSGS).
 *   3. Ask `ratio-policy.ts` whether publishing is allowed right now, and at what precision.
 *   4. If so, call `publishAttestedRatio(marketId, ratioBps)`.
 *
 * WHAT IT MUST NEVER DO, and the reason each one matters:
 *
 *   - Publish, log, or otherwise emit the MAGNITUDES. The decrypted totals are the single
 *     most sensitive value in the system; they are what the encrypted accumulator exists to
 *     hide. They are held in locals, used to compute one ratio, and dropped. There is no
 *     debug flag that prints them, because a debug flag that prints them is how they end up
 *     in a log aggregator.
 *   - Publish more often or more precisely than `ratio-policy.ts` allows. See the leak
 *     analysis in that file: the ratio is scale-free, but a fine-grained SEQUENCE of ratios
 *     combined with public bet sides and the exact totals revealed at settlement can be
 *     solved for individual stakes.
 *
 * WHAT IT IS NOT TRUSTED FOR:
 *
 *   The published ratio is UNVERIFIED, by construction -- see the notice on
 *   `publishAttestedRatio`. Checking a ratio against ciphertexts would need the plaintexts,
 *   and publishing those defeats the whole phase. So a dishonest publisher can post any
 *   number it likes. That is survivable only because NO PAYOUT READS THIS VALUE: settlement
 *   goes through `publishFinalTotals`, which carries a Chaum-Pedersen proof that the
 *   decryption is honest. The odds are decoration; the money is proved.
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
import { privateKeyToAccount } from "viem/accounts";
import { buildDecryptor, type Decryptor, type Point } from "./elgamal.ts";
import { decide, DEFAULT_POLICY, type RatioPolicy, type MarketState } from "./ratio-policy.ts";

export const ACCUMULATOR_ABI = parseAbi([
  "function totalAffine(uint32 marketId, uint8 outcome) view returns (uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)",
  "event StakeAccumulated(uint32 indexed marketId, uint8 outcome)",
]);

export const ENCRYPTED_POOL_ABI = parseAbi([
  "function publishAttestedRatio(uint32 marketId, uint256 ratioBps)",
  "function attestedRatioBps(uint32 marketId) view returns (uint256)",
  "function lastAttestedAt(uint32 marketId) view returns (uint256)",
  "function minPublishInterval() view returns (uint256)",
  "function settled(uint32 marketId) view returns (bool)",
]);

export const VAULT_ABI = parseAbi(["function bettingCloseTime() view returns (uint64)"]);
export const POOL_ABI = parseAbi(["function marketVault(uint32) view returns (address)"]);

const OUTCOME_YES = 1;
const OUTCOME_NO = 2;

/**
 * Blocks behind the tip the bet cursor trails.
 *
 * The cursor is monotonic -- it never re-reads a range -- so a log counted from a block
 * that is later reorged out is counted forever. Trailing the head makes that vanishingly
 * unlikely without needing reorg handling.
 */
const CONFIRMATIONS = 5n;

/// Monad's public RPC rejects wider ranges outright: "eth_getLogs is limited to a 100 range"
/// (error -32614). Measured, not assumed.
const MAX_LOG_RANGE = 100n;

/**
 * BSGS search bound. The circuits range-check `units` to 40 bits, but a POOL total is a sum
 * of many such stakes, so the bound has to cover the pool rather than one bet.
 *
 * Cost is O(sqrt(bound)) with a table of that size in memory, so this cannot simply be set
 * to 2^40: that is ~1e6 baby steps, which is workable, whereas the true 40-bit ceiling on a
 * sum would be far worse. 2^26 covers a pool of ~67 million units and costs ~8,192 steps.
 * If a real market exceeds it, decryption THROWS rather than publishing a wrong ratio.
 */
export const DEFAULT_DECRYPT_BOUND = 1n << 26n;

export interface PublisherConfig {
  rpcUrl: string;
  chain: Parameters<typeof createWalletClient>[0]["chain"];
  poolAddress: Address;
  accumulatorAddress: Address;
  encryptedPoolAddress: Address;
  /** Markets to publish odds for. */
  marketIds: number[];
  /**
   * The committee private key. Read from the environment by `main`, never from a file
   * committed to the repo, and never logged.
   */
  committeeSecret: bigint;
  /** Signs `publishAttestedRatio`. Distinct from the committee key: this one only pays gas. */
  publisherPrivateKey: `0x${string}`;
  policy?: RatioPolicy;
  decryptBound?: bigint;
  /**
   * Block the accumulator was deployed at. Without it the first scan starts at genesis,
   * which public RPC endpoints rate-limit or refuse.
   */
  deployBlock?: bigint;
}

export interface TickResult {
  marketId: number;
  published: boolean;
  ratioBps?: number;
  reason?: string;
}

export class Publisher {
  private readonly publicClient: PublicClient;
  private readonly walletClient: WalletClient;
  private readonly config: PublisherConfig;
  private readonly policy: RatioPolicy;
  private readonly bound: bigint;
  private decryptor: Decryptor | null = null;

  /** betCount at the last publication, per market. Rebuilt from logs on first tick. */
  private readonly betCountAtLastPublish = new Map<number, number>();

  /**
   * Running bet count per market, plus the block it is accurate through.
   *
   * Without this the publisher re-scanned every `StakeAccumulated` log from genesis on
   * every tick. That is O(chain length) per tick forever: it grows without bound, and it
   * is exactly the query a public RPC endpoint throttles first. The cursor makes a tick
   * cost one small range query regardless of how old the market is.
   */
  private readonly betCursor = new Map<number, { count: number; throughBlock: bigint }>();

  constructor(config: PublisherConfig) {
    this.config = config;
    this.policy = config.policy ?? DEFAULT_POLICY;
    this.bound = config.decryptBound ?? DEFAULT_DECRYPT_BOUND;

    this.publicClient = createPublicClient({
      chain: config.chain,
      transport: http(config.rpcUrl),
    }) as PublicClient;

    this.walletClient = createWalletClient({
      chain: config.chain,
      transport: http(config.rpcUrl),
      account: privateKeyToAccount(config.publisherPrivateKey),
    });
  }

  async init(): Promise<void> {
    this.decryptor = await buildDecryptor(this.config.committeeSecret);
  }

  /** One pass over every configured market. Never throws for a single market's failure. */
  async tick(): Promise<TickResult[]> {
    const out: TickResult[] = [];
    for (const marketId of this.config.marketIds) {
      try {
        out.push(await this.tickMarket(marketId));
      } catch (err) {
        // Deliberately does not include the error's data beyond its message: a decryption
        // failure could otherwise carry partial plaintext into a log.
        out.push({
          marketId,
          published: false,
          reason: `error: ${err instanceof Error ? err.message : "unknown"}`,
        });
      }
    }
    return out;
  }

  private async tickMarket(marketId: number): Promise<TickResult> {
    if (!this.decryptor) throw new Error("init() was not awaited");

    const state = await this.readState(marketId);
    const decision = decide(state, this.policy);

    if (!decision.publish) {
      return { marketId, published: false, reason: decision.reason };
    }

    await this.walletClient.writeContract({
      address: this.config.encryptedPoolAddress,
      abi: ENCRYPTED_POOL_ABI,
      functionName: "publishAttestedRatio",
      args: [marketId, BigInt(decision.ratioBps)],
      chain: this.config.chain,
      account: this.walletClient.account!,
    });

    this.betCountAtLastPublish.set(marketId, state.betCount);
    return { marketId, published: true, ratioBps: decision.ratioBps };
  }

  /**
   * Everything `decide` needs. The decrypted totals live only inside the returned object,
   * which the caller uses and drops.
   */
  private async readState(marketId: number): Promise<MarketState> {
    const [yes, no] = await Promise.all([
      this.decryptSide(marketId, OUTCOME_YES),
      this.decryptSide(marketId, OUTCOME_NO),
    ]);

    const [settled, lastAttestedAt, minPublishInterval, betCount, bettingClosed] = await Promise.all([
      this.publicClient.readContract({
        address: this.config.encryptedPoolAddress,
        abi: ENCRYPTED_POOL_ABI,
        functionName: "settled",
        args: [marketId],
      }) as Promise<boolean>,
      this.publicClient.readContract({
        address: this.config.encryptedPoolAddress,
        abi: ENCRYPTED_POOL_ABI,
        functionName: "lastAttestedAt",
        args: [marketId],
      }) as Promise<bigint>,
      this.publicClient.readContract({
        address: this.config.encryptedPoolAddress,
        abi: ENCRYPTED_POOL_ABI,
        functionName: "minPublishInterval",
      }) as Promise<bigint>,
      this.countBets(marketId),
      this.isBettingClosed(marketId),
    ]);

    const now = Math.floor(Date.now() / 1000);
    const everPublished = lastAttestedAt > 0n;

    return {
      yesUnits: yes,
      noUnits: no,
      betCount,
      // On a cold start `betCountAtLastPublish` is unknown even though the chain says a
      // publication happened. Treating that as "0 bets ago" would let the very next bet
      // trigger a publish; assuming the current count is the conservative direction, since
      // it forces a full `minBetsBetweenPublishes` gap before the next one.
      betCountAtLastPublish: everPublished
        ? (this.betCountAtLastPublish.get(marketId) ?? betCount)
        : null,
      secondsSinceLastPublish: everPublished ? now - Number(lastAttestedAt) : null,
      minPublishIntervalSeconds: Number(minPublishInterval),
      settled,
      bettingClosed,
    };
  }

  private async decryptSide(marketId: number, outcome: number): Promise<bigint> {
    const [c1x, c1y, c2x, c2y] = (await this.publicClient.readContract({
      address: this.config.accumulatorAddress,
      abi: ACCUMULATOR_ABI,
      functionName: "totalAffine",
      args: [marketId, outcome],
    })) as [bigint, bigint, bigint, bigint];

    const c1: Point = [c1x, c1y];
    const c2: Point = [c2x, c2y];
    return this.decryptor!.decrypt(c1, c2, this.bound);
  }

  /**
   * Encrypted bets seen for this market, from `StakeAccumulated` logs.
   *
   * Incremental: only the range since the last tick is queried, and the cursor advances
   * to a CONFIRMED head rather than the tip. Counting a log from a block that later
   * reorgs away would permanently overstate the count, and since the count gates
   * publication cadence, an overstated count means publishing more often than the policy
   * allows -- which is the leak the policy exists to bound.
   */
  private async countBets(marketId: number): Promise<number> {
    const head = await this.publicClient.getBlockNumber();
    const confirmed = head > CONFIRMATIONS ? head - CONFIRMATIONS : 0n;

    const cached = this.betCursor.get(marketId);

    // COLD START DOES NOT SCAN HISTORY. Monad's public RPC caps `eth_getLogs` at a 100-block
    // range, so walking back to the deploy block would take thousands of requests.
    //
    // It does not need to. The count only gates publication CADENCE, and starting from the
    // current head means a freshly-booted publisher waits for a full quota of NEW bets
    // before its first publication. That errs toward publishing less, which is the safe
    // direction -- the leak the policy bounds comes from publishing too OFTEN.
    const from = cached ? cached.throughBlock + 1n : confirmed;

    // Nothing newly confirmed since last time.
    if (cached && confirmed < from) return cached.count;

    // Chunked to the RPC's 100-block ceiling. Even an incremental range exceeds it after a
    // few minutes of downtime, and a host that sleeps idle services produces exactly that.
    let found = 0;
    for (let lo = from; lo <= confirmed; lo += MAX_LOG_RANGE) {
      const hi = lo + MAX_LOG_RANGE - 1n < confirmed ? lo + MAX_LOG_RANGE - 1n : confirmed;
      const logs = await this.publicClient.getLogs({
        address: this.config.accumulatorAddress,
        event: ACCUMULATOR_ABI[1],
        args: { marketId },
        fromBlock: lo,
        toBlock: hi,
      });
      found += logs.length;
    }

    const count = (cached?.count ?? 0) + found;
    this.betCursor.set(marketId, { count, throughBlock: confirmed });
    return count;
  }

  private async isBettingClosed(marketId: number): Promise<boolean> {
    const vault = (await this.publicClient.readContract({
      address: this.config.poolAddress,
      abi: POOL_ABI,
      functionName: "marketVault",
      args: [marketId],
    })) as Address;

    const closeTime = (await this.publicClient.readContract({
      address: vault,
      abi: VAULT_ABI,
      functionName: "bettingCloseTime",
    })) as bigint;

    return BigInt(Math.floor(Date.now() / 1000)) >= closeTime;
  }
}
