pragma circom 2.1.9;

include "note.circom";
include "merkle.circom";
include "comparators.circom";

/// ============================================================================
/// PROBE -- what do the two fee fields cost, in constraints and public signals?
/// ============================================================================
///
/// `V2_CIRCUIT_SPEC.md` specifies a flat in-circuit relayer fee and a proportional
/// protocol fee paid as a second change note. Both were specified without being costed,
/// and both must be in the circuit set BEFORE the ceremony -- so their cost has to be
/// known before the sealed-order circuit is written around them.
///
/// This is `withdraw.circom` with the fee fields added and nothing else changed, so the
/// delta against that file's own constraint count is the honest answer.
///
/// Baseline, measured: withdraw = 6,997 non-linear / 7,411 linear / 4 public inputs.

/// The flat relayer fee. A compile-time constant, like NULLIFIER_DOMAIN(), so it costs no
/// public signal and leaks nothing -- every action pays the same amount, exactly as every
/// action declares the same 2,000,000 gas limit.
function RELAYER_FEE() { return 1000; }

template WithdrawWithFees(levels, AMOUNT_BITS) {
    // ---- PUBLIC ----
    signal input root;
    signal input nullifierHash;
    signal input changeCommitment;
    signal input withdrawData;
    /// The protocol's fee note. Reserved now, even with the rate at zero: adding a public
    /// signal after the ceremony means a new verification key and a second ceremony.
    signal input feeCommitment;

    // ---- PRIVATE ----
    signal input nullifier;
    signal input secret;
    signal input newNullifier;
    signal input newSecret;
    signal input marketId;
    signal input units;
    signal input recipient;
    signal input amount;
    signal input change;

    // ---- PRIVATE, new ----
    signal input relayerFee;
    signal input protocolFee;
    signal input protocolNullifier;
    signal input protocolSecret;

    signal input pathElements[levels];
    signal input pathIndices[levels];

    var SETTLED = 3;

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

    component tree = MerkleTreeChecker(levels);
    tree.leaf <== oldNote.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    component nh = NullifierHash();
    nh.nullifier <== nullifier;
    nullifierHash === nh.out;

    // CONSERVATION, extended. Every term range-constrained for the reason withdraw.circom
    // already gives: without Num2Bits a prover supplies a huge field element and its
    // negative complement, satisfying the sum while paying out more than the note holds.
    // An unconstrained protocolFee is a NEGATIVE fee, which is a mint.
    units === amount + change + relayerFee + protocolFee;

    component amountBits = Num2Bits(AMOUNT_BITS);
    amountBits.in <== amount;
    component changeBits = Num2Bits(AMOUNT_BITS);
    changeBits.in <== change;
    component relayerBits = Num2Bits(AMOUNT_BITS);
    relayerBits.in <== relayerFee;
    component protocolBits = Num2Bits(AMOUNT_BITS);
    protocolBits.in <== protocolFee;

    // The relayer fee is not the prover's choice.
    relayerFee === RELAYER_FEE();

    component amountZero = IsZero();
    amountZero.in <== amount;
    amountZero.out === 0;

    component changeNote = NoteCommitment();
    changeNote.nullifier <== newNullifier;
    changeNote.secret <== newSecret;
    changeNote.marketId <== marketId;
    changeNote.outcome <== outcomeSig;
    changeNote.units <== change;

    changeCommitment === changeNote.commitment;

    // The protocol's fee note. marketId 0 / outcome 0 is the liquid unbet-collateral shape
    // withdraw.circom already handles, so the protocol collects revenue through the ordinary
    // withdraw path with the ordinary anonymity set -- no privileged surface.
    component feeNote = NoteCommitment();
    feeNote.nullifier <== protocolNullifier;
    feeNote.secret <== protocolSecret;
    feeNote.marketId <== 0;
    feeNote.outcome <== 0;
    feeNote.units <== protocolFee;

    feeCommitment === feeNote.commitment;

    component recipientBits = Num2Bits(160);
    recipientBits.in <== recipient;

    withdrawData === marketZero.out * (1 << 200) + recipient * (1 << 40) + amount;

    signal diff;
    diff <== changeCommitment - oldNote.commitment;
    component isSame = IsZero();
    isSame.in <== diff;
    isSame.out === 0;
}

component main {public [root, nullifierHash, changeCommitment, withdrawData, feeCommitment]} =
    WithdrawWithFees(20, 40);
