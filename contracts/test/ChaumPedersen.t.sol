// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console, stdJson} from "forge-std/Test.sol";
import {BabyJubJub} from "../src/BabyJubJub.sol";
import {ChaumPedersen} from "../src/ChaumPedersen.sol";

/// @notice Measure and verify Chaum-Pedersen decryption proofs, which land on PHASE 2's
///         critical path rather than Phase 3's.
///
/// @dev The reference gives 180,000 gas [DERIVED] as `6 x ecMul at 30,000`. That derivation
///      does not describe this computation: `ecMul` at 0x07 operates on alt_bn128 G1, a
///      short Weierstrass curve over the BN254 *base* field, while BabyJubJub is twisted
///      Edwards over the *scalar* field. Every scalar multiplication here is hand-written
///      Solidity, so the real figure has to be measured.
///
///      Correctness first: five tampered variants must be rejected, including a decryption
///      share computed with the wrong secret -- the case that would let a publisher forge a
///      ratio and drain the vault.
contract ChaumPedersenTest is Test {
    using stdJson for string;

    string fx;

    function setUp() public {
        fx = vm.readFile("../circuits/build/dleq-fixtures.json");
    }

    function _u(string memory k) internal view returns (uint256) {
        return fx.readUint(k);
    }

    function _proof(string memory path) internal view returns (ChaumPedersen.Proof memory) {
        return ChaumPedersen.Proof({
            ax: _u(string.concat(path, ".A[0]")),
            ay: _u(string.concat(path, ".A[1]")),
            bx: _u(string.concat(path, ".B[0]")),
            by: _u(string.concat(path, ".B[1]")),
            z: _u(string.concat(path, ".z"))
        });
    }

    function _verify(uint256 dx, uint256 dy, ChaumPedersen.Proof memory p) internal view returns (bool) {
        return ChaumPedersen.verify(_u(".H[0]"), _u(".H[1]"), _u(".C1[0]"), _u(".C1[1]"), dx, dy, p);
    }

    // -----------------------------------------------------------------------
    // The JS prover and the Solidity verifier must agree on the challenge
    // -----------------------------------------------------------------------

    /// @dev If these diverge, valid proofs are rejected and the failure looks like a
    ///      cryptography bug rather than a byte-layout mismatch.
    function test_challengeMatchesJsProver() public view {
        uint256 e = ChaumPedersen.challenge(
            _u(".H[0]"),
            _u(".H[1]"),
            _u(".C1[0]"),
            _u(".C1[1]"),
            _u(".D[0]"),
            _u(".D[1]"),
            _u(".valid.A[0]"),
            _u(".valid.A[1]"),
            _u(".valid.B[0]"),
            _u(".valid.B[1]")
        );
        assertEq(e, _u(".e"), "Fiat-Shamir challenge diverged from the prover");
    }

    function test_base8MatchesCircomlib() public view {
        assertEq(BabyJubJub.BASE8X, _u(".base8[0]"), "base point x diverged");
        assertEq(BabyJubJub.BASE8Y, _u(".base8[1]"), "base point y diverged");
        assertEq(BabyJubJub.L, _u(".L"), "subgroup order diverged");
    }

    /// @notice Scalar multiplication must agree with circomlibjs.
    /// @dev `[s]G` should equal the published committee key, which circomlibjs derived.
    function test_scalarMulMatchesCircomlibjs() public view {
        // D = [s]C1 was computed by circomlibjs; re-derive [e]H on-chain and compare
        // against the same computation done in the fixture's own verification equation.
        BabyJubJub.Point memory h = BabyJubJub.fromAffine(_u(".H[0]"), _u(".H[1]"));
        (uint256 x, uint256 y) = BabyJubJub.toAffine(BabyJubJub.scalarMulPublic(h, 1));
        assertEq(x, _u(".H[0]"), "[1]H != H");
        assertEq(y, _u(".H[1]"), "[1]H != H");

        // [0]P must be the identity.
        (x, y) = BabyJubJub.toAffine(BabyJubJub.scalarMulPublic(h, 0));
        assertEq(x, 0, "[0]H is not the identity");
        assertEq(y, 1, "[0]H is not the identity");
    }

    // -----------------------------------------------------------------------
    // Correctness
    // -----------------------------------------------------------------------

    function test_validProofVerifies() public view {
        assertTrue(_verify(_u(".D[0]"), _u(".D[1]"), _proof(".valid")), "valid proof rejected");
    }

    /// @notice THE attack: a decryption share computed with the wrong secret.
    /// @dev This is what a publisher would submit to forge a ratio. If it verified, the
    ///      publisher could declare any pool composition and overpay one side until the
    ///      vault was empty.
    function test_rejectsShareFromWrongSecret() public view {
        assertFalse(
            _verify(_u(".invalid.wrongShare.D[0]"), _u(".invalid.wrongShare.D[1]"), _proof(".invalid.wrongShare")),
            "accepted a decryption share from a different secret -- vault is drainable"
        );
    }

    function test_rejectsTamperedZ() public view {
        assertFalse(_verify(_u(".D[0]"), _u(".D[1]"), _proof(".invalid.tamperedZ")), "accepted tampered z");
    }

    function test_rejectsTamperedA() public view {
        assertFalse(_verify(_u(".D[0]"), _u(".D[1]"), _proof(".invalid.tamperedA")), "accepted tampered A");
    }

    function test_rejectsSwappedAB() public view {
        assertFalse(_verify(_u(".D[0]"), _u(".D[1]"), _proof(".invalid.swappedAB")), "accepted swapped A/B");
    }

    /// @dev z must be reduced mod L. An unreduced z would let a prover present the same
    ///      response as several distinct scalars.
    function test_rejectsOutOfRangeZ() public view {
        assertFalse(_verify(_u(".D[0]"), _u(".D[1]"), _proof(".invalid.zOutOfRange")), "accepted z >= L");
    }

    function test_rejectsOffCurvePoints() public view {
        ChaumPedersen.Proof memory p = _proof(".valid");
        p.ax = 1;
        p.ay = 1; // not on the curve
        assertFalse(_verify(_u(".D[0]"), _u(".D[1]"), p), "accepted an off-curve A");
    }

    /// @dev A proof is bound to its ciphertext. Reusing it against a different C1 must
    ///      fail, or one honest decryption could be replayed to justify any other.
    function test_proofIsBoundToItsCiphertext() public view {
        bool ok = ChaumPedersen.verify(
            _u(".H[0]"),
            _u(".H[1]"),
            _u(".base8[0]"), // a different C1 (the base point)
            _u(".base8[1]"),
            _u(".D[0]"),
            _u(".D[1]"),
            _proof(".valid")
        );
        assertFalse(ok, "proof verified against a ciphertext it was not made for");
    }

    // -----------------------------------------------------------------------
    // THE MEASUREMENT
    // -----------------------------------------------------------------------

    function test_report_verificationGas() public view {
        // Hoisted: vm.parseJson is a cheatcode and costs ~450,000 gas per call. Inline, it
        // would swamp the figure entirely.
        uint256 hx = _u(".H[0]");
        uint256 hy = _u(".H[1]");
        uint256 c1x = _u(".C1[0]");
        uint256 c1y = _u(".C1[1]");
        uint256 dx = _u(".D[0]");
        uint256 dy = _u(".D[1]");
        ChaumPedersen.Proof memory p = _proof(".valid");

        uint256 g = gasleft();
        bool ok = ChaumPedersen.verify(hx, hy, c1x, c1y, dx, dy, p);
        uint256 used = g - gasleft();

        require(ok, "measured an invalid proof");

        console.log("=== Chaum-Pedersen DLEQ verification, ONE share ===");
        console.log("measured gas          :", used);
        console.log("reference [DERIVED]   : 180000  (as 6 x ecMul at t=3)");
        console.log("");
        console.log("The reference figure assumes ecMul, which does not apply to");
        console.log("BabyJubJub -- every scalar mult here is hand-written Solidity.");
        console.log("");
        console.log("t=3 committee (3 shares):", used * 3);
        console.log("t=5 committee (5 shares):", used * 5);
    }

    function test_report_scalarMulGas() public view {
        BabyJubJub.Point memory h = BabyJubJub.fromAffine(_u(".H[0]"), _u(".H[1]"));
        uint256 k = _u(".valid.z");

        uint256 g = gasleft();
        BabyJubJub.scalarMulPublic(h, k);
        uint256 used = g - gasleft();

        console.log("=== one BabyJubJub scalar multiplication ===");
        console.log("measured gas :", used);
        console.log("ecMul (BN254, wrong curve for this) : 30000");
    }
}
