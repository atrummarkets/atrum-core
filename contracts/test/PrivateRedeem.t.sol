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
import {
    ShieldedPool,
    IDepositVerifier,
    IActionVerifier,
    IActionVerifier8,
    IEncryptedTotals
} from "../src/ShieldedPool.sol";
import {ChaumPedersen} from "../src/ChaumPedersen.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {RedeemVerifier} from "../src/verifiers/RedeemVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";
import {RedeemPrivateVerifier} from "../src/verifiers/RedeemPrivateVerifier.sol";

/// @notice PRIVATE REDEMPTION -- the one item both build plans refuse to cut.
///
/// @dev `atrum-build-plan.md`: *"Never cut private redemption."*
///      `atrum-4day-plan.md` §7: *"Redemption stays inside the shielded pool. Non-negotiable."*
///
///      The reason is specific: a public payout claim retroactively deanonymises every
///      position it pays, because the amount, the timing and the address correlate back to a
///      bet. That makes the privacy claim FALSE rather than weak.
///
///      `ShieldedPool.redeem` publishes both a recipient and an amount.
///      `redeemPrivate` publishes neither: the payout becomes a shielded note, and leaving for
///      public USDC is a separate action at a time of the holder's choosing.
///
///      WHAT THIS SUITE HAS TO ESTABLISH, beyond "it works"
///
///      1. No collateral moves. If any did, the amount would be observable and the whole
///         exercise pointless.
///      2. The payout note is tagged SETTLED and cannot be redeemed again. Without that tag
///         the payout note is itself redeemable as an unbet refund, giving an unbounded mint
///         where every individual step is legitimate and nullifiers do not help.
///      3. The divisors the proof used are the REAL settled totals. The payout division is
///         proved in-circuit against public divisors; if the contract does not pin those to
///         its own settled state, a prover invents a bigger pool and the circuit faithfully
///         computes an inflated payout from invented inputs.
contract PrivateRedeemTest is Test {
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
        RedeemPrivateVerifier rpv = new RedeemPrivateVerifier();

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
        pool.registerMarket(MARKET_ID, vault);
        pool.registerEncryptedMarket(ENCRYPTED_MARKET_ID, encryptedVault);

        encrypted = new EncryptedParimutuelPool(
            accumulator, pool, _e(".committeeKey[0]"), _e(".committeeKey[1]"), MIN_PUBLISH_INTERVAL
        );

        pool.bindEncryptedTotals(IEncryptedTotals(address(encrypted)), IActionVerifier(address(rpv)));
    }

    function _a(string memory k) internal view returns (uint256) {
        return actions.readUint(k);
    }

    function _e(string memory k) internal view returns (uint256) {
        return e2e.readUint(k);
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

    function _ct(string memory a) internal view returns (uint256[4] memory) {
        return [
            _a(string.concat(".", a, ".ciphertext[0]")),
            _a(string.concat(".", a, ".ciphertext[1]")),
            _a(string.concat(".", a, ".ciphertext[2]")),
            _a(string.concat(".", a, ".ciphertext[3]"))
        ];
    }

    function _flush(string memory key) internal {
        uint256[] memory real = actions.readUintArray(key);
        vm.prank(sequencer);
        pool.flushBatch(real);
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

    /// @dev The whole real lifecycle the fixtures were generated against, up to and including
    ///      grafting both position notes. Every proof is real.
    function _runToResolvedButUnsettled() internal {
        uint256 units = _a(".deposit.units");
        usdc.mint(depositor, units * DENOM * 6);
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

        pool.betEncrypted(
            _pA("betEncrypted"),
            _pB("betEncrypted"),
            _pC("betEncrypted"),
            _a(".betEncrypted.root"),
            _a(".betEncrypted.nullifierHash"),
            _a(".betEncrypted.newCommitment"),
            _a(".betEncrypted.betMeta"),
            _ct("betEncrypted")
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

        pool.betEncrypted(
            _pA("betEncrypted2"),
            _pB("betEncrypted2"),
            _pC("betEncrypted2"),
            _a(".betEncrypted2.root"),
            _a(".betEncrypted2.nullifierHash"),
            _a(".betEncrypted2.newCommitment"),
            _a(".betEncrypted2.betMeta"),
            _ct("betEncrypted2")
        );

        // Graft both position notes -- the redeem proof was built against this root.
        _flush(".batch5Real");
        assertEq(tree.root(), _a(".rootAfterBatch5"), "root diverged from the mirror at batch 5");

        // Resolve, but do not settle. Settlement is what publishes the divisors.
        vm.warp(resolutionStart);
        vm.prank(resolver);
        encryptedVault.resolve(Vault.Outcome.Yes);
    }

    function _runToSettled() internal {
        _runToResolvedButUnsettled();
        encrypted.publishFinalTotals(ENCRYPTED_MARKET_ID, _e(".total"), 0, _dec("yes"), _dec("no"));
        assertTrue(encrypted.settled(ENCRYPTED_MARKET_ID), "market did not settle");
    }

    function _redeemPrivate() internal {
        pool.redeemPrivate(
            _pA("redeemPrivate"),
            _pB("redeemPrivate"),
            _pC("redeemPrivate"),
            _a(".redeemPrivate.root"),
            _a(".redeemPrivate.nullifierHash"),
            _a(".redeemPrivate.newCommitment"),
            _a(".redeemPrivate.redeemMeta")
        );
    }

    // -----------------------------------------------------------------------
    // The claim
    // -----------------------------------------------------------------------

    /// @notice A winning position redeems into a shielded note, and NOTHING is paid out.
    function test_redeemPrivate_paysIntoANoteAndMovesNoCollateral() public {
        _runToSettled();

        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));
        uint256 vaultBalanceBefore = usdc.balanceOf(address(encryptedVault));
        uint256 queuedBefore = pool.queuedCount();

        // Hoisted. `_a`/`_pA` are vm.parseJson cheatcodes costing ~450,000 gas per call;
        // inline they land inside the bracket and reported this action at 3,578,946 -- a
        // number that looks like a contract catastrophe and is entirely harness overhead.
        // Third time this trap has appeared in this repo.
        uint256[2] memory pA = _pA("redeemPrivate");
        uint256[2][2] memory pB = _pB("redeemPrivate");
        uint256[2] memory pC = _pC("redeemPrivate");
        uint256 root = _a(".redeemPrivate.root");
        uint256 nh = _a(".redeemPrivate.nullifierHash");
        uint256 newCommitment = _a(".redeemPrivate.newCommitment");
        uint256 meta = _a(".redeemPrivate.redeemMeta");

        uint256 g = gasleft();
        pool.redeemPrivate(pA, pB, pC, root, nh, newCommitment, meta);
        uint256 used = g - gasleft();

        // THE point: no collateral moved anywhere.
        assertEq(usdc.balanceOf(address(pool)), poolBalanceBefore, "pool balance changed");
        assertEq(usdc.balanceOf(address(encryptedVault)), vaultBalanceBefore, "vault balance changed");

        // The payout exists only as a queued commitment.
        assertEq(pool.queuedCount(), queuedBefore + 1, "payout note was not queued");
        assertEq(
            pool.pendingCommitments(queuedBefore),
            _a(".redeemPrivate.newCommitment"),
            "queued note is not the payout note"
        );

        assertTrue(nullifiers.isSpent(_a(".redeemPrivate.nullifierHash")), "position nullifier not burned");

        console.log("=== PRIVATE REDEEM ===");
        console.log("position units (private, never on-chain) :", _a(".redeemPrivate.privateUnits"));
        console.log("payout units  (private, never on-chain) :", _a(".redeemPrivate.privatePayout"));
        console.log("collateral moved                        : 0");
        console.log("gas                                     :", used);
    }

    /// @notice The position cannot be redeemed twice.
    function test_redeemPrivate_isOneShot() public {
        _runToSettled();
        _redeemPrivate();

        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        _redeemPrivate();
    }

    /// @notice Cannot redeem before the market is settled -- the divisors do not exist yet.
    /// @dev Runs the whole real sequence and skips ONLY `publishFinalTotals`. An earlier
    ///      version stopped after batch 1 and got `UnknownRoot` instead: the root check runs
    ///      before the settlement check, so the test was passing for the wrong reason and
    ///      proving nothing about settlement.
    function test_redeemPrivate_revertsBeforeSettlement() public {
        _runToResolvedButUnsettled();

        vm.expectRevert(ShieldedPool.NotSettled2.selector);
        _redeemPrivate();
    }

    // -----------------------------------------------------------------------
    // The divisors must be the real ones
    // -----------------------------------------------------------------------

    /// @notice A proof built against invented pool totals must be refused.
    ///
    /// @dev This is the check that makes the in-circuit division trustworthy. The circuit
    ///      proves `units * totalPool == payout * winningPool + remainder` faithfully -- but
    ///      it proves it about whatever divisors it was handed. If the contract does not pin
    ///      those to its own settled state, a prover claims a larger `totalPool` and walks
    ///      away with a proportionally inflated payout, with a perfectly valid proof.
    function test_redeemPrivate_rejectsInventedTotals() public {
        _runToSettled();

        // Same proof, but claim a pool 10x larger. The contract must compare against its own
        // settled numbers rather than trusting the packed ones.
        uint256 meta = _a(".redeemPrivate.redeemMeta");
        uint256 inflated = meta + (uint256(10_000) << 64); // bump totalPool

        vm.expectRevert(ShieldedPool.TotalsMismatch.selector);
        pool.redeemPrivate(
            _pA("redeemPrivate"),
            _pB("redeemPrivate"),
            _pC("redeemPrivate"),
            _a(".redeemPrivate.root"),
            _a(".redeemPrivate.nullifierHash"),
            _a(".redeemPrivate.newCommitment"),
            inflated
        );
    }

    /// @notice Shrinking the winning pool inflates every holder's share, and must be refused.
    function test_redeemPrivate_rejectsShrunkWinningPool() public {
        _runToSettled();

        uint256 meta = _a(".redeemPrivate.redeemMeta");
        // Clear the low 64 bits (winningPool) and set it to 1.
        uint256 shrunk = (meta & ~uint256(type(uint64).max)) | 1;

        vm.expectRevert(ShieldedPool.TotalsMismatch.selector);
        pool.redeemPrivate(
            _pA("redeemPrivate"),
            _pB("redeemPrivate"),
            _pC("redeemPrivate"),
            _a(".redeemPrivate.root"),
            _a(".redeemPrivate.nullifierHash"),
            _a(".redeemPrivate.newCommitment"),
            shrunk
        );
    }

    /// @notice A plaintext market cannot be redeemed through the encrypted path.
    /// @dev Its total lives in `parimutuel`, not in the settled encrypted totals, so allowing
    ///      it would compute a payout from the wrong pool entirely.
    function test_redeemPrivate_rejectsPlaintextMarket() public {
        _runToSettled();

        uint256 meta = _a(".redeemPrivate.redeemMeta");
        // Rewrite marketId (bits 130+) from 8 to 7.
        uint256 plaintext = (meta & ((uint256(1) << 130) - 1)) | (uint256(MARKET_ID) << 130);

        vm.expectRevert(ShieldedPool.WrongActionForMarket.selector);
        pool.redeemPrivate(
            _pA("redeemPrivate"),
            _pB("redeemPrivate"),
            _pC("redeemPrivate"),
            _a(".redeemPrivate.root"),
            _a(".redeemPrivate.nullifierHash"),
            _a(".redeemPrivate.newCommitment"),
            plaintext
        );
    }

    // -----------------------------------------------------------------------
    // Binding is one-shot
    // -----------------------------------------------------------------------

    function test_bindEncryptedTotals_isIrreversible() public {
        vm.expectRevert(ShieldedPool.AlreadyBound.selector);
        pool.bindEncryptedTotals(IEncryptedTotals(address(encrypted)), IActionVerifier(address(0xBEEF)));
    }

    function test_bindEncryptedTotals_onlyAdmin() public {
        ShieldedPool fresh = _freshPool();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ShieldedPool.NotAdmin.selector);
        fresh.bindEncryptedTotals(IEncryptedTotals(address(encrypted)), IActionVerifier(address(0xBEEF)));
    }

    function _freshPool() internal returns (ShieldedPool) {
        // Verifiers FIRST. Deploying them inline in the constructor arguments advances this
        // contract's nonce after the prediction is computed, so the address never matches.
        DepositVerifier dv = new DepositVerifier();
        BetVerifier bv = new BetVerifier();
        RedeemVerifier rv = new RedeemVerifier();
        BetEncryptedVerifier bev = new BetEncryptedVerifier();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        IncrementalMerkleTree t = new IncrementalMerkleTree(poseidon, ZERO_VALUE, predicted);
        ParimutuelPool pm = new ParimutuelPool(predicted);
        MappingNullifierSet ns = new MappingNullifierSet();
        ElGamalAccumulator ac = new ElGamalAccumulator(predicted);

        ShieldedPool p = new ShieldedPool(
            t,
            ns,
            pm,
            ac,
            IDepositVerifier(address(dv)),
            IActionVerifier(address(bv)),
            IActionVerifier(address(rv)),
            IActionVerifier8(address(bev)),
            sequencer,
            address(this)
        );
        require(address(p) == predicted, "fresh pool prediction failed");
        return p;
    }
}
