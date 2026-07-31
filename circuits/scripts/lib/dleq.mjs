/**
 * Chaum-Pedersen discrete-log-equality proofs, in JavaScript.
 *
 * Proves `D = [s]C1` was computed with the same secret `s` as the published key
 * `H = [s]G`, without revealing `s`. The on-chain counterpart is
 * `contracts/src/ChaumPedersen.sol`, and the Fiat-Shamir challenge below must match
 * `ChaumPedersen.challenge` byte for byte -- a single differing byte makes every proof
 * fail verification with no diagnostic beyond `false`.
 *
 * This lives in a shared lib because two consumers need it and they must not drift:
 * the fixture generators that prove the verifier is sound, and the publisher that has
 * to produce a real proof every time it settles a market.
 *
 * WHAT THIS PROOF DOES NOT DO -- read before relying on it.
 *
 * It binds `D` to the key. It says NOTHING about what integer anyone claims the
 * plaintext is. Recovering the plaintext needs `C2 - D = [m]G`, and checking a CLAIMED
 * `m` against that is a separate step, done on-chain by
 * `EncryptedParimutuelPool._checkClaimedPlaintext`. A valid DLEQ proof alongside a
 * fabricated total is exactly the attack that check exists to stop.
 */
import { randomBytes } from "node:crypto";
import sha3 from "js-sha3";
import { SUBGROUP_ORDER } from "./elgamal.mjs";

const { keccak256 } = sha3;

const word = (v) => BigInt(v).toString(16).padStart(64, "0");

/**
 * @param elgamal  an instance from `buildElGamal` (supplies the curve and encoding)
 * @param secret   the committee secret `s`
 */
export function buildDLEQ(elgamal, secret) {
  const { babyJub, asPair } = elgamal;
  const L = SUBGROUP_ORDER;
  const s = BigInt(secret);

  const H = babyJub.mulPointEscalar(babyJub.Base8, s);
  const [BASE8X, BASE8Y] = asPair(babyJub.Base8);

  function randomScalar() {
    while (true) {
      const c = BigInt("0x" + randomBytes(32).toString("hex"));
      if (c > 0n && c < L) return c;
    }
  }

  /** Must match `ChaumPedersen.challenge` exactly, including the domain tag. */
  function challenge(h, c1, d, a, b) {
    const tag = Buffer.from("atrum.chaum-pedersen.v1", "utf8").toString("hex");
    const hex =
      tag +
      word(BASE8X) + word(BASE8Y) +
      word(h[0]) + word(h[1]) +
      word(c1[0]) + word(c1[1]) +
      word(d[0]) + word(d[1]) +
      word(a[0]) + word(a[1]) +
      word(b[0]) + word(b[1]);
    const bytes = Uint8Array.from(hex.match(/../g).map((x) => parseInt(x, 16)));
    return BigInt("0x" + keccak256(bytes)) % L;
  }

  /** The decryption share for a ciphertext's C1 component. */
  function share(c1) {
    return babyJub.mulPointEscalar(c1, s);
  }

  /**
   * Produce `D` and a proof that it is the honest decryption share for `c1`.
   *
   * Self-checks both verification equations before returning. A proof that fails here
   * would fail on-chain as a bare `false`, which is far harder to diagnose than an
   * exception raised at the point of construction.
   */
  function prove(c1) {
    const D = share(c1);

    const k = randomScalar();
    const A = babyJub.mulPointEscalar(babyJub.Base8, k);
    const B = babyJub.mulPointEscalar(c1, k);

    const e = challenge(asPair(H), asPair(c1), asPair(D), asPair(A), asPair(B));
    const z = (k + e * s) % L;

    const eq = (p, q) => p[0] === q[0] && p[1] === q[1];
    const lhs1 = asPair(babyJub.mulPointEscalar(babyJub.Base8, z));
    const rhs1 = asPair(babyJub.addPoint(A, babyJub.mulPointEscalar(H, e)));
    const lhs2 = asPair(babyJub.mulPointEscalar(c1, z));
    const rhs2 = asPair(babyJub.addPoint(B, babyJub.mulPointEscalar(D, e)));
    if (!eq(lhs1, rhs1) || !eq(lhs2, rhs2)) {
      throw new Error("DLEQ proof fails its own verification in JS -- refusing to emit it");
    }

    return { D, A, B, z, e };
  }

  return { H, L, prove, share, challenge, randomScalar };
}
