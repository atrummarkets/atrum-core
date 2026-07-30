// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BabyJubJub} from "./BabyJubJub.sol";

/// @title ChaumPedersen
/// @notice Verifies that an ElGamal decryption was performed with the committee's actual
///         key -- a proof of discrete-log equality.
///
/// @dev WHY THIS IS PHASE 2, NOT PHASE 3
///
///      `nisi-master-reference.md` §V6 lists decryption proofs as "REQUIRED once the
///      committee is t-of-n", i.e. Phase 3. That is mis-phased.
///
///      The moment payouts derive from a decrypted value, whoever publishes that value can
///      drain the vault: publish a ratio favouring one side and its holders are overpaid,
///      and nothing on-chain can detect it, because checking a ratio against a ciphertext
///      IS this proof. Phase 1 had no such exposure -- the contract computed payouts from
///      its own plaintext totals, so the publisher could not lie about them. Encrypting
///      the pool is what creates the hole.
///
///      So this is required as soon as the pool goes dark, even with a single key. Without
///      it, "single decryption key, disclosed plainly" is not a privacy caveat -- it is
///      unilateral authority over everyone's collateral.
///
///      THE PROTOCOL
///
///      Public: G (base), H = [s]G (committee key), C1 (ciphertext), D = [s]C1 (the
///      decryption share). The prover shows `log_G(H) == log_C1(D)` without revealing s:
///
///        pick k,  A = [k]G,  B = [k]C1
///        e = H(G, H, C1, D, A, B)          -- Fiat-Shamir
///        z = k + e*s   (mod L)
///
///      Verify:  [z]G == A + [e]H     and     [z]C1 == B + [e]D
///
///      Four scalar multiplications and two additions. On BabyJubJub every one of those is
///      hand-written Solidity: `ecMul` at 0x07 operates on alt_bn128 G1, a different curve
///      over a different field, so the reference's "6 x ecMul = 180,000" does not describe
///      this computation at all.
///
///      keccak for the challenge rather than Poseidon: the proof is never verified inside a
///      circuit, so it does not need to be ZK-friendly, and Poseidon would cost 28,980 gas
///      per invocation against ~30 here.
library ChaumPedersen {
    struct Proof {
        uint256 ax;
        uint256 ay; // A = [k]G
        uint256 bx;
        uint256 by; // B = [k]C1
        uint256 z; // z = k + e*s mod L
    }

    /// @notice Recompute the Fiat-Shamir challenge. Must match the prover exactly.
    /// @dev Every public value binds into the hash. Omitting any one of them would let a
    ///      prover reuse a proof across a different ciphertext or a different key.
    function challenge(
        uint256 hx,
        uint256 hy,
        uint256 c1x,
        uint256 c1y,
        uint256 dx,
        uint256 dy,
        uint256 ax,
        uint256 ay,
        uint256 bx,
        uint256 by
    ) internal pure returns (uint256) {
        return uint256(
            keccak256(
            abi.encodePacked(
            "atrum.chaum-pedersen.v1", BabyJubJub.BASE8X, BabyJubJub.BASE8Y, hx, hy, c1x, c1y, dx, dy, ax, ay, bx, by
        )
        )
        ) % BabyJubJub.L;
    }

    /// @notice Verify that `D` is `[s]C1` for the same `s` as `H = [s]G`.
    function verify(uint256 hx, uint256 hy, uint256 c1x, uint256 c1y, uint256 dx, uint256 dy, Proof memory proof)
        internal
        view
        returns (bool)
    {
        // Every supplied point must be on the curve. An off-curve point is not a group
        // element and the algebra below would be meaningless.
        if (!BabyJubJub.isOnCurve(hx, hy)) return false;
        if (!BabyJubJub.isOnCurve(c1x, c1y)) return false;
        if (!BabyJubJub.isOnCurve(dx, dy)) return false;
        if (!BabyJubJub.isOnCurve(proof.ax, proof.ay)) return false;
        if (!BabyJubJub.isOnCurve(proof.bx, proof.by)) return false;
        if (proof.z >= BabyJubJub.L) return false;

        uint256 e = challenge(hx, hy, c1x, c1y, dx, dy, proof.ax, proof.ay, proof.bx, proof.by);

        BabyJubJub.Point memory g = BabyJubJub.fromAffine(BabyJubJub.BASE8X, BabyJubJub.BASE8Y);
        BabyJubJub.Point memory h = BabyJubJub.fromAffine(hx, hy);
        BabyJubJub.Point memory c1 = BabyJubJub.fromAffine(c1x, c1y);
        BabyJubJub.Point memory d = BabyJubJub.fromAffine(dx, dy);
        // Each equation is rearranged so its two scalar multiplications share ONE
        // interleaved ladder, and so the comparison needs one projective-to-affine
        // conversion instead of two:
        //
        //   [z]G  == A + [e]H   becomes   [z]G  + [e](-H) == A
        //   [z]C1 == B + [e]D   becomes   [z]C1 + [e](-D) == B
        //
        // Negation is free on a twisted Edwards curve, so the rearrangement costs nothing
        // and halves the doublings.
        (uint256 lx, uint256 ly) =
            BabyJubJub.toAffine(BabyJubJub.doubleScalarMulPublic(g, proof.z, BabyJubJub.negate(h), e));
        if (lx != proof.ax || ly != proof.ay) return false;

        (lx, ly) = BabyJubJub.toAffine(BabyJubJub.doubleScalarMulPublic(c1, proof.z, BabyJubJub.negate(d), e));
        return lx == proof.bx && ly == proof.by;
    }
}
