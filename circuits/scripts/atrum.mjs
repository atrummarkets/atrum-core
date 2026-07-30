/**
 * Atrum note and tree primitives, in JavaScript.
 *
 * This is the third implementation of the same hashing rules -- the other two are
 * `circuits/src/note.circom` (in-circuit) and `contracts/src/IncrementalMerkleTree.sol`
 * (on-chain). All three must agree bit for bit.
 *
 * That is not a hypothetical risk. If the in-circuit and on-chain hashes diverge, every
 * proof fails at verification with no diagnostic, while every gas number still looks
 * fine. So the fixture generator recomputes commitments and roots with this module and
 * asserts they match what the circuit produced and what the contract stores, rather
 * than assuming three independent implementations happen to agree.
 *
 * Shared by `gen_action_fixtures.mjs` and the sequencer's tree mirror.
 */
import { buildPoseidon } from "circomlibjs";

export const FIELD_SIZE =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export const DEPTH = 20;
export const UNIT_BITS = 64n;
export const NULLIFIER_DOMAIN = 1n;

export const OUTCOME_UNBET = 0n;
export const OUTCOME_YES = 1n;
export const OUTCOME_NO = 2n;

let poseidon = null;

export async function init() {
  if (!poseidon) poseidon = await buildPoseidon();
  return poseidon;
}

/** Poseidon(2) over field elements, returned as a bigint. */
export function hash2(a, b) {
  if (!poseidon) throw new Error("call init() first");
  return BigInt(poseidon.F.toObject(poseidon([a, b])));
}

/**
 * The empty-leaf value, matching contracts/test and the deploy script:
 * keccak256("atrum.shielded.empty") reduced into the field.
 *
 * Deliberately non-zero. With zero, "an empty slot" and "a real note committing to
 * zero" would hash identically, and a leaf could be claimed to be either.
 */
export const ZERO_VALUE =
  0xfebf3885bd55618669912e9467d8bd5caf0e43e77b356703231d49a3cbf27a52n % FIELD_SIZE;

/** commitment = Poseidon(Poseidon(nullifier, secret), Poseidon(marketId, packed)) */
export function noteCommitment({ nullifier, secret, marketId, outcome, units }) {
  if (units >= 1n << UNIT_BITS) throw new Error("units out of range");
  if (outcome > 3n) throw new Error("outcome out of range");

  const packed = outcome * (1n << UNIT_BITS) + units;
  const ownerHash = hash2(nullifier, secret);
  const dataHash = hash2(marketId, packed);
  return hash2(ownerHash, dataHash);
}

export function nullifierHash(nullifier) {
  return hash2(nullifier, NULLIFIER_DOMAIN);
}

/** betData = marketId * 2^66 + outcome * 2^64 + units */
export function packBetData(marketId, outcome, units) {
  return marketId * (1n << (UNIT_BITS + 2n)) + outcome * (1n << UNIT_BITS) + units;
}

/** payoutData = recipient * 2^64 + units */
export function packPayoutData(recipient, units) {
  return BigInt(recipient) * (1n << UNIT_BITS) + units;
}

/** marketMeta = marketId * 4 + outcome */
export function packMarketMeta(marketId, outcome) {
  return marketId * 4n + outcome;
}

/**
 * Append-only Poseidon Merkle tree, mirroring IncrementalMerkleTree.sol.
 *
 * Keeps the full leaf set, unlike the contract which keeps only a frontier and a root.
 * That is the whole reason the sequencer exists: somebody has to be able to produce
 * Merkle paths, and the contract deliberately cannot.
 */
export class MerkleTree {
  constructor(depth = DEPTH, zeroValue = ZERO_VALUE) {
    this.depth = depth;
    this.leaves = [];
    this.zeros = [];

    let current = zeroValue;
    for (let i = 0; i < depth; i++) {
      this.zeros.push(current);
      current = hash2(current, current);
    }
    this.emptyRoot = current;
  }

  insert(leaf) {
    this.leaves.push(leaf);
    return this.leaves.length - 1;
  }

  /** Recompute level by level. O(n) per call -- fine for batch sizes, not for 2^20. */
  _levels() {
    const levels = [this.leaves.slice()];
    for (let d = 0; d < this.depth; d++) {
      const prev = levels[d];
      const next = [];
      for (let i = 0; i < prev.length; i += 2) {
        const left = prev[i];
        const right = i + 1 < prev.length ? prev[i + 1] : this.zeros[d];
        next.push(hash2(left, right));
      }
      levels.push(next);
    }
    return levels;
  }

  root() {
    if (this.leaves.length === 0) return this.emptyRoot;
    const levels = this._levels();
    return levels[this.depth][0];
  }

  /** Sibling path and left/right bits for `index`, as the circuit expects them. */
  path(index) {
    if (index >= this.leaves.length) throw new Error("no such leaf");

    const levels = this._levels();
    const pathElements = [];
    const pathIndices = [];

    let idx = index;
    for (let d = 0; d < this.depth; d++) {
      const isRight = idx % 2 === 1;
      const siblingIdx = isRight ? idx - 1 : idx + 1;
      const level = levels[d];
      const sibling = siblingIdx < level.length ? level[siblingIdx] : this.zeros[d];

      pathElements.push(sibling);
      pathIndices.push(isRight ? 1n : 0n);
      idx = Math.floor(idx / 2);
    }

    return { pathElements, pathIndices };
  }
}
