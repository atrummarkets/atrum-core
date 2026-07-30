// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console, stdJson} from "forge-std/Test.sol";
import {BabyJubJub} from "../src/BabyJubJub.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {ActionGasPolicy} from "../src/ActionGasPolicy.sol";

/// @notice PHASE 2 GATE: does the homomorphic accumulator fit the remaining headroom, and
///         is its arithmetic actually correct?
///
/// @dev Correctness first, and it matters more here than anywhere else in the repo.
///
///      A corrupted ciphertext is INDISTINGUISHABLE from a valid one on-chain. There is
///      no revert, no failing proof, no event -- the accumulator would keep accepting
///      stakes and the pool total would simply be undecryptable forever. Nobody would
///      find out until the publisher tried to read the odds.
///
///      So every vector below comes from circomlibjs (`gen_elgamal_fixtures.mjs`), and
///      the Solidity is required to reproduce it exactly before any gas figure from this
///      contract is quoted.
///
///      Headroom is the reason this is a gate: MEASUREMENTS.md §1c records a real testnet
///      `deposit` at 1,816,031 gas -- 91% of the 2,000,000 envelope. Roughly 184,000 gas
///      is left, and the accumulator has to fit inside it.
contract ElGamalAccumulatorTest is Test {
    using stdJson for string;

    ElGamalAccumulator acc;
    string fx;

    address pool = makeAddr("shieldedPool");
    uint32 constant MARKET_ID = 7;
    uint8 constant YES = 1;
    uint8 constant NO = 2;

    function setUp() public {
        fx = vm.readFile("../circuits/build/elgamal-fixtures.json");
        acc = new ElGamalAccumulator(pool);

        // Initialise here, NOT in a test body: writing these slots warms them, and a
        // "cold" measurement taken afterwards describes a state no real bet ever sees.
        acc.initMarket(MARKET_ID, YES);
        acc.initMarket(MARKET_ID, NO);
    }

    function _u(string memory k) internal view returns (uint256) {
        return fx.readUint(k);
    }

    // -----------------------------------------------------------------------
    // Curve parameters must match circomlib exactly
    // -----------------------------------------------------------------------

    function test_curveParametersMatchCircomlib() public view {
        assertEq(BabyJubJub.A, _u(".curve.a"), "curve parameter a diverged");
        assertEq(BabyJubJub.D, _u(".curve.d"), "curve parameter d diverged");
        assertEq(BabyJubJub.Q, _u(".curve.q"), "base field q diverged");
    }

    function test_base8IsOnCurve() public view {
        assertTrue(
            BabyJubJub.isOnCurve(_u(".curve.base8[0]"), _u(".curve.base8[1]")),
            "circomlib's base point is not on our curve -- parameters are wrong"
        );
    }

    /// @dev The identity is (0,1), NOT all-zeros. An uninitialised storage slot reads as
    ///      (0,0), which is off-curve -- which is precisely why `initMarket` exists.
    function test_identityIsOnCurveButZeroIsNot() public pure {
        assertTrue(BabyJubJub.isOnCurve(0, 1), "identity (0,1) must be on the curve");
        assertFalse(BabyJubJub.isOnCurve(0, 0), "(0,0) must NOT be on the curve");
    }

    // -----------------------------------------------------------------------
    // Point addition, against circomlibjs
    // -----------------------------------------------------------------------

    /// @notice Every addition vector, including the three edge cases that break naive
    ///         implementations: identity operands, doubling, and P + (-P).
    function test_pointAdditionMatchesCircomlibjs() public view {
        uint256 count = 7;

        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".additions[", vm.toString(i), "]");

            uint256 ax = _u(string.concat(base, ".a[0]"));
            uint256 ay = _u(string.concat(base, ".a[1]"));
            uint256 bx = _u(string.concat(base, ".b[0]"));
            uint256 by = _u(string.concat(base, ".b[1]"));
            uint256 wx = _u(string.concat(base, ".sum[0]"));
            uint256 wy = _u(string.concat(base, ".sum[1]"));

            BabyJubJub.Point memory sum = BabyJubJub.add(BabyJubJub.fromAffine(ax, ay), BabyJubJub.fromAffine(bx, by));
            (uint256 gx, uint256 gy) = BabyJubJub.toAffine(sum);

            assertEq(gx, wx, string.concat("x mismatch on vector ", vm.toString(i)));
            assertEq(gy, wy, string.concat("y mismatch on vector ", vm.toString(i)));
        }
    }

    /// @notice Addition must be commutative -- a basic sanity property of the group.
    function test_additionIsCommutative() public view {
        uint256 ax = _u(".accumulate.alice.c1[0]");
        uint256 ay = _u(".accumulate.alice.c1[1]");
        uint256 bx = _u(".accumulate.carol.c1[0]");
        uint256 by = _u(".accumulate.carol.c1[1]");

        (uint256 x1, uint256 y1) =
            BabyJubJub.toAffine(BabyJubJub.add(BabyJubJub.fromAffine(ax, ay), BabyJubJub.fromAffine(bx, by)));
        (uint256 x2, uint256 y2) =
            BabyJubJub.toAffine(BabyJubJub.add(BabyJubJub.fromAffine(bx, by), BabyJubJub.fromAffine(ax, ay)));

        assertEq(x1, x2, "addition is not commutative");
        assertEq(y1, y2, "addition is not commutative");
    }

    function test_inverseIsCorrect() public view {
        uint256 v = _u(".curve.base8[0]");
        uint256 inv = BabyJubJub.inverse(v);
        assertEq(mulmod(v, inv, BabyJubJub.Q), 1, "modular inverse is wrong");
    }

    function test_rejectsOffCurvePoints() public view {
        for (uint256 i = 0; i < 3; i++) {
            uint256 x = _u(string.concat(".offCurve[", vm.toString(i), "][0]"));
            uint256 y = _u(string.concat(".offCurve[", vm.toString(i), "][1]"));
            assertFalse(BabyJubJub.isOnCurve(x, y), "accepted an off-curve point");
        }
    }

    // -----------------------------------------------------------------------
    // The homomorphic property, on-chain
    // -----------------------------------------------------------------------

    /// @notice THE load-bearing test: accumulating Enc(50) then Enc(20) on-chain must land
    ///         on exactly the ciphertext circomlibjs computed for Enc(70).
    /// @dev If this passes, the contract is genuinely summing encrypted stakes without
    ///      decrypting -- which is the entire premise of Phase 2.
    function test_accumulateExtendedMatchesCircomlibjs() public {
        vm.startPrank(pool);
        acc.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.alice.c1[0]"),
            _u(".accumulate.alice.c1[1]"),
            _u(".accumulate.alice.c2[0]"),
            _u(".accumulate.alice.c2[1]")
        );

        (uint256 x1, uint256 y1, uint256 x2, uint256 y2) = acc.totalExtended(MARKET_ID, YES);
        assertEq(x1, _u(".accumulate.afterAlice.c1[0]"), "c1.x wrong after first stake");
        assertEq(y1, _u(".accumulate.afterAlice.c1[1]"), "c1.y wrong after first stake");
        assertEq(x2, _u(".accumulate.afterAlice.c2[0]"), "c2.x wrong after first stake");
        assertEq(y2, _u(".accumulate.afterAlice.c2[1]"), "c2.y wrong after first stake");

        acc.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.carol.c1[0]"),
            _u(".accumulate.carol.c1[1]"),
            _u(".accumulate.carol.c2[0]"),
            _u(".accumulate.carol.c2[1]")
        );
        vm.stopPrank();

        (x1, y1, x2, y2) = acc.totalExtended(MARKET_ID, YES);
        assertEq(x1, _u(".accumulate.afterBoth.c1[0]"), "c1.x wrong after both stakes");
        assertEq(y1, _u(".accumulate.afterBoth.c1[1]"), "c1.y wrong after both stakes");
        assertEq(x2, _u(".accumulate.afterBoth.c2[0]"), "c2.x wrong after both stakes");
        assertEq(y2, _u(".accumulate.afterBoth.c2[1]"), "c2.y wrong after both stakes");
    }

    /// @notice The affine variant must reach the identical total.
    function test_accumulateAffineMatchesExtended() public {
        vm.startPrank(pool);
        acc.accumulateAffine(
            MARKET_ID,
            YES,
            _u(".accumulate.alice.c1[0]"),
            _u(".accumulate.alice.c1[1]"),
            _u(".accumulate.alice.c2[0]"),
            _u(".accumulate.alice.c2[1]")
        );
        acc.accumulateAffine(
            MARKET_ID,
            YES,
            _u(".accumulate.carol.c1[0]"),
            _u(".accumulate.carol.c1[1]"),
            _u(".accumulate.carol.c2[0]"),
            _u(".accumulate.carol.c2[1]")
        );
        vm.stopPrank();

        (uint256 x1, uint256 y1, uint256 x2, uint256 y2) = acc.totalAffine(MARKET_ID, YES);
        assertEq(x1, _u(".accumulate.afterBoth.c1[0]"), "affine c1.x diverged");
        assertEq(y1, _u(".accumulate.afterBoth.c1[1]"), "affine c1.y diverged");
        assertEq(x2, _u(".accumulate.afterBoth.c2[0]"), "affine c2.x diverged");
        assertEq(y2, _u(".accumulate.afterBoth.c2[1]"), "affine c2.y diverged");
    }

    /// @notice Order must not matter -- a parimutuel pool is order-independent, and the
    ///         accumulator has to preserve that or the design's zero-MEV claim is false.
    function test_accumulationIsOrderIndependent() public {
        // `acc` is already initialised in setUp; only the second one needs it.
        ElGamalAccumulator a2 = new ElGamalAccumulator(pool);
        a2.initMarket(MARKET_ID, YES);

        vm.startPrank(pool);
        acc.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.alice.c1[0]"),
            _u(".accumulate.alice.c1[1]"),
            _u(".accumulate.alice.c2[0]"),
            _u(".accumulate.alice.c2[1]")
        );
        acc.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.carol.c1[0]"),
            _u(".accumulate.carol.c1[1]"),
            _u(".accumulate.carol.c2[0]"),
            _u(".accumulate.carol.c2[1]")
        );

        // Reverse order.
        a2.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.carol.c1[0]"),
            _u(".accumulate.carol.c1[1]"),
            _u(".accumulate.carol.c2[0]"),
            _u(".accumulate.carol.c2[1]")
        );
        a2.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.alice.c1[0]"),
            _u(".accumulate.alice.c1[1]"),
            _u(".accumulate.alice.c2[0]"),
            _u(".accumulate.alice.c2[1]")
        );
        vm.stopPrank();

        (uint256 ax, uint256 ay,,) = acc.totalExtended(MARKET_ID, YES);
        (uint256 bx, uint256 by,,) = a2.totalExtended(MARKET_ID, YES);
        assertEq(ax, bx, "accumulation is order-dependent");
        assertEq(ay, by, "accumulation is order-dependent");
    }

    // -----------------------------------------------------------------------
    // Access control and guards
    // -----------------------------------------------------------------------

    function test_onlyPoolCanAccumulate() public {
        vm.expectRevert(ElGamalAccumulator.NotPool.selector);
        acc.accumulateExtended(MARKET_ID, YES, 0, 1, 0, 1);
    }

    function test_rejectsUninitialisedMarket() public {
        ElGamalAccumulator fresh = new ElGamalAccumulator(pool);
        vm.prank(pool);
        vm.expectRevert(ElGamalAccumulator.NotInitialised.selector);
        fresh.accumulateExtended(MARKET_ID, 1, 0, 1, 0, 1);
    }

    function test_rejectsDoubleInit() public {
        vm.expectRevert(ElGamalAccumulator.AlreadyInitialised.selector);
        acc.initMarket(MARKET_ID, YES);
    }

    /// @dev Outcome 0 is unbet collateral, not stake -- it must never move the odds.
    function test_rejectsOutcomeZeroAndThree() public {
        vm.expectRevert(ElGamalAccumulator.InvalidOutcome.selector);
        acc.initMarket(MARKET_ID, 0);
        vm.expectRevert(ElGamalAccumulator.InvalidOutcome.selector);
        acc.initMarket(MARKET_ID, 3);
    }

    /// @notice Off-curve ciphertexts must be refused at the contract boundary.
    /// @dev The circuit constrains this too, but the contract must not rely on a proof it
    ///      did not verify for a property this destructive: an off-curve addend makes the
    ///      pool total permanently undecryptable, silently.
    function test_rejectsOffCurveCiphertext() public {
        vm.startPrank(pool);

        vm.expectRevert(ElGamalAccumulator.NotOnCurve.selector);
        acc.accumulateExtended(MARKET_ID, YES, 1, 1, 0, 1);

        vm.expectRevert(ElGamalAccumulator.NotOnCurve.selector);
        acc.accumulateExtended(MARKET_ID, YES, 0, 1, 2, 3);

        vm.stopPrank();
    }

    function test_yesAndNoAccumulateIndependently() public {
        vm.prank(pool);
        acc.accumulateExtended(
            MARKET_ID,
            YES,
            _u(".accumulate.alice.c1[0]"),
            _u(".accumulate.alice.c1[1]"),
            _u(".accumulate.alice.c2[0]"),
            _u(".accumulate.alice.c2[1]")
        );

        (uint256 nx, uint256 ny,,) = acc.totalExtended(MARKET_ID, NO);
        assertEq(nx, 0, "NO side moved when YES was staked");
        assertEq(ny, 1, "NO side moved when YES was staked");
    }

    // -----------------------------------------------------------------------
    // THE GATE
    // -----------------------------------------------------------------------

    /// @notice Extended vs affine, measured with genuinely COLD storage.
    ///
    /// @dev The first version of this test was wrong and the wrongness mattered. It called
    ///      `initMarket` inside the test body, which WRITES every accumulator slot -- so by
    ///      the time the "cold" figure was taken the slots were already warm, and the
    ///      number described a case that never happens in production.
    ///
    ///      The tell was that the extended layout measured the same on Monad and at
    ///      Ethereum pricing (89,799 vs 89,894) when eight genuinely cold SLOADs should
    ///      differ by ~48,000. A separate experiment (`StorageContiguity.t.sol`) ruled out
    ///      MIP-8 page-sharing as the explanation: contiguity is worth only ~2,600 gas, and
    ///      Monad does charge the full per-slot surcharge.
    ///
    ///      Initialisation now happens in `setUp`, so each test body is a fresh
    ///      transaction and the accumulator's slots start cold -- which is exactly the
    ///      state a user's first bet on a market finds them in.
    function test_gate_extendedColdCost() public {
        // Hoisted: `_u` is a vm.parseJson cheatcode and costs ~450,000 gas per call.
        // Inline, four of them put this measurement at 1,888,082 -- a number that looks
        // like a catastrophic contract cost and is entirely the harness.
        uint256 c1x = _u(".accumulate.alice.c1[0]");
        uint256 c1y = _u(".accumulate.alice.c1[1]");
        uint256 c2x = _u(".accumulate.alice.c2[0]");
        uint256 c2y = _u(".accumulate.alice.c2[1]");

        vm.prank(pool);
        uint256 g = gasleft();
        acc.accumulateExtended(MARKET_ID, YES, c1x, c1y, c2x, c2y);
        uint256 used = g - gasleft();

        console.log("extended, COLD storage (8 slots, no inversion):", used);
        console.log("  headroom available:", HEADROOM);
        console.log("  fits:", used < HEADROOM ? "YES" : "NO -- this is why affine is the production path");

        // Deliberately NOT asserted to fit. This layout is measurably the wrong choice:
        // it exceeds the headroom a real deposit leaves, so `ShieldedPool` uses
        // `accumulateAffine`. Kept and measured so the decision stays evidence-backed
        // rather than folklore -- and so a future gas change that reverses the verdict
        // shows up here.
        assertGt(used, 100_000, "extended layout got suspiciously cheap -- re-check the measurement");
    }

    function test_gate_affineColdCost() public {
        uint256 c1x = _u(".accumulate.alice.c1[0]");
        uint256 c1y = _u(".accumulate.alice.c1[1]");
        uint256 c2x = _u(".accumulate.alice.c2[0]");
        uint256 c2y = _u(".accumulate.alice.c2[1]");

        vm.prank(pool);
        uint256 g = gasleft();
        acc.accumulateAffine(MARKET_ID, NO, c1x, c1y, c2x, c2y);
        uint256 used = g - gasleft();
        console.log("affine, COLD storage (4 slots, 2 inversions) :", used);
        _record("affine", used);
    }

    /// @dev Warm cost matters for the sequencer's batched path, not for user bets.
    function test_gate_warmCosts() public {
        uint256 a1x = _u(".accumulate.alice.c1[0]");
        uint256 a1y = _u(".accumulate.alice.c1[1]");
        uint256 a2x = _u(".accumulate.alice.c2[0]");
        uint256 a2y = _u(".accumulate.alice.c2[1]");
        uint256 k1x = _u(".accumulate.carol.c1[0]");
        uint256 k1y = _u(".accumulate.carol.c1[1]");
        uint256 k2x = _u(".accumulate.carol.c2[0]");
        uint256 k2y = _u(".accumulate.carol.c2[1]");

        vm.startPrank(pool);
        acc.accumulateExtended(MARKET_ID, YES, a1x, a1y, a2x, a2y);
        uint256 g = gasleft();
        acc.accumulateExtended(MARKET_ID, YES, k1x, k1y, k2x, k2y);
        uint256 extWarm = g - gasleft();

        acc.accumulateAffine(MARKET_ID, NO, a1x, a1y, a2x, a2y);
        g = gasleft();
        acc.accumulateAffine(MARKET_ID, NO, k1x, k1y, k2x, k2y);
        uint256 affWarm = g - gasleft();
        vm.stopPrank();

        console.log("extended, WARM:", extWarm);
        console.log("affine,   WARM:", affWarm);
        console.log("warm winner   :", extWarm < affWarm ? "EXTENDED" : "AFFINE");
    }

    uint256 constant HEADROOM = 183_969;

    /// @dev Asserts the PRODUCTION layout fits the headroom a real deposit leaves.
    function _record(string memory layout, uint256 used) internal view {
        console.log("  headroom left by a real testnet deposit:", HEADROOM);
        console.log("  fits:", used < HEADROOM ? "YES" : "NO");
        require(used < HEADROOM, string.concat(layout, " accumulate does not fit the envelope headroom"));
    }
}
