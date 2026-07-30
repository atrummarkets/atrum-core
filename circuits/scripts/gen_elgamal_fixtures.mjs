/**
 * Fixtures for the on-chain ElGamal accumulator, computed with circomlibjs.
 *
 * The Solidity accumulator is a fourth independent implementation of curve arithmetic
 * that already exists in circom, in circomlibjs, and in the sequencer. If it disagrees
 * with the others by so much as one field element, the running pool total becomes
 * undecryptable -- and nothing on-chain would notice, because a corrupted ciphertext is
 * indistinguishable from a valid one until someone tries to decrypt it. There is no
 * revert, no event, no failing proof. The pool would simply be lost.
 *
 * So the Solidity arithmetic is checked against circomlibjs before any gas number from
 * it is trusted, exactly as `poseidon2-runtime.hex` was.
 *
 * Emits:
 *   - point addition vectors, including the identity and doubling edge cases
 *   - a full accumulate-then-decrypt vector: Enc(50) + Enc(20) must total to Enc(70)
 *
 * Usage: node scripts/gen_elgamal_fixtures.mjs
 */
import { buildBabyjub } from "circomlibjs";
import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const BUILD = new URL("../build/", import.meta.url);
const OUT = new URL("../build/elgamal-fixtures.json", import.meta.url);

const babyJub = await buildBabyjub();
const F = babyJub.F;

const SUBGROUP_ORDER =
  2736030358979909402780800718157159386076813972158567259200215660948447373041n;

const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD)));
const secret = BigInt(key.secret);
const H = [F.e(BigInt(key.pubKey[0])), F.e(BigInt(key.pubKey[1]))];

const IDENTITY = [F.e(0n), F.e(1n)];

function randomScalar() {
  while (true) {
    const c = BigInt("0x" + randomBytes(32).toString("hex"));
    if (c > 0n && c < SUBGROUP_ORDER) return c;
  }
}

const affine = (p) => [F.toObject(p[0]).toString(), F.toObject(p[1]).toString()];

/** C1 = [r]G, C2 = [m]G + [r]H */
function encrypt(m, r) {
  const c1 = babyJub.mulPointEscalar(babyJub.Base8, r);
  const mG = m === 0n ? IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, m);
  const rH = babyJub.mulPointEscalar(H, r);
  return { c1, c2: babyJub.addPoint(mG, rH) };
}

function decrypt(c1, c2, bound) {
  const sC1 = babyJub.mulPointEscalar(c1, secret);
  const target = babyJub.addPoint(c2, [F.neg(sC1[0]), sC1[1]]);
  if (F.eq(target[0], IDENTITY[0]) && F.eq(target[1], IDENTITY[1])) return 0n;

  const m = BigInt(Math.ceil(Math.sqrt(Number(bound))) + 1);
  const table = new Map();
  let acc = IDENTITY;
  for (let j = 0n; j < m; j++) {
    table.set(`${F.toObject(acc[0])},${F.toObject(acc[1])}`, j);
    acc = babyJub.addPoint(acc, babyJub.Base8);
  }
  const mG = babyJub.mulPointEscalar(babyJub.Base8, m);
  const negMG = [F.neg(mG[0]), mG[1]];
  let cur = target;
  for (let i = 0n; i <= m; i++) {
    const hit = table.get(`${F.toObject(cur[0])},${F.toObject(cur[1])}`);
    if (hit !== undefined) return i * m + hit;
    cur = babyJub.addPoint(cur, negMG);
  }
  throw new Error("BSGS failed");
}

const out = {
  _note: "Reference vectors from circomlibjs. Solidity must reproduce these exactly.",
  curve: {
    a: "168700",
    d: "168696",
    q: F.p.toString(),
    base8: affine(babyJub.Base8),
    identity: ["0", "1"],
  },
  pubKey: affine(H),
};

// ---- point addition vectors, edge cases first ----
const G = babyJub.Base8;
const G2 = babyJub.addPoint(G, G);
const G3 = babyJub.addPoint(G2, G);
const rand = babyJub.mulPointEscalar(G, randomScalar());

out.additions = [
  { name: "identity + G", a: affine(IDENTITY), b: affine(G), sum: affine(babyJub.addPoint(IDENTITY, G)) },
  { name: "G + identity", a: affine(G), b: affine(IDENTITY), sum: affine(babyJub.addPoint(G, IDENTITY)) },
  { name: "identity + identity", a: affine(IDENTITY), b: affine(IDENTITY), sum: affine(babyJub.addPoint(IDENTITY, IDENTITY)) },
  { name: "G + G (doubling)", a: affine(G), b: affine(G), sum: affine(G2) },
  { name: "G2 + G", a: affine(G2), b: affine(G), sum: affine(G3) },
  { name: "random + G", a: affine(rand), b: affine(G), sum: affine(babyJub.addPoint(rand, G)) },
  // P + (-P) = identity. On twisted Edwards, -(x,y) = (-x,y).
  {
    name: "G + (-G) = identity",
    a: affine(G),
    b: [F.toObject(F.neg(G[0])).toString(), F.toObject(G[1]).toString()],
    sum: affine(IDENTITY),
  },
];

// ---- the accumulator vector: the reference's worked example ----
const ALICE = 50_000_000n;
const CAROL = 20_000_000n;

const encA = encrypt(ALICE, randomScalar());
const encC = encrypt(CAROL, randomScalar());
const sum = {
  c1: babyJub.addPoint(encA.c1, encC.c1),
  c2: babyJub.addPoint(encA.c2, encC.c2),
};

const total = decrypt(sum.c1, sum.c2, 200_000_000n);
if (total !== ALICE + CAROL) {
  throw new Error(`homomorphic addition broken in JS: ${total} != ${ALICE + CAROL}`);
}

// Accumulating onto a fresh Enc(0) identity, which is what the contract actually does.
const zeroAcc = { c1: IDENTITY, c2: IDENTITY };
const step1 = {
  c1: babyJub.addPoint(zeroAcc.c1, encA.c1),
  c2: babyJub.addPoint(zeroAcc.c2, encA.c2),
};
const step2 = {
  c1: babyJub.addPoint(step1.c1, encC.c1),
  c2: babyJub.addPoint(step1.c2, encC.c2),
};

if (
  !F.eq(step2.c1[0], sum.c1[0]) ||
  !F.eq(step2.c2[0], sum.c2[0])
) {
  throw new Error("accumulating from identity diverged from direct addition");
}

out.accumulate = {
  alice: { plaintext: ALICE.toString(), c1: affine(encA.c1), c2: affine(encA.c2) },
  carol: { plaintext: CAROL.toString(), c1: affine(encC.c1), c2: affine(encC.c2) },
  afterAlice: { c1: affine(step1.c1), c2: affine(step1.c2) },
  afterBoth: { c1: affine(step2.c1), c2: affine(step2.c2) },
  expectedTotal: (ALICE + CAROL).toString(),
};

// ---- off-curve rejection vectors ----
// A point that satisfies no curve equation. The contract must refuse it: adding a
// non-group element corrupts the total in a way no decryption can undo.
out.offCurve = [
  ["1", "1"],
  ["2", "3"],
  [F.p.toString(), "1"], // out of field entirely
];

writeFileSync(OUT, JSON.stringify(out, null, 2));

console.log("ElGamal reference vectors written.\n");
console.log("  point additions   :", out.additions.length, "vectors (identity, doubling, negation)");
console.log("  accumulate vector : Enc(50) + Enc(20) -> decrypts to", total.toString());
console.log("  off-curve vectors :", out.offCurve.length);
console.log("\nwrote build/elgamal-fixtures.json");
