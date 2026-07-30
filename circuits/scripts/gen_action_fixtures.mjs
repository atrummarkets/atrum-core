/**
 * Generate real Groth16 proofs for the Phase 1 action circuits, and write them where
 * the Foundry suite can replay them.
 *
 * The whole lifecycle is exercised here -- deposit, bet, redeem -- against a JS mirror
 * of the tree, so the contracts are tested with proofs that a real client would
 * produce rather than with mocked verifiers. A mocked verifier tests the plumbing and
 * nothing else; the failure modes that matter (a public-signal ordering mismatch, a
 * packing layout that disagrees between circom and Solidity, an in-circuit hash that
 * differs from the on-chain one) all live exactly where a mock would paper over them.
 *
 * Every proof is checked three ways before being written:
 *   1. snarkjs verifies it against the verification key.
 *   2. The commitment and root the circuit used are recomputed independently in JS.
 *   3. The public signals are asserted to be in the order the Solidity unpacking
 *      assumes -- `snarkjs verify` passing says nothing about ORDER, and a swapped
 *      pair would verify here and revert on-chain.
 *
 * Usage: node scripts/gen_action_fixtures.mjs
 */
import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import * as snarkjs from "snarkjs";
import {
  init,
  MerkleTree,
  DEPTH,
  OUTCOME_UNBET,
  OUTCOME_YES,
  OUTCOME_NO,
  noteCommitment,
  nullifierHash,
  packBetData,
  packPayoutData,
  packMarketMeta,
  FIELD_SIZE,
} from "./atrum.mjs";

const BUILD = new URL("../build/", import.meta.url);
const OUT = new URL("../build/action-fixtures.json", import.meta.url);

const BATCH_SIZE = 64;
const MARKET_ID = 7n;
const UNITS = 100n;

/** Uniform field element. */
function randomField() {
  return BigInt("0x" + randomBytes(31).toString("hex")) % FIELD_SIZE;
}

function assert(condition, message) {
  if (!condition) throw new Error(`ASSERTION FAILED: ${message}`);
}

async function prove(circuit, input, { emitCalldata = true } = {}) {
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    new URL(`${circuit}_js/${circuit}.wasm`, BUILD).pathname,
    new URL(`${circuit}.zkey`, BUILD).pathname,
  );

  const vkey = JSON.parse(
    readFileSync(new URL(`${circuit}_vkey.json`, BUILD), "utf8"),
  );
  const ok = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  assert(ok, `${circuit}: snarkjs rejected its own proof`);

  // snarkjs SWAPS each G2 coordinate pair when emitting calldata, because the
  // generated verifier expects the opposite Fp2 limb order from the proof file. Using
  // the raw proof order produces a well-formed but invalid proof that reverts on-chain
  // -- easy to misdiagnose as a gas problem. Take snarkjs's own encoding.
  const raw = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  const [pA, pB, pC, signals] = JSON.parse(`[${raw}]`);

  // Also emit the calldata in the shape `tools/measure_verifier.py` reads, so the
  // Phase 0 gate and the anti-fingerprinting guard cover the Phase 1 action verifiers
  // without a second encoder. Two encoders would eventually disagree about the G2 limb
  // order, and that failure looks like a gas problem rather than an encoding one.
  if (emitCalldata) {
    writeFileSync(new URL(`${circuit}_calldata.json`, BUILD).pathname, raw);
  }

  return { pA, pB, pC, publicSignals: signals };
}

