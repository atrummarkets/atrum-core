pragma circom 2.1.9;
include "poseidon.circom";

/// PROBE -- verify gas for a NINE public-signal Groth16 verifier.
///
/// MEASUREMENTS.md 1e measures 8 signals at 1,152,559 warm / 1,162,809 cold, and 30,756
/// per additional signal, confirmed three times independently (3->4, 4->6, 4->8). A
/// 9-signal figure has been DERIVED from that but never measured, and the sealed order
/// needs 9 to carry feeCommitment.
///
/// Verify cost depends only on the public-signal count, not circuit size -- MEASUREMENTS.md
/// 1 proves this (`bet` at 14,194 constraints costs exactly what a 6,834-constraint probe
/// costs). So a minimal circuit with 9 public signals measures the real thing.
template Sig9() {
    signal input a[9];   // public
    signal input w;      // private

    component h = Poseidon(2);
    h.inputs[0] <== a[0];
    h.inputs[1] <== w;

    signal bind[8];
    bind[0] <== h.out * a[1];
    for (var i = 1; i < 8; i++) {
        bind[i] <== bind[i - 1] * a[i + 1];
    }
}
component main {public [a]} = Sig9();
