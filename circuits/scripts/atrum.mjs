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
 * Shared by `gen_action_fixtures.mjs`, the sequencer's tree mirror, AND the browser client,
 * which bundles this file rather than reimplementing it. A fourth implementation living in
 * the frontend is exactly how the three above would drift apart, so keep this module
 * runtime-neutral: no `Buffer`, no `node:*` imports, nothing that only exists under Node.
 */
import { buildPoseidon } from "circomlibjs";
import sha3 from "js-sha3";
const { keccak256 } = sha3;

/**
 * The padding leaf the CONTRACT derives for slot `slot` of the batch grafted at tree
 * position `treeStart`. Must match `ShieldedPool._derivedFiller` exactly.
 *
 * Padding is derived rather than sequencer-supplied because a sequencer-chosen filler is
 * a spendable note: `redeem.circom` proves Merkle membership, never provenance, so a
 * "filler" whose secrets the sequencer knew could be redeemed 1:1 for collateral it never
 * deposited. See `contracts/test/PaddingExploit.t.sol`.
 *
 * keccak rather than Poseidon: a filler is never hashed in-circuit, so it does not need
 * to be ZK-friendly, and Poseidon would cost 28,980 gas per filler on-chain.
 */
export function derivedFiller(treeStart, slot) {
  const be = (v) => BigInt(v).toString(16).padStart(64, "0");
  const preimage = PAD_DOMAIN_HEX + be(treeStart) + be(slot);
  const bytes = Uint8Array.from(
    preimage.match(/../g).map((b) => parseInt(b, 16)),
  );
  return BigInt("0x" + keccak256(bytes)) % FIELD_SIZE;
}

/**
 * keccak256("atrum.shielded.padding.v1"), the contract's PAD_DOMAIN.
 *
 * `TextEncoder` rather than `Buffer` because this module is also bundled for the browser
 * client -- see the header note on staying runtime-neutral. It is UTF-8 either way.
 */
export const PAD_DOMAIN_HEX = keccak256(
  new TextEncoder().encode("atrum.shielded.padding.v1"),
);

export const FIELD_SIZE =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export const DEPTH = 20;
export const UNIT_BITS = 64n;
export const AMOUNT_BITS = 40n;
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

/** marketMeta = marketId * 4 + outcome. `bet_encrypted`'s `betMeta`. */
export function packMarketMeta(marketId, outcome) {
  return marketId * 4n + outcome;
}

/**
 * redeemMeta = marketId*2^130 + outcome*2^128 + totalPool*2^64 + winningPool
 *
 * Matches `redeem_private.circom:137` and `ShieldedPool._unpackRedeemMeta`. The pools are
 * public because the contract pins them to the settled totals -- without that pin the
 * circuit would faithfully prove the payout arithmetic about invented divisors.
 */
export function packRedeemMeta(marketId, outcome, totalPool, winningPool) {
  if (totalPool >= 1n << 64n) throw new Error("totalPool out of range");
  if (winningPool >= 1n << 64n) throw new Error("winningPool out of range");
  return (
    marketId * (1n << 130n) +
    outcome * (1n << 128n) +
    totalPool * (1n << 64n) +
    winningPool
  );
}

/**
 * withdrawData = unbetExit*2^200 + recipient*2^40 + amount
 *
 * Matches `withdraw.circom:178` and `ShieldedPool._unpackWithdrawData`. `amount` is 40 bits,
 * not 64 -- the wider unit field does not fit alongside a 160-bit address. `unbetExit` used to
 * be the full `marketId`; narrowed to one bit so a winner's withdrawal no longer publicly names
 * the market they won in, which was deanonymising every winner regardless of how private the
 * bet itself was.
 */
export function packWithdrawData(unbetExit, recipient, amount) {
  if (amount >= 1n << AMOUNT_BITS) throw new Error("amount out of range");
  return (unbetExit ? 1n : 0n) * (1n << 200n) + BigInt(recipient) * (1n << AMOUNT_BITS) + amount;
}

/**
 * The denomination ladder, mirroring `contracts/src/Denominations.sol`.
 *
 * Powers of ten only -- NOT 1-2-5. Privacy rests on withdrawals looking identical, so the
 * set is deliberately coarse. Enforced on-chain for `deposit` units and the `withdraw`
 * amount, and deliberately NOT for change notes or redeem payouts, which are whatever the
 * parimutuel arithmetic produced.
 *
 * Exported here so the client can reject an invalid amount BEFORE the user pays to build a
 * proof for a transaction that would revert.
 */
export const MAX_DENOMINATION_EXPONENT = 9;

export const DENOMINATIONS = Array.from(
  { length: MAX_DENOMINATION_EXPONENT + 1 },
  (_, i) => 10n ** BigInt(i),
);

export function isValidDenomination(units) {
  return DENOMINATIONS.includes(BigInt(units));
}

/** The largest valid denomination at or below `units`, or null if there is none. */
export function snapToDenomination(units) {
  const v = BigInt(units);
  if (v <= 0n) return null;
  let best = null;
  for (const d of DENOMINATIONS) if (d <= v) best = d;
  return best;
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
