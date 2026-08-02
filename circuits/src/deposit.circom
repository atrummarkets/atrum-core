pragma circom 2.1.9;

include "note.circom";

/// ============================================================================
/// DEPOSIT -- enter the shielded pool.
/// ============================================================================
///
/// The user has already split collateral into a complete set in the Vault, publicly.
/// This proves the commitment they are publishing really does encode that amount, so
/// the note they get out is worth exactly what they paid in.
///
/// What is public:  the commitment, which market, how many units.
/// What is hidden:  who owns it -- `nullifier` and `secret` never leave the client.
///
/// Privacy at this step is deliberately partial: the deposit transaction is signed by
/// the depositor, so the amount and the address are both visible. The anonymity comes
/// later, when `bet` spends this note from inside the tree and nothing links the spend
/// back to this leaf. Fixed denominations are what stop `units` itself being an
/// identifier across that boundary.
///
/// The proof is NOT ceremonial. Without it a user could pay for one unit and publish a
/// commitment claiming a hundred, then bet and redeem the hundred. The circuit is the
/// only thing binding the sealed value to the public payment.
///
/// Public signals: commitment, marketId, units = 3, inside the plan's ceiling of 4.
template Deposit() {
    // ---- PUBLIC ----
    signal input commitment;
    signal input units;

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;

    // A fresh deposit is unbet collateral, so outcome is fixed at 0 rather than being
    // an input. Accepting it as a signal would let a depositor mint a note already
    // committed to a winning side without ever placing a bet.
    //
    // `marketId` is fixed at NO_MARKET (0) for exactly the same reason, and it is why this
    // circuit has two public signals rather than three. A deposit no longer names a market:
    // the note it creates can back a bet in ANY market, which is what makes the anonymity
    // set every unspent note in the system instead of one market's depositors.
    //
    // NoteCommitment still CARRIES marketId, and must -- a YES position in market 8 that
    // could be redeemed against market 10 would be a theft, not a privacy feature. Unbet
    // notes simply use the sentinel, and `bet_encrypted` requires the note it spends to
    // carry it. Market 0 is unregisterable on-chain so the sentinel can never collide with
    // a real market.
    component note = NoteCommitment();
    note.nullifier <== nullifier;
    note.secret <== secret;
    note.marketId <== 0;
    note.outcome <== 0;
    note.units <== units;

    commitment === note.commitment;

    // Zero-unit notes are unspendable clutter that still consume a leaf, and the tree
    // has a hard capacity of 2^20. Reject them here rather than in the contract, so the
    // rule holds for every entry path.
    component isZero = IsZero();
    isZero.in <== units;
    isZero.out === 0;
}

component main {public [commitment, units]} = Deposit();
