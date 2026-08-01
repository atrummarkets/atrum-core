/**
 * SOUNDNESS SUITE for redeem_private.circom.
 *
 * Every case is an attack and the pass condition is REJECTION. Witness calculation decides
 * constraint satisfaction, so this needs no trusted setup and runs in seconds.
 *
 * Two families of attack matter here, and they are why this file is long:
 *
 *   1. THE UNBOUNDED MINT. The payout note must not be redeemable. If it were, a holder
 *      could redeem a winner, receive a payout note, redeem THAT, and repeat forever --
 *      nullifiers do not help, because each payout note is genuinely new. Every individual
 *      step would be legitimate.
 *
 *   2. PAYOUT INFLATION. `units` and the payout are both private, so the CONTRACT CANNOT
 *      CHECK EITHER. The only thing standing between a holder and an arbitrary payout is
 *      the in-circuit division. Every way of lying about it is tried below.
 *
 * Usage: node scripts/soundness_redeem_private.mjs
 */
import { randomBytes } from "node:crypto";
import * as snarkjs from "snarkjs";
import {
  init,
  hash2,
  MerkleTree,
  DEPTH,
  OUTCOME_UNBET,
  OUTCOME_YES,
  OUTCOME_NO,
  nullifierHash,
  FIELD_SIZE,
} from "./atrum.mjs";

const BUILD = new URL("../build/", import.meta.url);
const WASM = new URL("redeem_private_js/redeem_private.wasm", BUILD).pathname;

const SETTLED = 3n;
const MARKET_ID = 7n;

await init();

const randomField = () => BigInt("0x" + randomBytes(31).toString("hex")) % FIELD_SIZE;

/** Note commitment without the JS mirror's range guard, so out-of-range attacks reach the circuit. */
function rawNote({ nullifier, secret, marketId, outcome, units }) {
  const packed = outcome * (1n << 64n) + units;
  return hash2(hash2(nullifier, secret), hash2(marketId, packed));
}

const packMeta = (marketId, outcome, totalPool, winningPool) =>
  marketId * (1n << 130n) + outcome * (1n << 128n) + totalPool * (1n << 64n) + winningPool;

/**
 * A known-good witness. Every attack mutates exactly one thing about it.
 *
 * Default shape: a winning YES position of 100 in a pool of 400 total / 250 winning, so the
 * payout is a real division with a real remainder (100*400/250 = 160 exactly, remainder 0),
 * and `pro` below picks numbers that do NOT divide evenly so the remainder path is exercised.
 */
function baseline({
  outcome = OUTCOME_YES,
  units = 100n,
  totalPool = 400n,
  winningPool = 250n,
  marketId = MARKET_ID,
  overrides = {},
} = {}) {
  const nullifier = randomField();
  const secret = randomField();
  const newNullifier = randomField();
  const newSecret = randomField();

  const oldCommitment = rawNote({ nullifier, secret, marketId, outcome, units });

  const tree = new MerkleTree(DEPTH);
  tree.insert(oldCommitment);
  for (let i = 0; i < 7; i++) tree.insert(randomField());
  const path = tree.path(0);

  // Honest division. On the refund path the quotient is unused, but supply a consistent one
  // anyway so the only thing under test is the constraint, not a malformed witness.
  const isUnbet = outcome === OUTCOME_UNBET;
  const dividend = units * totalPool;
  const payout = winningPool === 0n ? 0n : dividend / winningPool;
  const remainder = winningPool === 0n ? 0n : dividend % winningPool;

  const payoutUnits = isUnbet ? units : payout;

  const newCommitment = rawNote({
    nullifier: newNullifier,
    secret: newSecret,
    marketId,
    outcome: SETTLED,
    units: payoutUnits,
  });

  return {
    root: tree.root().toString(),
    nullifierHash: nullifierHash(nullifier).toString(),
    newCommitment: newCommitment.toString(),
    redeemMeta: packMeta(marketId, outcome, totalPool, winningPool).toString(),

    nullifier: nullifier.toString(),
    secret: secret.toString(),
    newNullifier: newNullifier.toString(),
    newSecret: newSecret.toString(),
    marketId: marketId.toString(),
    outcome: outcome.toString(),
    units: units.toString(),
    totalPool: totalPool.toString(),
    winningPool: winningPool.toString(),
    payout: payout.toString(),
    remainder: remainder.toString(),
    pathElements: path.pathElements.map(String),
    pathIndices: path.pathIndices.map(String),
    ...overrides,
  };
}

