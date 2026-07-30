pragma circom 2.1.9;

include "note.circom";
include "merkle.circom";

/// ============================================================================
/// REDEEM -- claim a winning position.
/// ============================================================================
///
/// The prover claims:
///
///   "One of the leaves under root R is a position of mine on outcome `outcome` in
///    market `marketId`, worth `units`. Here is its nullifier hash. Pay `recipient`."
///
/// The contract checks `outcome` against the Vault's resolution and pays pro rata out
/// of the parimutuel pool.
///
/// ---------------------------------------------------------------------------
/// THIS PAYOUT IS PUBLIC, AND THAT IS A KNOWN HOLE
/// ---------------------------------------------------------------------------
/// `atrum-build-plan.md` is blunt that a public redemption path makes the privacy claim
/// *false rather than degraded*: an observer correlates payout amounts and timing back
/// to positions, which retroactively deanonymises the bets that funded them. It is the
/// one item the plan says never to cut.
///
/// It is public here because Phase 1's milestone is explicitly "shielded positions,
/// public pool total" -- an internal milestone, not a launch. Phase 2 moves redemption
/// inside the shielded pool, paying into a fresh note instead of an address. Nothing
/// built on this circuit should be described as a private prediction market until then.
///
/// `recipient` is packed into `payoutData`, which the constraint below forces into the
/// system. That is what stops a mempool watcher lifting the proof, swapping in their
/// own address and stealing the payout -- with `recipient` merely a public signal the
/// circuit never touched, the theft would verify.
///
/// Public signals: root, nullifierHash, payoutData, marketMeta = 4.
template Redeem(levels) {
    // ---- PUBLIC ----
    signal input root;
    signal input nullifierHash;
    signal input payoutData;  // recipient * 2^UNIT_BITS + units   (160 + 64 bits)
    signal input marketMeta;  // marketId * 4 + outcome

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;
    signal input marketId;
    signal input outcome;
    signal input units;
    signal input recipient;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // 1. Rebuild the note being claimed.
    //
    //    `outcome` is deliberately NOT restricted to {1,2} here. A note that was
    //    deposited but never bet (outcome 0) still holds real collateral and must be
    //    refundable 1:1, otherwise depositing and changing your mind burns the stake.
    //    NoteCommitment already range-constrains outcome to 2 bits; deciding which
    //    values pay, and how much, is the contract's job because only it knows the
    //    resolution and the pool totals.
    component note = NoteCommitment();
    note.nullifier <== nullifier;
    note.secret <== secret;
    note.marketId <== marketId;
    note.outcome <== outcome;
    note.units <== units;

    // 2. Prove membership without revealing the position.
    component tree = MerkleTreeChecker(levels);
    tree.leaf <== note.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    // 3. Burn it, so a winning ticket pays exactly once.
    component nh = NullifierHash();
    nh.nullifier <== nullifier;
    nullifierHash === nh.out;

    // 4. Bind recipient and amount together. 160 + 64 = 224 bits, inside the 254-bit
    //    field, so the layout is injective once `recipient` is range-checked -- an
    //    over-wide recipient would otherwise carry into the units field and inflate the
    //    payout.
    component recipientBits = Num2Bits(160);
    recipientBits.in <== recipient;

    payoutData === recipient * (1 << UNIT_BITS()) + units;

    // 5. Bind market and side. `outcome` is already constrained to {1,2} above, so
    //    multiplying marketId by 4 cannot collide across markets.
    component marketBits = Num2Bits(32);
    marketBits.in <== marketId;

    marketMeta === marketId * 4 + outcome;
}

component main {public [root, nullifierHash, payoutData, marketMeta]} = Redeem(20);
