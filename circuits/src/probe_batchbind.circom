pragma circom 2.1.9;

include "merkle.circom";
include "poseidon.circom";

/// ============================================================================
/// PROBE -- how does the routing proof bind its N orders to the real batch?
/// ============================================================================
///
/// `V2_ROUTING_PROBE.md` measures the routing argument at 21,056 constraints for
/// N=64, L=20 and names this the only remaining item that could make the design
/// unaffordable. Two ways to bind, and a ~15x swing between them.
///
/// WHAT THE PROOF ACTUALLY HAS TO ESTABLISH
///
/// Not "these orders exist somewhere". Two things, and separating them is the whole
/// finding:
///
///   SOUNDNESS   -- every routed order is a real committed order. A solver must not be
///                  able to invent an order that moves the clearing price.
///   COMPLETENESS -- no committed order was left out. A solver must not be able to drop
///                  an order it dislikes, which is censorship and is worth money.
///
/// A per-order Merkle path gives soundness and NOT completeness -- proving 64 orders are
/// in the tree says nothing about a 65th that was also submitted. Completeness is what
/// actually matters here, and it is the cheaper property.
///
/// SPEND AUTHORITY IS A DIFFERENT QUESTION, ALREADY ANSWERED ELSEWHERE
///
/// Whether the order's owner was entitled to place it -- that their note exists and is
/// unspent -- is proven at ORDER time by the sealed-order circuit, which carries its own
/// Merkle path exactly as `bet_encrypted` does. By CLEARING time that is settled. The
/// routing proof re-proving global tree membership would be proving something already
/// proven, at N times the cost.

/// A: per-order membership in the global commitment tree. The expensive option, and the
///    one that turns out to be answering the wrong question.
template BindByPaths(N, levels) {
    signal input root;
    signal input leaf[N];
    signal input pathElements[N][levels];
    signal input pathIndices[N][levels];

    component tree[N];
    for (var i = 0; i < N; i++) {
        tree[i] = MerkleTreeChecker(levels);
        tree[i].leaf <== leaf[i];
        tree[i].root <== root;
        for (var j = 0; j < levels; j++) {
            tree[i].pathElements[j] <== pathElements[i][j];
            tree[i].pathIndices[j] <== pathIndices[i][j];
        }
    }
}

/// B: recompute the contract's running batch hash.
///
///    `ShieldedPool` folds each accepted order into `batchHash = Poseidon(batchHash,
///    orderCommitment)` as it arrives -- one on-chain Poseidon(2) at 28,980 gas
///    (MEASUREMENTS.md 1b), paid once per order. The routing proof replays the same fold
///    over the orders it claims to have routed and asserts it lands on the same value.
///
///    This gives BOTH properties at once, which paths do not. The chain is order-sensitive
///    and length-sensitive: dropping an order, adding one, or reordering produces a
///    different final hash. Completeness comes free with soundness because the contract's
///    own accumulator is the reference.
template BindByChain(N) {
    signal input batchHashIn;
    signal input batchHashOut;
    signal input leaf[N];

    component h[N];
    signal acc[N + 1];
    acc[0] <== batchHashIn;

    for (var i = 0; i < N; i++) {
        h[i] = Poseidon(2);
        h[i].inputs[0] <== acc[i];
        h[i].inputs[1] <== leaf[i];
        acc[i + 1] <== h[i].out;
    }

    batchHashOut === acc[N];
}
