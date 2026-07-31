/**
 * The sequencer's mirror of the on-chain commitment tree.
 *
 * The contract stores only a frontier and a root -- it deliberately cannot produce a
 * Merkle path for anyone. Somebody has to, or no user can ever build a bet proof. That
 * is this file, and it is why the sequencer exists at all.
 *
 * The mirror must agree with `IncrementalMerkleTree.sol` and `note.circom` bit for bit.
 * If it drifts, users receive paths that produce proofs which fail on-chain with no
 * diagnostic, while every gas number still looks correct. `test/tree.test.ts` asserts
 * the mirror's root against the contract's root after every batch rather than trusting
 * that three implementations of the same rules happen to agree.
 */
import { buildPoseidon } from "circomlibjs";
import { keccak_256 } from "@noble/hashes/sha3.js";

export const FIELD_SIZE =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** keccak256("atrum.shielded.padding.v1") -- the contract's PAD_DOMAIN. */
const PAD_DOMAIN = keccak_256(new TextEncoder().encode("atrum.shielded.padding.v1"));

/**
 * The padding leaf the CONTRACT derives for `slot` of the batch grafted at `treeStart`.
 * Must match `ShieldedPool._derivedFiller` byte for byte.
 *
 * Padding is derived on-chain rather than supplied by the sequencer because a
 * sequencer-chosen filler is a SPENDABLE note: `redeem.circom` proves Merkle membership
 * and never provenance, so a filler whose secrets the sequencer knew could be redeemed
 * 1:1 against collateral it never deposited. That was a full vault drain -- see
 * `contracts/test/PaddingExploit.t.sol`.
 */
export function derivedFiller(treeStart: bigint, slot: bigint): bigint {
  const word = (v: bigint): Uint8Array => {
    const out = new Uint8Array(32);
    let x = v;
    for (let i = 31; i >= 0; i--) {
      out[i] = Number(x & 0xffn);
      x >>= 8n;
    }
    return out;
  };

  const preimage = new Uint8Array(96);
  preimage.set(PAD_DOMAIN, 0);
  preimage.set(word(treeStart), 32);
  preimage.set(word(slot), 64);

  const digest = keccak_256(preimage);
  const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
  return BigInt("0x" + hex) % FIELD_SIZE;
}

export const DEPTH = 20;
export const BATCH_SIZE = 64;

/**
 * keccak256("atrum.shielded.empty") reduced into the field.
 *
 * Non-zero on purpose: with zero, an empty slot and a real note committing to zero
 * would hash identically, so a leaf could be claimed to be either.
 */
export const ZERO_VALUE =
  0xfebf3885bd55618669912e9467d8bd5caf0e43e77b356703231d49a3cbf27a52n % FIELD_SIZE;

type PoseidonFn = ((inputs: bigint[]) => unknown) & { F: { toObject(x: unknown): bigint } };

let poseidon: PoseidonFn | null = null;

export async function initHasher(): Promise<void> {
  if (!poseidon) poseidon = (await buildPoseidon()) as PoseidonFn;
}

export function hash2(a: bigint, b: bigint): bigint {
  if (!poseidon) throw new Error("call initHasher() first");
  return BigInt(poseidon.F.toObject(poseidon([a, b])));
}

export interface MerklePath {
  pathElements: bigint[];
  pathIndices: bigint[];
}

export class CommitmentTree {
  readonly depth: number;
  readonly zeros: bigint[] = [];
  readonly emptyRoot: bigint;
  private leaves: bigint[] = [];

  constructor(depth = DEPTH, zeroValue = ZERO_VALUE) {
    this.depth = depth;

    let current = zeroValue;
    for (let i = 0; i < depth; i++) {
      this.zeros.push(current);
      current = hash2(current, current);
    }
    this.emptyRoot = current;
  }

  get size(): number {
    return this.leaves.length;
  }

  /**
   * Append a whole batch.
   *
   * Batches are all-or-nothing because the contract grafts an aligned power-of-two
   * subtree. Appending leaf by leaf here would still produce the right root, but it
   * would let the mirror drift into states the contract can never reach, and a state
   * the contract cannot reach is a state no user's proof can reference.
   */
  insertBatch(leaves: bigint[]): number {
    if (leaves.length !== BATCH_SIZE) {
      throw new Error(`batch must be exactly ${BATCH_SIZE} leaves, got ${leaves.length}`);
    }
    if (this.leaves.length % BATCH_SIZE !== 0) {
      throw new Error("mirror is not batch-aligned -- it has drifted from the contract");
    }

    const start = this.leaves.length;
    this.leaves.push(...leaves);
    return start;
  }

  private levels(): bigint[][] {
    const levels: bigint[][] = [this.leaves.slice()];
    for (let d = 0; d < this.depth; d++) {
      const prev = levels[d]!;
      const next: bigint[] = [];
      for (let i = 0; i < prev.length; i += 2) {
        const left = prev[i]!;
        const right = i + 1 < prev.length ? prev[i + 1]! : this.zeros[d]!;
        next.push(hash2(left, right));
      }
      levels.push(next);
    }
    return levels;
  }

  root(): bigint {
    if (this.leaves.length === 0) return this.emptyRoot;
    return this.levels()[this.depth]![0]!;
  }

  indexOf(commitment: bigint): number {
    return this.leaves.findIndex((l) => l === commitment);
  }

  /** Sibling path for `index`, in the order `bet.circom` and `redeem.circom` expect. */
  path(index: number): MerklePath {
    if (index < 0 || index >= this.leaves.length) {
      throw new Error(`no leaf at index ${index}`);
    }

    const levels = this.levels();
    const pathElements: bigint[] = [];
    const pathIndices: bigint[] = [];

    let idx = index;
    for (let d = 0; d < this.depth; d++) {
      const isRight = idx % 2 === 1;
      const siblingIdx = isRight ? idx - 1 : idx + 1;
      const level = levels[d]!;
      pathElements.push(siblingIdx < level.length ? level[siblingIdx]! : this.zeros[d]!);
      pathIndices.push(isRight ? 1n : 0n);
      idx = Math.floor(idx / 2);
    }

    return { pathElements, pathIndices };
  }
}
