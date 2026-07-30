pragma circom 2.1.9;

include "poseidon.circom";

/// Swap two field elements iff `s` is 1, proving the swap rather than assuming it.
///
/// This is where a naive Merkle circuit leaks or breaks. The path index bit decides
/// whether the current node is the left or right child, and it is a PRIVATE input --
/// so it cannot be branched on in circom, which has no runtime control flow. The
/// arithmetic below computes both orderings and selects between them with a single
/// multiplication, which is constant-shape regardless of the secret bit.
///
/// `s` MUST be constrained boolean by the caller. Without `s * (1 - s) === 0` a
/// malicious prover can pass s = 2 and produce an output pair that corresponds to no
/// real tree position, which forges membership.
template DualMux() {
    signal input in[2];
    signal input s;

    signal output out[2];

    s * (1 - s) === 0;

    out[0] <== (in[1] - in[0]) * s + in[0];
    out[1] <== (in[0] - in[1]) * s + in[1];
}

/// Prove `leaf` sits at the position described by `pathIndices` under `root`.
///
/// Mirrors `IncrementalMerkleTree.sol` exactly: Poseidon(2) per level, left child
/// first. If the two ever disagree -- a different arity, a different field, a
/// different sibling order -- proofs fail at verification time with no clue why, so
/// `scripts/prove.mjs` recomputes both sides independently rather than trusting them
/// to match.
template MerkleTreeChecker(levels) {
    signal input leaf;
    signal input root;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    component selectors[levels];
    component hashers[levels];

    for (var i = 0; i < levels; i++) {
        selectors[i] = DualMux();
        selectors[i].in[0] <== i == 0 ? leaf : hashers[i - 1].out;
        selectors[i].in[1] <== pathElements[i];
        selectors[i].s <== pathIndices[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== selectors[i].out[0];
        hashers[i].inputs[1] <== selectors[i].out[1];
    }

    root === hashers[levels - 1].out;
}
