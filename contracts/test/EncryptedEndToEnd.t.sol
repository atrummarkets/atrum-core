// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console, stdJson} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {EncryptedParimutuelPool} from "../src/EncryptedParimutuelPool.sol";
import {ShieldedPool, IDepositVerifier, IActionVerifier, IActionVerifier8} from "../src/ShieldedPool.sol";
import {ChaumPedersen} from "../src/ChaumPedersen.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {RedeemVerifier} from "../src/verifiers/RedeemVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";

/// @notice THE SEAM TEST: settle the ciphertext a real encrypted bet actually produced.
///
/// @dev Phase 2's two halves were each well tested, against different inputs:
///
///        - `ShieldedPool.t.sol` runs a real `betEncrypted` proof, so the accumulator
///          receives a ciphertext the CIRCUIT built.
///        - `EncryptedParimutuelPool.t.sol` settles ciphertexts that
///          `gen_settlement_fixtures.mjs` built directly in JavaScript.
///
///      Nothing joined them. No test had ever shown that a ciphertext produced by the
///      circuit can be decrypted and settled on-chain — which is exactly the claim Phase 2
///      rests on.
///
///      That gap is worth closing specifically because every real bug found in this repo so
///      far has lived in that kind of seam, not inside a component:
///
///        - `queuePadding`: `deposit.circom` and `redeem.circom` were each correct; neither
///          proved that a tree leaf originated from a deposit. Full vault drain.
///        - the guard migration: `units == 0` was checked in Solidity, and when `units` went
///          private the check did not move into the circuit. It just vanished.
///
///      Both halves passing says nothing about the join. This test is the join: one real
///      `betEncrypted`, then `publishFinalTotals` against the accumulator state that bet
///      produced, then a payout computed from it.
contract EncryptedEndToEndTest is Test {
    using stdJson for string;

    MockERC20 usdc;
    Vault vault;
    Vault encryptedVault;
    IncrementalMerkleTree tree;
    MappingNullifierSet nullifiers;
    ParimutuelPool parimutuel;
    ElGamalAccumulator accumulator;
    EncryptedParimutuelPool encrypted;
    ShieldedPool pool;
    IPoseidonT3 poseidon;

    address sequencer = makeAddr("sequencer");
    address resolver = makeAddr("resolver");
    address depositor = makeAddr("depositor");

    uint32 constant MARKET_ID = 7;
    uint32 constant ENCRYPTED_MARKET_ID = 8;
    uint256 constant DENOM = 1e6;
    uint256 constant MIN_PUBLISH_INTERVAL = 1 hours;
    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty")) % R;

    string actions;
    string e2e;

    uint64 bettingClose;
    uint64 resolutionStart;

    function setUp() public {
        vm.warp(1_800_000_000);
        actions = vm.readFile("../circuits/build/action-fixtures.json");
        e2e = vm.readFile("../circuits/build/e2e-fixtures.json");

        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);
        poseidon = IPoseidonT3(addr);

        usdc = new MockERC20();
        bettingClose = uint64(block.timestamp + 7 days);
        resolutionStart = bettingClose + 2 hours;
        vault = new Vault(IERC20(address(usdc)), DENOM, resolver, keccak256("spec"), bettingClose, resolutionStart);
        encryptedVault =
            new Vault(IERC20(address(usdc)), DENOM, resolver, keccak256("spec-enc"), bettingClose, resolutionStart);

        DepositVerifier dv = new DepositVerifier();
        BetVerifier bv = new BetVerifier();
        RedeemVerifier rv = new RedeemVerifier();
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
            IActionVerifier(address(rv)),
            IActionVerifier8(address(bev)),
            sequencer,
            address(this)
        );
        require(address(pool) == predicted, "pool address prediction failed");

        nullifiers.bindPool(address(pool));
        // Market 7 stays on the Phase 1 plaintext path and market 8 on the encrypted one --
        // the fixtures were generated against exactly that split, and a market cannot be
        // both (two sources of truth for one pool total is a settlement bug waiting).
        pool.registerMarket(MARKET_ID, vault);
        pool.registerEncryptedMarket(ENCRYPTED_MARKET_ID, encryptedVault);

        // The committee key comes from the e2e fixture, which derives it from the same
        // `committee-key.json` the CIRCUIT was compiled against. If those ever diverge the
        // settlement below cannot verify, which is the divergence this test exists to catch.
        encrypted = new EncryptedParimutuelPool(
            accumulator, pool, _e(".committeeKey[0]"), _e(".committeeKey[1]"), MIN_PUBLISH_INTERVAL
        );
    }

    function _a(string memory k) internal view returns (uint256) {
        return actions.readUint(k);
    }

    function _e(string memory k) internal view returns (uint256) {
        return e2e.readUint(k);
    }

    function _dec(string memory side) internal view returns (EncryptedParimutuelPool.Decryption memory) {
        return EncryptedParimutuelPool.Decryption({
            dx: _e(string.concat(".", side, ".d[0]")),
            dy: _e(string.concat(".", side, ".d[1]")),
            proof: ChaumPedersen.Proof({
                ax: _e(string.concat(".", side, ".proof.ax")),
                ay: _e(string.concat(".", side, ".proof.ay")),
                bx: _e(string.concat(".", side, ".proof.bx")),
                by: _e(string.concat(".", side, ".proof.by")),
                z: _e(string.concat(".", side, ".proof.z"))
            })
        });
    }

    function _flush(string memory key) internal {
        uint256[] memory real = actions.readUintArray(key);
        vm.prank(sequencer);
        pool.flushBatch(real);
    }

    function _pA(string memory a) internal view returns (uint256[2] memory) {
        return [_a(string.concat(".", a, ".pA[0]")), _a(string.concat(".", a, ".pA[1]"))];
    }

    function _pB(string memory a) internal view returns (uint256[2][2] memory) {
        return [
            [_a(string.concat(".", a, ".pB[0][0]")), _a(string.concat(".", a, ".pB[0][1]"))],
            [_a(string.concat(".", a, ".pB[1][0]")), _a(string.concat(".", a, ".pB[1][1]"))]
        ];
    }

    function _pC(string memory a) internal view returns (uint256[2] memory) {
        return [_a(string.concat(".", a, ".pC[0]")), _a(string.concat(".", a, ".pC[1]"))];
    }

    function _ciphertext(string memory a) internal view returns (uint256[4] memory) {
        return [
            _a(string.concat(".", a, ".ciphertext[0]")),
            _a(string.concat(".", a, ".ciphertext[1]")),
            _a(string.concat(".", a, ".ciphertext[2]")),
            _a(string.concat(".", a, ".ciphertext[3]"))
        ];
    }

    /// @dev The full real sequence the fixtures were generated against. Every proof here is
    ///      a real Groth16 proof; nothing is mocked and no state is written directly.
    ///
    ///      Plaintext market 7 first (deposit, bet) because the fixture's tree contains
    ///      those leaves and the encrypted notes' Merkle paths depend on them. Skipping
    ///      ahead would change every root.
    function _runToBothEncryptedBets() internal {
        uint256 units = _a(".deposit.units");
        usdc.mint(depositor, units * DENOM * 4);

        vm.prank(depositor);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(depositor);
        pool.deposit(_pA("deposit"), _pB("deposit"), _pC("deposit"), _a(".deposit.commitment"), MARKET_ID, units);
        _flush(".batch1Real");

        pool.bet(
            _pA("bet"),
            _pB("bet"),
            _pC("bet"),
            _a(".bet.root"),
            _a(".bet.nullifierHash"),
            _a(".bet.newCommitment"),
            _a(".bet.betData")
        );
        _flush(".batch2Real");

        vm.prank(depositor);
        pool.deposit(
            _pA("depositEncrypted"),
            _pB("depositEncrypted"),
            _pC("depositEncrypted"),
            _a(".depositEncrypted.commitment"),
            ENCRYPTED_MARKET_ID,
            units
        );
        _flush(".batch3Real");
        assertEq(tree.root(), _a(".rootAfterBatch3"), "root diverged from the mirror at batch 3");

        // First real encrypted bet: 100 units, never revealed to the contract.
        pool.betEncrypted(
            _pA("betEncrypted"),
            _pB("betEncrypted"),
            _pC("betEncrypted"),
            _a(".betEncrypted.root"),
            _a(".betEncrypted.nullifierHash"),
            _a(".betEncrypted.newCommitment"),
            _a(".betEncrypted.betMeta"),
            _ciphertext("betEncrypted")
        );

        vm.prank(depositor);
        pool.deposit(
            _pA("depositEncrypted2"),
            _pB("depositEncrypted2"),
            _pC("depositEncrypted2"),
            _a(".depositEncrypted2.commitment"),
            ENCRYPTED_MARKET_ID,
            _a(".depositEncrypted2.units")
        );
        _flush(".batch4Real");
        assertEq(tree.root(), _a(".rootAfterBatch4"), "root diverged from the mirror at batch 4");

        // Second real encrypted bet: 37 units. The accumulator now holds Enc(100) + Enc(37),
        // summed by point addition, still never decrypted.
        pool.betEncrypted(
            _pA("betEncrypted2"),
            _pB("betEncrypted2"),
            _pC("betEncrypted2"),
            _a(".betEncrypted2.root"),
            _a(".betEncrypted2.nullifierHash"),
            _a(".betEncrypted2.newCommitment"),
            _a(".betEncrypted2.betMeta"),
            _ciphertext("betEncrypted2")
        );
    }

    function _closeAndResolve() internal {
        vm.warp(resolutionStart);
        vm.prank(resolver);
        encryptedVault.resolve(Vault.Outcome.Yes);
    }

    // -----------------------------------------------------------------------
    // The seam
    // -----------------------------------------------------------------------

    /// @notice The on-chain accumulator must hold the homomorphic SUM of both real bets.
    ///
    /// @dev Enc(100) + Enc(37) summed by on-chain point addition, checked against the sum the
    ///      JS mirror computed from the same two circuit-produced ciphertexts. This is the
    ///      earliest point a divergence would show — before any decryption is attempted — and
    ///      it also covers accumulating onto the identity, which is (0,1) and not all-zeros.
    function test_accumulatorHoldsSumOfBothRealBets() public {
        _runToBothEncryptedBets();

        (uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y) = accumulator.totalAffine(ENCRYPTED_MARKET_ID, 1);

        assertEq(c1x, _a(".accumulatorAfterBothBets.ciphertext[0]"), "accumulated c1.x wrong");
        assertEq(c1y, _a(".accumulatorAfterBothBets.ciphertext[1]"), "accumulated c1.y wrong");
        assertEq(c2x, _a(".accumulatorAfterBothBets.ciphertext[2]"), "accumulated c2.x wrong");
        assertEq(c2y, _a(".accumulatorAfterBothBets.ciphertext[3]"), "accumulated c2.y wrong");

        // The e2e fixture computed its decryption against this exact state. If these
        // disagree, the settlement below is proving something about a different ciphertext
        // than the chain actually holds.
        assertEq(c1x, _e(".yes.c1[0]"), "e2e fixture c1.x disagrees with the chain");
        assertEq(c1y, _e(".yes.c1[1]"), "e2e fixture c1.y disagrees with the chain");
        assertEq(c2x, _e(".yes.c2[0]"), "e2e fixture c2.x disagrees with the chain");
        assertEq(c2y, _e(".yes.c2[1]"), "e2e fixture c2.y disagrees with the chain");

        // The NO side was never bet on and must still be Enc(0) = the identity.
        (uint256 n1x, uint256 n1y,,) = accumulator.totalAffine(ENCRYPTED_MARKET_ID, 2);
        assertEq(n1x, 0, "untouched NO side is not the identity");
        assertEq(n1y, 1, "identity is (0,1), not all-zeros");
    }

    /// @notice THE END-TO-END CLAIM: a real encrypted bet settles to the amount it staked.
    ///
    /// @dev This is the assertion Phase 2 exists to support. `units` was private throughout:
    ///      the contract never saw it, the circuit proved the ciphertext encrypted it, the
    ///      accumulator summed ciphertext only, and the committee's decryption — bound by a
    ///      DLEQ proof — recovers it at settlement.
    function test_bothRealEncryptedBetsSettleToTheirSum() public {
        _runToBothEncryptedBets();
        _closeAndResolve();

        uint256 stake = _e(".total");
        assertGt(stake, 0, "fixture stake is zero -- test would be vacuous");

        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, stake, 0, _dec("yes"), _dec("no"));

        assertTrue(encrypted.settled(ENCRYPTED_MARKET_ID), "market did not settle");
        assertEq(encrypted.finalYesTotal(ENCRYPTED_MARKET_ID), stake, "settled YES total != the staked amount");
        assertEq(encrypted.finalNoTotal(ENCRYPTED_MARKET_ID), 0, "settled NO total should be zero");

        console.log("=== END TO END ===");
        console.log("staked (private throughout) :", stake);
        console.log("settled YES total           :", encrypted.finalYesTotal(ENCRYPTED_MARKET_ID));
        console.log("published YES probability   :", encrypted.finalYesProbabilityBps(ENCRYPTED_MARKET_ID));
    }

    /// @notice The published odds derive from the decrypted totals, not from anything the
    ///         contract could see earlier.
    function test_publishedOddsFollowFromTheDecryptedTotals() public {
        _runToBothEncryptedBets();
        _closeAndResolve();

        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, _e(".total"), 0, _dec("yes"), _dec("no"));

        assertEq(
            encrypted.finalYesProbabilityBps(ENCRYPTED_MARKET_ID),
            _e(".expected.yesProbabilityBps"),
            "published probability is wrong"
        );
    }

    /// @notice Payout is computed from the settled totals. Sole side staked, so the winner
    ///         takes the whole pool, which with nothing on NO is 1:1.
    function test_payoutFollowsFromSettledTotals() public {
        _runToBothEncryptedBets();
        _closeAndResolve();

        uint256 stake = _e(".total");
        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, stake, 0, _dec("yes"), _dec("no"));

        assertEq(
            encrypted.payoutUnits(ENCRYPTED_MARKET_ID, 1, stake),
            _e(".expected.payoutForFullTotal"),
            "payout does not follow from the settled totals"
        );
    }

    /// @notice A lying total is still rejected on the REAL accumulator state.
    /// @dev `EncryptedParimutuelPool.t.sol` proves this against a JS-built ciphertext. Worth
    ///      re-proving here: the binding must hold against the ciphertext the circuit
    ///      produced, which is the one that will exist in production.
    function test_lyingTotalRejectedAgainstRealCiphertext() public {
        _runToBothEncryptedBets();
        _closeAndResolve();

        uint256 lie = _e(".total") + 1;
        vm.expectRevert(EncryptedParimutuelPool.ClaimedPlaintextMismatch.selector);
        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, lie, 0, _dec("yes"), _dec("no"));
    }

    /// @notice The empty side is not a special case that gets waved through.
    /// @dev The NO accumulator holds Enc(0), whose C1 is the curve identity. An honest proof
    ///      for it must verify — and a claim that the empty side holds anything must not.
    function test_emptySideMustAlsoBeProven() public {
        _runToBothEncryptedBets();
        _closeAndResolve();

        vm.expectRevert(EncryptedParimutuelPool.ClaimedPlaintextMismatch.selector);
        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, _e(".total"), 1, _dec("yes"), _dec("no"));
    }

    /// @notice Settlement cannot happen while betting is open, even with a valid proof.
    /// @dev Revealing the totals early hands late bettors exactly the read the encryption
    ///      exists to deny.
    function test_cannotSettleWhileBettingOpen() public {
        _runToBothEncryptedBets();

        vm.expectRevert(EncryptedParimutuelPool.BettingStillOpen.selector);
        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, _e(".total"), 0, _dec("yes"), _dec("no"));
    }
}
