pragma circom 2.1.9;

include "note.circom";
include "merkle.circom";

/// ============================================================================
/// BET -- the action every privacy claim in Atrum rests on.
/// ============================================================================
///
/// The prover claims:
///
///   "One of the leaves under root R is an unbet note of mine worth `units` in market
///    `marketId`. Here is its nullifier hash, so it can never be spent again. Insert
///    this new commitment, which is the same stake committed to outcome YES or NO."
///
/// The contract learns the root, the nullifier hash, the new commitment, and the
/// packed (marketId, outcome, units). It does NOT learn which leaf was spent, so the
/// bet is unlinkable to the deposit that funded it. The anonymity set is every other
/// note in the tree.
///
/// `units` and `outcome` are public in Phase 1 because the parimutuel pool totals are
/// public in Phase 1 -- the contract has to add the stake to a side to publish odds.
/// That is the honest limit of this milestone: positions are shielded, the pool is not.
/// Phase 2 replaces these with an ElGamal ciphertext and proves consistency with the
/// spent note instead, at which point the totals go dark too.
///
/// Public signals: root, nullifierHash, newCommitment, betData = 4, exactly the ceiling.
/// Getting there needs marketId, outcome and units packed into one field element --
/// see note.circom. At 30,756 gas per public input, unpacking in Solidity is free by
/// comparison.
template Bet(levels) {
    // ---- PUBLIC ----
    signal input root;
    signal input nullifierHash;
    signal input newCommitment;
    signal input betData;

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;
    signal input newNullifier;
    signal input newSecret;
    signal input marketId;
    signal input outcome;
    signal input units;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // 1. Rebuild the note being spent. Outcome 0: only unbet collateral can be bet,
    //    which is what stops a position being re-bet onto the other side after news
    //    lands.
    //
    //    marketId is pinned to NO_MARKET (0) for a second, independent reason. A deposit
    //    no longer names a market, so every unbet note carries the sentinel; requiring it
    //    here is what stops a POSITION note being fed back in as unbet collateral. The
    //    outcome pin alone does not cover that, because the prover controls both signals.
    component oldNote = NoteCommitment();
    oldNote.nullifier <== nullifier;
    oldNote.secret <== secret;
    oldNote.marketId <== 0;
    oldNote.outcome <== 0;
    oldNote.units <== units;

    // 2. Prove it is in the tree, without revealing where.
    component tree = MerkleTreeChecker(levels);
    tree.leaf <== oldNote.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    // 3. Burn it. The contract rejects a repeated nullifierHash, which is the entire
    //    double-spend defence -- and it needs plain set membership, not non-membership,
    //    which is why a mapping is sound here and an indexed tree is not required.
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

    // 5. Bind the packed public value. `units` and `outcome` are already range-checked
    //    inside NoteCommitment; marketId is checked here so the layout stays injective
    //    -- an unbounded marketId could carry into the outcome and units fields and
    //    describe a different bet than the note actually encodes.
    component marketBits = Num2Bits(32);
    marketBits.in <== marketId;

    betData === marketId * (1 << (UNIT_BITS() + OUTCOME_BITS()))
        + outcome * (1 << UNIT_BITS())
        + units;

    // 6. The new note must differ from the spent one. Reusing the same secrets would
    //    produce an identical commitment, and the sequencer would insert a duplicate
    //    leaf -- making that position ambiguous for every later Merkle proof.
    signal diff;
    diff <== newCommitment - oldNote.commitment;
    component isSame = IsZero();
    isSame.in <== diff;
    isSame.out === 0;
}

component main {public [root, nullifierHash, newCommitment, betData]} = Bet(20);
