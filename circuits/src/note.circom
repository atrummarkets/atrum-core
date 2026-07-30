pragma circom 2.1.9;

include "poseidon.circom";
include "bitify.circom";
include "comparators.circom";

/// ============================================================================
/// The Atrum note, and the packing rules every circuit and contract shares.
/// ============================================================================
///
/// A note is a shielded position. Its commitment is the tree leaf:
///
///     ownerHash  = Poseidon(nullifier, secret)
///     dataHash   = Poseidon(marketId, outcome * 2^UNIT_BITS + units)
///     commitment = Poseidon(ownerHash, dataHash)
///
/// Every hash is arity 2 on purpose. On-chain there is exactly one Poseidon contract
/// (`PoseidonT3`, measured at 28,980 gas), the sequencer's mirror uses one hasher, and
/// the circuits use one template -- so there is a single place for in-circuit and
/// on-chain hashing to diverge, and `prove.mjs` checks that one place.
///
/// Splitting owner from data is not cosmetic. `bet` re-commits the SAME owner secrets
/// to NEW market data, so keeping the two halves separate means the spend authority is
/// proven once and reused, instead of being re-derived per field.
///
/// ---------------------------------------------------------------------------
/// PUBLIC INPUT PACKING
/// ---------------------------------------------------------------------------
/// `MEASUREMENTS.md` §1 measures **30,756 gas per public input** (one ecMul at 30,000
/// plus one ecAdd, both repriced ~5x on Monad), and `atrum-build-plan.md` caps every
/// circuit at 4. A field element holds 254 bits, so several values ride in one signal
/// and the contract unpacks them. The layouts, LSB first:
///
///     betData    = marketId * 2^(UNIT_BITS+2) + outcome * 2^UNIT_BITS + units
///     payoutData = recipient * 2^UNIT_BITS + units          (160 + 64 = 224 bits)
///     marketMeta = marketId * 4 + outcome
///
/// Packing is only safe if each field is range-constrained; otherwise a prover picks
/// oversized values that alias a different tuple with the same sum. Every template
/// below does the range checks that make the layout injective.

/// Units are collateral denominations, not base units. 2^64 denominations is far
/// beyond any real market and leaves room to pack alongside a 160-bit address.
function UNIT_BITS() { return 64; }

/// Outcome: 0 = unbet collateral, 1 = YES, 2 = NO. Two bits.
function OUTCOME_BITS() { return 2; }

/// Domain tag so a nullifier hash can never collide with a commitment hash.
function NULLIFIER_DOMAIN() { return 1; }

/// commitment = Poseidon(Poseidon(nullifier, secret), Poseidon(marketId, packed))
template NoteCommitment() {
    signal input nullifier;
    signal input secret;
    signal input marketId;
    signal input outcome;
    signal input units;

    signal output commitment;

    // Range-constrain before packing. Without these the packed value is ambiguous:
    // (outcome=0, units=2^64) and (outcome=1, units=0) would produce the same field
    // element, letting a prover restate an unbet note as a winning position.
    component unitBits = Num2Bits(UNIT_BITS());
    unitBits.in <== units;

    component outcomeBits = Num2Bits(OUTCOME_BITS());
    outcomeBits.in <== outcome;

    signal packed;
    packed <== outcome * (1 << UNIT_BITS()) + units;

    component ownerHash = Poseidon(2);
    ownerHash.inputs[0] <== nullifier;
    ownerHash.inputs[1] <== secret;

    component dataHash = Poseidon(2);
    dataHash.inputs[0] <== marketId;
    dataHash.inputs[1] <== packed;

    component leaf = Poseidon(2);
    leaf.inputs[0] <== ownerHash.out;
    leaf.inputs[1] <== dataHash.out;

    commitment <== leaf.out;
}

/// nullifierHash = Poseidon(nullifier, NULLIFIER_DOMAIN)
///
/// The contract stores this to block a second spend. It is one-way, so publishing it
/// proves the nullifier was known without revealing it, and it is unlinkable to the
/// leaf because the leaf mixes in `secret`.
template NullifierHash() {
    signal input nullifier;
    signal output out;

    component h = Poseidon(2);
    h.inputs[0] <== nullifier;
    h.inputs[1] <== NULLIFIER_DOMAIN();

    out <== h.out;
}

/// Constrain `outcome` to a real betting side: 1 (YES) or 2 (NO), never 0.
///
/// `(outcome - 1) * (outcome - 2) === 0` is the whole check -- a degree-2 constraint
/// with exactly two roots. Cheaper and tighter than a range check, which would also
/// admit 0 and 3.
template IsBettableOutcome() {
    signal input outcome;
    (outcome - 1) * (outcome - 2) === 0;
}
