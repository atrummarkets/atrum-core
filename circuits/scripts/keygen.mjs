/**
 * Generate a BabyJubJub ElGamal keypair.
 *
 * Phase 0/2 uses a SINGLE decryption key, disclosed plainly -- not yet a t-of-n
 * committee. That is a deliberate, stated cut line, not an oversight: with one key
 * the operator can decrypt the pool total, and the honest description of the system
 * at that stage says so out loud. The 3-of-5 threshold committee with
 * Chaum-Pedersen decryption proofs is Phase 3.
 *
 * This key is for measurement and testing only. Never use a key generated here,
 * with this RNG, for anything holding value.
 */
import { buildBabyjub } from "circomlibjs";
import { randomBytes, createHash } from "node:crypto";
import { writeFileSync } from "node:fs";

const babyJub = await buildBabyjub();
const F = babyJub.F;

// BabyJubJub prime-order subgroup order.
const SUBGROUP_ORDER =
  2736030358979909402780800718157159386076813972158567259200215660948447373041n;

/** Uniform scalar in [1, l), by rejection sampling -- no modular bias. */
function randomScalar() {
  while (true) {
    const candidate = BigInt("0x" + randomBytes(32).toString("hex"));
    if (candidate > 0n && candidate < SUBGROUP_ORDER) return candidate;
  }
}

/**
 * PINNED test secret, derived from a public seed by counter-hashing until in range.
 *
 * This key is PUBLIC and therefore WORTHLESS as a secret -- anyone reading this file can
 * decrypt every pool encrypted under it. That is already true of any key this script
 * produces: it is a single-party key held on one machine, and Phase 2 ships "a single
 * decryption key, disclosed plainly" by design. Pinning changes reproducibility, not
 * security.
 *
 * What it fixes: a random key made `committee_key.circom` -- and therefore the compiled
 * circuits -- differ per machine, so committed key-dependent fixtures could not match a
 * fresh checkout. With this pinned, the circuit, the fixtures and the on-chain
 * `EncryptedParimutuelPool` constructor all agree everywhere.
 *
 * Set `ATRUM_RANDOM_KEY=1` to get a fresh random key instead. A real deployment uses
 * neither path -- it uses a key from an actual ceremony.
 */
function pinnedScalar(seed) {
  for (let counter = 0; ; counter++) {
    const digest = createHash("sha256").update(`${seed}:${counter}`).digest("hex");
    const candidate = BigInt("0x" + digest);
    if (candidate > 0n && candidate < SUBGROUP_ORDER) return candidate;
  }
}

const PINNED_SEED = "atrum-test-committee-key-v1-PUBLIC-DO-NOT-USE-IN-PRODUCTION";

const useRandom = process.env.ATRUM_RANDOM_KEY === "1";
const secret = useRandom ? randomScalar() : pinnedScalar(PINNED_SEED);

if (useRandom) {
  console.log("ATRUM_RANDOM_KEY=1 -- generating a FRESH key.");
  console.log("Committed key-dependent fixtures will no longer match. Regenerate them.\n");
} else {
  console.log("using the PINNED test key (public, reproducible, worthless as a secret)\n");
}

// H = [secret] * G, where G is the canonical order-8 base point circomlib uses.
const H = babyJub.mulPointEscalar(babyJub.Base8, secret);

const pubKey = [F.toObject(H[0]).toString(), F.toObject(H[1]).toString()];

// Sanity: the derived point must satisfy the curve equation, and must lie in the
// prime-order subgroup ([l]H == identity). A point off the subgroup would leak
// bits of the plaintext through small-subgroup effects.
if (!babyJub.inCurve(H)) throw new Error("derived pubkey is not on the curve");

const shouldBeIdentity = babyJub.mulPointEscalar(H, SUBGROUP_ORDER);
if (
  F.toObject(shouldBeIdentity[0]) !== 0n ||
  F.toObject(shouldBeIdentity[1]) !== 1n
) {
  throw new Error("derived pubkey is not in the prime-order subgroup");
}

const out = {
  _warning: "TEST KEY. Generated for gas measurement. Not for production use.",
  secret: secret.toString(),
  pubKey,
};

writeFileSync(
  new URL("../build/committee-key.json", import.meta.url),
  JSON.stringify(out, null, 2),
);

console.log("secret :", secret.toString());
console.log("pubKey.x:", pubKey[0]);
console.log("pubKey.y:", pubKey[1]);
console.log("\ncurve check: on-curve ok, prime-order subgroup ok");