async function main() {
  await init();
  mkdirSync(new URL(".", OUT).pathname, { recursive: true });

  const tree = new MerkleTree(DEPTH);
  const fixtures = { batchSize: BATCH_SIZE, depth: DEPTH, marketId: MARKET_ID.toString() };

  // -------------------------------------------------------------------------
  // 1. DEPOSIT
  // -------------------------------------------------------------------------
  const depositNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: MARKET_ID,
    outcome: OUTCOME_UNBET,
    units: UNITS,
  };
  const depositCommitment = noteCommitment(depositNote);

  const depositProof = await prove("deposit", {
    commitment: depositCommitment,
    marketId: MARKET_ID,
    units: UNITS,
    nullifier: depositNote.nullifier,
    secret: depositNote.secret,
  });

  assert(
    BigInt(depositProof.publicSignals[0]) === depositCommitment,
    "deposit signal[0] is not the commitment -- public signal ORDER differs from " +
      "what ShieldedPool.deposit assumes",
  );
  assert(BigInt(depositProof.publicSignals[1]) === MARKET_ID, "deposit signal[1] != marketId");
  assert(BigInt(depositProof.publicSignals[2]) === UNITS, "deposit signal[2] != units");

  fixtures.deposit = {
    ...depositProof,
    commitment: depositCommitment.toString(),
    units: UNITS.toString(),
  };

  // -------------------------------------------------------------------------
  // 2. Sequencer grafts batch 1: the real deposit plus 63 fillers.
  // -------------------------------------------------------------------------
  const batch1 = [depositCommitment];
  while (batch1.length < BATCH_SIZE) batch1.push(randomField());
  for (const leaf of batch1) tree.insert(leaf);

  const rootAfterBatch1 = tree.root();
  const depositPath = tree.path(0);

  fixtures.batch1 = batch1.map((x) => x.toString());
  fixtures.rootAfterBatch1 = rootAfterBatch1.toString();

  // -------------------------------------------------------------------------
  // 3. BET -- spend the deposit note, commit the stake to YES
  // -------------------------------------------------------------------------
  const positionNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: MARKET_ID,
    outcome: OUTCOME_YES,
    units: UNITS,
  };
  const positionCommitment = noteCommitment(positionNote);
  const betNullifierHash = nullifierHash(depositNote.nullifier);
  const betData = packBetData(MARKET_ID, OUTCOME_YES, UNITS);

  const betProof = await prove("bet", {
    root: rootAfterBatch1,
    nullifierHash: betNullifierHash,
    newCommitment: positionCommitment,
    betData,
    nullifier: depositNote.nullifier,
    secret: depositNote.secret,
    newNullifier: positionNote.nullifier,
    newSecret: positionNote.secret,
    marketId: MARKET_ID,
    outcome: OUTCOME_YES,
    units: UNITS,
    pathElements: depositPath.pathElements,
    pathIndices: depositPath.pathIndices,
  });

  assert(BigInt(betProof.publicSignals[0]) === rootAfterBatch1, "bet signal[0] != root");
  assert(
    BigInt(betProof.publicSignals[1]) === betNullifierHash,
    "bet signal[1] != nullifierHash",
  );
  assert(
    BigInt(betProof.publicSignals[2]) === positionCommitment,
    "bet signal[2] != newCommitment",
  );
  assert(BigInt(betProof.publicSignals[3]) === betData, "bet signal[3] != betData");

  fixtures.bet = {
    ...betProof,
    root: rootAfterBatch1.toString(),
    nullifierHash: betNullifierHash.toString(),
    newCommitment: positionCommitment.toString(),
    betData: betData.toString(),
  };

  // -------------------------------------------------------------------------
  // 4. Sequencer grafts batch 2, carrying the position note.
  // -------------------------------------------------------------------------
  const batch2 = [positionCommitment];
  while (batch2.length < BATCH_SIZE) batch2.push(randomField());
  for (const leaf of batch2) tree.insert(leaf);

  const rootAfterBatch2 = tree.root();
  const positionPath = tree.path(BATCH_SIZE);

  fixtures.batch2 = batch2.map((x) => x.toString());
  fixtures.rootAfterBatch2 = rootAfterBatch2.toString();

  // -------------------------------------------------------------------------
  // 5. REDEEM -- claim the winning position
  // -------------------------------------------------------------------------
  // Anvil's default account 0. The recipient is bound into the proof through
  // payoutData, so a mempool watcher cannot swap it.
  const recipient = 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266n;
  const payoutData = packPayoutData(recipient, UNITS);
  const marketMeta = packMarketMeta(MARKET_ID, OUTCOME_YES);
  const redeemNullifierHash = nullifierHash(positionNote.nullifier);

  const redeemProof = await prove("redeem", {
    root: rootAfterBatch2,
    nullifierHash: redeemNullifierHash,
    payoutData,
    marketMeta,
    nullifier: positionNote.nullifier,
    secret: positionNote.secret,
    marketId: MARKET_ID,
    outcome: OUTCOME_YES,
    units: UNITS,
    recipient,
    pathElements: positionPath.pathElements,
    pathIndices: positionPath.pathIndices,
  });

  assert(BigInt(redeemProof.publicSignals[0]) === rootAfterBatch2, "redeem signal[0] != root");
  assert(
    BigInt(redeemProof.publicSignals[1]) === redeemNullifierHash,
    "redeem signal[1] != nullifierHash",
  );
  assert(
    BigInt(redeemProof.publicSignals[2]) === payoutData,
    "redeem signal[2] != payoutData",
  );
  assert(
    BigInt(redeemProof.publicSignals[3]) === marketMeta,
    "redeem signal[3] != marketMeta",
  );

  fixtures.redeem = {
    ...redeemProof,
    root: rootAfterBatch2.toString(),
    nullifierHash: redeemNullifierHash.toString(),
    payoutData: payoutData.toString(),
    marketMeta: marketMeta.toString(),
    recipient: "0x" + recipient.toString(16).padStart(40, "0"),
  };

  // -------------------------------------------------------------------------
  // 6. Negative fixture: a bet proof for a note that was never deposited.
  //    The contract must reject it, and the only thing standing in the way is the
  //    Merkle constraint -- worth having a real counterexample rather than trusting it.
  // -------------------------------------------------------------------------
  const forgedNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: MARKET_ID,
    outcome: OUTCOME_UNBET,
    units: UNITS,
  };
  const forgedTree = new MerkleTree(DEPTH);
  forgedTree.insert(noteCommitment(forgedNote));
  const forgedPath = forgedTree.path(0);

  const forgedPosition = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: MARKET_ID,
    outcome: OUTCOME_NO,
    units: UNITS,
  };
  const forgedNewCommitment = noteCommitment(forgedPosition);
  const forgedNullifierHash = nullifierHash(forgedNote.nullifier);
  const forgedBetData = packBetData(MARKET_ID, OUTCOME_NO, UNITS);

  // Do not overwrite bet_calldata.json -- the gate must measure the real bet proof.
  const forgedProof = await prove("bet", {
    root: forgedTree.root(),
    nullifierHash: forgedNullifierHash,
    newCommitment: forgedNewCommitment,
    betData: forgedBetData,
    nullifier: forgedNote.nullifier,
    secret: forgedNote.secret,
    newNullifier: forgedPosition.nullifier,
    newSecret: forgedPosition.secret,
    marketId: MARKET_ID,
    outcome: OUTCOME_NO,
    units: UNITS,
    pathElements: forgedPath.pathElements,
    pathIndices: forgedPath.pathIndices,
  }, { emitCalldata: false });

  // Internally valid -- it proves membership in a tree the CONTRACT has never seen.
  // This is the fixture that shows `isKnownRoot` is load-bearing: without it, anyone
  // could invent a tree containing a note they never paid for and spend it.
  fixtures.betAgainstUnknownRoot = {
    ...forgedProof,
    root: forgedTree.root().toString(),
    nullifierHash: forgedNullifierHash.toString(),
    newCommitment: forgedNewCommitment.toString(),
    betData: forgedBetData.toString(),
  };

  writeFileSync(OUT.pathname, JSON.stringify(fixtures, null, 2));

  console.log("wrote", OUT.pathname);
  console.log("  deposit commitment :", depositCommitment);
  console.log("  root after batch 1 :", rootAfterBatch1);
  console.log("  root after batch 2 :", rootAfterBatch2);
  console.log("\nall proofs verified, all public signal orderings checked");
}

main().then(() => process.exit(0));
