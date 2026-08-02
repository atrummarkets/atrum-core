/**
 * Relay user actions, so a user's own address never appears on chain.
 *
 * WHY THIS IS THE FIRST PRIVACY CHANGE, NOT THE LAST
 *
 * Every other privacy mechanism in this system protects a fact that `tx.from` has already
 * given away. The Merkle proof carefully hides WHICH note was spent; the ElGamal ciphertext
 * hides HOW MUCH was staked -- and then the transaction's sender field names the actor in the
 * most visible position on the chain. Combined with `betMeta`, which carries the outcome, the
 * chain today reads "0xAlice bet YES". Hiding the amount is the entire privacy currently
 * delivered.
 *
 * WHY IT NEEDS NO CONTRACT CHANGE
 *
 * `betEncrypted`, `redeemPrivate` and `withdraw` are PROOF-gated, not sender-gated -- verified
 * exhaustively against ShieldedPool.sol: `msg.sender` appears there only in admin gates, the
 * `onlySequencer` modifier (used by `flushBatch` alone), and `deposit`'s `transferFrom`.
 *
 * The one non-obvious case is `Vault.split/merge/redeem`, which DO read `msg.sender` -- but
 * that sender is the pool contract, never an EOA, so relaying changes nothing about vault
 * accounting.
 *
 * `withdraw` is safe to relay for a subtler reason worth stating: its `recipient` is unpacked
 * from `withdrawData`, which is a PUBLIC SIGNAL OF THE PROOF. A relayer that rewrote the
 * recipient would invalidate the proof. It cannot steal the withdrawal it is submitting.
 *
 * `deposit` is deliberately NOT relayable: it pulls collateral via `transferFrom(msg.sender)`,
 * so relaying it means the relayer holds the money, which means the user paid the relayer --
 * the same link, one hop along.
 *
 * WHAT THIS DOES NOT FIX, AND MUST BE SAID OUT LOUD
 *
 * The relayer knows it was you. Your network address, your proof, your request. Trust is
 * RELOCATED, not removed: instead of the whole chain seeing your address, one party sees your
 * identity. And a relayer can censor -- a second liveness chokepoint after the sequencer. The
 * mitigations are the ordinary ones (several independent relayers, Tor for users who care) and
 * none of them is implemented here.
 */
import { createWalletClient, http, parseAbi } from "viem";
import type { Address, Chain, PublicClient, WalletClient } from "viem";
import { RelayerPool } from "./relayers.ts";

/**
 * The declared gas limit for every relayed action.
 *
 * Monad bills the DECLARED limit rather than the gas used, so the limit is public metadata
 * about which action was taken. Every shielded action therefore declares the SAME value --
 * that uniformity is the anti-fingerprinting rule the whole envelope design rests on.
 *
 * `eth_estimateGas` is banned here for exactly that reason, the same as in `Sequencer.submit`:
 * a per-action estimate leaks the action type to anyone watching the mempool.
 */
export const ACTION_GAS_LIMIT = 2_500_000n;

/** The three actions that are proof-gated and therefore relayable. `deposit` is not one. */
export const RELAYABLE = ["betEncrypted", "redeemPrivate", "withdraw"] as const;
export type RelayableAction = (typeof RELAYABLE)[number];

const RELAY_ABI = parseAbi([
  "function betEncrypted(uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256 root, uint256 nullifierHash, uint256 newCommitment, uint256 betMeta, uint256[4] ciphertext)",
  "function redeemPrivate(uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256 root, uint256 nullifierHash, uint256 newCommitment, uint256 redeemMeta)",
  "function withdraw(uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256 root, uint256 nullifierHash, uint256 changeCommitment, uint256 withdrawData)",
]);

/** How many arguments each action takes after the three proof points. */
const TAIL_ARITY: Record<RelayableAction, number> = {
  betEncrypted: 5, // root, nullifierHash, newCommitment, betMeta, ciphertext[4]
  redeemPrivate: 4, // root, nullifierHash, newCommitment, redeemMeta
  withdraw: 4, // root, nullifierHash, changeCommitment, withdrawData
};

export interface RelayRequest {
  action: string;
  pA: unknown;
  pB: unknown;
  pC: unknown;
  args: unknown;
}

export interface RelayResult {
  hash: `0x${string}`;
  blockNumber: bigint;
  gasUsed: bigint;
  relayer: Address;
}

export class RelayError extends Error {
  // Declared as a field and assigned in the body, NOT as a constructor parameter property.
  // This service runs under `node --experimental-strip-types`, which is strip-only: parameter
  // properties need code generation, not just type erasure, and fail at load with
  // ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX. vitest transpiles properly, so this passes tests and
  // breaks only the real process -- the same shape of gap that hid the initHasher ordering bug.
  readonly status: number;

