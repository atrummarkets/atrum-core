/**
 * Settlement fixtures: real accumulated ciphertexts, real decryption proofs, and the
 * lies those proofs must not be able to tell.
 *
 * This exercises the step that actually moves money in Phase 2. `EncryptedParimutuelPool`
 * is handed a claimed pool total and has to decide whether to believe it. Getting that
 * wrong drains the vault, so the fixtures here are built to attack it, not to demonstrate
 * it working.
 *
 * The ciphertexts are built the way the accumulator really builds them -- by summing
 * per-bet ciphertexts -- rather than by encrypting the total directly. Those are equal by
 * the homomorphic property, and asserting that they are equal is itself worth doing: it is
 * the property the whole design rests on.
 *
 * THE ATTACK THAT MATTERS
 *
 * `honestProofLyingTotal` carries a decryption share and a DLEQ proof that are both
 * completely valid, next to a fabricated total. Chaum-Pedersen alone ACCEPTS this -- it
 * only ever proves `D` came from the right key. Only the `C2 - D = [m]G` binding rejects
 * it. If that check is ever removed, this fixture settles a market at whatever number the
 * publisher chose.
 *
 * Usage: node scripts/gen_settlement_fixtures.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { buildElGamal } from "./lib/elgamal.mjs";
import { buildDLEQ } from "./lib/dleq.mjs";

const BUILD = new URL("../build/", import.meta.url);
const OUT = new URL("../build/settlement-fixtures.json", import.meta.url);

const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD)));
const elgamal = await buildElGamal(key.pubKey, key.secret);
const dleq = buildDLEQ(elgamal, key.secret);

const { babyJub, asPair, encrypt, decrypt, addCiphertext } = elgamal;

function assert(cond, msg) {
  if (!cond) throw new Error(`ASSERTION FAILED: ${msg}`);
}

const pt = (p) => asPair(p).map(String);

/** Sum a list of per-bet stakes into one ciphertext, as the accumulator does on-chain. */
function accumulate(stakes) {
  let acc = null;
  for (const m of stakes) {
    const c = encrypt(m, elgamal.randomScalar());
    acc = acc === null ? c : addCiphertext(acc, c);
  }
  return acc;
}

// Three bets on YES, two on NO -- a market with a real shape, not a single bet.
const YES_STAKES = [100n, 250n, 75n];
const NO_STAKES = [300n, 50n];

const yesTotal = YES_STAKES.reduce((a, b) => a + b, 0n); // 425
const noTotal = NO_STAKES.reduce((a, b) => a + b, 0n); // 350

const yesCipher = accumulate(YES_STAKES);
const noCipher = accumulate(NO_STAKES);

// The homomorphic property, checked rather than assumed: the sum of the per-bet
// ciphertexts must decrypt to the sum of the stakes.
assert(decrypt(yesCipher.c1, yesCipher.c2, 10_000n) === yesTotal, "YES ciphertext does not decrypt to its total");
assert(decrypt(noCipher.c1, noCipher.c2, 10_000n) === noTotal, "NO ciphertext does not decrypt to its total");

const yesProof = dleq.prove(yesCipher.c1);
const noProof = dleq.prove(noCipher.c1);

// `C2 - D` must equal `[m]G`. This is the equation the contract checks, verified here
// independently so a contract bug cannot be masked by a fixture built the same way.
function checkBinding(cipher, D, m) {
  const target = babyJub.addPoint(cipher.c2, elgamal.negate(D));
  const mG = m === 0n ? elgamal.IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, m);
  return elgamal.samePoint(target, mG);
}

assert(checkBinding(yesCipher, yesProof.D, yesTotal), "YES binding C2 - D = [m]G does not hold");
assert(checkBinding(noCipher, noProof.D, noTotal), "NO binding C2 - D = [m]G does not hold");

// A lie must not satisfy the binding, or the check is vacuous.
assert(!checkBinding(yesCipher, yesProof.D, yesTotal + 1n), "binding accepted a wrong plaintext");

// An empty side. A market can close with no bets on one outcome and must still settle;
// [0]G is the identity (0,1), which is a different code path from any other value.
const emptyCipher = encrypt(0n, elgamal.randomScalar());
const emptyProof = dleq.prove(emptyCipher.c1);
assert(decrypt(emptyCipher.c1, emptyCipher.c2, 10n) === 0n, "empty side does not decrypt to 0");
assert(checkBinding(emptyCipher, emptyProof.D, 0n), "empty-side binding fails");

const side = (cipher, proof, total) => ({
  c1: pt(cipher.c1),
  c2: pt(cipher.c2),
  d: pt(proof.D),
  proof: { ax: pt(proof.A)[0], ay: pt(proof.A)[1], bx: pt(proof.B)[0], by: pt(proof.B)[1], z: proof.z.toString() },
  total: total.toString(),
});

writeFileSync(
  OUT,
  JSON.stringify(
    {
      _note:
        "Settlement fixtures. `yes`/`no` must settle. `honestProofLyingTotal` carries a VALID " +
        "DLEQ proof with a FABRICATED total and must be rejected by the C2-D=[m]G binding, " +
        "not by the DLEQ check.",
      committeeKey: pt(dleq.H),
      yes: side(yesCipher, yesProof, yesTotal),
      no: side(noCipher, noProof, noTotal),
      empty: side(emptyCipher, emptyProof, 0n),
      // Same valid proof, same valid share, wrong number.
      honestProofLyingTotal: {
        ...side(yesCipher, yesProof, yesTotal),
        claimedTotal: (yesTotal * 3n).toString(),
      },
      expected: {
        yesTotal: yesTotal.toString(),
        noTotal: noTotal.toString(),
        yesProbabilityBps: ((yesTotal * 10_000n) / (yesTotal + noTotal)).toString(),
      },
    },
    null,
    2,
  ),
);

console.log("settlement fixtures written to", OUT.pathname);
console.log(`  YES total ${yesTotal} from ${YES_STAKES.length} bets, NO total ${noTotal} from ${NO_STAKES.length}`);
console.log("  homomorphic sums decrypt correctly, C2 - D = [m]G holds, and a wrong plaintext is rejected");
