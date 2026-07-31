// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BabyJubJub} from "../src/BabyJubJub.sol";

/// @notice Where does the gas in a scalar-multiplication ladder actually go?
///
/// @dev Two cost models have already been wrong here. The first predicted Monad's cold
///      SLOAD would dominate the accumulator's layout choice; it did not. The second
///      predicted per-operation struct allocation dominated the ladder, so flattening to
///      in-place memory arrays would give a large win; it gave 15%, and interleaving two
///      ladders (Straus) gave 1%.
///
///      Guessing a third time is not a method. This decomposes the ladder into its parts
///      and measures each, so any further optimisation targets a measured cost rather than
///      an assumed one.
contract CurveMicrobenchTest is Test {
    uint256 constant Q = BabyJubJub.Q;
    uint256 constant A = 168700;
    uint256 constant D = 168696;
    uint256 constant ITERS = 252;

    /// Baseline: the loop skeleton with no curve arithmetic at all.
    function _emptyLoop(uint256 k) internal pure returns (uint256 acc) {
        for (uint256 i = 0; i < ITERS; i++) {
            if ((k >> i) & 1 == 1) acc++;
        }
    }

    /// The raw field arithmetic of one addition, inline, on stack values only --
    /// no function call, no array indexing, no bounds checks.
    function _inlineAdds(uint256 k) internal pure returns (uint256 out) {
        uint256 x1 = 1;
        uint256 y1 = 2;
        uint256 t1 = 3;
        uint256 z1 = 4;

        for (uint256 i = 0; i < ITERS; i++) {
            uint256 a = mulmod(x1, x1, Q);
            uint256 b = mulmod(y1, y1, Q);
            uint256 e = mulmod(addmod(x1, y1, Q), addmod(x1, y1, Q), Q);
            e = addmod(addmod(e, Q - a, Q), Q - b, Q);
            uint256 c = mulmod(mulmod(D, t1, Q), t1, Q);
            uint256 d = mulmod(z1, z1, Q);
            uint256 f = addmod(d, Q - c, Q);
            uint256 g = addmod(d, c, Q);
            uint256 h = addmod(b, Q - mulmod(A, a, Q), Q);
            x1 = mulmod(e, f, Q);
            y1 = mulmod(g, h, Q);
            t1 = mulmod(e, h, Q);
            z1 = mulmod(f, g, Q);
        }
        out = x1;
        if (k == type(uint256).max) revert("unreachable");
    }

    function test_report_decomposition() public view {
        uint256 k = BabyJubJub.L - 1; // ~every bit set: worst case

        uint256 g0 = gasleft();
        _emptyLoop(k);
        uint256 emptyLoop = g0 - gasleft();

        g0 = gasleft();
        _inlineAdds(k);
        uint256 inlineArith = g0 - gasleft();

        BabyJubJub.Point memory p = BabyJubJub.fromAffine(BabyJubJub.BASE8X, BabyJubJub.BASE8Y);
        g0 = gasleft();
        BabyJubJub.scalarMulPublic(p, k);
        uint256 ladder = g0 - gasleft();

        // A ladder over a worst-case scalar performs ~252 doublings + ~251 additions.
        uint256 pointOps = 503;

        console.log("=== ladder cost decomposition (252 iterations) ===");
        console.log("empty loop skeleton         :", emptyLoop);
        console.log("252 inline additions        :", inlineArith);
        console.log("  -> per inline addition    :", inlineArith / ITERS);
        console.log("full scalarMulPublic        :", ladder);
        console.log("  -> per point operation    :", ladder / pointOps);
        console.log("");
        console.log("So the arithmetic itself is:", inlineArith / ITERS);
        console.log(
            "and the call + array overhead:",
            (ladder / pointOps) > (inlineArith / ITERS) ? (ladder / pointOps) - (inlineArith / ITERS) : 0
        );
    }
}
