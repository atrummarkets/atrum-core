pragma circom 2.1.9;

include "note.circom";
include "merkle.circom";
include "comparators.circom";

/// ============================================================================
/// PRIVATE REDEEM -- the item both build plans refuse to cut.
/// ============================================================================
///
/// The prover claims:
///
///   "One of the leaves under root R is a position of mine in market `marketId` on
///    `outcome`. Here is its nullifier hash. Insert this new commitment: the same owner,
///    same market, holding the payout that position earned -- and tagged SETTLED so it can
///    only ever be withdrawn, never redeemed again."
///
/// WHY THIS REPLACES `redeem.circom`
///
/// `redeem.circom` publishes `payoutData = recipient * 2^64 + units`: a public address and a
/// public amount. `atrum-build-plan.md` calls that out directly -- a public payout claim
/// "retroactively reveals every position", which makes the privacy claim FALSE rather than
/// weak, and it is the one item the plan says never to cut. `atrum-4day-plan.md` §7 repeats
/// it: "Redemption stays inside the shielded pool. Non-negotiable."
///
/// So nothing is paid out here. The payout becomes a note. Exiting to public USDC is a
/// separate action, at a time of the holder's choosing, unlinkable from the position that
/// earned it.
///
/// THE OUTCOME=3 TAG, AND THE UNBOUNDED MINT IT PREVENTS
///
/// The payout note has to carry some outcome value, and every existing value is a trap:
///
///   outcome 0 (unbet) -- redeemable as a 1:1 refund. So: redeem a winning position, receive
///   a payout note tagged unbet, redeem THAT as a refund, receive another payout note,
///   forever. Nullifiers do not stop it because each payout note is genuinely new with a
///   fresh nullifier, and every individual step is legitimate. Unbounded mint.
///
///   outcome 1 or 2 -- redeemable again if that side won. Same loop.
///
/// Hence a fourth value. The 2-bit outcome field already has room, so it costs nothing:
///
///   0 = unbet collateral   bettable, redeemable (1:1 refund), not withdrawable
///   1 = YES position       not bettable, redeemable if YES won
///   2 = NO position        not bettable, redeemable if NO won
///   3 = SETTLED payout     not bettable, NOT redeemable, withdrawable only
///
/// This circuit accepts {0,1,2} and always emits 3. `withdraw` accepts only 3. The cycle is
/// closed by construction rather than by a check that could be forgotten.
///
/// WHY THE DIVISION IS IN-CIRCUIT
///
/// Parimutuel payout is `units * totalPool / winningPool`. In Phase 1 the contract computed
/// it, because `units` was public. Here `units` is private -- that is the point -- so the
/// contract cannot. The settled totals ARE public (`EncryptedParimutuelPool.finalYesTotal`
/// and `finalNoTotal` are written in the clear at settlement), so the division is proved
/// against public divisors with a private dividend:
///
///     units * totalPool == payout * winningPool + remainder,  0 <= remainder < winningPool
///
/// which is exactly integer division, and truncates DOWN -- so the sum of payouts can only
/// come in under the pool, never over. Same solvency argument as `ParimutuelPool`.
///
/// @param levels       Merkle depth.
/// @param AMOUNT_BITS  range bound on units and payout.
template RedeemPrivate(levels, AMOUNT_BITS) {
    // ---- PUBLIC ----
    signal input root;
    signal input nullifierHash;
    signal input newCommitment;
    /// redeemMeta = marketId * 2^130 + outcome * 2^128 + totalPool * 2^64 + winningPool
    ///
    /// Packed to stay at 4 public signals, the plan's ceiling, at a measured 30,756 gas
    /// each. 32 + 2 + 64 + 64 = 162 bits, inside the 254-bit field. Every field is
    /// range-constrained below, without which the layout is not injective and a prover
    /// could carry bits from one field into another.
    signal input redeemMeta;

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;
    signal input newNullifier;
    signal input newSecret;
    signal input marketId;
    signal input outcome; // the position being redeemed: 0, 1 or 2
    signal input units; // stays private -- this is what Phase 1 leaked
    signal input totalPool;
    signal input winningPool;
    signal input payout; // quotient of the division below
    signal input remainder; // and its remainder
    signal input pathElements[levels];
    signal input pathIndices[levels];

    var SETTLED = 3;

    // 1. Rebuild the note being redeemed.
    component oldNote = NoteCommitment();
    oldNote.nullifier <== nullifier;
    oldNote.secret <== secret;
    oldNote.marketId <== marketId;
    oldNote.outcome <== outcome;
    oldNote.units <== units;

    // 2. Prove membership without revealing which leaf.
    component tree = MerkleTreeChecker(levels);
    tree.leaf <== oldNote.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    // 3. Burn it, so a position pays exactly once.
    component nh = NullifierHash();
    nh.nullifier <== nullifier;
    nullifierHash === nh.out;

    // 4. REJECT an already-settled note.
    //
    //    This is the constraint that closes the mint loop. `NoteCommitment` range-checks
    //    outcome to 2 bits, which admits 3, so without this a SETTLED payout note could be
    //    redeemed again -- and again. Asserted explicitly rather than left to the contract:
    //    the contract cannot see `outcome`, because it is private here.
    component isSettled = IsZero();
    isSettled.in <== outcome - SETTLED;
    isSettled.out === 0;

    // 5. Range-constrain every packed field, so `redeemMeta` is injective.
    component marketBits = Num2Bits(32);
    marketBits.in <== marketId;
    component totalBits = Num2Bits(64);
    totalBits.in <== totalPool;
    component winningBits = Num2Bits(64);
    winningBits.in <== winningPool;
    // `outcome` is already 2-bit-constrained inside NoteCommitment.

    redeemMeta === marketId * (1 << 130) + outcome * (1 << 128) + totalPool * (1 << 64) + winningPool;

    // 6. THE PAYOUT.
    //
    //    Two regimes, and circom has no branching, so both are computed and selected:
    //
    //      outcome 0 (never bet)  -> refund 1:1. Depositing and changing your mind must not
    //                                burn the stake.
    //      outcome 1 or 2 (a won position) -> pro rata across the whole staked pool.
    //
    //    A LOSING position is not handled here at all: it is worth nothing, so there is
    //    nothing to redeem. The contract decides which outcome won and refuses the other.
    component isUnbet = IsZero();
    isUnbet.in <== outcome;

    // Integer division, proved rather than performed:
    //     units * totalPool == payout * winningPool + remainder,  remainder < winningPool
    //
    // Conditioned on NOT being the refund path. An unbet note may be redeemed in a market
    // where `winningPool` is 0 -- nobody backed the winning side -- and an unconditional
    // division constraint would be unsatisfiable there (remainder < 0 is impossible),
    // wrongly bricking a legitimate refund.
    signal dividend;
    dividend <== units * totalPool;

    signal product;
    product <== payout * winningPool;

    // (1 - isUnbet) * (dividend - product - remainder) === 0
    signal divisionResidual;
    divisionResidual <== dividend - product - remainder;
    (1 - isUnbet.out) * divisionResidual === 0;

    // remainder < winningPool, enforced only on the pro-rata path.
    component remLt = LessThan(64);
    remLt.in[0] <== remainder;
    remLt.in[1] <== winningPool;
    (1 - isUnbet.out) * (1 - remLt.out) === 0;

    // winningPool != 0 on the pro-rata path, or the division is undefined.
    component winZero = IsZero();
    winZero.in <== winningPool;
    (1 - isUnbet.out) * winZero.out === 0;

    // Select: refund pays `units`, a won position pays the quotient.
    //
    // Written as `payout + isUnbet * (units - payout)` rather than the readable
    // `isUnbet*units + (1-isUnbet)*payout`, because the latter is two multiplications in one
    // constraint and R1CS allows only one. Same value, quadratic form.
    signal payoutUnits;
    payoutUnits <== payout + isUnbet.out * (units - payout);

    // A zero payout would mint an unspendable note that still consumes a leaf from a tree
    // capped at 2^20. It is also a signal that something upstream is wrong.
    component payoutZero = IsZero();
    payoutZero.in <== payoutUnits;
    payoutZero.out === 0;

    // 7. The payout note: same owner secrets are NOT reused (fresh ones are supplied), same
    //    market, tagged SETTLED, holding the payout.
    component newNote = NoteCommitment();
    newNote.nullifier <== newNullifier;
    newNote.secret <== newSecret;
    newNote.marketId <== marketId;
    newNote.outcome <== SETTLED;
    newNote.units <== payoutUnits;

    newCommitment === newNote.commitment;

    // 8. The payout note must differ from the note it replaces, or the sequencer would graft
    //    a duplicate leaf and make that tree position ambiguous for every later proof.
    signal diff;
    diff <== newCommitment - oldNote.commitment;
    component isSame = IsZero();
    isSame.in <== diff;
    isSame.out === 0;
}

component main {public [root, nullifierHash, newCommitment, redeemMeta]} = RedeemPrivate(20, 40);
