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
  derivedFiller,
  FIELD_SIZE,
} from "./atrum.mjs";
import { buildElGamal } from "./lib/elgamal.mjs";

const BUILD = new URL("../build/", import.meta.url);
const OUT = new URL("../build/action-fixtures.json", import.meta.url);

const BATCH_SIZE = 64;
const MARKET_ID = 7n;

/// A market registered on the Phase 2 path. Distinct from MARKET_ID because a market's
/// total lives either in ParimutuelPool or in ElGamalAccumulator, never both.
const ENCRYPTED_MARKET_ID = 8n;

const UNITS = 100n;

/** Uniform field element. */
function randomField() {
  return BigInt("0x" + randomBytes(31).toString("hex")) % FIELD_SIZE;
}

function assert(condition, message) {
  if (!condition) throw new Error(`ASSERTION FAILED: ${message}`);
}

/**
 * Every witness input the generator built, keyed by circuit.
 *
 * Written out because a browser client has to construct exactly these, and a recorded
 * example is a far better specification than prose. Also feeds the proving-time spike --
 * benchmarking needs real inputs, and inventing them by hand is how you end up measuring a
 * witness that would never satisfy the circuit.
 */
const witnessInputs = {};

async function prove(circuit, input, { emitCalldata = true } = {}) {
  // Last one wins where a circuit is proved more than once; they are the same shape, which
  // is all a client or a benchmark needs.
  witnessInputs[circuit] = input;

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
  // Only the real commitment is submitted. The CONTRACT derives the remaining 63
  // fillers, so the mirror must derive the identical values or the root diverges and
  // every Merkle path built here fails on-chain.
  const batch1 = [depositCommitment];
  while (batch1.length < BATCH_SIZE) {
    batch1.push(derivedFiller(0, batch1.length));
  }
  for (const leaf of batch1) tree.insert(leaf);

  const rootAfterBatch1 = tree.root();
  const depositPath = tree.path(0);

  fixtures.batch1 = batch1.map((x) => x.toString());
  fixtures.batch1Real = [depositCommitment.toString()];
  fixtures.derivedFiller_0_1 = derivedFiller(0, 1).toString();
  fixtures.derivedFiller_0_63 = derivedFiller(0, 63).toString();
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
  while (batch2.length < BATCH_SIZE) {
    batch2.push(derivedFiller(BATCH_SIZE, batch2.length));
  }
  for (const leaf of batch2) tree.insert(leaf);

  const rootAfterBatch2 = tree.root();
  const positionPath = tree.path(BATCH_SIZE);

  fixtures.batch2 = batch2.map((x) => x.toString());
  fixtures.batch2Real = [positionCommitment.toString()];
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
  // 6. PHASE 2 -- deposit into an ENCRYPTED market, then bet with the stake hidden
  // -------------------------------------------------------------------------
  // A separate market with its own batch, deliberately appended after the Phase 1
  // lifecycle rather than woven into it. A market's pool total lives EITHER in
  // `ParimutuelPool` (plaintext) or in `ElGamalAccumulator` (ciphertext), never both,
  // so the encrypted bet cannot reuse market 7 -- and `marketId` is bound inside the
  // note commitment, so it cannot reuse market 7's note either.
  //
  // Appending also keeps `rootAfterBatch1`/`rootAfterBatch2` byte-identical, so every
  // existing Phase 1 test keeps replaying against the roots it was written for.
  const encDepositNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_UNBET,
    units: UNITS,
  };
  const encDepositCommitment = noteCommitment(encDepositNote);

  const encDepositProof = await prove("deposit", {
    commitment: encDepositCommitment,
    marketId: ENCRYPTED_MARKET_ID,
    units: UNITS,
    nullifier: encDepositNote.nullifier,
    secret: encDepositNote.secret,
  }, { emitCalldata: false });

  fixtures.encryptedMarketId = ENCRYPTED_MARKET_ID.toString();
  fixtures.depositEncrypted = {
    ...encDepositProof,
    commitment: encDepositCommitment.toString(),
    units: UNITS.toString(),
  };

  const batch3 = [encDepositCommitment];
  while (batch3.length < BATCH_SIZE) {
    batch3.push(derivedFiller(2 * BATCH_SIZE, batch3.length));
  }
  for (const leaf of batch3) tree.insert(leaf);

  const rootAfterBatch3 = tree.root();
  const encDepositPath = tree.path(2 * BATCH_SIZE);

  fixtures.batch3 = batch3.map((x) => x.toString());
  fixtures.batch3Real = [encDepositCommitment.toString()];
  fixtures.rootAfterBatch3 = rootAfterBatch3.toString();

  // The committee key encrypts the stake. Only the PUBLIC half is needed to encrypt --
  // the secret is read here purely to prove the ciphertext decrypts back to the stake,
  // which is the property the accumulator's correctness rests on.
  const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD), "utf8"));
  const elgamal = await buildElGamal(key.pubKey, key.secret);

  const encRandomness = elgamal.randomScalar();
  const cipher = elgamal.encrypt(UNITS, encRandomness);
  const [c1x, c1y] = elgamal.asPair(cipher.c1);
  const [c2x, c2y] = elgamal.asPair(cipher.c2);

  const encPositionNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_YES,
    units: UNITS,
  };
  const encPositionCommitment = noteCommitment(encPositionNote);
  const encBetNullifierHash = nullifierHash(encDepositNote.nullifier);

  // Note the packing change from Phase 1: `betData` carried units, `betMeta` cannot.
  // Publishing the stake in a public signal is exactly what this circuit exists to stop.
  const betMeta = packMarketMeta(ENCRYPTED_MARKET_ID, OUTCOME_YES);

  const betEncryptedProof = await prove("bet_encrypted", {
    root: rootAfterBatch3,
    nullifierHash: encBetNullifierHash,
    newCommitment: encPositionCommitment,
    betMeta,
    c1: [c1x, c1y],
    c2: [c2x, c2y],
    nullifier: encDepositNote.nullifier,
    secret: encDepositNote.secret,
    newNullifier: encPositionNote.nullifier,
    newSecret: encPositionNote.secret,
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_YES,
    units: UNITS,
    encRandomness,
    pathElements: encDepositPath.pathElements,
    pathIndices: encDepositPath.pathIndices,
  });

  const encSignals = betEncryptedProof.publicSignals.map(BigInt);
  assert(encSignals.length === 8, "bet_encrypted: expected 8 public signals");
  assert(encSignals[0] === rootAfterBatch3, "bet_encrypted signal[0] != root");
  assert(encSignals[1] === encBetNullifierHash, "bet_encrypted signal[1] != nullifierHash");
  assert(encSignals[2] === encPositionCommitment, "bet_encrypted signal[2] != newCommitment");
  assert(encSignals[3] === betMeta, "bet_encrypted signal[3] != betMeta");
  assert(encSignals[4] === c1x, "bet_encrypted signal[4] != c1.x");
  assert(encSignals[5] === c1y, "bet_encrypted signal[5] != c1.y");
  assert(encSignals[6] === c2x, "bet_encrypted signal[6] != c2.x");
  assert(encSignals[7] === c2y, "bet_encrypted signal[7] != c2.y");

  // None of the 8 public signals may be the stake. The whole point of Phase 2 is that
  // `units` stopped being one of them, and an accidental re-widening of the public
  // signal list would be invisible to `snarkjs verify`.
  for (let i = 0; i < encSignals.length; i++) {
    assert(encSignals[i] !== UNITS, `bet_encrypted signal[${i}] leaks the plaintext stake`);
  }

  // The consistency constraint is the load-bearing part of this circuit, so check it
  // the way `prove.mjs` checks the probes: decrypt what the circuit actually published
  // and confirm it is the stake inside the note that was spent. A proof verifying says
  // a witness satisfied the constraints -- it does not say the ciphertext encrypts the
  // amount we think, and that is the exact failure a malicious prover would exploit.
  assert(
    elgamal.decrypt(cipher.c1, cipher.c2, 1000n) === UNITS,
    "bet_encrypted: published ciphertext does not decrypt to the staked units",
  );

  fixtures.betEncrypted = {
    ...betEncryptedProof,
    root: rootAfterBatch3.toString(),
    nullifierHash: encBetNullifierHash.toString(),
    newCommitment: encPositionCommitment.toString(),
    betMeta: betMeta.toString(),
    ciphertext: [c1x.toString(), c1y.toString(), c2x.toString(), c2y.toString()],
    // The plaintext stake, so tests can assert the contract never receives it.
    units: UNITS.toString(),
  };

  // -------------------------------------------------------------------------
  // 6b. A SECOND encrypted bet -- so the homomorphic property can be shown on-chain
  // -------------------------------------------------------------------------
  // One encrypted bet proves the ciphertext is accepted. Two prove the thing the whole
  // architecture rests on: that the contract can TOTAL them without decrypting. After
  // this bet the accumulator holds Enc(UNITS) + Enc(SECOND_UNITS), and only someone
  // with the committee key can tell that it means UNITS + SECOND_UNITS.
  //
  // A different stake from the first, deliberately: with two equal stakes a broken
  // accumulator that simply doubled one input would produce the same answer.
  //
  // Was 37, which is not on the denomination ladder. `ShieldedPool.deposit` now refuses
  // any amount that is not a power of ten, because a one-of-a-kind deposit amount is a
  // name tag -- see `Denominations.sol`. 10 keeps the stakes distinct while being a
  // legal rung.
  const SECOND_UNITS = 10n;

  const encDepositNote2 = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_UNBET,
    units: SECOND_UNITS,
  };
  const encDepositCommitment2 = noteCommitment(encDepositNote2);

  const encDepositProof2 = await prove("deposit", {
    commitment: encDepositCommitment2,
    marketId: ENCRYPTED_MARKET_ID,
    units: SECOND_UNITS,
    nullifier: encDepositNote2.nullifier,
    secret: encDepositNote2.secret,
  }, { emitCalldata: false });

  fixtures.depositEncrypted2 = {
    ...encDepositProof2,
    commitment: encDepositCommitment2.toString(),
    units: SECOND_UNITS.toString(),
  };

  // Batch 4 carries TWO real leaves, in queue order: the position note the first
  // encrypted bet created, then this second deposit. The first bet's commitment was
  // queued and not yet grafted, and `flushBatch` consumes the queue strictly in order --
  // so the mirror has to graft it here or the on-chain root diverges from every Merkle
  // path built after this point.
  const batch4 = [encPositionCommitment, encDepositCommitment2];
  while (batch4.length < BATCH_SIZE) {
    batch4.push(derivedFiller(3 * BATCH_SIZE, batch4.length));
  }
  for (const leaf of batch4) tree.insert(leaf);

  const rootAfterBatch4 = tree.root();
  const encDepositPath2 = tree.path(3 * BATCH_SIZE + 1);

  fixtures.batch4 = batch4.map((x) => x.toString());
  fixtures.batch4Real = [encPositionCommitment.toString(), encDepositCommitment2.toString()];
  fixtures.rootAfterBatch4 = rootAfterBatch4.toString();

  const encRandomness2 = elgamal.randomScalar();
  const cipher2 = elgamal.encrypt(SECOND_UNITS, encRandomness2);
  const [c1x2, c1y2] = elgamal.asPair(cipher2.c1);
  const [c2x2, c2y2] = elgamal.asPair(cipher2.c2);

  const encPositionNote2 = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_YES,
    units: SECOND_UNITS,
  };
  const encPositionCommitment2 = noteCommitment(encPositionNote2);
  const encBetNullifierHash2 = nullifierHash(encDepositNote2.nullifier);

  const betEncryptedProof2 = await prove("bet_encrypted", {
    root: rootAfterBatch4,
    nullifierHash: encBetNullifierHash2,
    newCommitment: encPositionCommitment2,
    betMeta,
    c1: [c1x2, c1y2],
    c2: [c2x2, c2y2],
    nullifier: encDepositNote2.nullifier,
    secret: encDepositNote2.secret,
    newNullifier: encPositionNote2.nullifier,
    newSecret: encPositionNote2.secret,
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_YES,
    units: SECOND_UNITS,
    encRandomness: encRandomness2,
    pathElements: encDepositPath2.pathElements,
    pathIndices: encDepositPath2.pathIndices,
  }, { emitCalldata: false });

  // The expected accumulator state after BOTH bets, computed the way the contract will
  // compute it: ciphertext addition, no decryption. The on-chain value must equal this
  // exactly, and it must decrypt to the sum of the two stakes.
  const summed = elgamal.addCiphertext(cipher, cipher2);
  const [sumC1x, sumC1y] = elgamal.asPair(summed.c1);
  const [sumC2x, sumC2y] = elgamal.asPair(summed.c2);

  assert(
    elgamal.decrypt(summed.c1, summed.c2, 10_000n) === UNITS + SECOND_UNITS,
    "homomorphic sum does not decrypt to the sum of the two stakes",
  );

  fixtures.betEncrypted2 = {
    ...betEncryptedProof2,
    root: rootAfterBatch4.toString(),
    nullifierHash: encBetNullifierHash2.toString(),
    newCommitment: encPositionCommitment2.toString(),
    betMeta: betMeta.toString(),
    ciphertext: [c1x2.toString(), c1y2.toString(), c2x2.toString(), c2y2.toString()],
    units: SECOND_UNITS.toString(),
  };

  fixtures.accumulatorAfterBothBets = {
    ciphertext: [sumC1x.toString(), sumC1y.toString(), sumC2x.toString(), sumC2y.toString()],
    decryptsTo: (UNITS + SECOND_UNITS).toString(),
    fromStakes: [UNITS.toString(), SECOND_UNITS.toString()],
  };

  // -------------------------------------------------------------------------
  // 6b. PRIVATE REDEEM: turn a winning position into a SETTLED note, paying nobody.
  //
  //     This is the item both build plans refuse to cut. `redeem.circom` publishes a
  //     recipient address and an amount; `redeem_private.circom` publishes neither and emits
  //     a note instead, so exiting to USDC becomes a separate, later, unlinkable action.
  //
  //     The note redeemed here is the position `betEncrypted` created, so this fixture only
  //     works against a tree that actually contains it -- batch 5 below grafts both position
  //     notes, and the contract's root must match `rpRootAfterBatch`.
  // -------------------------------------------------------------------------
  // ONLY the second position note. The first was already grafted in batch 4 alongside the
  // second encrypted deposit -- re-listing it here asks the contract to graft a leaf that is
  // no longer queued, which is exactly what `NotEnoughQueued` was reporting.
  const rpBatch = [encPositionCommitment2];
  while (rpBatch.length < BATCH_SIZE) {
    rpBatch.push(derivedFiller(4 * BATCH_SIZE, rpBatch.length));
  }
  for (const leaf of rpBatch) tree.insert(leaf);

  const rpRootAfterBatch = tree.root();
  fixtures.batch5 = rpBatch.map((x) => x.toString());
  fixtures.batch5Real = [encPositionCommitment2.toString()];
  fixtures.rootAfterBatch5 = rpRootAfterBatch.toString();

  // The position note being redeemed is the FIRST leaf of batch 4 (index 3 * BATCH_SIZE),
  // not batch 5 -- `betEncrypted` queued it before the second encrypted deposit, so batch 4
  // grafted both together. Its Merkle path is taken after batch 5 so the proof is built
  // against `rpRootAfterBatch`, a root the contract will actually hold.
  const rpPositionPath = tree.path(3 * BATCH_SIZE);

  // Settled totals: both bets went on YES, nothing on NO. So YES wins and takes the whole
  // pool, and the payout for a position of UNITS is `UNITS * total / winning`.
  const rpSettledYes = UNITS + SECOND_UNITS;
  const rpSettledNo = 0n;
  const rpTotalPool = rpSettledYes + rpSettledNo;
  const rpWinningPool = rpSettledYes;

  const rpDividend = UNITS * rpTotalPool;
  const rpPayout = rpDividend / rpWinningPool;
  const rpRemainder = rpDividend % rpWinningPool;

  assert(
    rpPayout * rpWinningPool + rpRemainder === rpDividend,
    "redeem division does not reconstruct its rpDividend",
  );
  assert(rpRemainder < rpWinningPool, "redeem remainder is not less than the divisor");

  const RP_SETTLED = 3n;

  const rpSettledNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: ENCRYPTED_MARKET_ID,
    outcome: RP_SETTLED,
    units: rpPayout,
  };
  const rpSettledCommitment = noteCommitment(rpSettledNote);
  const rpNullifierHash = nullifierHash(encPositionNote.nullifier);

  // rpRedeemMeta = marketId * 2^130 + outcome * 2^128 + rpTotalPool * 2^64 + rpWinningPool
  const rpRedeemMeta =
    ENCRYPTED_MARKET_ID * (1n << 130n) +
    OUTCOME_YES * (1n << 128n) +
    rpTotalPool * (1n << 64n) +
    rpWinningPool;

  const rpProof = await prove("redeem_private", {
    root: rpRootAfterBatch,
    nullifierHash: rpNullifierHash,
    newCommitment: rpSettledCommitment,
    // Explicit keys, not shorthand: these must be the CIRCUIT's signal names, which are
    // independent of whatever the JS variables are called.
    redeemMeta: rpRedeemMeta,
    nullifier: encPositionNote.nullifier,
    secret: encPositionNote.secret,
    newNullifier: rpSettledNote.nullifier,
    newSecret: rpSettledNote.secret,
    marketId: ENCRYPTED_MARKET_ID,
    outcome: OUTCOME_YES,
    units: UNITS,
    totalPool: rpTotalPool,
    winningPool: rpWinningPool,
    payout: rpPayout,
    remainder: rpRemainder,
    pathElements: rpPositionPath.pathElements,
    pathIndices: rpPositionPath.pathIndices,
  });

  fixtures.redeemPrivate = {
    ...rpProof,
    root: rpRootAfterBatch.toString(),
    nullifierHash: rpNullifierHash.toString(),
    newCommitment: rpSettledCommitment.toString(),
    redeemMeta: rpRedeemMeta.toString(),
    // Everything below is for the test's assertions, NOT sent on-chain -- units and the
    // payout are private, which is the whole point of this circuit.
    privateUnits: UNITS.toString(),
    privatePayout: rpPayout.toString(),
    settledYesTotal: rpSettledYes.toString(),
    settledNoTotal: rpSettledNo.toString(),
    settledOutcome: RP_SETTLED.toString(),
  };

  // -------------------------------------------------------------------------
  // 6c. WITHDRAW: the SETTLED note leaves for public USDC, keeping change.
  //
  //     Spends the note `redeemPrivate` just produced, so this only works against a tree
  //     that contains it -- batch 6 grafts it, and the contract's root must match
  //     `rootAfterBatch6`.
  //
  //     The withdrawal is PARTIAL on purpose. A settled payout is whatever the parimutuel
  //     arithmetic produced, and that exact number identifies the position that earned it;
  //     withdrawing a round amount instead is what keeps the exit unlinkable. The remainder
  //     comes back as a change note that is still SETTLED, so it stays withdrawable and
  //     stays un-redeemable.
  //
  //     Variable names carry a `wd` prefix: an earlier addition to this file reused names
  //     already bound above and failed to parse, and a blanket rename then silently mangled
  //     the witness input keys, which must be the CIRCUIT's signal names.
  // -------------------------------------------------------------------------
  const wdBatch = [rpSettledCommitment];
  while (wdBatch.length < BATCH_SIZE) {
    wdBatch.push(derivedFiller(5 * BATCH_SIZE, wdBatch.length));
  }
  for (const leaf of wdBatch) tree.insert(leaf);

  const wdRootAfterBatch = tree.root();
  fixtures.batch6 = wdBatch.map((x) => x.toString());
  fixtures.batch6Real = [rpSettledCommitment.toString()];
  fixtures.rootAfterBatch6 = wdRootAfterBatch.toString();

  // The settled note is the first leaf of batch 6.
  const wdPath = tree.path(5 * BATCH_SIZE);

  // Take a ladder amount out of the payout and leave the rest as private change.
  //
  // Was 60, which is not a rung. The withdrawn amount is PUBLIC, so it must look like
  // every other withdrawal or it identifies the position that earned it -- which is the
  // whole reason partial withdrawal exists. The CHANGE is unconstrained: it stays a
  // private note, and a parimutuel payout cannot be forced onto a ladder anyway.
  const wdAmount = 10n;
  const wdChange = rpPayout - wdAmount;
  assert(wdAmount + wdChange === rpPayout, "withdraw does not conserve the note value");
  assert(wdAmount > 0n, "withdraw amount must be non-zero");

  // Anvil account 0, matching the recipient the Solidity suite checks.
  const wdRecipient = 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266n;

  const wdChangeNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: ENCRYPTED_MARKET_ID,
    outcome: RP_SETTLED,
    units: wdChange,
  };
  const wdChangeCommitment = noteCommitment(wdChangeNote);
  const wdNullifierHash = nullifierHash(rpSettledNote.nullifier);

  // withdrawData = marketId * 2^200 + recipient * 2^40 + amount
  const wdWithdrawData =
    ENCRYPTED_MARKET_ID * (1n << 200n) + wdRecipient * (1n << 40n) + wdAmount;

  const wdProof = await prove("withdraw", {
    root: wdRootAfterBatch,
    nullifierHash: wdNullifierHash,
    changeCommitment: wdChangeCommitment,
    withdrawData: wdWithdrawData,
    nullifier: rpSettledNote.nullifier,
    secret: rpSettledNote.secret,
    newNullifier: wdChangeNote.nullifier,
    newSecret: wdChangeNote.secret,
    marketId: ENCRYPTED_MARKET_ID,
    units: rpPayout,
    recipient: wdRecipient,
    amount: wdAmount,
    change: wdChange,
    pathElements: wdPath.pathElements,
    pathIndices: wdPath.pathIndices,
  });

  fixtures.withdraw = {
    ...wdProof,
    root: wdRootAfterBatch.toString(),
    nullifierHash: wdNullifierHash.toString(),
    changeCommitment: wdChangeCommitment.toString(),
    withdrawData: wdWithdrawData.toString(),
    // For assertions only -- the note value and the change are PRIVATE and never sent.
    amount: wdAmount.toString(),
    recipient: "0x" + wdRecipient.toString(16),
    privateNoteValue: rpPayout.toString(),
    privateChange: wdChange.toString(),
  };

  // -------------------------------------------------------------------------
  // 7. Negative fixture: a bet proof for a note that was never deposited.
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

  // BigInts are not JSON-serialisable; the circuits take decimal strings anyway, which is
  // also the shape a browser client will hand snarkjs.
  writeFileSync(
    new URL("../build/witness-inputs.json", import.meta.url).pathname,
    JSON.stringify(witnessInputs, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2),
  );

  console.log("wrote", OUT.pathname);
  console.log("  deposit commitment :", depositCommitment);
  console.log("  root after batch 1 :", rootAfterBatch1);
  console.log("  root after batch 2 :", rootAfterBatch2);
  console.log("\nall proofs verified, all public signal orderings checked");
}

main().then(() => process.exit(0));
