// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console, stdJson} from "forge-std/Test.sol";
import {BabyJubJub} from "../src/BabyJubJub.sol";

/// @notice The correctness corpus that guards every optimisation of the curve arithmetic.
///
/// @dev 155 vectors from circomlibjs: boundary scalars (0, 1, 2, 3, L-1, L), adversarial
///      bit patterns (single high bit, 250 consecutive ones, alternating, powers of two),
///      the identity as both operand and result, and 44 random cases.
///
///      Sized for optimisation rather than for a first implementation. Windowed ladders,
///      interleaved multi-scalar multiplication and flattened coordinates all fail on
///      narrow inputs -- a specific bit pattern, the identity appearing mid-ladder, the top
///      of the scalar range. A handful of random vectors misses exactly those.
///
///      This suite must pass BEFORE and AFTER any change to `BabyJubJub`.
contract CurveVectorsTest is Test {
    using stdJson for string;

    string fx;
    uint256 scalarCount;
    uint256 jointCount;

    function setUp() public {
        fx = vm.readFile("../circuits/build/curve-vectors.json");
        scalarCount = fx.readUint(".scalarMulCount");
        jointCount = fx.readUint(".doubleScalarMulCount");
    }

    function _u(string memory k) internal view returns (uint256) {
        return fx.readUint(k);
    }

    function test_constantsMatchCircomlib() public view {
        assertEq(BabyJubJub.L, _u(".L"), "subgroup order diverged");
        assertEq(BabyJubJub.BASE8X, _u(".base8[0]"), "base point x diverged");
        assertEq(BabyJubJub.BASE8Y, _u(".base8[1]"), "base point y diverged");
    }

    /// @notice Every scalar-multiplication vector must match circomlibjs exactly.
    function test_scalarMulAgainstFullCorpus() public view {
        assertGt(scalarCount, 100, "corpus is smaller than expected -- did it regenerate?");

        for (uint256 i = 0; i < scalarCount; i++) {
            string memory b = string.concat(".scalarMul[", vm.toString(i), "]");

            BabyJubJub.Point memory p =
                BabyJubJub.fromAffine(_u(string.concat(b, ".point[0]")), _u(string.concat(b, ".point[1]")));
            uint256 k = _u(string.concat(b, ".k"));

            (uint256 x, uint256 y) = BabyJubJub.toAffine(BabyJubJub.scalarMulPublic(p, k));

            assertEq(x, _u(string.concat(b, ".expected[0]")), string.concat("x mismatch, vector ", vm.toString(i)));
            assertEq(y, _u(string.concat(b, ".expected[1]")), string.concat("y mismatch, vector ", vm.toString(i)));
        }
    }

    /// @notice `[a]P + [b]Q` -- the shape Chaum-Pedersen verifies.
    /// @dev Interleaved ladders have failure modes single-scalar ones do not: joint bit
    ///      patterns where one scalar's bit is set and the other's is not, and the
    ///      cancellation case where the result is the identity.
    function test_doubleScalarMulAgainstFullCorpus() public view {
        assertGt(jointCount, 15, "joint corpus is smaller than expected");

        for (uint256 i = 0; i < jointCount; i++) {
            string memory b = string.concat(".doubleScalarMul[", vm.toString(i), "]");

            BabyJubJub.Point memory p =
                BabyJubJub.fromAffine(_u(string.concat(b, ".p[0]")), _u(string.concat(b, ".p[1]")));
            BabyJubJub.Point memory q =
                BabyJubJub.fromAffine(_u(string.concat(b, ".q[0]")), _u(string.concat(b, ".q[1]")));

            (uint256 x, uint256 y) = BabyJubJub.toAffine(
                BabyJubJub.doubleScalarMulPublic(p, _u(string.concat(b, ".a")), q, _u(string.concat(b, ".b")))
            );

            assertEq(x, _u(string.concat(b, ".expected[0]")), string.concat("x mismatch, joint ", vm.toString(i)));
            assertEq(y, _u(string.concat(b, ".expected[1]")), string.concat("y mismatch, joint ", vm.toString(i)));
        }
    }

    /// @notice Scalars must reduce mod L, so `[k]P == [k mod L]P`.
    /// @dev A ladder that runs a fixed 252 iterations over an unreduced scalar silently
    ///      computes the wrong point. The corpus includes `k = L` for exactly this.
    function test_scalarsReduceModL() public view {
        BabyJubJub.Point memory g = BabyJubJub.fromAffine(BabyJubJub.BASE8X, BabyJubJub.BASE8Y);

        (uint256 x1, uint256 y1) = BabyJubJub.toAffine(BabyJubJub.scalarMulPublic(g, BabyJubJub.L));
        assertEq(x1, 0, "[L]G must be the identity");
        assertEq(y1, 1, "[L]G must be the identity");

        (uint256 x2, uint256 y2) = BabyJubJub.toAffine(BabyJubJub.scalarMulPublic(g, BabyJubJub.L + 1));
        assertEq(x2, BabyJubJub.BASE8X, "[L+1]G must equal G");
        assertEq(y2, BabyJubJub.BASE8Y, "[L+1]G must equal G");
    }

    function test_report_gas() public view {
        BabyJubJub.Point memory g = BabyJubJub.fromAffine(BabyJubJub.BASE8X, BabyJubJub.BASE8Y);
        BabyJubJub.Point memory q = BabyJubJub.scalarMulPublic(g, 12345);
        uint256 k = BabyJubJub.L - 1; // worst case: nearly every bit set

        uint256 s = gasleft();
        BabyJubJub.scalarMulPublic(g, k);
        uint256 single = s - gasleft();

        s = gasleft();
        BabyJubJub.doubleScalarMulPublic(g, k, q, k);
        uint256 joint = s - gasleft();

        console.log("=== BabyJubJub gas (worst-case scalar, L-1) ===");
        console.log("scalarMulPublic       :", single);
        console.log("doubleScalarMulPublic :", joint);
        console.log("  vs 2 separate mults :", single * 2);
    }
}
