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
