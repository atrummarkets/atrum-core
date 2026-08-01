/**
 * SOUNDNESS SUITE for withdraw.circom.
 *
 * Every case is an attack; the pass condition is REJECTION. Witness calculation decides
 * constraint satisfaction, so no trusted setup is needed.
 *
 * This is the ONLY circuit where real collateral leaves the system, so two families matter:
 *
 *   1. CONSERVATION. `amount + change == units`. Break it and the holder withdraws the full
 *      note while keeping a full-value change note -- collateral minted from nothing. The
 *      contract cannot check it: `units` and `change` are both private.
 *
 *   2. THE OUTCOME PIN. Only a SETTLED (outcome 3) note may be withdrawn. If an unbet note
 *      (outcome 0) or a live position (1 or 2) were withdrawable, a holder would skip
 *      `redeemPrivate` entirely -- taking collateral out without the payout arithmetic ever
 *      running, and while their position still counted toward the pool.
 *
 * Usage: node scripts/soundness_withdraw.mjs
 */
import { randomBytes } from "node:crypto";
import * as snarkjs from "snarkjs";
import { init, hash2, MerkleTree, DEPTH, nullifierHash, FIELD_SIZE } from "./atrum.mjs";

const BUILD = new URL("../build/", import.meta.url);
const WASM = new URL("withdraw_js/withdraw.wasm", BUILD).pathname;

const SETTLED = 3n;
const MARKET_ID = 8n;
const RECIPIENT = 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266n;

await init();

const randomField = () => BigInt("0x" + randomBytes(31).toString("hex")) % FIELD_SIZE;

/** Commitment without the JS mirror's range guard, so out-of-range attacks reach the circuit. */
function rawNote({ nullifier, secret, marketId, outcome, units }) {
  const packed = outcome * (1n << 64n) + units;
  return hash2(hash2(nullifier, secret), hash2(marketId, packed));
}

const packWithdraw = (marketId, recipient, amount) =>
  marketId * (1n << 200n) + recipient * (1n << 40n) + amount;

function baseline({
  outcome = SETTLED,
  units = 137n,
  amount = 100n,
  change = null,
  marketId = MARKET_ID,
  recipient = RECIPIENT,
} = {}) {
  const c = change === null ? units - amount : change;

  const nullifier = randomField();
  const secret = randomField();
  const newNullifier = randomField();
  const newSecret = randomField();

  const oldCommitment = rawNote({ nullifier, secret, marketId, outcome, units });

  const tree = new MerkleTree(DEPTH);
  tree.insert(oldCommitment);
  for (let i = 0; i < 7; i++) tree.insert(randomField());
  const path = tree.path(0);

  const changeCommitment = rawNote({
    nullifier: newNullifier,
    secret: newSecret,
    marketId,
    outcome: SETTLED,
    units: c,
  });

  return {
    root: tree.root().toString(),
    nullifierHash: nullifierHash(nullifier).toString(),
    changeCommitment: changeCommitment.toString(),
    withdrawData: packWithdraw(marketId, recipient, amount).toString(),

    nullifier: nullifier.toString(),
    secret: secret.toString(),
    newNullifier: newNullifier.toString(),
    newSecret: newSecret.toString(),
    marketId: marketId.toString(),
    units: units.toString(),
    recipient: recipient.toString(),
    amount: amount.toString(),
    change: c.toString(),
    pathElements: path.pathElements.map(String),
    pathIndices: path.pathIndices.map(String),
  };
}

