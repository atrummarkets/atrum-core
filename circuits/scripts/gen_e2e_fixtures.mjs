/**
 * END-TO-END fixture: settle the ciphertext a REAL encrypted bet produced.
 *
 * WHY THIS EXISTS
 *
 * Phase 2's two halves are each well tested, against different inputs:
 *
 *   - `ShieldedPool.t.sol` runs a real `betEncrypted` proof, so the accumulator receives a
 *     ciphertext the CIRCUIT built.
 *   - `EncryptedParimutuelPool.t.sol` settles ciphertexts that `gen_settlement_fixtures.mjs`
 *     built directly in JavaScript.
 *
 * Nothing joins them. No test has ever shown that a ciphertext produced by the circuit can
 * actually be decrypted and settled on-chain — which is precisely the claim Phase 2 rests
 * on. Every real bug found in this repo so far has lived in exactly that kind of seam:
 * `queuePadding` (deposit and redeem each correct, neither proving provenance), and the
 * guard migration (`units == 0`, which fell through the Solidity/circuit boundary).
 *
 * So this reads the ciphertext out of the REAL bet proof in `action-fixtures.json` and
 * produces the decryption share and DLEQ proof for it. If the circuit's encryption and the
 * contract's settlement disagree by so much as one field element, the test that consumes
 * this will fail.
 *
 * The NO side is deliberately left empty: its accumulator holds Enc(0), which is the curve
 * identity, and `C1 = identity` is the degenerate input the DLEQ verifier has to handle
 * rather than choke on. A market with bets on only one side is also the common case early
 * in a market's life, so it is not a contrived edge.
 *
 * Usage: node scripts/gen_e2e_fixtures.mjs   (after gen_action_fixtures.mjs)
 */
import { readFileSync, writeFileSync } from "node:fs";
import { buildElGamal } from "./lib/elgamal.mjs";
import { buildDLEQ } from "./lib/dleq.mjs";

const BUILD = new URL("../build/", import.meta.url);
const OUT = new URL("../build/e2e-fixtures.json", import.meta.url);

function assert(cond, msg) {
  if (!cond) throw new Error(`ASSERTION FAILED: ${msg}`);
}

const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD)));
const elgamal = await buildElGamal(key.pubKey, key.secret);
const { babyJub, asPair, decrypt, addCiphertext } = elgamal;
const dleq = buildDLEQ(elgamal, key.secret);

const pt = (p) => asPair(p).map(String);

// ---------------------------------------------------------------------------
// The accumulator state that TWO REAL encrypted bets produced.
//
// `gen_action_fixtures.mjs` already emits this: two `betEncrypted` proofs on the same
// market and side, and the resulting accumulated ciphertext. Using it rather than a single
// bet exercises the homomorphic property on real circuit output -- Enc(100) + Enc(37) has
// to settle to 137, summed on-chain by point addition and never decrypted until now.
// ---------------------------------------------------------------------------
const actions = JSON.parse(readFileSync(new URL("action-fixtures.json", BUILD)));
assert(
  actions.accumulatorAfterBothBets,
  "action-fixtures.json has no accumulatorAfterBothBets -- run gen_action_fixtures.mjs",
);

const acc = actions.accumulatorAfterBothBets;
const ct = acc.ciphertext;
assert(Array.isArray(ct) && ct.length === 4, "ciphertext must be [c1x, c1y, c2x, c2y]");

const stakes = acc.fromStakes.map(BigInt);
const total = stakes.reduce((a, b) => a + b, 0n);
assert(
  total === BigInt(acc.decryptsTo),
  `fixture disagrees with itself: stakes sum to ${total}, decryptsTo says ${acc.decryptsTo}`,
);

const accumulated = {
  c1: [elgamal.F.e(BigInt(ct[0])), elgamal.F.e(BigInt(ct[1]))],
  c2: [elgamal.F.e(BigInt(ct[2])), elgamal.F.e(BigInt(ct[3]))],
};

// THE assertion that ties the circuit to the settlement path: the sum of two ciphertexts
// the CIRCUIT built must decrypt to the sum of the stakes. If the circuit's encryption and
// this decryption ever diverge, it fails here rather than producing a market that can never
// be settled.
const recovered = decrypt(accumulated.c1, accumulated.c2, 1_000_000n);
assert(
  recovered === total,
  `accumulated circuit ciphertext decrypts to ${recovered}, expected ${total}`,
);

// ---------------------------------------------------------------------------
// Decryption shares for what the accumulator will actually hold.
// ---------------------------------------------------------------------------
const yesProof = dleq.prove(accumulated.c1);

// NO side: never bet on, so its accumulator still holds Enc(0) = (identity, identity).
// C1 = identity is the degenerate input the DLEQ verifier must handle rather than choke on,
// and a market with bets on only one side is the common early case, not a contrived edge.
const identity = { c1: elgamal.IDENTITY, c2: elgamal.IDENTITY };
const emptyProof = dleq.prove(identity.c1);

/** `C2 - D == [m]G` -- the exact equation `_checkClaimedPlaintext` evaluates on-chain. */
function checkBinding(cipher, D, m) {
  const target = babyJub.addPoint(cipher.c2, elgamal.negate(D));
  const mG = m === 0n ? elgamal.IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, m);
  return elgamal.samePoint(target, mG);
}

assert(checkBinding(accumulated, yesProof.D, total), "YES binding C2 - D = [m]G does not hold");
assert(checkBinding(identity, emptyProof.D, 0n), "empty-side binding does not hold for Enc(0)");

const serialise = (cipher, proof, total) => ({
  c1: pt(cipher.c1),
  c2: pt(cipher.c2),
  d: pt(proof.D),
  // Field names match `gen_settlement_fixtures.mjs` and `ChaumPedersen.Proof` so the
  // Solidity readers are identical across both fixtures. Two conventions for the same
  // struct is a trap.
  proof: {
    ax: pt(proof.A)[0],
    ay: pt(proof.A)[1],
    bx: pt(proof.B)[0],
    by: pt(proof.B)[1],
    z: proof.z.toString(),
  },
  total: total.toString(),
});

writeFileSync(
  OUT,
  JSON.stringify(
    {
      _note:
        "END-TO-END: the YES ciphertext here came from a REAL bet_encrypted proof, not from JS. Settling it proves the circuit and the settlement path agree.",
      committeeKey: pt(dleq.H),
      stakes: stakes.map(String),
      total: total.toString(),
      // The accumulator's state after two real encrypted bets on YES and nothing on NO.
      yes: serialise(accumulated, yesProof, total),
      no: serialise(identity, emptyProof, 0n),
      expected: {
        yesTotal: total.toString(),
        noTotal: "0",
        // Sole side staked, so YES is the whole pool: 100%.
        yesProbabilityBps: "10000",
        // Winners split the entire pool pro rata; with nothing on NO that is 1:1.
        payoutForFullTotal: total.toString(),
      },
    },
    null,
    2,
  ),
);

console.log("end-to-end settlement fixture written");
console.log("  ciphertext source : TWO REAL bet_encrypted proofs (not JS-constructed)");
console.log("  stakes            :", stakes.map(String).join(" + "), "=", total.toString());
console.log("  decrypts to total : yes");
console.log("  bindings C2-D=[m]G: hold for both the staked side and the empty side");
console.log("\nwrote build/e2e-fixtures.json");
