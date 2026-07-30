/**
 * A correctness corpus for BabyJubJub scalar multiplication, sized for OPTIMISATION.
 *
 * A handful of happy-path vectors is enough to check a straightforward implementation. It
 * is not enough to protect an optimised one: windowed ladders, interleaved multi-scalar
 * multiplication and flattened coordinate handling all fail on narrow, specific inputs --
 * a particular bit pattern, the identity appearing mid-ladder, the top or bottom of the
 * scalar range. Those are exactly the cases a few random vectors miss.
 *
 * So: every boundary scalar, adversarial bit patterns, the identity and small-order
 * behaviour, plus 32 random vectors. Every expected value comes from circomlibjs.
 *
 * Usage: node scripts/gen_curve_vectors.mjs
 */
import { buildBabyjub } from "circomlibjs";
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";

const OUT = new URL("../build/curve-vectors.json", import.meta.url);
const babyJub = await buildBabyjub();
const F = babyJub.F;

const L = 2736030358979909402780800718157159386076813972158567259200215660948447373041n;
const IDENTITY = [F.e(0n), F.e(1n)];

const aff = (p) => [F.toObject(p[0]).toString(), F.toObject(p[1]).toString()];
const G = babyJub.Base8;

function randomScalar() {
  while (true) {
    const c = BigInt("0x" + randomBytes(32).toString("hex"));
    if (c > 0n && c < L) return c;
  }
}

function mul(p, k) {
  if (k === 0n) return IDENTITY;
  return babyJub.mulPointEscalar(p, k);
}

const scalars = [
  // Boundaries. `0` and `1` break ladders that assume a non-trivial scalar; `L-1` and
  // `L` catch off-by-one in the loop bound and in range checks.
  ["k = 0", 0n],
  ["k = 1", 1n],
  ["k = 2", 2n],
  ["k = 3", 3n],
  ["k = L-1", L - 1n],
  ["k = L", L],

  // Bit patterns. All-ones and alternating patterns exercise every add in the ladder;
  // powers of two exercise the doubling path alone with no additions at all.
  ["k = 2^250 (single high bit)", 2n ** 250n],
  ["k = 2^251", 2n ** 251n],
  ["k = 2^250 - 1 (250 ones)", 2n ** 250n - 1n],
  ["k = 0b1010... (alternating)", (2n ** 250n - 1n) / 3n * 2n],
  ["k = 2^128", 2n ** 128n],
  ["k = 2^128 + 1", 2n ** 128n + 1n],
  ["k = 8 (order of the base point cofactor)", 8n],
];

for (let i = 0; i < 32; i++) scalars.push([`random ${i}`, randomScalar()]);

// Points to multiply: the base point, a random subgroup element, and the identity --
// which an optimised ladder can mishandle if it special-cases the accumulator start.
const points = [
  ["G", G],
  ["random point", babyJub.mulPointEscalar(G, randomScalar())],
  ["identity", IDENTITY],
];

const out = {
  _note:
    "circomlibjs reference vectors. Any BabyJubJub implementation -- naive or optimised -- must reproduce every one.",
  L: L.toString(),
  base8: aff(G),
  scalarMul: [],
  doubleScalarMul: [],
};

for (const [pname, p] of points) {
  for (const [kname, k] of scalars) {
    out.scalarMul.push({
      name: `[${kname}] * ${pname}`,
      point: aff(p),
      k: k.toString(),
      expected: aff(mul(p, k % L)),
    });
  }
}

// aP + bQ, the shape Chaum-Pedersen actually verifies. An interleaved (Strauss) ladder
// has failure modes a single-scalar one does not: joint bit patterns where one scalar's
// bit is set and the other's is not, and the case aP == -bQ giving the identity.
const P = G;
const Q = babyJub.mulPointEscalar(G, randomScalar());
const jointCases = [
  ["a=0,b=0", 0n, 0n],
  ["a=1,b=0", 1n, 0n],
  ["a=0,b=1", 0n, 1n],
  ["a=1,b=1", 1n, 1n],
  ["a=L-1,b=L-1", L - 1n, L - 1n],
  ["a=2^250,b=1", 2n ** 250n, 1n],
  ["a=1,b=2^250", 1n, 2n ** 250n],
];
for (let i = 0; i < 12; i++) jointCases.push([`random ${i}`, randomScalar(), randomScalar()]);

for (const [name, a, b] of jointCases) {
  const sum = babyJub.addPoint(mul(P, a % L), mul(Q, b % L));
  out.doubleScalarMul.push({
    name,
    p: aff(P),
    q: aff(Q),
    a: a.toString(),
    b: b.toString(),
    expected: aff(sum),
  });
}

// aP + (-aP) == identity, the cancellation case.
{
  const a = randomScalar();
  const aP = babyJub.mulPointEscalar(P, a);
  const negAP = [F.neg(aP[0]), aP[1]];
  out.doubleScalarMul.push({
    name: "aP + (-a)P = identity (cancellation)",
    p: aff(P),
    q: aff(negAP),
    a: a.toString(),
    b: "1",
    expected: aff(IDENTITY),
  });
}

// Explicit counts: Foundry's JSON reader has no array-length primitive, and a `[*]`
// wildcard is not supported. Without these the Solidity suite has to hardcode a length,
// which silently stops covering new vectors the moment the corpus grows.
out.scalarMulCount = out.scalarMul.length;
out.doubleScalarMulCount = out.doubleScalarMul.length;

writeFileSync(OUT, JSON.stringify(out, null, 2));
console.log(`scalarMul vectors       : ${out.scalarMul.length}`);
console.log(`doubleScalarMul vectors : ${out.doubleScalarMul.length}`);
console.log("wrote build/curve-vectors.json");
