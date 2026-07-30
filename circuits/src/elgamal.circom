pragma circom 2.1.9;

include "escalarmulfix.circom";
include "escalarmulany.circom";
include "babyjub.circom";
include "bitify.circom";

/// Exponential ("additive") ElGamal encryption on BabyJubJub.
///
///   C1 = [r]G
///   C2 = [m]G + [r]H
///
/// Written additively; the reference states the same scheme multiplicatively as
/// `(g^r, H^r * g^m)`. Identical construction, different notation.
///
/// The property the whole protocol leans on: ciphertexts add.
///   Enc(m1) + Enc(m2) = ([r1+r2]G, [m1+m2]G + [r1+r2]H) = Enc(m1+m2)
/// so the accumulator contract can total the pool with two point additions and
/// never a decryption. It is ONLY addition -- no comparison, no multiplication --
/// which is precisely why the market mechanism must be parimutuel.
///
/// Curve choice is forced, not preferred: this encryption has to be proved correct
/// *inside* a BN254 circuit, which requires the curve's base field to equal the
/// proof system's scalar field. BabyJubJub is the curve where that holds. Moving
/// the verifier to BLS12-381 (measured 4.97x cheaper per verify) would break the
/// alignment and force non-native field arithmetic in-circuit.
///
/// @param AMOUNT_BITS  range bound on the plaintext. Not cosmetic: the publisher
///        recovers the pool total from [total]G by baby-step giant-step, which is
///        only tractable for bounded plaintexts. This bounds each addend so the
///        aggregate stays inside BSGS range.
template ElGamalEncrypt(AMOUNT_BITS) {
    signal input amount;      // m -- private
    signal input randomness;  // r -- private
    signal input pubKey[2];   // H -- the committee/decryption public key

    signal output c1[2];
    signal output c2[2];

    var BASE8[2] = [
        5299619240641551281634865583518297030282874472190772894086521144482721001553,
        16950150798460657717958625567821834550301663161624707787222815936182638968203
    ];

    // H must actually be on the curve. Without this, a prover could supply a
    // bogus "key" whose discrete log they know and encrypt to themselves.
    component keyCheck = BabyCheck();
    keyCheck.x <== pubKey[0];
    keyCheck.y <== pubKey[1];

    // Range-constrains m: Num2Bits is what enforces amount < 2^AMOUNT_BITS.
    component amountBits = Num2Bits(AMOUNT_BITS);
    amountBits.in <== amount;

    // r < 2^251. The BabyJubJub subgroup order l is approximately 2^251.09, so
    // 2^251 < l and every representable r is a valid, in-range scalar.
    component rBits = Num2Bits(251);
    rBits.in <== randomness;

    // ---- C1 = [r]G ----
    component rG = EscalarMulFix(251, BASE8);
    for (var i = 0; i < 251; i++) {
        rG.e[i] <== rBits.out[i];
    }
    c1[0] <== rG.out[0];
    c1[1] <== rG.out[1];

    // ---- [m]G ----
    component mG = EscalarMulFix(AMOUNT_BITS, BASE8);
    for (var i = 0; i < AMOUNT_BITS; i++) {
        mG.e[i] <== amountBits.out[i];
    }

    // ---- [r]H ----
    component rH = EscalarMulAny(251);
    for (var i = 0; i < 251; i++) {
        rH.e[i] <== rBits.out[i];
    }
    rH.p[0] <== pubKey[0];
    rH.p[1] <== pubKey[1];

    // ---- C2 = [m]G + [r]H ----
    // BabyAdd is the complete twisted-Edwards addition law, so it stays correct
    // when either operand is the identity (notably m = 0).
    component add = BabyAdd();
    add.x1 <== mG.out[0];
    add.y1 <== mG.out[1];
    add.x2 <== rH.out[0];
    add.y2 <== rH.out[1];
    c2[0] <== add.xout;
    c2[1] <== add.yout;
}
