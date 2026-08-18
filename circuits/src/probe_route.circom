pragma circom 2.1.9;

include "comparators.circom";
include "bitify.circom";

/// ============================================================================
/// PROBE -- how expensive is proving a sealed batch routes to price levels?
/// ============================================================================
///
/// `V2_CIRCUIT_SPEC.md` §3 identifies this as V2's largest unknown. The price-grid
/// clearing design needs an order added to `levels[side][limitPrice]`, but those are
/// mapping keys, so a contract doing the routing would have to be told side and limit --
/// which is exactly what the sealed order hides.
///
/// The escape is to route OFF-CHAIN and prove it. A solver takes N committed orders and
/// produces L per-level totals, proving each order landed in the level its own private
/// limit specifies, without opening any order.
///
/// This measures the routing argument alone. It is deliberately NOT the finished circuit:
///
///   - Order commitments are not opened here (that is N Poseidon(2), ~240 constraints each,
///     and is a known separable cost -- see the report).
///   - Level totals are outputs, not packed or hashed. Public-signal layout is a separate
///     problem with its own gas budget.
///
/// What it does measure is the part nobody has a number for: the selector logic that makes
/// routing sound. If THAT is affordable, the design survives; if it is not, no amount of
/// packing saves it.
///
/// WHY THIS IS NOT A SORTING NETWORK
///
/// Clearing was originally assumed to need the batch sorted in-circuit, at roughly
/// N log^2 N. It does not. Routing to a fixed grid is a decode-and-accumulate, and the
/// price levels are the fixed structure that sorting would otherwise have to discover.
///
/// @param N  orders per batch
/// @param L  price levels
template Route(N, L) {
    // ---- PRIVATE: the sealed order contents ----
    signal input limit[N];   // price level index, 0..L-1
    signal input size[N];    // size at that level
    signal input side[N];    // 0 = ask, 1 = bid

    // ---- OUTPUT: per-level totals, one array per side ----
    signal output bidTotal[L];
    signal output askTotal[L];

    // Bits needed to address L levels. Range-constraining `limit` is not optional: an
    // out-of-range limit would match no level, and its size would silently vanish from
    // every total -- an order that is provably in the batch yet absent from clearing.
    var LIMIT_BITS = 0;
    var span = 1;
    while (span < L) {
        span = span * 2;
        LIMIT_BITS = LIMIT_BITS + 1;
    }

    component limitBits[N];
    component sideBool[N];

    // one-hot[i][j] = 1 exactly when order i's limit is level j.
    component isLevel[N][L];

    // Per (order, level) contribution, split by side. Two multiplications each: one to
    // select the level, one to select the side.
    signal bidPart[N][L];
    signal askPart[N][L];
    signal sized[N][L];

    for (var i = 0; i < N; i++) {
        limitBits[i] = Num2Bits(LIMIT_BITS);
        limitBits[i].in <== limit[i];

        // `side` must be boolean or an order could contribute to both books at once, or to
        // neither. `side * (side - 1) === 0` is the whole check.
        side[i] * (side[i] - 1) === 0;

        for (var j = 0; j < L; j++) {
            isLevel[i][j] = IsEqual();
            isLevel[i][j].in[0] <== limit[i];
            isLevel[i][j].in[1] <== j;

            // Quadratic constraints must be split -- circom allows one multiplication per
            // constraint, so `size * isLevel * side` is two signals, not one expression.
            sized[i][j] <== size[i] * isLevel[i][j].out;
            bidPart[i][j] <== sized[i][j] * side[i];
            askPart[i][j] <== sized[i][j] - bidPart[i][j];
        }
    }

    // Accumulate. Addition is linear and nearly free; the cost above is the selectors.
    var bidAcc[L];
    var askAcc[L];
    for (var j = 0; j < L; j++) {
        bidAcc[j] = 0;
        askAcc[j] = 0;
    }
    for (var i = 0; i < N; i++) {
        for (var j = 0; j < L; j++) {
            bidAcc[j] += bidPart[i][j];
            askAcc[j] += askPart[i][j];
        }
    }
    for (var j = 0; j < L; j++) {
        bidTotal[j] <== bidAcc[j];
        askTotal[j] <== askAcc[j];
    }
}
