/**
 * Generate real Groth16 proofs and independently verify the ElGamal mechanism.
 *
 * Deliberately does more than `snarkjs verify`. A passing proof only says the
 * witness satisfied the constraints -- it says nothing about whether the
 * constraints encode the scheme we think they do. So this also:
 *
 *   1. recomputes C1/C2 independently with circomlibjs and checks the circuit's
 *      outputs match, and
 *   2. exercises the homomorphic property end to end -- add two ciphertexts,
 *      decrypt the sum, confirm it equals m1 + m2.
 *
 * (2) is the load-bearing claim of the whole architecture: it is what lets the
 * accumulator total the pool without ever decrypting. If it failed, the design
 * would be dead regardless of gas.
 *
 * Writes proof + public-signal calldata for on-chain gas measurement.
 */
import { buildBabyjub } from "circomlibjs";
import * as snarkjs from "snarkjs";
import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const BUILD = new URL("../build/", import.meta.url);
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

const asPair = (p) => [F.toObject(p[0]), F.toObject(p[1])];
const samePoint = (a, b) => F.eq(a[0], b[0]) && F.eq(a[1], b[1]);

/** C1 = [r]G, C2 = [m]G + [r]H -- computed outside the circuit. */
function encrypt(m, r) {
  const c1 = babyJub.mulPointEscalar(babyJub.Base8, r);
  const mG = m === 0n ? IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, m);
  const rH = babyJub.mulPointEscalar(H, r);
  return { c1, c2: babyJub.addPoint(mG, rH) };
}

/**
 * Recover m from a ciphertext: [m]G = C2 - [s]C1, then discrete log by
 * baby-step giant-step.
 *
 * BSGS is why plaintexts must be range-bounded. It is O(sqrt(bound)), so the
 * publisher can recover a pool total of ~2^40 in ~2^20 steps, but the cost grows
 * as the square root of the bound -- an unbounded plaintext is unrecoverable.
 */
function decrypt(c1, c2, bound) {
  const sC1 = babyJub.mulPointEscalar(c1, secret);
  // Negate: on a twisted Edwards curve, -(x, y) = (-x, y).
  const target = babyJub.addPoint(c2, [F.neg(sC1[0]), sC1[1]]);

  if (samePoint(target, IDENTITY)) return 0n;

  const m = BigInt(Math.ceil(Math.sqrt(Number(bound))) + 1);

  // Baby steps: table of [j]G for j in [0, m).
  const table = new Map();
  let acc = IDENTITY;
  for (let j = 0n; j < m; j++) {
    table.set(`${F.toObject(acc[0])},${F.toObject(acc[1])}`, j);
    acc = babyJub.addPoint(acc, babyJub.Base8);
  }

  // Giant steps: target - [i*m]G, looking for a baby step.
  const mG = babyJub.mulPointEscalar(babyJub.Base8, m);
  const negMG = [F.neg(mG[0]), mG[1]];

  let cur = target;
  for (let i = 0n; i <= m; i++) {
    const hit = table.get(`${F.toObject(cur[0])},${F.toObject(cur[1])}`);
    if (hit !== undefined) return i * m + hit;
    cur = babyJub.addPoint(cur, negMG);
  }
  throw new Error("BSGS failed -- plaintext outside the searched bound");
}

// ---------------------------------------------------------------------------

const VARIANTS = {
  probe_pubkey_input: (amount, randomness) => ({
    amount: amount.toString(),
    randomness: randomness.toString(),
    pubKey: [F.toObject(H[0]).toString(), F.toObject(H[1]).toString()],
  }),
  probe_fixed_key: (amount, randomness) => ({
    amount: amount.toString(),
    randomness: randomness.toString(),
  }),
};

let failures = 0;
const check = (label, ok) => {
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}`);
  if (!ok) failures++;
};

for (const [name, makeInput] of Object.entries(VARIANTS)) {
  console.log(`\n=== ${name} ===`);

  // 50 USDC at 6 decimals -- the reference's worked example.
  const amount = 50_000_000n;
  const randomness = randomScalar();
  const input = makeInput(amount, randomness);

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    new URL(`${name}_js/${name}.wasm`, BUILD).pathname,
    new URL(`${name}.zkey`, BUILD).pathname,
  );

  const vkey = JSON.parse(readFileSync(new URL(`${name}_vkey.json`, BUILD)));
  check("groth16 proof verifies", await snarkjs.groth16.verify(vkey, publicSignals, proof));
  check(
    `public signal count is ${publicSignals.length}`,
    publicSignals.length === (name === "probe_fixed_key" ? 4 : 6),
  );

  // Circuit outputs come first in publicSignals: c1.x, c1.y, c2.x, c2.y.
  const circuitC1 = [BigInt(publicSignals[0]), BigInt(publicSignals[1])];
  const circuitC2 = [BigInt(publicSignals[2]), BigInt(publicSignals[3])];

  // Independent recomputation -- does the circuit encode the scheme we think?
  const expected = encrypt(amount, randomness);
  const [ex1, ey1] = asPair(expected.c1);
  const [ex2, ey2] = asPair(expected.c2);
  check("C1 matches independent computation",
    circuitC1[0] === ex1 && circuitC1[1] === ey1);
  check("C2 matches independent computation",
    circuitC2[0] === ex2 && circuitC2[1] === ey2);

  // Round-trip through real decryption.
  const recovered = decrypt(expected.c1, expected.c2, 100_000_000n);
  check(`decrypt round-trip recovers ${amount}`, recovered === amount);

  // A tampered public signal must break verification.
  const tampered = [...publicSignals];
  tampered[0] = ((BigInt(tampered[0]) + 1n)).toString();
  check("tampered public signal is rejected",
    !(await snarkjs.groth16.verify(vkey, tampered, proof)));

  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  writeFileSync(new URL(`${name}_calldata.json`, BUILD), calldata);
  writeFileSync(
    new URL(`${name}_proof.json`, BUILD),
    JSON.stringify({ proof, publicSignals }, null, 2),
  );
}

// ---------------------------------------------------------------------------
// The homomorphic property -- the reference's worked example, verified for real.
// ---------------------------------------------------------------------------
console.log("\n=== homomorphic accumulation (Alice 50 + Carol 20 = 70) ===");

const alice = 50_000_000n;
const carol = 20_000_000n;

const encA = encrypt(alice, randomScalar());
const encC = encrypt(carol, randomScalar());

// This is exactly what ElGamalAccumulator.sol does on-chain: two point additions
// on ciphertext, no decryption anywhere.
const sum = {
  c1: babyJub.addPoint(encA.c1, encC.c1),
  c2: babyJub.addPoint(encA.c2, encC.c2),
};

const total = decrypt(sum.c1, sum.c2, 200_000_000n);
check(`Enc(50) + Enc(20) decrypts to ${alice + carol}`, total === alice + carol);

// The ratio is the only thing that is ever published. Raw totals stay sealed.
const noSide = encrypt(30_000_000n, randomScalar());
const noTotal = decrypt(noSide.c1, noSide.c2, 200_000_000n);
const yesPct = Number((total * 10000n) / (total + noTotal)) / 100;
check(`published ratio is YES ${yesPct}% (expected 70%)`, yesPct === 70);

// Zero must encrypt and decrypt cleanly -- m = 0 makes [m]G the identity, which is
// the edge case the complete twisted-Edwards addition law exists to handle.
const encZero = encrypt(0n, randomScalar());
check("zero plaintext round-trips", decrypt(encZero.c1, encZero.c2, 1000n) === 0n);

console.log(
  failures === 0
    ? "\nall checks passed"
    : `\n${failures} CHECK(S) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
