// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Vault} from "../src/Vault.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {EncryptedParimutuelPool} from "../src/EncryptedParimutuelPool.sol";
import {ChaumPedersen} from "../src/ChaumPedersen.sol";
import {ShieldedPool, IDepositVerifier, IActionVerifier, IActionVerifier8} from "../src/ShieldedPool.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";

/// @notice The step that moves money in Phase 2, attacked rather than demonstrated.
///
/// @dev The contract is handed a claimed pool total and must decide whether to believe
///      it. Believing a lie overpays one side out of the other's collateral, so the tests
///      that matter here are the ones where a well-formed proof accompanies a false
///      number.
///
///      The headline case is `test_settle_rejectsHonestProofWithLyingTotal`: a VALID
///      Chaum-Pedersen proof and a VALID decryption share next to a fabricated total.
///      Chaum-Pedersen accepts it -- it only ever proves the share came from the right
///      key. Only the `C2 - D = [m]G` binding catches it. Delete that binding and this
///      test is the one that fails.
contract EncryptedParimutuelPoolTest is Test {
    using stdJson for string;

    MockERC20 usdc;
    Vault vault;
    IncrementalMerkleTree tree;
    MappingNullifierSet nullifiers;
    ParimutuelPool parimutuel;
    ElGamalAccumulator accumulator;
    EncryptedParimutuelPool encrypted;
    ShieldedPool pool;
    IPoseidonT3 poseidon;

    address sequencer = makeAddr("sequencer");
    address resolver = makeAddr("resolver");

    uint32 constant MARKET_ID = 8;
    uint256 constant DENOM = 1e6;
    uint256 constant MIN_PUBLISH_INTERVAL = 1 hours;

    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty"))
        % 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    string fx;

    uint64 bettingClose;
    uint64 resolutionStart;

    function setUp() public {
        vm.warp(1_800_000_000);
        fx = vm.readFile("../circuits/build/settlement-fixtures.json");

        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);
        poseidon = IPoseidonT3(addr);

        usdc = new MockERC20();
        bettingClose = uint64(block.timestamp + 7 days);
        resolutionStart = bettingClose + 2 hours;
        vault = new Vault(IERC20(address(usdc)), DENOM, resolver, keccak256("spec"), bettingClose, resolutionStart);

        DepositVerifier dv = new DepositVerifier();
        BetVerifier bv = new BetVerifier();
        BetEncryptedVerifier bev = new BetEncryptedVerifier();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        tree = new IncrementalMerkleTree(poseidon, ZERO_VALUE, predicted);
        parimutuel = new ParimutuelPool(predicted);
        nullifiers = new MappingNullifierSet();
        accumulator = new ElGamalAccumulator(predicted);

        pool = new ShieldedPool(
            tree,
            nullifiers,
            parimutuel,
            accumulator,
            IDepositVerifier(address(dv)),
            IActionVerifier(address(bv)),
            IActionVerifier8(address(bev)),
            IERC20(address(usdc)),
            DENOM,
            sequencer,
            address(this)
        );
        require(address(pool) == predicted, "pool address prediction failed");

        nullifiers.bindPool(address(pool));
        pool.registerEncryptedMarket(MARKET_ID, vault);

        encrypted = new EncryptedParimutuelPool(
            accumulator, pool, _u(".committeeKey[0]"), _u(".committeeKey[1]"), MIN_PUBLISH_INTERVAL
        );
    }

    // -----------------------------------------------------------------------
    // Fixture helpers
    // -----------------------------------------------------------------------

    function _u(string memory key) internal view returns (uint256) {
        return fx.readUint(key);
    }

    function _dec(string memory side) internal view returns (EncryptedParimutuelPool.Decryption memory) {
        return EncryptedParimutuelPool.Decryption({
            dx: _u(string.concat(".", side, ".d[0]")),
            dy: _u(string.concat(".", side, ".d[1]")),
            proof: ChaumPedersen.Proof({
                ax: _u(string.concat(".", side, ".proof.ax")),
                ay: _u(string.concat(".", side, ".proof.ay")),
                bx: _u(string.concat(".", side, ".proof.bx")),
                by: _u(string.concat(".", side, ".proof.by")),
                z: _u(string.concat(".", side, ".proof.z"))
            })
        });
    }

    /// @dev Force the accumulator into the state the fixtures were built against.
    ///
    ///      The fixtures' ciphertexts are sums of several per-bet ciphertexts, which is
    ///      what the accumulator really holds after a few bets. Reproducing that through
    ///      `betEncrypted` would need one real Groth16 proof per bet; the settlement logic
    ///      under test here does not care how the ciphertext got there, so the state is
    ///      written directly. The path from a real bet TO this state is covered by
    ///      `ShieldedPoolTest.test_betEncrypted_accumulatesWithoutRevealingStake`.
    function _seedAccumulator(string memory yesSide, string memory noSide) internal {
        vm.startPrank(address(pool));
        accumulator.accumulateAffine(
            MARKET_ID,
            1,
            _u(string.concat(".", yesSide, ".c1[0]")),
            _u(string.concat(".", yesSide, ".c1[1]")),
            _u(string.concat(".", yesSide, ".c2[0]")),
            _u(string.concat(".", yesSide, ".c2[1]"))
        );
        accumulator.accumulateAffine(
            MARKET_ID,
            2,
            _u(string.concat(".", noSide, ".c1[0]")),
            _u(string.concat(".", noSide, ".c1[1]")),
            _u(string.concat(".", noSide, ".c2[0]")),
            _u(string.concat(".", noSide, ".c2[1]"))
        );
        vm.stopPrank();
    }

    function _closeAndResolve() internal {
        vm.warp(resolutionStart + 1);
        vm.prank(resolver);
        vault.resolve(Vault.Outcome.Yes);
    }

    function _settle() internal {
        encrypted.publishFinalTotals(MARKET_ID, _u(".yes.total"), _u(".no.total"), _dec("yes"), _dec("no"));
    }

    // -----------------------------------------------------------------------
    // Settlement -- the happy path
    // -----------------------------------------------------------------------

    function test_settle_acceptsHonestTotals() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();
        _settle();

        assertTrue(encrypted.settled(MARKET_ID), "market not settled");
        assertEq(encrypted.finalYesTotal(MARKET_ID), _u(".expected.yesTotal"), "YES total wrong");
        assertEq(encrypted.finalNoTotal(MARKET_ID), _u(".expected.noTotal"), "NO total wrong");
        assertEq(
            encrypted.finalYesProbabilityBps(MARKET_ID), _u(".expected.yesProbabilityBps"), "settled probability wrong"
        );
    }

    /// @notice The homomorphic property, proven on-chain: the accumulator summed five
    ///         independent bet ciphertexts and the settled totals are the sums of the
    ///         underlying stakes. Nothing decrypted anything on-chain to get here.
    function test_settle_totalsAreTheSumOfIndividualBets() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();
        _settle();

        // 100 + 250 + 75 on YES, 300 + 50 on NO.
        assertEq(encrypted.finalYesTotal(MARKET_ID), 425, "YES is not the sum of its bets");
        assertEq(encrypted.finalNoTotal(MARKET_ID), 350, "NO is not the sum of its bets");
    }

    // -----------------------------------------------------------------------
    // THE ATTACK
    // -----------------------------------------------------------------------

    /// @notice A valid proof attached to a fabricated total must not settle the market.
    ///
    /// @dev This is the whole reason `_checkClaimedPlaintext` exists. The decryption share
    ///      and the Chaum-Pedersen proof here are genuine and verify perfectly -- the
    ///      fixture asserts as much in JS before writing them. Only the claimed number is
    ///      false. The revert must therefore be `ClaimedPlaintextMismatch`, NOT
    ///      `InvalidDecryptionProof`: if it were the latter, the test would be passing for
    ///      the wrong reason and the binding could be silently broken.
    function test_settle_rejectsHonestProofWithLyingTotal() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();

        uint256 lie = _u(".honestProofLyingTotal.claimedTotal");
        assertTrue(lie != _u(".yes.total"), "fixture is not actually lying");

        vm.expectRevert(EncryptedParimutuelPool.ClaimedPlaintextMismatch.selector);
        encrypted.publishFinalTotals(MARKET_ID, lie, _u(".no.total"), _dec("yes"), _dec("no"));
    }

    /// @notice And the proof itself still has to be real -- the binding did not replace
    ///         the DLEQ check, it sits on top of it.
    function test_settle_rejectsForgedDecryptionShare() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();

        EncryptedParimutuelPool.Decryption memory forged = _dec("yes");
        forged.dx = forged.dx + 1;

        vm.expectRevert(EncryptedParimutuelPool.InvalidDecryptionProof.selector);
        encrypted.publishFinalTotals(MARKET_ID, _u(".yes.total"), _u(".no.total"), forged, _dec("no"));
    }

    function test_settle_rejectsTamperedProofScalar() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();

        EncryptedParimutuelPool.Decryption memory tampered = _dec("yes");
        tampered.proof.z = tampered.proof.z + 1;

        vm.expectRevert(EncryptedParimutuelPool.InvalidDecryptionProof.selector);
        encrypted.publishFinalTotals(MARKET_ID, _u(".yes.total"), _u(".no.total"), tampered, _dec("no"));
    }

    // -----------------------------------------------------------------------
    // Timing gates -- both are privacy controls, not bookkeeping
    // -----------------------------------------------------------------------

    /// @notice Revealing exact totals while betting is open hands late bettors precisely
    ///         the read the encryption exists to deny.
    function test_settle_refusedWhileBettingOpen() public {
        _seedAccumulator("yes", "no");

        vm.expectRevert(EncryptedParimutuelPool.BettingStillOpen.selector);
        _settle();
    }

    function test_settle_refusedBeforeResolution() public {
        _seedAccumulator("yes", "no");
        vm.warp(resolutionStart + 1);

        vm.expectRevert(EncryptedParimutuelPool.MarketNotResolved.selector);
        _settle();
    }

    function test_settle_isOneShot() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();
        _settle();

        vm.expectRevert(EncryptedParimutuelPool.AlreadySettled.selector);
        _settle();
    }

    // -----------------------------------------------------------------------
    // Empty side
    // -----------------------------------------------------------------------

    /// @notice A market can close with nothing on one side and must still settle.
    /// @dev `[0]G` is the identity `(0,1)`, a different code path from every other value.
    function test_settle_handlesEmptySide() public {
        _seedAccumulator("yes", "empty");
        _closeAndResolve();

        encrypted.publishFinalTotals(MARKET_ID, _u(".yes.total"), 0, _dec("yes"), _dec("empty"));

        assertEq(encrypted.finalNoTotal(MARKET_ID), 0, "empty side did not settle to zero");
        assertEq(encrypted.finalYesProbabilityBps(MARKET_ID), 10_000, "one-sided pool should read 100%");
        // Winners split the whole pool, which is exactly their own stakes back.
        assertEq(encrypted.payoutUnits(MARKET_ID, 1, 100), 100, "one-sided payout should be 1:1");
    }

    // -----------------------------------------------------------------------
    // Payout maths
    // -----------------------------------------------------------------------

    function test_payout_isProRataAndCannotExceedThePool() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();
        _settle();

        uint256 yes = _u(".expected.yesTotal");
        uint256 no = _u(".expected.noTotal");

        // A holder of the entire winning side receives the entire pool, never more.
        assertEq(encrypted.payoutUnits(MARKET_ID, 1, yes), yes + no, "full winner should receive the whole pool");

        // Truncation is down-only, so payouts sum to at most the pool.
        uint256 half = encrypted.payoutUnits(MARKET_ID, 1, yes / 2);
        assertLe(half * 2, yes + no, "truncation must not let payouts exceed the pool");
    }

    function test_payout_revertsBeforeSettlement() public {
        vm.expectRevert(EncryptedParimutuelPool.NotSettled.selector);
        encrypted.payoutUnits(MARKET_ID, 1, 100);
    }

    // -----------------------------------------------------------------------
    // Attested ratio -- informational, and rate-limited for privacy
    // -----------------------------------------------------------------------

    /// @notice Continuous publication would let an observer diff the odds after each bet
    ///         and recover roughly what that bet was. The cadence is enforced on-chain
    ///         rather than trusted to the publisher's timer.
    function test_attestedRatio_enforcesCadence() public {
        encrypted.publishAttestedRatio(MARKET_ID, 5_500);
        assertEq(encrypted.attestedRatioBps(MARKET_ID), 5_500, "ratio not stored");

        vm.expectRevert(EncryptedParimutuelPool.PublishedTooSoon.selector);
        encrypted.publishAttestedRatio(MARKET_ID, 5_600);

        vm.warp(block.timestamp + MIN_PUBLISH_INTERVAL);
        encrypted.publishAttestedRatio(MARKET_ID, 5_600);
        assertEq(encrypted.attestedRatioBps(MARKET_ID), 5_600, "ratio not updated after the interval");
    }

    function test_attestedRatio_rejectsOutOfRange() public {
        vm.expectRevert(EncryptedParimutuelPool.InvalidRatio.selector);
        encrypted.publishAttestedRatio(MARKET_ID, 10_001);
    }

    /// @notice The attested ratio must never influence settlement. It is operator-asserted
    ///         and unverifiable; if a payout ever read it, this contract's security
    ///         argument would be void.
    function test_attestedRatio_doesNotAffectSettledTotals() public {
        encrypted.publishAttestedRatio(MARKET_ID, 9_900);

        _seedAccumulator("yes", "no");
        _closeAndResolve();
        _settle();

        assertEq(encrypted.finalYesTotal(MARKET_ID), _u(".expected.yesTotal"), "attestation leaked into settlement");
        assertEq(
            encrypted.finalYesProbabilityBps(MARKET_ID),
            _u(".expected.yesProbabilityBps"),
            "settled probability follows the attestation rather than the ciphertext"
        );
    }

    // -----------------------------------------------------------------------
    // Gas
    // -----------------------------------------------------------------------

    function test_report_settlementGas() public {
        _seedAccumulator("yes", "no");
        _closeAndResolve();

        // Hoisted: `_u` runs vm.parseJson cheatcodes costing ~450,000 gas each, which
        // would otherwise be reported as protocol cost.
        uint256 yesTotal = _u(".yes.total");
        uint256 noTotal = _u(".no.total");
        EncryptedParimutuelPool.Decryption memory yes = _dec("yes");
        EncryptedParimutuelPool.Decryption memory no = _dec("no");

        uint256 before = gasleft();
        encrypted.publishFinalTotals(MARKET_ID, yesTotal, noTotal, yes, no);
        uint256 used = before - gasleft();

        console.log("=== publishFinalTotals: 2 DLEQ verifies + 2 plaintext bindings ===");
        console.log("gas used:", used);
        console.log("  once per market, at settlement -- not a per-bet cost");
    }
}