  constructor(message: string, status = 400) {
    super(message);
    this.name = "RelayError";
    this.status = status;
  }
}

/**
 * Coerce one untrusted value into a bigint.
 *
 * Everything arrives over HTTP from a client we do not trust, as JSON, so numbers are strings
 * (they exceed Number.MAX_SAFE_INTEGER). Anything unparseable is rejected here rather than
 * being handed to viem, which would fail later and less legibly.
 */
function big(value: unknown, what: string): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === "string" && /^(0x[0-9a-fA-F]+|\d+)$/.test(value)) return BigInt(value);
  throw new RelayError(`${what} is not a valid integer`);
}

function bigArray(value: unknown, length: number, what: string): bigint[] {
  if (!Array.isArray(value) || value.length !== length) {
    throw new RelayError(`${what} must be an array of ${length}`);
  }
  return value.map((v, i) => big(v, `${what}[${i}]`));
}

/**
 * Validate an untrusted relay request into concrete contract arguments.
 *
 * This does NOT verify the proof -- the contract does that, and duplicating a Groth16 verifier
 * here would be a second implementation to keep in sync. What it does is reject anything
 * malformed before it costs gas, and refuse any action that is not on the relayable list, so a
 * caller cannot talk the relayer into submitting something unintended with its own funds.
 */
export function parseRelayRequest(body: RelayRequest): {
  action: RelayableAction;
  args: readonly unknown[];
} {
  const action = body?.action;
  if (!RELAYABLE.includes(action as RelayableAction)) {
    throw new RelayError(
      `action must be one of ${RELAYABLE.join(", ")} -- 'deposit' is deliberately not relayable`,
    );
  }
  const act = action as RelayableAction;

  const pA = bigArray(body.pA, 2, "pA");
  const pBraw = body.pB;
  if (!Array.isArray(pBraw) || pBraw.length !== 2) throw new RelayError("pB must be a 2x2 array");
  const pB = [bigArray(pBraw[0], 2, "pB[0]"), bigArray(pBraw[1], 2, "pB[1]")];
  const pC = bigArray(body.pC, 2, "pC");

  const tail = body.args;
  if (!Array.isArray(tail) || tail.length !== TAIL_ARITY[act]) {
    throw new RelayError(`args must be an array of ${TAIL_ARITY[act]} for ${act}`);
  }

  const parsedTail =
    act === "betEncrypted"
      ? [
          big(tail[0], "root"),
          big(tail[1], "nullifierHash"),
          big(tail[2], "newCommitment"),
          big(tail[3], "betMeta"),
          bigArray(tail[4], 4, "ciphertext"),
        ]
      : tail.map((v, i) => big(v, `args[${i}]`));

  return { action: act, args: [pA, pB, pC, ...parsedTail] };
}

export interface RelayerConfig {
  rpcUrl: string;
  chain: Chain;
  poolAddress: Address;
  mnemonic: string;
  publicClient: PublicClient;
  relayerCount?: number;
  /**
   * How long to hold a submission before releasing it, in milliseconds. 0 disables holding.
   *
   * See `Relayer`'s notice: this is the off-chain half of the timing defence, and it is the
   * half a user cannot verify. It is worth having anyway, and worth being honest about.
   */
  releaseIntervalMs?: number;
}

/** A submission waiting for its release window. */
interface Held {
  action: RelayableAction;
  args: readonly unknown[];
  resolve: (r: RelayResult) => void;
  reject: (e: unknown) => void;
}

/**
 * Submits relayed actions, one at a time per account.
 *
 * NONCE SERIALISATION IS THE WHOLE POINT OF THIS CLASS. `Sequencer.submit` builds a fresh
 * WalletClient per call and lets viem fetch the nonce from RPC, which is correct there only
 * because `tick()` is a strictly serial loop. User submissions arrive concurrently, and two
 * in-flight transactions from one account would both read the same nonce and one would be
 * dropped. Each account therefore gets a promise chain, and a submission waits for the
 * previous one on that account before it starts.
 *
 * Round-robin across accounts (from RelayerPool) gives back the parallelism that serialising
 * costs, and is the same rotation the sequencer uses to avoid a single fixed submitter
 * address becoming a landmark.
 *
 * BATCHING AND SHUFFLING -- the off-chain half of the timing defence
 *
 * Forwarding each action the instant it arrives makes ORDER a channel. Alice's request lands
 * before Bob's, so Alice's transaction is mined first, and anyone correlating request timing
 * against on-chain order learns which is which. The on-chain root-age rule stops a note being
 * spent out of the batch that created it; it does nothing about the order of what is already
 * eligible.
 *
 * So submissions are held for a fixed window and released in a shuffled batch. Everything in
 * one window becomes order-indistinguishable.
 *
 * WHAT THIS DOES NOT DO, STATED PLAINLY. This is the relayer promising to behave. It sees
 * every request with its arrival time and its network address, and a user cannot verify that
 * the shuffle happened -- unlike the root-age rule, which is a consensus check they can read
 * off the chain. It raises the cost of passive correlation; it is not a defence against the
 * relayer itself. That asymmetry is exactly why the on-chain half exists.
 */
