pragma circom 2.1.9;

include "note.circom";
include "merkle.circom";
include "comparators.circom";

/// ============================================================================
/// WITHDRAW -- leaving the shielded pool for public USDC.
/// ============================================================================
///
/// The prover claims:
///
///   "One of the leaves under root R is a note of mine that is entitled to leave -- either a
///    SETTLED payout in market `marketId`, or, when `marketId` is 0, collateral I deposited
///    and never staked. Here is its nullifier hash. Pay `amount` to `recipient`, and insert
///    this new commitment holding the change."
///
/// WHAT IS AND IS NOT PRIVATE HERE, STATED HONESTLY
///
/// The amount and the recipient are PUBLIC, and they have to be: real collateral leaves the
/// system, and a transfer is visible. There is no cryptography that hides an outgoing
/// payment on a public chain.
///
/// So the privacy of this action does not come from hiding the amount. It comes from
/// UNLINKABILITY:
///
///   - Which note funded the withdrawal is hidden. The anonymity set is every other note in
///     the tree.
///   - `redeemPrivate` already broke the link from position to payout, so what is withdrawn
///     is not tied to any bet.
///   - The withdrawal happens whenever the holder chooses, not when their position settled,
///     so timing does not correlate either.
///
/// AND WHY PARTIAL WITHDRAWAL EXISTS
///
/// A settled payout is whatever the parimutuel arithmetic produced -- 137, 1,041, an odd
/// number. If the only option were withdrawing a note in full, the public amount would be
/// that exact payout, and a payout uniquely identifies the position that earned it. The
/// amount would leak precisely what `redeemPrivate` just protected.
///
/// Partial withdrawal fixes that: the holder withdraws a round, uniform amount and keeps the
/// remainder as a change note. Withdrawing in FIXED DENOMINATIONS -- which
/// `atrum-build-plan.md` lists as a non-negotiable for exactly this reason -- makes every
/// withdrawal look identical and the amount carries no information at all.
///
/// Conservation is the load-bearing constraint: `amount + change == units`. Without it a
/// holder withdraws the full note AND keeps a full-value change note, minting collateral.
///
/// Public signals: root, nullifierHash, changeCommitment, withdrawData = 4.
///
/// @param levels       Merkle depth.
/// @param AMOUNT_BITS  range bound on the note value, the amount and the change.
template Withdraw(levels, AMOUNT_BITS) {
    // ---- PUBLIC ----
    signal input root;
    signal input nullifierHash;
    signal input changeCommitment;
    /// withdrawData = marketId * 2^200 + recipient * 2^40 + amount
    ///
    /// 32 + 160 + 40 = 232 bits, inside the 254-bit field. `marketId` must be public because
    /// the contract has to know WHICH vault the collateral comes out of, and `recipient` must
    /// be bound into the proof or a mempool watcher lifts the proof and swaps in their own
    /// address -- the POC already learned that one.
    signal input withdrawData;

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;
    signal input newNullifier;
    signal input newSecret;
    signal input marketId;
    signal input units; // the note's full value -- stays private
    signal input recipient;
    signal input amount;
    signal input change;

    signal input pathElements[levels];
    signal input pathIndices[levels];

    var SETTLED = 3;

    // 1. Rebuild the note being spent. TWO kinds of note can leave the pool, and which one
    //    this is is DERIVED from `marketId` rather than chosen by the prover.
    //
    //      marketId != 0 -- a SETTLED payout note. This is the other half of the anti-mint
    //        pair: `redeem_private` always emits outcome 3 and refuses to spend one; this
    //        refuses to spend any other market-scoped outcome. Together the only path out
    //        of a market is deposit -> bet -> redeem -> withdraw, each step consuming its
    //        input exactly once.
    //
    //      marketId == 0 (NO_MARKET) -- an UNBET note, straight back out of shared custody.
    //        Under one shared pool a deposit names no market, so collateral that was never
    //        staked has no market to wait for and no payout arithmetic to run: it is backed
    //        1:1 and `amount + change === units` below is the whole of its correctness.
    //        Without this path that collateral would be permanently stranded, since there
    //        is no market whose settlement could ever release it.
    //
    //    `outcomeSig` is a pure function of `marketId`, not an input, so the prover cannot
    //    mix the two: a SETTLED note can never be spent on the unbet path (it has a real
    //    marketId), and an unbet note can never be spent on the settled path (it does not).
    //    That is what keeps the anti-mint argument intact -- an unbet note still cannot
    //    reach a market's pool arithmetic without first being bet and redeemed.
    component marketZero = IsZero();
    marketZero.in <== marketId;

    signal outcomeSig;
    outcomeSig <== SETTLED * (1 - marketZero.out);

    component oldNote = NoteCommitment();
    oldNote.nullifier <== nullifier;
    oldNote.secret <== secret;
    oldNote.marketId <== marketId;
    oldNote.outcome <== outcomeSig;
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

    // 4. CONSERVATION. Without this the holder withdraws the full note and keeps a
    //    full-value change note, minting collateral out of nothing.
    units === amount + change;

    // Range-constrain both halves. `units` is already AMOUNT_BITS-constrained inside
    // NoteCommitment, but the split must be too: without these, `amount` could be a huge
    // field element and `change` its negative complement, satisfying the sum while paying out
    // far more than the note holds.
    component amountBits = Num2Bits(AMOUNT_BITS);
    amountBits.in <== amount;
    component changeBits = Num2Bits(AMOUNT_BITS);
    changeBits.in <== change;

    // A zero withdrawal burns the note and pays nothing -- pointless, and it would let a
    // holder destroy their own funds by accident.
    component amountZero = IsZero();
    amountZero.in <== amount;
    amountZero.out === 0;

    // 5. The change note: same market, same derived outcome. A settled note's change stays
    //    SETTLED so it remains withdrawable and remains un-redeemable; an unbet note's change
    //    stays UNBET so the remainder is still liquid AND still bettable, which is the point
    //    of not binding a deposit to a market in the first place.
    //
    //    `change == 0` is allowed. The note is then worth nothing and is unspendable -- a
    //    later withdraw against it would need `amount > 0` with `amount + change == 0` --
    //    so it is harmless, at the cost of one leaf from a tree that holds 2^20. The
    //    alternative, forcing a non-zero change, would make it impossible to fully exit.
    component changeNote = NoteCommitment();
    changeNote.nullifier <== newNullifier;
    changeNote.secret <== newSecret;
    changeNote.marketId <== marketId;
    changeNote.outcome <== outcomeSig;
    changeNote.units <== change;

    changeCommitment === changeNote.commitment;

    // 6. Bind the packed public value. Every field range-checked, or the layout is not
    //    injective and bits carry between fields.
    component marketBits = Num2Bits(32);
    marketBits.in <== marketId;
    component recipientBits = Num2Bits(160);
    recipientBits.in <== recipient;

    withdrawData === marketId * (1 << 200) + recipient * (1 << 40) + amount;

    // 7. The change note must differ from the note it replaces. Fresh secrets are supplied,
    //    but if a caller reused them AND withdrew nothing the two leaves would coincide,
    //    making that tree position ambiguous for every later proof.
    signal diff;
    diff <== changeCommitment - oldNote.commitment;
    component isSame = IsZero();
    isSame.in <== diff;
    isSame.out === 0;
}

component main {public [root, nullifierHash, changeCommitment, withdrawData]} = Withdraw(20, 40);
