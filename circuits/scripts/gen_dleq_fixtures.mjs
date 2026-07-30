/**
 * Chaum-Pedersen (discrete-log equality) proof fixtures, and the negative cases.
 *
 * Proves an ElGamal decryption share `D = [s]C1` was computed with the same secret `s`
 * as the published key `H = [s]G`, without revealing `s`.
 *
 * This is on Phase 2's critical path, not Phase 3's. Once payouts derive from a decrypted
 * ratio, whoever publishes that ratio can drain the vault unless the ratio is bound to the
 * on-chain ciphertext -- and this proof is that binding.
 *
 * Emits a valid proof plus five tampered variants, because a verifier that accepts
 * everything would look identical to a correct one on a single happy-path vector.
 *
 * Usage: node scripts/gen_dleq_fixtures.mjs
 */
import { buildBabyjub } from "circomlibjs";
import { randomBytes, createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import sha3 from "js-sha3";
const { keccak256 } = sha3;

const BUILD = new URL("../build/", import.meta.url);
const OUT = new URL("../build/dleq-fixtures.json", import.meta.url);

const babyJub = await buildBabyjub();
const F = babyJub.F;
const L = 2736030358979909402780800718157159386076813972158567259200215660948447373041n;

const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD)));
const s = BigInt(key.secret);
const H = babyJub.mulPointEscalar(babyJub.Base8, s);

const aff = (p) => [F.toObject(p[0]), F.toObject(p[1])];
const [BASE8X, BASE8Y] = aff(babyJub.Base8);

function randomScalar() {
  while (true) {
    const c = BigInt("0x" + randomBytes(32).toString("hex"));
    if (c > 0n && c < L) return c;
  }
}

const word = (v) => BigInt(v).toString(16).padStart(64, "0");

/** Must match ChaumPedersen.challenge byte for byte. */
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

// A ciphertext to decrypt: C1 = [r]G.
const r = randomScalar();
const C1 = babyJub.mulPointEscalar(babyJub.Base8, r);
// The decryption share.
const D = babyJub.mulPointEscalar(C1, s);

// Prove it.
const k = randomScalar();
const A = babyJub.mulPointEscalar(babyJub.Base8, k);
const B = babyJub.mulPointEscalar(C1, k);

const e = challenge(aff(H), aff(C1), aff(D), aff(A), aff(B));
const z = (k + e * s) % L;

// Self-check both verification equations before writing anything out.
const lhs1 = babyJub.mulPointEscalar(babyJub.Base8, z);
const rhs1 = babyJub.addPoint(A, babyJub.mulPointEscalar(H, e));
const lhs2 = babyJub.mulPointEscalar(C1, z);
const rhs2 = babyJub.addPoint(B, babyJub.mulPointEscalar(D, e));
const eq = (p, q) => F.eq(p[0], q[0]) && F.eq(p[1], q[1]);
if (!eq(lhs1, rhs1) || !eq(lhs2, rhs2)) {
  throw new Error("DLEQ proof fails its own verification in JS -- do not measure this");
}

const pt = (p) => { const [x, y] = aff(p); return [x.toString(), y.toString()]; };

// A decryption share computed with the WRONG secret -- the drain-the-vault case.
const wrongSecret = randomScalar();
const wrongD = babyJub.mulPointEscalar(C1, wrongSecret);

writeFileSync(OUT, JSON.stringify({
  _note: "Chaum-Pedersen DLEQ. `valid` must verify; every `invalid.*` must be rejected.",
  base8: [BASE8X.toString(), BASE8Y.toString()],
  L: L.toString(),
  H: pt(H),
  C1: pt(C1),
  D: pt(D),
  e: e.toString(),
  valid: { A: pt(A), B: pt(B), z: z.toString() },
  invalid: {
    // The attack that matters: a share from a different key, i.e. a forged decryption.
    wrongShare: { D: pt(wrongD), A: pt(A), B: pt(B), z: z.toString() },
    tamperedZ: { A: pt(A), B: pt(B), z: ((z + 1n) % L).toString() },
    tamperedA: { A: [((BigInt(pt(A)[0]) + 1n)).toString(), pt(A)[1]], B: pt(B), z: z.toString() },
    swappedAB: { A: pt(B), B: pt(A), z: z.toString() },
    zOutOfRange: { A: pt(A), B: pt(B), z: (L + 1n).toString() },
  },
}, null, 2));

console.log("DLEQ fixtures written.");
console.log("  challenge e :", e.toString());
console.log("  both verification equations hold in JS");
console.log("  negative cases: wrongShare, tamperedZ, tamperedA, swappedAB, zOutOfRange");