export class Relayer {
  private readonly relayers: RelayerPool;
  private readonly config: RelayerConfig;
  /** Per-account tail of the submission chain, keyed by address. */
  private readonly queues = new Map<Address, Promise<unknown>>();

  /** Submissions waiting for the current release window to close. */
  private held: Held[] = [];
  private releaseTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(config: RelayerConfig) {
    this.config = config;
    this.relayers = new RelayerPool(config.mnemonic, config.relayerCount ?? 1);
  }

  /** Milliseconds a submission is held before release. 0 means immediate. */
  get releaseIntervalMs(): number {
    return this.config.releaseIntervalMs ?? 0;
  }

  /** How many submissions are currently waiting for a release window. */
  get pending(): number {
    return this.held.length;
  }

  /**
   * Release everything held, in a random order.
   *
   * Exposed so tests can drive the window deterministically rather than sleeping, and so a
   * shutdown can flush rather than drop submissions users are waiting on.
   */
  flush(): void {
    if (this.releaseTimer !== undefined) {
      clearTimeout(this.releaseTimer);
      this.releaseTimer = undefined;
    }

    const batch = this.held;
    this.held = [];
    if (batch.length === 0) return;

    for (const item of shuffle(batch)) {
      this.dispatch(item.action, item.args).then(item.resolve, item.reject);
    }
  }

  get addresses(): Address[] {
    return this.relayers.addresses;
  }

  async submit(action: RelayableAction, args: readonly unknown[]): Promise<RelayResult> {
    if (this.releaseIntervalMs <= 0) return this.dispatch(action, args);

    return new Promise<RelayResult>((resolve, reject) => {
      this.held.push({ action, args, resolve, reject });

      // One timer per WINDOW, not per submission. A timer per submission would release each
      // one exactly `releaseIntervalMs` after it arrived, preserving arrival order perfectly
      // -- a delay that looks like a defence and provides none.
      if (this.releaseTimer === undefined) {
        this.releaseTimer = setTimeout(() => this.flush(), this.releaseIntervalMs);
        // Do not hold the process open for an empty window.
        this.releaseTimer.unref?.();
      }
    });
  }

  private async dispatch(action: RelayableAction, args: readonly unknown[]): Promise<RelayResult> {
    const account = this.relayers.next();

    const previous = this.queues.get(account.address) ?? Promise.resolve();
    // Swallow the predecessor's rejection: one failed submission must not poison every later
    // submission queued behind it on the same account.
    const mine = previous
      .catch(() => undefined)
      .then(() => this.send(account, action, args));

    this.queues.set(account.address, mine);
    try {
      return await mine;
    } finally {
      // Only clear if nothing else queued behind this one, or we would drop a live chain.
      if (this.queues.get(account.address) === mine) this.queues.delete(account.address);
    }
  }

  private async send(
    account: ReturnType<RelayerPool["next"]>,
    action: RelayableAction,
    args: readonly unknown[],
  ): Promise<RelayResult> {
    const wallet: WalletClient = createWalletClient({
      account,
      chain: this.config.chain,
      transport: http(this.config.rpcUrl),
    });

    const hash = await wallet.writeContract({
      address: this.config.poolAddress,
      abi: RELAY_ABI,
      functionName: action as never,
      args: args as never,
      gas: ACTION_GAS_LIMIT,
      chain: this.config.chain,
      account,
    });

    // Included is not the same as succeeded -- viem never inspects `status`. The sequencer
    // learned this the expensive way: an unchecked receipt turned every revert into a silent
    // success and corrupted the tree mirror one tick later.
    const receipt = await this.config.publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new RelayError(
        `${action} reverted on chain (tx ${hash}, relayer ${account.address})`,
        502,
      );
    }

    return {
      hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed,
      relayer: account.address,
    };
  }
}

/**
 * Fisher-Yates, on a copy.
 *
 * `Math.random` is deliberate: this shuffles submission order, not key material, and an
 * observer who can predict it still has to be the relayer to use it. Reaching for a CSPRNG
 * here would suggest the shuffle carries a cryptographic guarantee, which it does not -- the
 * guarantee is the on-chain root-age rule.
 */
function shuffle<T>(items: readonly T[]): T[] {
  const out = items.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j]!, out[i]!];
  }
  return out;
}
