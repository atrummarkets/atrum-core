pragma circom 2.1.9;

include "note.circom";
include "merkle.circom";
include "elgamal.circom";
include "committee_key.circom";

/// ============================================================================
/// BET, PHASE 2 -- the version where the pool total goes dark.
/// ============================================================================
///
/// The prover claims:
///
///   "One of the leaves under root R is an unbet note of mine in market `marketId`.
///    Here is its nullifier hash. Insert this new commitment, which is the same stake
///    committed to a side. And here is Enc(stake) under the committee key -- which I
///    prove encrypts exactly the amount inside the note I just spent."
///
/// WHAT CHANGES FROM PHASE 1, AND WHY IT IS THE WHOLE POINT
///
/// In `bet.circom`, `units` is PUBLIC: the contract had to see the stake in order to add
/// it to a plaintext pool total. That is the honest limit of Phase 1 -- positions were
/// shielded, the pool was not.
///
/// Here `units` is PRIVATE. The contract never learns it. Instead it receives a
/// ciphertext and adds it to a running encrypted total with two point additions, so the
/// pool total is hidden from everyone including the operator until the committee
/// decrypts a ratio.
///
/// That is not a privacy garnish. It fixes parimutuel's one real weakness: with a
/// visible running total, late bettors get a free read on everyone else's information.
///
/// THE CONSISTENCY CONSTRAINT IS THE LOAD-BEARING PART
///
/// Emitting a ciphertext is easy. Proving it encrypts the SAME amount as the spent note
/// is what makes the accumulator trustworthy. Without step 6 below, a bettor could spend
/// a 1-unit note and emit Enc(1,000,000), inflating their share of the pool while risking
/// almost nothing -- and nothing on-chain could detect it, because the contract cannot
/// read either value. `units` feeds both the note commitment and the encryption from the
/// same signal, so they cannot diverge.
///
/// PUBLIC SIGNAL COST, STATED PLAINLY
///
/// Public signals: root, nullifierHash, newCommitment, betMeta, c1[2], c2[2] = 8. That
/// is double `atrum-build-plan.md`'s ceiling of 4, and at a measured 30,756 gas each the
/// four ciphertext signals cost ~123,000 gas.
///
/// It is not avoidable by hashing: the contract must add the actual curve points to the
/// accumulator, so it needs the actual values. Publishing a Poseidon hash of them instead
/// and passing the points as calldata would save 3 signals (~92,000) and cost 3 on-chain
/// Poseidon(2) calls (~87,000) -- a wash, for materially more moving parts.
///
/// The committee key is compiled in rather than passed as two more public signals, which
/// keeps this at 8 instead of 10. `committee_key.circom` is generated from the key file
/// so the circuit cannot drift from the key it was built against.
template BetEncrypted(levels, AMOUNT_BITS) {
    // ---- PUBLIC ----
    signal input root;
    signal input nullifierHash;
    signal input newCommitment;
    signal input betMeta; // marketId * 4 + outcome
    signal input c1[2]; // Enc(units).C1 = [r]G
    signal input c2[2]; // Enc(units).C2 = [units]G + [r]H

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;
    signal input newNullifier;
    signal input newSecret;
    signal input marketId;
    signal input outcome;
    signal input units; // private in Phase 2 -- this is the change
    signal input encRandomness; // r, fresh per bet
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // 1. Rebuild the note being spent. Outcome is pinned to 0: only unbet collateral can
    //    be bet, which is what stops a position being re-bet onto the other side after
    //    news lands.
    component oldNote = NoteCommitment();
    oldNote.nullifier <== nullifier;
    oldNote.secret <== secret;
    oldNote.marketId <== marketId;
    oldNote.outcome <== 0;
    oldNote.units <== units;

    // 2. Prove membership without revealing which leaf.
    component tree = MerkleTreeChecker(levels);
    tree.leaf <== oldNote.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    // 3. Burn it.
    component nh = NullifierHash();
    nh.nullifier <== nullifier;
    nullifierHash === nh.out;

    // 4. The replacement note: same market, same stake, now committed to a side.
    component sideCheck = IsBettableOutcome();
    sideCheck.outcome <== outcome;

    component newNote = NoteCommitment();
    newNote.nullifier <== newNullifier;
    newNote.secret <== newSecret;
    newNote.marketId <== marketId;
    newNote.outcome <== outcome;
    newNote.units <== units;

    newCommitment === newNote.commitment;

    // 5. Bind market and side. `units` is deliberately absent -- it is private now, and
    //    packing it would publish exactly what this phase exists to hide.
    component marketBits = Num2Bits(32);
    marketBits.in <== marketId;

    betMeta === marketId * 4 + outcome;

    // 6. THE CONSISTENCY CONSTRAINT. Encrypt `units` -- the same signal that went into
    //    both note commitments -- under the compiled-in committee key, and force the
    //    result to equal the published ciphertext.
    //
    //    `units` is already range-constrained to AMOUNT_BITS inside NoteCommitment, and
    //    ElGamalEncrypt range-constrains it again. That bound is what keeps the pool
    //    total recoverable: the publisher inverts [total]G by baby-step giant-step, which
    //    is only tractable for bounded plaintexts.
    component enc = ElGamalEncrypt(AMOUNT_BITS);
    enc.amount <== units;
    enc.randomness <== encRandomness;
    enc.pubKey[0] <== committeeKeyX();
    enc.pubKey[1] <== committeeKeyY();

    c1[0] === enc.c1[0];
    c1[1] === enc.c1[1];
    c2[0] === enc.c2[0];
    c2[1] === enc.c2[1];

    // 7. Reject zero encryption randomness.
    //
    //    r = 0 makes C1 the identity and C2 = [units]G, so ANYONE can recover the stake by
    //    discrete log -- the ciphertext stops being a ciphertext.
    //
    //    On its own that is self-inflicted, and a soundness suite would let it pass. It is
    //    constrained because the client choosing r is not necessarily the bettor's: a
    //    malicious or compromised frontend could force r = 0 on every user, publishing
    //    every bet while the contract sees nothing wrong. Enforcing it here means no client
    //    can produce that proof at all.
    //
    //    It also protects other bettors, not just this one. A known addend of the encrypted
    //    total narrows what the rest of the pool can be.
    component randZero = IsZero();
    randZero.in <== encRandomness;
    randZero.out === 0;

    // 8. Reject a zero stake.
    //
    //    This constraint exists BECAUSE `units` went private. In Phase 1 the contract
    //    checked `units == 0` itself; in Phase 2 it cannot see the value at all, so every
    //    guard that used to live in Solidity has to move here or vanish silently.
    //
    //    A reachability argument says a zero-unit note cannot exist -- `deposit.circom`
    //    rejects zero, `bet` preserves `units`, and padding fillers are unspendable -- so
    //    this is defence in depth rather than a live hole. It is added anyway: the
    //    argument spans three circuits and a contract, and one future change to any of
    //    them turns "unreachable" into "unnoticed". A zero-unit note would consume a leaf
    //    from a tree capped at 2^20 and accumulate Enc(0) forever.
    component unitsZero = IsZero();
    unitsZero.in <== units;
    unitsZero.out === 0;

    // 9. The new note must differ from the spent one, or the sequencer would graft a
    //    duplicate leaf and make that position ambiguous for every later Merkle proof.
    signal diff;
    diff <== newCommitment - oldNote.commitment;
    component isSame = IsZero();
    isSame.in <== diff;
    isSame.out === 0;
}

component main {public [root, nullifierHash, newCommitment, betMeta, c1, c2]} = BetEncrypted(20, 40);
