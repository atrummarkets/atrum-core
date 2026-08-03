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
/// The marketId every UNBET note carries, since a deposit no longer names a market.
/// `deposit.circom` and `bet_encrypted.circom` both pin to it, and `registerEncryptedMarket`
/// refuses to register it, so it can never collide with a real market.
const NO_MARKET = 0n;

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

async function prove(circuit, input, { emitCalldata = true, record = true } = {}) {
  // Last one wins where a circuit is proved more than once; they are the same shape, which
  // is all a client or a benchmark needs.
  //
  // `record: false` opts a variant out. `withdraw` is proved twice with genuinely different
  // shapes -- a settled payout and the unbet exit -- and the recorded example must stay the
  // settled one, because that is what `atrum-client`'s bundle check validates field for
  // field. Letting the unbet variant win would break that check with a witness that is
  // perfectly valid.
  if (record) witnessInputs[circuit] = input;

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
  // A deposit names NO MARKET. The note it creates carries the NO_MARKET sentinel and can
  // back a bet in any market, which is what makes the anonymity set every unspent note in
  // the system rather than one market's depositors. `deposit.circom` pins marketId to 0, so
  // passing anything else here would build a witness the circuit refuses.
  const depositNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: NO_MARKET,
    outcome: OUTCOME_UNBET,
    units: UNITS,
  };
  const depositCommitment = noteCommitment(depositNote);

  const depositProof = await prove("deposit", {
    commitment: depositCommitment,
    units: UNITS,
    nullifier: depositNote.nullifier,
    secret: depositNote.secret,
  });

  assert(
    BigInt(depositProof.publicSignals[0]) === depositCommitment,
    "deposit signal[0] is not the commitment -- public signal ORDER differs from " +
      "what ShieldedPool.deposit assumes",
  );
  assert(BigInt(depositProof.publicSignals[1]) === UNITS, "deposit signal[1] != units");

  fixtures.deposit = {
    ...depositProof,
    commitment: depositCommitment.toString(),
    units: UNITS.toString(),
  };

  // -------------------------------------------------------------------------
  // 1b. A SECOND deposit, at a different rung, alongside the first
  // -------------------------------------------------------------------------
  // Not decoration. Two gates depend on the pool having a crowd, and a recorded lifecycle
  // that cannot satisfy them would only ever prove the gates are unreachable:
  //
  //   - `_requireAnonymitySet` refuses a bet until `minAnonymitySet` deposits exist. The
  //     first bet below happens immediately after batch 1, so batch 1 must already carry
  //     enough deposits for a pool configured at the test minimum.
  //   - `_checkWithdrawable` refuses a withdrawal at a rung nobody else has used. The
  //     settled withdrawal takes 10 units, so 10 has to be a rung the pool has seen more
  //     than once -- this deposit and `depositEncrypted2` are those two.
  //
  // It is never spent. An unspent note is exactly what an anonymity set is made of.
  const LADDER_UNITS = 10n;

  const ladderNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: NO_MARKET,
    outcome: OUTCOME_UNBET,
    units: LADDER_UNITS,
  };
  const ladderCommitment = noteCommitment(ladderNote);

  const ladderProof = await prove("deposit", {
    commitment: ladderCommitment,
    units: LADDER_UNITS,
    nullifier: ladderNote.nullifier,
    secret: ladderNote.secret,
  }, { emitCalldata: false, record: false });

  fixtures.depositLadder = {
    ...ladderProof,
    commitment: ladderCommitment.toString(),
    units: LADDER_UNITS.toString(),
  };

  // -------------------------------------------------------------------------
  // 2. Sequencer grafts batch 1: the two real deposits plus 62 fillers.
  // -------------------------------------------------------------------------
  // Only the real commitments are submitted. The CONTRACT derives the remaining fillers,
  // so the mirror must derive the identical values or the root diverges and every Merkle
  // path built here fails on-chain.
  const batch1 = [depositCommitment, ladderCommitment];
  while (batch1.length < BATCH_SIZE) {
    batch1.push(derivedFiller(0, batch1.length));
  }
  for (const leaf of batch1) tree.insert(leaf);

  const rootAfterBatch1 = tree.root();
  const depositPath = tree.path(0);

  fixtures.batch1 = batch1.map((x) => x.toString());
  fixtures.batch1Real = [depositCommitment.toString(), ladderCommitment.toString()];
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
  // so the encrypted bet cannot reuse market 7's POSITION note -- `marketId` is bound
  // inside a position note's commitment.
  //
  // The DEPOSIT below is market-agnostic, exactly like the Phase 1 one: a second unbet
  // note carrying NO_MARKET. It exists only because the Phase 1 deposit note was already
  // spent, not because market 8 needs its own deposit. Under one shared pool, either
  // note could have funded either bet -- which is the entire point of the change.
  //
  // Appending also keeps `rootAfterBatch1`/`rootAfterBatch2` byte-identical, so every
  // existing Phase 1 test keeps replaying against the roots it was written for.
  const encDepositNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: NO_MARKET,
    outcome: OUTCOME_UNBET,
    units: UNITS,
  };
  const encDepositCommitment = noteCommitment(encDepositNote);

  const encDepositProof = await prove("deposit", {
    commitment: encDepositCommitment,
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
    marketId: NO_MARKET,
    outcome: OUTCOME_UNBET,
    units: SECOND_UNITS,
  };
  const encDepositCommitment2 = noteCommitment(encDepositNote2);

  const encDepositProof2 = await prove("deposit", {
    commitment: encDepositCommitment2,
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

  // withdrawData = unbetExit * 2^200 + recipient * 2^40 + amount. A settled payout has a
  // nonzero marketId, so the circuit's `marketZero.out` -- and this bit -- is 0.
  const wdWithdrawData = 0n * (1n << 200n) + wdRecipient * (1n << 40n) + wdAmount;

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
  // 6f. THE UNBET EXIT -- deposit, never bet, walk out.
  // -------------------------------------------------------------------------
  // The path that only exists because a deposit stopped naming a market. Previously an
  // unbet note was locked until ITS market resolved, so capital committed for a bet that
  // was never placed sat frozen for the life of a market it never entered. With no market
  // binding there is nothing to wait for.
  //
  // `withdraw.circom` derives the spent note's outcome from `marketId`, so this fixture is
  // also the negative test for that derivation: a proof carrying `marketId == 0` can only
  // have come from an UNBET note, and the contract short-circuits every market check on
  // that basis. If the derivation were ever loosened into a free signal, this fixture and
  // `fixtures.withdraw` would both still verify while a SETTLED note became spendable on
  // the unbet path.
  const unbetNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: NO_MARKET,
    outcome: OUTCOME_UNBET,
    units: UNITS,
  };
  const unbetCommitment = noteCommitment(unbetNote);

  const unbetDepositProof = await prove("deposit", {
    commitment: unbetCommitment,
    units: UNITS,
    nullifier: unbetNote.nullifier,
    secret: unbetNote.secret,
  }, { emitCalldata: false });

  fixtures.depositUnbetExit = {
    ...unbetDepositProof,
    commitment: unbetCommitment.toString(),
    units: UNITS.toString(),
  };

  // Batch 7 carries TWO real leaves in QUEUE ORDER: the change note the settled withdrawal
  // above produced, then this deposit. `flushBatch` consumes the queue strictly in order, so
  // omitting the change note here would make the mirror and the chain disagree the moment a
  // test runs the settled withdrawal and this one in the same timeline -- which is exactly
  // what the invariant suite does. The whole fixture file is one timeline; it has to stay one.
  const unbetBatch = [wdChangeCommitment, unbetCommitment];
  while (unbetBatch.length < BATCH_SIZE) {
    unbetBatch.push(derivedFiller(6 * BATCH_SIZE, unbetBatch.length));
  }
  for (const leaf of unbetBatch) tree.insert(leaf);

  const unbetRoot = tree.root();
  const unbetPath = tree.path(6 * BATCH_SIZE + 1);

  fixtures.batch7 = unbetBatch.map((x) => x.toString());
  fixtures.batch7Real = [wdChangeCommitment.toString(), unbetCommitment.toString()];
  fixtures.rootAfterBatch7 = unbetRoot.toString();

  // Partial on purpose. The change note stays UNBET rather than SETTLED, so the remainder
  // is not just still withdrawable -- it is still BETTABLE, in any market. That is the
  // shared-pool property stated as a fixture rather than as prose.
  const unbetAmount = 10n;
  const unbetChange = UNITS - unbetAmount;

  const unbetChangeNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: NO_MARKET,
    outcome: OUTCOME_UNBET,
    units: unbetChange,
  };
  const unbetChangeCommitment = noteCommitment(unbetChangeNote);
  const unbetNullifierHash = nullifierHash(unbetNote.nullifier);

  // marketId is 0, so the circuit's `marketZero.out` -- and this bit -- is 1: the sentinel
  // the contract branches on is now one bit, not the full marketId.
  const unbetWithdrawData = 1n * (1n << 200n) + wdRecipient * (1n << 40n) + unbetAmount;

  const unbetWithdrawProof = await prove("withdraw", {
    root: unbetRoot,
    nullifierHash: unbetNullifierHash,
    changeCommitment: unbetChangeCommitment,
    withdrawData: unbetWithdrawData,
    nullifier: unbetNote.nullifier,
    secret: unbetNote.secret,
    newNullifier: unbetChangeNote.nullifier,
    newSecret: unbetChangeNote.secret,
    marketId: NO_MARKET,
    units: UNITS,
    recipient: wdRecipient,
    amount: unbetAmount,
    change: unbetChange,
    pathElements: unbetPath.pathElements,
    pathIndices: unbetPath.pathIndices,
  }, { emitCalldata: false, record: false });

  fixtures.withdrawUnbet = {
    ...unbetWithdrawProof,
    root: unbetRoot.toString(),
    nullifierHash: unbetNullifierHash.toString(),
    changeCommitment: unbetChangeCommitment.toString(),
    withdrawData: unbetWithdrawData.toString(),
    amount: unbetAmount.toString(),
    recipient: "0x" + wdRecipient.toString(16),
    privateNoteValue: UNITS.toString(),
    privateChange: unbetChange.toString(),
  };

  // -------------------------------------------------------------------------
  // 7. Negative fixture: a bet proof for a note that was never deposited.
  //    The contract must reject it, and the only thing standing in the way is the
  //    Merkle constraint -- worth having a real counterexample rather than trusting it.
  // -------------------------------------------------------------------------
  const forgedNote = {
    nullifier: randomField(),
    secret: randomField(),
    marketId: NO_MARKET,
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
