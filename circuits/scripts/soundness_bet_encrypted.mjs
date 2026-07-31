/**
 * SOUNDNESS SUITE for bet_encrypted.circom.
 *
 * A circuit test that only checks honest inputs produce a valid proof tests almost
 * nothing. What matters is the opposite: that every malicious witness is REJECTED. So
 * every case below is an attack, and the pass condition is that witness generation
 * FAILS.
 *
 * Witness calculation alone decides constraint satisfaction, so this needs no trusted
 * setup and no zkey -- it runs in seconds against the wasm.
 *
 * The attack that matters most is ciphertext inflation. In Phase 2 `units` is private,
 * so the CONTRACT CANNOT SEE IT. Every guard that used to live in Solidity
 * (`units == 0`, stake matches note) has to move into the circuit or disappear entirely.
 * That shift is the whole reason this file exists.
 *
 * Usage: node scripts/soundness_bet_encrypted.mjs
 */
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import * as snarkjs from "snarkjs";
import { buildBabyjub } from "circomlibjs";
import {
  init,
  hash2,
  MerkleTree,
  DEPTH,
  OUTCOME_UNBET,
  OUTCOME_YES,
  OUTCOME_NO,
  noteCommitment,
  nullifierHash,
  FIELD_SIZE,
} from "./atrum.mjs";

const BUILD = new URL("../build/", import.meta.url);
const WASM = new URL("bet_encrypted_js/bet_encrypted.wasm", BUILD).pathname;

const AMOUNT_BITS = 40n;
const MARKET_ID = 7n;
const UNITS = 100n;

await init();
const babyJub = await buildBabyjub();
const F = babyJub.F;

const SUBGROUP_ORDER =
  2736030358979909402780800718157159386076813972158567259200215660948447373041n;

const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD)));
const H = [F.e(BigInt(key.pubKey[0])), F.e(BigInt(key.pubKey[1]))];
const IDENTITY = [F.e(0n), F.e(1n)];

const randomField = () => BigInt("0x" + randomBytes(31).toString("hex")) % FIELD_SIZE;
function randomScalar() {
  while (true) {
    const c = BigInt("0x" + randomBytes(32).toString("hex"));
    if (c > 0n && c < SUBGROUP_ORDER) return c;
  }
}

const aff = (p) => [F.toObject(p[0]), F.toObject(p[1])];

/**
 * Note commitment WITHOUT the JS mirror's range guard.
 *
 * `atrum.mjs::noteCommitment` throws on out-of-range units, which is correct for honest
 * code and useless for an attack harness -- it stops the malicious witness in JavaScript
 * before the circuit ever sees it, and a test that never reaches the circuit proves
 * nothing about the circuit.
 */
function rawNoteCommitment({ nullifier, secret, marketId, outcome, units }) {
  const packed = outcome * (1n << 64n) + units;
  return hash2(hash2(nullifier, secret), hash2(marketId, packed));
}

/** C1 = [r]G, C2 = [m]G + [r]H, under an arbitrary key (default: the committee's). */
function encrypt(m, r, pubKey = H) {
  const c1 = r === 0n ? IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, r);
  const mG = m === 0n ? IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, m);
  const rH = r === 0n ? IDENTITY : babyJub.mulPointEscalar(pubKey, r);
  return { c1, c2: babyJub.addPoint(mG, rH) };
}

// ---------------------------------------------------------------------------
// A known-good witness, which every attack below mutates exactly one field of.
// ---------------------------------------------------------------------------
function baseline({ units = UNITS, outcome = OUTCOME_YES, marketId = MARKET_ID } = {}) {
  const nullifier = randomField();
  const secret = randomField();
  const newNullifier = randomField();
  const newSecret = randomField();
  const r = randomScalar();

  const oldCommitment = rawNoteCommitment({
    nullifier,
    secret,
    marketId,
    outcome: OUTCOME_UNBET,
    units,
  });

  const tree = new MerkleTree(DEPTH);
  tree.insert(oldCommitment);
  // Some decoys, so the path is not trivially all-zeros.
  for (let i = 0; i < 7; i++) tree.insert(randomField());
  const path = tree.path(0);

  const newCommitment = rawNoteCommitment({
    nullifier: newNullifier,
    secret: newSecret,
    marketId,
    outcome,
    units,
  });

  const enc = encrypt(units, r);
  const [c1x, c1y] = aff(enc.c1);
  const [c2x, c2y] = aff(enc.c2);

  return {
    root: tree.root().toString(),
    nullifierHash: nullifierHash(nullifier).toString(),
    newCommitment: newCommitment.toString(),
    betMeta: (marketId * 4n + outcome).toString(),
    c1: [c1x.toString(), c1y.toString()],
    c2: [c2x.toString(), c2y.toString()],

    nullifier: nullifier.toString(),
    secret: secret.toString(),
    newNullifier: newNullifier.toString(),
    newSecret: newSecret.toString(),
    marketId: marketId.toString(),
    outcome: outcome.toString(),
    units: units.toString(),
    encRandomness: r.toString(),
    pathElements: path.pathElements.map(String),
    pathIndices: path.pathIndices.map(String),
  };
}

