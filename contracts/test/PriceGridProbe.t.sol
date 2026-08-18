// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PriceGridAccumulator} from "../src/probe/PriceGridAccumulator.sol";

/// @title PriceGridProbe
/// @notice Costs V2 sealed-batch clearing that never decrypts an individual order.
///
/// @dev Answers one question with a number: does keeping orders encrypted through clearing
///      fit the gas envelope, or does V2's privacy claim have to be weakened to
///      "delayed disclosure"?
///
///      TWO FIGURES MATTER, AND THEY ARE PAID BY DIFFERENT PEOPLE.
///
///      1. PER ORDER, paid by the relayer, once per order, inside the 2,000,000 uniform
///         action envelope. Compare against `ElGamalAccumulator.accumulateAffine`, measured
///         at 122,270 cold in production. If the price grid matches it, the grid is FREE
///         relative to V1 -- the demand curve is non-increasing, so one order touches one
///         level, and the level index is just a different mapping key.
///
///      2. PER BATCH, paid by the publisher at clearing. Not an action, so the uniform
///         envelope does not apply -- but the 150,000,000 block limit and the 30,000,000
///         transaction limit do.
///
///      METHODOLOGY, following this repo's own corrections:
///        - Fixture reads are `vm.parseJson` cheatcodes and cost real gas. Hoisted out of
///          every `gasleft()` bracket -- MEASUREMENTS.md 1d records a 971,000-gas error
///          from leaving them inline, which read convincingly like a contract problem.
///        - Levels are initialised in `setUp`, never in a test body, so a "cold" figure
///          describes the state a real order actually finds.
///        - `--network monad` is required. Without it these are Ethereum's prices, and
///          MEASUREMENTS.md 3 measures BN254 understated ~5x and cold SLOAD ~4x.
///        - Local forge understates real Monad transactions by 32-41% (MEASUREMENTS.md 1c).
///          EVERY FIGURE HERE IS A LOWER BOUND and is labelled as one.
contract PriceGridProbeTest is Test {
    PriceGridAccumulator internal grid;

    string internal fx;

    uint32 internal constant MARKET = 1;
    uint8 internal constant BID = 1;
    uint8 internal constant ASK = 2;

    /// @dev Grid sizes probed. 100 = a 1c grid over a 0-1 probability range, which is how
    ///      prediction markets are quoted. 20 = a 5c grid, the coarse fallback if 100 does
    ///      not fit. 50 sits between so the scaling is visible rather than inferred from
    ///      two points.
    uint16 internal constant L_COARSE = 20;
    uint16 internal constant L_MID = 50;
    uint16 internal constant L_FINE = 100;

    function setUp() public {
        grid = new PriceGridAccumulator();
        fx = vm.readFile("../circuits/build/elgamal-fixtures.json");

        // Initialise every level of every grid size used below, HERE, so no test body warms
        // a slot it is about to call cold.
        for (uint16 i = 0; i < L_FINE; i++) {
            grid.initLevel(MARKET, BID, i);
            grid.initLevel(MARKET, ASK, i);
        }
    }

    function _u(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(fx, key);
    }

    // -----------------------------------------------------------------------
    // 1. Per order
    // -----------------------------------------------------------------------

    /// @notice One order writes one level. Compare to production's 122,270 cold.
    function test_probe_perOrderCold() public {
        // Hoisted: cheatcodes must not land inside the bracket.
        uint256 c1x = _u(".accumulate.alice.c1[0]");
        uint256 c1y = _u(".accumulate.alice.c1[1]");
        uint256 c2x = _u(".accumulate.alice.c2[0]");
        uint256 c2y = _u(".accumulate.alice.c2[1]");

        // Level 63 -- an arbitrary interior level, cold, untouched since setUp.
        uint256 g = gasleft();
        grid.addOrder(MARKET, BID, 63, c1x, c1y, c2x, c2y);
        uint256 used = g - gasleft();

        console.log("");
        console.log("=== 1. PER ORDER (lower bound; live Monad runs 32-41%% higher) ===");
        console.log("price-grid addOrder, cold  :", used);
        console.log("production accumulateAffine:", uint256(122270));
        console.log("2,000,000 envelope headroom after a betEncrypted-shaped action:");
        console.log("  real betEncrypted (live)  : 1904506  ->  95,494 spare");
    }

    /// @notice Second order at the SAME level -- the case where a price level is popular.
    function test_probe_perOrderWarm() public {
        uint256 c1x = _u(".accumulate.alice.c1[0]");
        uint256 c1y = _u(".accumulate.alice.c1[1]");
        uint256 c2x = _u(".accumulate.alice.c2[0]");
        uint256 c2y = _u(".accumulate.alice.c2[1]");

        grid.addOrder(MARKET, BID, 63, c1x, c1y, c2x, c2y);

        uint256 g = gasleft();
        grid.addOrder(MARKET, BID, 63, c1x, c1y, c2x, c2y);
        uint256 used = g - gasleft();

        console.log("price-grid addOrder, warm  :", used);
    }

    // -----------------------------------------------------------------------
    // 2. Per batch -- the clearing sweep
    // -----------------------------------------------------------------------

    /// @dev ONE SWEEP PER TEST, and never two in the same body.
    ///
    ///      The first draft of this file measured L=20, L=50 and L=100 in sequence and got
    ///      47,438 / 33,646 / 30,416 gas per level -- an apparently improving curve, and a
    ///      "loaded book clears cheaper than an empty one" result that is arithmetically
    ///      impossible. Both were the same artifact: the first sweep warmed the low levels,
    ///      so every later sweep read warm slots that a real publisher, in its own
    ///      transaction, finds cold. MEASUREMENTS.md 1d records this repo making the same
    ///      class of mistake before. forge gives each test function fresh state from
    ///      `setUp`, so isolation is one sweep per function -- nothing subtler.
    function _sweepCost(uint16 levels) internal returns (uint256) {
        uint256 g = gasleft();
        grid.sweepSuffix(MARKET, BID, levels);
        return g - gasleft();
    }

    function test_probe_sweep_L20() public {
        console.log("sweep L=20  :", _sweepCost(L_COARSE));
    }

    function test_probe_sweep_L50() public {
        console.log("sweep L=50  :", _sweepCost(L_MID));
    }

    /// @notice The whole demand curve, as ciphertexts, in one transaction.
    ///
    /// @dev This is what replaces sorting. If it fits a transaction, the publisher can
    ///      locate the clearing price by decrypting only a few probed levels rather than
    ///      opening the batch.
    function test_probe_sweep_L100() public {
        uint256 fine = _sweepCost(L_FINE);
        console.log("sweep L=100 :", fine);
        console.log("both sides  :", fine * 2);
        console.log("tx limit 30,000,000 / block limit 150,000,000");
        assertLt(fine * 2, 30_000_000, "both sides must clear inside one transaction limit");
    }

    // -----------------------------------------------------------------------
    // 3. The property the design lives or dies on
    // -----------------------------------------------------------------------

    /// @notice Clearing cost must be set by the GRID, not by how many people traded.
    ///
    /// @dev This is the whole argument for the design. Transparent clearing costs the
    ///      publisher one decryption per ORDER, so it scales with the metric V2 exists to
    ///      grow -- the same unbounded-subsidy shape as relayed gas. The grid scales with
    ///      price LEVELS, which are fixed at design time. A batch of 64 and a batch of
    ///      6,400 must clear for the same gas.
    ///
    ///      Measured against `test_probe_sweep_L100`'s empty-book figure, which runs in its
    ///      own transaction with its own cold state -- NOT against a sweep in this body.
    function test_probe_sweep_L100_with64Orders() public {
        uint256 c1x = _u(".accumulate.alice.c1[0]");
        uint256 c1y = _u(".accumulate.alice.c1[1]");
        uint256 c2x = _u(".accumulate.alice.c2[0]");
        uint256 c2y = _u(".accumulate.alice.c2[1]");

        // A full batch at the anonymity-set size the production tree already batches at,
        // spread across the grid so most levels hold a real ciphertext rather than Enc(0).
        for (uint16 i = 0; i < 64; i++) {
            grid.addOrder(MARKET, BID, uint16(i % L_FINE), c1x, c1y, c2x, c2y);
        }

        // The orders above warmed 64 of the 100 levels, so this sweep is NOT comparable to
        // the empty-book figure directly -- it is a warm-biased lower bound on an already
        // lower-bound number. Reported as such rather than asserted against.
        console.log("sweep L=100, 64 orders resident (warm-biased):", _sweepCost(L_FINE));
        console.log("compare: test_probe_sweep_L100, empty book, all-cold");
    }
}