/** Rebuild the change commitment for a claimed change value, so attacks are self-consistent. */
function withChange(inp, claimedChange) {
  return {
    ...inp,
    change: claimedChange.toString(),
    changeCommitment: rawNote({
      nullifier: BigInt(inp.newNullifier),
      secret: BigInt(inp.newSecret),
      marketId: BigInt(inp.marketId),
      outcome: SETTLED,
      units: claimedChange,
    }).toString(),
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
const mustAccept = async (n, i) => {
  const ok = await satisfies(i);
  console.log(`  ${ok ? "ok  " : "FAIL"}  ACCEPTS  ${n}`);
  ok ? pass++ : fail++;
};
const mustReject = async (n, i) => {
  const ok = await satisfies(i);
  console.log(`  ${!ok ? "ok  " : "FAIL"}  rejects  ${n}`);
  !ok ? pass++ : fail++;
};

// ---------------------------------------------------------------------------
console.log("\n=== baseline: honest withdrawals must be accepted ===");
await mustAccept("partial withdrawal (137 note, take 100, change 37)", baseline());
await mustAccept("full withdrawal (change 0)", baseline({ units: 137n, amount: 137n }));
await mustAccept("withdraw 1 unit", baseline({ units: 137n, amount: 1n }));
await mustAccept(
  "fixed-denomination withdrawal, the privacy-preserving shape",
  baseline({ units: 1000n, amount: 100n }),
);
await mustAccept("note of 1, take 1", baseline({ units: 1n, amount: 1n }));
await mustAccept("top of range", baseline({ units: 2n ** 40n - 1n, amount: 2n ** 40n - 1n }));
await mustAccept("marketId = 0", baseline({ marketId: 0n }));
await mustAccept("marketId = 2^32 - 1", baseline({ marketId: 2n ** 32n - 1n }));

// ---------------------------------------------------------------------------
console.log("\n=== CONSERVATION: amount + change == units (contract sees neither) ===");
{
  // Take the whole note AND keep it as change. Collateral minted from nothing.
  const inp = baseline({ units: 137n, amount: 137n });
  await mustReject("withdraw 137 and keep 137 change", withChange(inp, 137n));
}
{
  const inp = baseline({ units: 137n, amount: 100n });
  await mustReject("change inflated (37 -> 100)", withChange(inp, 100n));
}
{
  const inp = baseline({ units: 137n, amount: 100n });
  await mustReject("change deflated (37 -> 0), amount unchanged", withChange(inp, 0n));
}
{
  // Withdraw more than the note is worth.
  const inp = baseline({ units: 100n, amount: 1000n, change: 0n });
  await mustReject("amount exceeds the note value", inp);
}
{
  // The classic field-wraparound attack on a sum: pick amount huge and change as its
  // complement so `amount + change == units` holds mod p. The range checks are what stop it.
  const inp = baseline({ units: 137n, amount: 100n });
  const huge = 2n ** 200n;
  const bad = withChange({ ...inp, amount: huge.toString() }, 137n - huge + FIELD_SIZE);
  bad.withdrawData = packWithdraw(MARKET_ID, RECIPIENT, huge).toString();
  await mustReject("amount 2^200 with a complementary negative change", bad);
}
{
  const inp = baseline({ units: 137n, amount: 100n });
  await mustReject("amount = 2^40 (one past range)", {
    ...inp,
    amount: (2n ** 40n).toString(),
    change: (137n - 2n ** 40n + FIELD_SIZE).toString(),
    withdrawData: packWithdraw(MARKET_ID, RECIPIENT, 2n ** 40n).toString(),
  });
}
await mustReject("zero withdrawal", baseline({ units: 137n, amount: 0n }));

// ---------------------------------------------------------------------------
console.log("\n=== THE OUTCOME PIN: only a SETTLED note may be withdrawn ===");
{
  // An unbet note. If withdrawable, a depositor takes collateral straight back out without
  // ever redeeming -- which is fine in isolation, but it also means a POSITION could be
  // withdrawn while still counted in the pool.
  const inp = baseline({ outcome: 0n, units: 137n, amount: 100n });
  await mustReject("withdrawing an unbet note (outcome 0)", inp);
}
{
  // A live YES position: withdraw the stake while the bet still counts toward the pool.
  const inp = baseline({ outcome: 1n, units: 100n, amount: 100n });
  await mustReject("withdrawing a live YES position (outcome 1)", inp);
}
{
  const inp = baseline({ outcome: 2n, units: 100n, amount: 100n });
  await mustReject("withdrawing a live NO position (outcome 2)", inp);
}
{
  // The change note must stay SETTLED. Tagged 0 it becomes redeemable as an unbet refund --
  // reopening exactly the mint loop `redeem_private` was written to close.
  const inp = baseline({ units: 137n, amount: 100n });
  const bad = {
    ...inp,
    changeCommitment: rawNote({
      nullifier: BigInt(inp.newNullifier),
      secret: BigInt(inp.newSecret),
      marketId: MARKET_ID,
      outcome: 0n,
      units: 37n,
    }).toString(),
  };
  await mustReject("change note tagged outcome=0 instead of SETTLED", bad);
}
{
  const inp = baseline({ units: 137n, amount: 100n });
  const bad = {
    ...inp,
    changeCommitment: rawNote({
      nullifier: BigInt(inp.newNullifier),
      secret: BigInt(inp.newSecret),
      marketId: MARKET_ID,
      outcome: 1n,
      units: 37n,
    }).toString(),
  };
  await mustReject("change note tagged outcome=1 (a live position)", bad);
}

// ---------------------------------------------------------------------------
console.log("\n=== recipient binding and packing ===");
{
  // The mempool-theft attack: lift a valid proof, swap the destination.
  const inp = baseline();
  const thief = 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefn;
  await mustReject("recipient swapped in withdrawData", {
    ...inp,
    withdrawData: packWithdraw(MARKET_ID, thief, 100n).toString(),
  });
}
{
  const inp = baseline();
  await mustReject("recipient swapped in the witness only", { ...inp, recipient: "1" });
}
await mustReject("recipient = 2^160 (one past range)", baseline({ recipient: 2n ** 160n }));
await mustReject("marketId = 2^32 (one past range)", baseline({ marketId: 2n ** 32n }));
{
  const inp = baseline();
  await mustReject("withdrawData off by one", {
    ...inp,
    withdrawData: (BigInt(inp.withdrawData) + 1n).toString(),
  });
}
{
  // Claim a different market, so collateral comes out of the wrong vault.
  const inp = baseline();
  await mustReject("withdrawData claims a different market than the note", {
    ...inp,
    withdrawData: packWithdraw(9n, RECIPIENT, 100n).toString(),
  });
}

// ---------------------------------------------------------------------------
console.log("\n=== identity and note binding ===");
{
  const inp = baseline();
  await mustReject("nullifierHash does not match", { ...inp, nullifierHash: randomField().toString() });
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
  // Reuse the spent note's secrets with a zero withdrawal, which would make the change note
  // byte-identical to the note being spent -- a duplicate leaf.
  const nullifier = randomField();
  const secret = randomField();
  const units = 137n;
  const oldC = rawNote({ nullifier, secret, marketId: MARKET_ID, outcome: SETTLED, units });

  const tree = new MerkleTree(DEPTH);
  tree.insert(oldC);
  for (let i = 0; i < 7; i++) tree.insert(randomField());
  const path = tree.path(0);

  await mustReject("change note identical to the spent note", {
    root: tree.root().toString(),
    nullifierHash: nullifierHash(nullifier).toString(),
    changeCommitment: oldC.toString(),
    withdrawData: packWithdraw(MARKET_ID, RECIPIENT, 0n).toString(),
    nullifier: nullifier.toString(),
    secret: secret.toString(),
    newNullifier: nullifier.toString(),
    newSecret: secret.toString(),
    marketId: MARKET_ID.toString(),
    units: units.toString(),
    recipient: RECIPIENT.toString(),
    amount: "0",
    change: units.toString(),
    pathElements: path.pathElements.map(String),
    pathIndices: path.pathIndices.map(String),
  });
}

console.log(
  `\n${fail === 0 ? "ALL SOUNDNESS CHECKS PASSED" : `${fail} SOUNDNESS CHECK(S) FAILED`}  (${pass} passed, ${fail} failed)`,
);
process.exit(fail === 0 ? 0 : 1);