async function satisfies(input) {
  try {
    await snarkjs.wtns.calculate(input, WASM, "/dev/null");
    return true;
  } catch {
    return false;
  }
}

let pass = 0;
let fail = 0;

async function mustAccept(name, input) {
  const ok = await satisfies(input);
  console.log(`  ${ok ? "ok  " : "FAIL"}  ACCEPTS  ${name}`);
  ok ? pass++ : fail++;
}

async function mustReject(name, input) {
  const ok = await satisfies(input);
  console.log(`  ${!ok ? "ok  " : "FAIL"}  rejects  ${name}`);
  !ok ? pass++ : fail++;
}

// ---------------------------------------------------------------------------
console.log("\n=== baseline: honest witnesses must be accepted ===");
// If these fail, every rejection below is meaningless -- a circuit that rejects
// everything would score a perfect soundness result.
await mustAccept("honest bet on YES", baseline());
await mustAccept("honest bet on NO", baseline({ outcome: OUTCOME_NO }));
await mustAccept("units = 1 (minimum sensible stake)", baseline({ units: 1n }));
await mustAccept("units = 2^40 - 1 (top of range)", baseline({ units: 2n ** AMOUNT_BITS - 1n }));
await mustAccept("marketId = 0", baseline({ marketId: 0n }));
await mustAccept("marketId = 2^32 - 1 (top of range)", baseline({ marketId: 2n ** 32n - 1n }));

// ---------------------------------------------------------------------------
console.log("\n=== ciphertext inflation: the attack Phase 2 lives or dies on ===");
{
  // Spend a 1-unit note, publish Enc(1,000,000). If this were accepted the bettor would
  // claim a million units of the pool having risked one -- and NOTHING on-chain could
  // detect it, because the contract cannot read either value.
  const inp = baseline({ units: 1n });
  const r = BigInt(inp.encRandomness);
  const fake = encrypt(1_000_000n, r);
  const [x1, y1] = aff(fake.c1);
  const [x2, y2] = aff(fake.c2);
  inp.c1 = [x1.toString(), y1.toString()];
  inp.c2 = [x2.toString(), y2.toString()];
  await mustReject("Enc(1,000,000) against a 1-unit note", inp);
}
{
  // Deflation is equally unsound: it would let someone hold a large position while
  // barely moving the published odds.
  const inp = baseline({ units: 1000n });
  const r = BigInt(inp.encRandomness);
  const fake = encrypt(1n, r);
  const [x1, y1] = aff(fake.c1);
  const [x2, y2] = aff(fake.c2);
  inp.c1 = [x1.toString(), y1.toString()];
  inp.c2 = [x2.toString(), y2.toString()];
  await mustReject("Enc(1) against a 1000-unit note", inp);
}
{
  // Encrypting the right amount under the ATTACKER's key instead of the committee's.
  // The committee could then never decrypt the pool, and the attacker alone could.
  const inp = baseline();
  const attackerSecret = randomScalar();
  const attackerKey = babyJub.mulPointEscalar(babyJub.Base8, attackerSecret);
  const r = BigInt(inp.encRandomness);
  const fake = encrypt(UNITS, r, attackerKey);
  const [x1, y1] = aff(fake.c1);
  const [x2, y2] = aff(fake.c2);
  inp.c1 = [x1.toString(), y1.toString()];
  inp.c2 = [x2.toString(), y2.toString()];
  await mustReject("Enc(units) under the attacker's own key", inp);
}
{
  const inp = baseline();
  inp.c1 = ["0", "1"]; // identity, not [r]G
  await mustReject("C1 replaced with the identity", inp);
}
{
  const inp = baseline();
  inp.c2 = ["0", "1"];
  await mustReject("C2 replaced with the identity", inp);
}
{
  const inp = baseline();
  inp.c1 = [inp.c2[0], inp.c2[1]]; // swap the two points
  await mustReject("C1 and C2 swapped", inp);
}
{
  const inp = baseline();
  inp.c2 = [(BigInt(inp.c2[0]) + 1n).toString(), inp.c2[1]];
  await mustReject("C2.x off by one", inp);
}

// ---------------------------------------------------------------------------
console.log("\n=== range and value bounds (the contract can no longer check these) ===");
await mustReject("units = 0 (worthless note, still consumes a leaf)", baseline({ units: 0n }));
await mustReject("units = 2^40 (one past the range)", baseline({ units: 2n ** AMOUNT_BITS }));
await mustReject("units = 2^64", baseline({ units: 2n ** 64n }));
await mustReject("marketId = 2^32 (one past the range)", baseline({ marketId: 2n ** 32n }));