/** Rebuild `newCommitment` for a claimed payout, so inflation attacks are self-consistent. */
function withClaimedPayout(inp, claimedPayout) {
  const out = { ...inp };
  out.newCommitment = rawNote({
    nullifier: BigInt(inp.newNullifier),
    secret: BigInt(inp.newSecret),
    marketId: BigInt(inp.marketId),
    outcome: SETTLED,
    units: claimedPayout,
  }).toString();
  return out;
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
const mustAccept = async (name, inp) => {
  const ok = await satisfies(inp);
  console.log(`  ${ok ? "ok  " : "FAIL"}  ACCEPTS  ${name}`);
  ok ? pass++ : fail++;
};
const mustReject = async (name, inp) => {
  const ok = await satisfies(inp);
  console.log(`  ${!ok ? "ok  " : "FAIL"}  rejects  ${name}`);
  !ok ? pass++ : fail++;
};

// ---------------------------------------------------------------------------
console.log("\n=== baseline: honest redemptions must be accepted ===");
// Without these the rejections below prove nothing -- a circuit rejecting everything would
// score perfectly.
await mustAccept("winning YES, exact division (100*400/250 = 160)", baseline());
await mustAccept("winning NO", baseline({ outcome: OUTCOME_NO, totalPool: 400n, winningPool: 150n }));
await mustAccept(
  "winning YES with a REMAINDER (100*400/300 = 133 rem 100)",
  baseline({ totalPool: 400n, winningPool: 300n }),
);
await mustAccept("unbet refund 1:1", baseline({ outcome: OUTCOME_UNBET }));
await mustAccept(
  "unbet refund when NOBODY backed the winning side (winningPool = 0)",
  baseline({ outcome: OUTCOME_UNBET, totalPool: 0n, winningPool: 0n }),
);
await mustAccept("sole winner takes the whole pool (units == winningPool)", baseline({ units: 250n, totalPool: 400n, winningPool: 250n }));
await mustAccept("units = 1", baseline({ units: 1n, totalPool: 400n, winningPool: 250n }));
await mustAccept("marketId = 2^32 - 1", baseline({ marketId: 2n ** 32n - 1n }));

// ---------------------------------------------------------------------------
console.log("\n=== THE UNBOUNDED MINT: a settled payout note must not be redeemable ===");
{
  // Redeem a note that is ALREADY tagged SETTLED. If accepted, the loop is open: each
  // redemption produces another redeemable note, forever, and every step looks legitimate.
  const inp = baseline({ outcome: SETTLED, units: 160n, totalPool: 400n, winningPool: 250n });
  await mustReject("redeeming an outcome=3 SETTLED note", inp);
}
{
  // Same, via the refund path -- the variant that would look most innocent, since a refund
  // does not touch the pool totals at all.
  const inp = baseline({ outcome: SETTLED, units: 160n, totalPool: 0n, winningPool: 0n });
  await mustReject("redeeming a SETTLED note as an unbet refund", inp);
}
{
  // The payout note must be tagged SETTLED, not something re-redeemable. Claim outcome 0.
  const inp = baseline();
  inp.newCommitment = rawNote({
    nullifier: BigInt(inp.newNullifier),
    secret: BigInt(inp.newSecret),
    marketId: MARKET_ID,
    outcome: OUTCOME_UNBET,
    units: 160n,
  }).toString();
  await mustReject("payout note tagged outcome=0 instead of SETTLED", inp);
}
{
  const inp = baseline();
  inp.newCommitment = rawNote({
    nullifier: BigInt(inp.newNullifier),
    secret: BigInt(inp.newSecret),
    marketId: MARKET_ID,
    outcome: OUTCOME_YES,
    units: 160n,
  }).toString();
  await mustReject("payout note tagged outcome=1 instead of SETTLED", inp);
}

// ---------------------------------------------------------------------------
console.log("\n=== PAYOUT INFLATION: the contract cannot see units OR the payout ===");
{
  // Claim a bigger payout than the division allows.
  const inp = baseline();
  const bad = withClaimedPayout(inp, 1_000_000n);
  bad.payout = "1000000";
  await mustReject("inflated payout with a matching note", bad);
}
{
  // Keep the honest quotient in the witness but commit a bigger number to the note. This is
  // the attack that would succeed if `payoutUnits` were not the value fed into the note.
  const inp = baseline();
  await mustReject("honest quotient, inflated note", withClaimedPayout(inp, 1_000_000n));
}
{
  // Lie about the remainder to shift the quotient upward.
  const inp = baseline({ totalPool: 400n, winningPool: 300n });
  const q = 133n;
  const bad = withClaimedPayout({ ...inp, payout: (q + 1n).toString() }, q + 1n);
  bad.payout = (q + 1n).toString();
  bad.remainder = "0";
  await mustReject("quotient bumped by one, remainder forced to 0", bad);
}
{
  // remainder >= winningPool is exactly how you steal a whole extra unit of payout.
  const inp = baseline({ totalPool: 400n, winningPool: 300n });
  const bad = { ...inp, payout: "133", remainder: "300" };
  await mustReject("remainder == winningPool (must be strictly less)", bad);
}
{
  const inp = baseline({ totalPool: 400n, winningPool: 300n });
  const bad = { ...inp, remainder: "99999" };
  await mustReject("remainder wildly out of range", bad);
}
{
  // Claim the pool is bigger than it is, which inflates every payout pro rata.
  const inp = baseline();
  const bad = { ...inp, totalPool: "999999" };
  await mustReject("totalPool in the witness disagrees with redeemMeta", bad);
}
{
  // Claim a smaller winning pool, so your share of it is larger.
  const inp = baseline();
  const bad = { ...inp, winningPool: "1" };
  await mustReject("winningPool in the witness disagrees with redeemMeta", bad);
}
{
  // Claim more units than the note holds.
  const inp = baseline();
  const bad = { ...inp, units: "100000" };
  await mustReject("units in the witness disagrees with the note", bad);
}
{
  // A refund must pay exactly `units`, not more.
  const inp = baseline({ outcome: OUTCOME_UNBET, units: 100n, totalPool: 0n, winningPool: 0n });
  await mustReject("unbet refund inflated above units", withClaimedPayout(inp, 101n));
}
{
  // Division by zero on the PRO-RATA path must be refused, not silently allowed.
  const inp = baseline({ outcome: OUTCOME_YES, units: 100n, totalPool: 400n, winningPool: 0n });
  await mustReject("won position claimed against winningPool = 0", inp);
}
{
  // A zero payout mints an unspendable note that still consumes a leaf.
  const inp = baseline({ units: 1n, totalPool: 0n, winningPool: 250n });
  await mustReject("zero payout", withClaimedPayout({ ...inp, payout: "0" }, 0n));
}

// ---------------------------------------------------------------------------
console.log("\n=== packing and range bounds ===");
await mustReject("marketId = 2^32 (one past range)", baseline({ marketId: 2n ** 32n }));
await mustReject("totalPool = 2^64", baseline({ totalPool: 2n ** 64n, winningPool: 250n }));
await mustReject("winningPool = 2^64", baseline({ totalPool: 2n ** 64n + 1n, winningPool: 2n ** 64n }));
{
  const inp = baseline();
  const bad = { ...inp, redeemMeta: (BigInt(inp.redeemMeta) + 1n).toString() };
  await mustReject("redeemMeta off by one", bad);
}
{
  // Same fields, different market -- redeeming against another market's pool.
  const inp = baseline();
  const bad = { ...inp, redeemMeta: packMeta(8n, OUTCOME_YES, 400n, 250n).toString() };
  await mustReject("redeemMeta claims a different market than the note", bad);
}

// ---------------------------------------------------------------------------
console.log("\n=== identity and note binding ===");
{
  const inp = baseline();
  await mustReject("nullifierHash does not match the nullifier", { ...inp, nullifierHash: randomField().toString() });
}
{
  const inp = baseline();
  await mustReject("root not the one the path proves", { ...inp, root: randomField().toString() });
}
{
  const inp = baseline();
  const bad = { ...inp, pathElements: [...inp.pathElements] };
  bad.pathElements[0] = randomField().toString();
  await mustReject("tampered Merkle path element", bad);
}
{
  const inp = baseline();
  const bad = { ...inp, pathIndices: [...inp.pathIndices] };
  bad.pathIndices[0] = "2";
  await mustReject("non-boolean path index", bad);
}
{
  const inp = baseline();
  await mustReject("spending a note not in the tree", { ...inp, secret: randomField().toString() });
}
{
  // Reusing the spent note's secrets for the payout note. Here it cannot produce an
  // identical leaf (outcome and units differ), but the guard must hold regardless -- and it
  // is what stops a duplicate leaf when they would otherwise coincide.
  const inp = baseline({ outcome: OUTCOME_UNBET, units: 100n, totalPool: 0n, winningPool: 0n });
  const bad = { ...inp, newNullifier: inp.nullifier, newSecret: inp.secret };
  bad.newCommitment = rawNote({
    nullifier: BigInt(inp.nullifier),
    secret: BigInt(inp.secret),
    marketId: MARKET_ID,
    outcome: OUTCOME_UNBET,
    units: 100n,
  }).toString();
  await mustReject("payout note identical to the spent note", bad);
}

console.log(
  `\n${fail === 0 ? "ALL SOUNDNESS CHECKS PASSED" : `${fail} SOUNDNESS CHECK(S) FAILED`}  (${pass} passed, ${fail} failed)`,
);
process.exit(fail === 0 ? 0 : 1);
