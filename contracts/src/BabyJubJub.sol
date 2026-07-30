// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title BabyJubJub
/// @notice Twisted Edwards curve arithmetic for the homomorphic pool accumulator.
///
/// @dev WHY THIS IS HAND-WRITTEN AND NOT A PRECOMPILE
///
///      `nisi-master-reference.md` §1.3 lists "BN254 via `ecAdd` precompile, affine,
///      4 slots -- 600 gas" as an accumulator option. **That option does not exist for
///      this design.** The `ecAdd` precompile at 0x06 operates on alt_bn128 G1, a short
///      Weierstrass curve `y^2 = x^3 + 3` over the BN254 *base* field. BabyJubJub is a
///      twisted Edwards curve over the BN254 *scalar* field. Different curve, different
///      field -- the precompile cannot touch these points.
///
///      The curve is not interchangeable either. ElGamal has to be proved correct
///      *inside* a BN254 circuit, which requires the encryption curve's base field to
///      equal the proof system's scalar field. BabyJubJub is where that holds. So the
///      accumulator pays for Solidity `mulmod`/`addmod` and there is no shortcut.
///
///      Curve: `a * x^2 + y^2 = 1 + d * x^2 * y^2` over F_r, matching circomlib.
library BabyJubJub {
    /// @notice BN254 scalar field = BabyJubJub base field.
    uint256 internal constant Q = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice circomlib's canonical order-8 base point.
    uint256 internal constant BASE8X = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
    uint256 internal constant BASE8Y = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

    uint256 internal constant A = 168700;
    uint256 internal constant D = 168696;

    /// @notice A point in extended twisted Edwards coordinates.
    /// @dev `x = X/Z`, `y = Y/Z`, `T = X*Y/Z`. Extended coordinates exist so addition
    ///      needs no modular inversion: inverting costs a `modexp` call, and on the hot
    ///      path that is paid per bet.
    struct Point {
        uint256 x;
        uint256 y;
        uint256 t;
        uint256 z;
    }

    /// @notice The neutral element, `(0, 1)` in affine terms.
    function identity() internal pure returns (Point memory) {
        return Point(0, 1, 0, 1);
    }

    /// @notice Extended-coordinate addition (Hisil-Wong-Carter-Dawson 2008, `add-2008-hwcd`).
    ///
    /// @dev Complete for twisted Edwards with `a != d`, so it needs no special-casing for
    ///      the identity or for doubling -- which matters because the accumulator adds a
    ///      caller-supplied ciphertext and must not have an input that behaves specially.
    ///
    ///      9 `mulmod` plus a handful of `addmod`. Every intermediate stays reduced mod Q.
    function add(Point memory p1, Point memory p2) internal pure returns (Point memory p3) {
        uint256 a = mulmod(p1.x, p2.x, Q);
        uint256 b = mulmod(p1.y, p2.y, Q);
        uint256 c = mulmod(mulmod(D, p1.t, Q), p2.t, Q);
        uint256 d = mulmod(p1.z, p2.z, Q);

        // e = (x1 + y1) * (x2 + y2) - a - b
        uint256 e = mulmod(addmod(p1.x, p1.y, Q), addmod(p2.x, p2.y, Q), Q);
        e = addmod(e, Q - a % Q, Q);
        e = addmod(e, Q - b % Q, Q);

        uint256 f = addmod(d, Q - c % Q, Q);
        uint256 g = addmod(d, c, Q);
        // h = b - a*A
        uint256 h = addmod(b, Q - mulmod(A, a, Q), Q);

        p3.x = mulmod(e, f, Q);
        p3.y = mulmod(g, h, Q);
        p3.t = mulmod(e, h, Q);
        p3.z = mulmod(f, g, Q);
    }

    /// @notice Convert an affine point to extended coordinates.
    /// @dev Callers supply ciphertexts in affine form, because that is what the circuit
    ///      emits and what a 2-slot storage layout would hold.
    function fromAffine(uint256 x, uint256 y) internal pure returns (Point memory) {
        return Point(x, y, mulmod(x, y, Q), 1);
    }

    /// @notice Project back to affine. Costs one modular inversion.
    /// @dev Only for reads and for the affine storage variant -- never on the extended
    ///      accumulator's hot path.
    function toAffine(Point memory p) internal view returns (uint256 x, uint256 y) {
        uint256 zInv = inverse(p.z);
        x = mulmod(p.x, zInv, Q);
        y = mulmod(p.y, zInv, Q);
    }

    /// @notice `v^(Q-2) mod Q`, i.e. the multiplicative inverse, via the modexp precompile.
    /// @dev Measured at 4,048 gas on Monad (MEASUREMENTS.md §3) -- notably cheaper than
    ///      the reference's 4,712, and cheap enough that the affine storage variant is
    ///      worth measuring rather than dismissing. See `ElGamalAccumulator`.
    function inverse(uint256 v) internal view returns (uint256 result) {
        uint256 q = Q;
        assembly {
            let p := mload(0x40)
            mstore(p, 0x20) // base length
            mstore(add(p, 0x20), 0x20) // exponent length
            mstore(add(p, 0x40), 0x20) // modulus length
            mstore(add(p, 0x60), v)
            mstore(add(p, 0x80), sub(q, 2))
            mstore(add(p, 0xa0), q)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            result := mload(p)
        }
    }

    /// @notice BabyJubJub prime-order subgroup order. Scalars live mod L.
    uint256 internal constant L = 2736030358979909402780800718157159386076813972158567259200215660948447373041;

    /// @dev `dst += src` in place, same HWCD formula as `add`, but with no per-operation
    ///      allocation.
    ///
    ///      This is where the gas was. The struct form allocates a fresh 4-word `Point` per
    ///      operation and a ladder performs ~500 of them -- measured at ~1,200 gas per point
    ///      operation against roughly 110 gas of actual field arithmetic, i.e. ~90%
    ///      allocation overhead. Both arrays here are allocated once by the caller.
    ///
    ///      Takes two array pointers rather than twelve stack values: eight parameters plus
    ///      four returns plus eight intermediates exceeds the EVM stack under non-IR
    ///      codegen, and `via_ir` is deliberately off in this repo because enabling it would
    ///      change every gas figure in MEASUREMENTS.md.
    ///
    ///      ALIASING: `src` may be `dst` -- that is how doubling is done. Every read of both
    ///      arrays completes before the first write, so the aliased case is correct. Do not
    ///      reorder the assignments above the reads. The corpus covers this directly with
    ///      power-of-two scalars, which exercise the doubling path and nothing else.
    function _addAssign(uint256[4] memory dst, uint256[4] memory src) private pure {
        // Yul, because the cost here is Solidity's stack management -- not the arithmetic
        // and not the function call. Measured decomposition: `mulmod` and `addmod` are 10
        // gas each on Monad (identical to Ethereum -- NOT repriced, verified in
        // ArithRepricing.t.sol), so the sixteen operations below are ~160 gas. A Solidity
        // implementation of the same formula measured ~1,300, because eight-plus live
        // 256-bit intermediates exceed what the non-IR stack allocator keeps in registers
        // and the remainder spills to memory. An inline-Solidity version measured WORSE
        // than the function-call version for exactly that reason.
        //
        // The scoping below is deliberate: operands are read and released in an order that
        // keeps the live set small (peak ~7 values), which is what avoids the spills.
        //
        // `sub(q, v)` is unchecked negation mod q. Every `v` here is a `mulmod` result and
        // therefore already < q, so it cannot underflow. Note `sub(q, 0) == q` and
        // `addmod(x, q, q) == x`, so the zero case is still correct.
        assembly {
            let q := 21888242871839275222246405745257275088548364400416034343698204186575808495617
            let e
            let h

            {
                let x1 := mload(dst)
                let y1 := mload(add(dst, 0x20))
                let x2 := mload(src)
                let y2 := mload(add(src, 0x20))

                let a := mulmod(x1, x2, q)
                let b := mulmod(y1, y2, q)

                e := mulmod(addmod(x1, y1, q), addmod(x2, y2, q), q)
                e := addmod(addmod(e, sub(q, a), q), sub(q, b), q)

                h := addmod(b, sub(q, mulmod(168700, a, q)), q)
            }

            let f
            let g
            {
                let c := mulmod(mulmod(168696, mload(add(dst, 0x40)), q), mload(add(src, 0x40)), q)
                let d := mulmod(mload(add(dst, 0x60)), mload(add(src, 0x60)), q)
                f := addmod(d, sub(q, c), q)
                g := addmod(d, c, q)
            }

            // Every read of dst and src is complete before this point, so aliasing
            // (src == dst, which is how doubling is done) is safe.
            mstore(dst, mulmod(e, f, q))
            mstore(add(dst, 0x20), mulmod(g, h, q))
            mstore(add(dst, 0x40), mulmod(e, h, q))
            mstore(add(dst, 0x60), mulmod(f, g, q))
        }
    }

    /// @notice `[k]P`, for a scalar that is PUBLIC.
    ///
    /// @dev THE NAME IS THE WARNING. This is a plain double-and-add ladder: the additions
    ///      it performs depend on the bits of `k`, so gas consumption and trace shape leak
    ///      the scalar. That is fine for its only current caller -- Chaum-Pedersen
    ///      verification operates entirely on published proof data, where there is no
    ///      secret to leak and a constant-time ladder would be paying gas to defend against
    ///      nothing.
    ///
    ///      It is NOT fine for a secret scalar. If a future caller needs `[secret]P`
    ///      on-chain, this function is the wrong one and a constant-time ladder is required.
    ///      The `Public` suffix exists so that misuse has to be typed out explicitly rather
    ///      than reached by accident.
    ///
    ///      `k` is reduced mod L first: an unreduced scalar would otherwise run past the
    ///      252-bit loop bound and silently compute the wrong point.
    function scalarMulPublic(Point memory p, uint256 k) internal pure returns (Point memory r) {
        k = k % L;

        // Accumulator starts at the identity (0, 1, 0, 1). Both live in memory arrays
        // allocated once and mutated in place -- see `doubleScalarMulPublic` for why.
        uint256[4] memory acc = [uint256(0), uint256(1), uint256(0), uint256(1)];
        uint256[4] memory cur = [p.x, p.y, p.t, p.z];

        // 252 bits covers L (~2^251.1).
        for (uint256 i = 0; i < 252; i++) {
            if ((k >> i) & 1 == 1) _addAssign(acc, cur);
            _addAssign(cur, cur);
        }

        r = Point(acc[0], acc[1], acc[2], acc[3]);
    }

    /// @notice `[a]P + [b]Q` in one interleaved ladder (Straus), for PUBLIC scalars.
    ///
    /// @dev Chaum-Pedersen verifies two equations of exactly this shape, so computing each
    ///      jointly halves the doublings: one shared ladder instead of two.
    ///
    ///      Working state lives in `uint256[4]` memory arrays allocated ONCE and mutated in
    ///      place, rather than flat stack locals. Twelve simultaneous locals exceeds the
    ///      EVM stack under non-IR codegen, and `via_ir` is deliberately off in this repo
    ///      because enabling it would change every gas figure in MEASUREMENTS.md. In-place
    ///      arrays recover the point that mattered anyway -- the cost was never memory, it
    ///      was allocating a fresh 4-word struct per point operation, ~500 times per ladder.
    ///
    ///      Same public-scalar caveat as `scalarMulPublic`, for the same reason and with the
    ///      same suffix.
    function doubleScalarMulPublic(Point memory p, uint256 a, Point memory q, uint256 b)
        internal
        pure
        returns (Point memory r)
    {
        a = a % L;
        b = b % L;

        uint256[4] memory acc = [uint256(0), uint256(1), uint256(0), uint256(1)];
        uint256[4] memory pp = [p.x, p.y, p.t, p.z];
        uint256[4] memory qq = [q.x, q.y, q.t, q.z];

        for (uint256 i = 0; i < 252; i++) {
            if ((a >> i) & 1 == 1) _addAssign(acc, pp);
            if ((b >> i) & 1 == 1) _addAssign(acc, qq);
            _addAssign(pp, pp);
            _addAssign(qq, qq);
        }

        r = Point(acc[0], acc[1], acc[2], acc[3]);
    }

    /// @notice `-P`. On a twisted Edwards curve negation is `(x, y) -> (-x, y)`.
    /// @dev Free, which is what lets `A + [e]H == [z]G` be rearranged into a single
    ///      interleaved ladder: `[z]G + [e](-H) == A`.
    function negate(Point memory p) internal pure returns (Point memory) {
        return Point(p.x == 0 ? 0 : Q - p.x, p.y, p.t == 0 ? 0 : Q - p.t, p.z);
    }

    /// @notice Is `(x, y)` actually on the curve?
    /// @dev The accumulator must reject off-curve input. An off-curve "ciphertext" is not
    ///      a group element, so adding it corrupts the running total in a way no
    ///      decryption can undo, and the whole pool becomes unrecoverable.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= Q || y >= Q) return false;

        uint256 x2 = mulmod(x, x, Q);
        uint256 y2 = mulmod(y, y, Q);

        // a*x^2 + y^2 == 1 + d*x^2*y^2
        uint256 lhs = addmod(mulmod(A, x2, Q), y2, Q);
        uint256 rhs = addmod(1, mulmod(mulmod(D, x2, Q), y2, Q), Q);
        return lhs == rhs;
    }
}