// ---------------------------------------------------------------------------
console.log("\n=== outcome constraints ===");
await mustReject("outcome = 0 (unbet is not a side)", baseline({ outcome: 0n }));
await mustReject("outcome = 3 (out of range)", baseline({ outcome: 3n }));
{
  // Spending a note that is ALREADY on a side -- re-betting after news lands.
  const inp = baseline();
  inp.outcome = OUTCOME_NO.toString();
  // betMeta still claims YES.
  await mustReject("outcome disagrees with betMeta", inp);
}

// ---------------------------------------------------------------------------
console.log("\n=== identity and note-binding ===");
{
  const inp = baseline();
  inp.nullifierHash = randomField().toString();
  await mustReject("nullifierHash does not match the nullifier", inp);
}
{
  const inp = baseline();
  inp.root = randomField().toString();
  await mustReject("root not the one the path proves", inp);
}
{
  const inp = baseline();
  inp.pathElements[0] = randomField().toString();
  await mustReject("tampered Merkle path element", inp);
}
{
  const inp = baseline();
  inp.pathIndices[0] = inp.pathIndices[0] === "0" ? "1" : "0";
  await mustReject("flipped Merkle path index", inp);
}
{
  const inp = baseline();
  inp.pathIndices[0] = "2"; // non-boolean -- forges membership if unconstrained
  await mustReject("non-boolean path index (2)", inp);
}
{
  const inp = baseline();
  inp.newCommitment = randomField().toString();
  await mustReject("newCommitment not the note the witness describes", inp);
}
{
  // Reusing the spent note's secrets makes the new leaf identical to the old one, which
  // would make that tree position ambiguous for every later Merkle proof.
  const nullifier = randomField();
  const secret = randomField();
  const units = UNITS;
  const oldC = rawNoteCommitment({ nullifier, secret, marketId: MARKET_ID, outcome: OUTCOME_UNBET, units });

  const tree = new MerkleTree(DEPTH);
  tree.insert(oldC);
  for (let i = 0; i < 7; i++) tree.insert(randomField());
  const path = tree.path(0);

  const r = randomScalar();
  const enc = encrypt(units, r);
  const [c1x, c1y] = aff(enc.c1);
  const [c2x, c2y] = aff(enc.c2);

  await mustReject("new note reuses the spent note's secrets and outcome", {
    root: tree.root().toString(),
    nullifierHash: nullifierHash(nullifier).toString(),
    newCommitment: oldC.toString(),
    betMeta: (MARKET_ID * 4n + OUTCOME_UNBET).toString(),
    c1: [c1x.toString(), c1y.toString()],
    c2: [c2x.toString(), c2y.toString()],
    nullifier: nullifier.toString(),
    secret: secret.toString(),
    newNullifier: nullifier.toString(),
    newSecret: secret.toString(),
    marketId: MARKET_ID.toString(),
    outcome: OUTCOME_UNBET.toString(),
    units: units.toString(),
    encRandomness: r.toString(),
    pathElements: path.pathElements.map(String),
    pathIndices: path.pathIndices.map(String),
  });
}
{
  // A note not in the tree at all.
  const inp = baseline();
  inp.secret = randomField().toString();
  await mustReject("spending a note that is not in the tree", inp);
}
{
  const inp = baseline();
  inp.betMeta = (BigInt(inp.betMeta) + 4n).toString(); // different market
  await mustReject("betMeta claims a different market than the note", inp);
}

// ---------------------------------------------------------------------------
console.log("\n=== encryption randomness ===");
{
  // r = 0 makes C1 the identity and C2 = [m]G, so ANYONE can recover the stake by
  // discrete log. Self-inflicted rather than a protocol break, but a footgun worth
  // knowing the circuit's stance on.
  const inp = baseline();
  const enc = encrypt(UNITS, 0n);
  const [x1, y1] = aff(enc.c1);
  const [x2, y2] = aff(enc.c2);
  inp.encRandomness = "0";
  inp.c1 = [x1.toString(), y1.toString()];
  inp.c2 = [x2.toString(), y2.toString()];
  const accepted = await satisfies(inp);
  console.log(
    `  ${accepted ? "NOTE" : "ok  "}  ${accepted ? "ACCEPTS" : "rejects"}  encRandomness = 0 (leaks the stake to everyone)`,
  );
  if (accepted) {
    console.log(
      "        -> circuit permits it. Not unsound, but a client that does this publishes",
    );
    console.log(
      "           its own bet. Consider rejecting C1 == identity at the contract boundary.",
    );
  }
}

console.log(
  `\n${fail === 0 ? "ALL SOUNDNESS CHECKS PASSED" : `${fail} SOUNDNESS CHECK(S) FAILED`}  (${pass} passed, ${fail} failed)`,
);
process.exit(fail === 0 ? 0 : 1);
