// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, stdJson} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {
    ShieldedPool,
    IDepositVerifier,
    IActionVerifier,
    IActionVerifier8
} from "../src/ShieldedPool.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";

/// @notice The gate that refuses a bet which cannot be private.
///
/// @dev WHAT THIS IS FOR
///
///      A user betting into a pool of two is not making a private bet. They are making a
///      public one with extra steps, and they have no way to tell, because the proof looks
///      identical either way. Every other suite runs at `MIN_ANON_SET = 2` so the recorded
///      lifecycle is reachable at all; this one runs the gate at values where it BITES.
///
///      THE TWO GATES ARE DIFFERENT, AND THE DIFFERENCE IS THE POINT
///
///      The original plan gated betting on the count for the note's own denomination. That is
///      not implementable: `betEncrypted` never receives `units` -- the stake is encrypted, so
///      the contract cannot know which rung the spent note sits on. It is also the wrong set.
///      A bet publishes no amount, so its anonymity set is every unspent note, not every note
///      of one size.
///
///      Denomination narrows the crowd only where a size becomes PUBLIC, which is `withdraw`.
///      So betting is gated on the total, and withdrawing is gated per rung.
contract AnonymitySetGateTest is Test {
    using stdJson for string;

    MockERC20 usdc;
    Vault vault;
    IncrementalMerkleTree tree;
    MappingNullifierSet nullifiers;
    ParimutuelPool parimutuel;
    ElGamalAccumulator accumulator;
    ShieldedPool pool;
    IPoseidonT3 poseidon;

    address sequencer = makeAddr("sequencer");
    address resolver = makeAddr("resolver");
    address depositor = makeAddr("depositor");

    uint32 constant MARKET_ID = 7;
    uint256 constant DENOM = 1e6;

    /// @dev The production value. This suite exists precisely to run at it.
    uint256 constant K = 8;

    /// @dev Zero in every suite but `RootAge.t.sol`. The recorded lifecycle bets against the
    ///      root of the batch it was built on, and `vm.warp`ing between every step to age it
    ///      would change nothing about what those suites test while making each of them
    ///      depend on a timing constant they do not care about.
    uint256 constant MIN_ROOT_AGE = 0;

    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty")) % R;

    string fixtures;

    function setUp() public {
        vm.warp(1_800_000_000);
        fixtures = vm.readFile("../circuits/build/action-fixtures.json");

        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);
        poseidon = IPoseidonT3(addr);

        usdc = new MockERC20();
        uint64 bettingClose = uint64(block.timestamp + 7 days);
        vault = new Vault(
            IERC20(address(usdc)), DENOM, resolver, keccak256("spec"), bettingClose, bettingClose + 2 hours
        );

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
            ShieldedPool.Policy({
                denomination: DENOM,
                minAnonymitySet: K,
                minRootAge: MIN_ROOT_AGE
            }),
            sequencer,
            address(this)
        );
        require(address(pool) == predicted, "pool address prediction failed");

        nullifiers.bindPool(address(pool));
        pool.registerMarket(MARKET_ID, vault);

        usdc.mint(depositor, 1_000_000 * DENOM);
        vm.prank(depositor);
        usdc.approve(address(pool), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    function test_constructorRefusesASetOfOne() public {
        // A "minimum anonymity set" of 1 passes for the only note in the pool -- the exact
        // case the gate exists to refuse. Permitting it would let a deployment advertise a
        // gate that gates nothing, and `minAnonymitySet` is public, so people would read it.
        vm.expectRevert(ShieldedPool.MinAnonymitySetTooSmall.selector);
        new ShieldedPool(
            tree,
            nullifiers,
            parimutuel,
            accumulator,
            IDepositVerifier(address(0xD1)),
            IActionVerifier(address(0xB1)),
            IActionVerifier8(address(0xB8)),
            IERC20(address(usdc)),
            ShieldedPool.Policy({
                denomination: DENOM,
                minAnonymitySet: 1,
                minRootAge: MIN_ROOT_AGE
            }),
            sequencer,
            address(this)
        );
    }

    function test_minAnonymitySetIsReadableOnChain() public view {
        // Immutable and public on purpose: anyone can tell a test deployment from a real one
        // without trusting what the operator says about it.
        assertEq(pool.minAnonymitySet(), K, "K is not what the deployment claims");
    }

    // -----------------------------------------------------------------------
    // The bet gate
    // -----------------------------------------------------------------------

    /// @notice A pool with one deposit refuses to let that deposit bet.
    /// @dev The bootstrapping cost, asserted rather than hidden. There is no version of this
    ///      gate without it: refusing to let anyone bet into a crowd that does not exist means
    ///      the first K depositors have to wait for each other.
    function test_bet_revertsWhileTheCrowdIsTooSmall() public {
        _deposit(".deposit", 100);
        assertEq(pool.totalDeposits(), 1, "precondition: exactly one deposit");

        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.AnonymitySetTooSmall.selector, 1, K));
        pool.bet(
            _pA("bet"),
            _pB("bet"),
            _pC("bet"),
            _u(".bet.root"),
            _u(".bet.nullifierHash"),
            _u(".bet.newCommitment"),
            _u(".bet.betData")
        );
    }

    /// @notice The revert carries the real number, not just a refusal.
    /// @dev The counter is an UPPER bound on the live set -- notes get spent and it never
    ///      decrements -- so reporting it lets a client say "4 notes currently look like
    ///      yours, 8 needed" instead of implying a precision the pool does not have.
    function test_bet_revertReportsHowFarOffThePoolIs() public {
        _deposit(".deposit", 100);
        _deposit(".depositLadder", 10);

        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.AnonymitySetTooSmall.selector, 2, K));
        pool.bet(
            _pA("bet"),
            _pB("bet"),
            _pC("bet"),
            _u(".bet.root"),
            _u(".bet.nullifierHash"),
            _u(".bet.newCommitment"),
            _u(".bet.betData")
        );
    }

    /// @notice The gate is checked BEFORE the proof, so a rejection costs no verification.
    /// @dev Not a micro-optimisation. Every action is submitted with the same declared gas
    ///      limit and Monad bills the declared limit, so ordering does not change what a user
    ///      pays -- but it does mean an invalid-proof revert and a too-small-crowd revert stay
    ///      distinguishable, and the second is the one a client can act on.
    function test_bet_gateIsCheckedBeforeTheProof() public {
        _deposit(".deposit", 100);

        // Deliberately garbage proof points. If the gate ran second, this would revert with
        // InvalidProof and the caller would never learn the real reason.
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.AnonymitySetTooSmall.selector, 1, K));
        pool.bet(
            [uint256(1), uint256(2)],
            [[uint256(3), uint256(4)], [uint256(5), uint256(6)]],
            [uint256(7), uint256(8)],
            _u(".bet.root"),
            _u(".bet.nullifierHash"),
            _u(".bet.newCommitment"),
            _u(".bet.betData")
        );
    }

    /// @notice Once K deposits exist, the gate stops being the reason a bet fails.
    /// @dev The proof here is against a root this pool never grafted, so `UnknownRoot` is the
    ///      correct and expected outcome -- and it is exactly the point. The assertion is that
    ///      the ANONYMITY GATE has stopped objecting, which a revert of any other kind proves.
    ///      Driving a genuinely successful bet would need a fixture chain built against this
    ///      pool's roots, which is what `PrivateRedeem.t.sol` already does at a lower K.
    function test_bet_gateOpensAtK() public {
        for (uint256 i = 0; i < K; i++) {
            // The same recorded deposit proof, replayed. The pool has no duplicate-commitment
            // check -- commitments are opaque and a repeat is indistinguishable from a fresh
            // note -- so this is a legitimate way to move the counter to K.
            _deposit(".deposit", 100);
        }
        assertEq(pool.totalDeposits(), K, "counter did not reach K");

        vm.expectRevert(ShieldedPool.UnknownRoot.selector);
        pool.bet(
            _pA("bet"),
            _pB("bet"),
            _pC("bet"),
            _u(".bet.root"),
            _u(".bet.nullifierHash"),
            _u(".bet.newCommitment"),
            _u(".bet.betData")
        );
    }

    /// @notice The counter never goes down.
    /// @dev It cannot. Decrementing would require observing which notes are still unspent,
    ///      and that is precisely the fact the pool exists to hide. The consequence is that
    ///      the figure is an upper bound, and the code says so rather than pretending.
    function test_counterIsMonotonic() public {
        for (uint256 i = 0; i < 3; i++) {
            _deposit(".deposit", 100);
            assertEq(pool.totalDeposits(), i + 1, "deposit did not advance the counter");
        }
    }

    // -----------------------------------------------------------------------
    // The withdraw gate
    // -----------------------------------------------------------------------

    /// @notice Deposits are counted per rung, not just in total.
    function test_depositsAtDenominationTracksEachRungSeparately() public {
        _deposit(".deposit", 100);
        _deposit(".deposit", 100);
        _deposit(".depositLadder", 10);

        assertEq(pool.depositsAtDenomination(100), 2, "rung 100 miscounted");
        assertEq(pool.depositsAtDenomination(10), 1, "rung 10 miscounted");
        assertEq(pool.depositsAtDenomination(1000), 0, "an unused rung must count zero");
        assertEq(pool.totalDeposits(), 3, "total must count every rung");
    }

    /// @notice Being on the ladder is necessary and not sufficient.
    /// @dev `10^9` is a legal rung. If yours is the only 10^9 that ever entered the pool, the
    ///      withdrawal names you regardless of what the proof hides -- which is why the ladder
    ///      check alone was not enough and this gate exists next to it.
    function test_withdraw_revertsAtARungNobodyElseUses() public {
        // Enough deposits at 100 to clear the TOTAL gate, so the failure below can only be
        // about the rung. Without this the test would pass for the wrong reason.
        for (uint256 i = 0; i < K; i++) _deposit(".deposit", 100);

        uint256 rareAmount = 1000;
        assertEq(pool.depositsAtDenomination(rareAmount), 0, "precondition: rung unused");

        // withdrawData = marketId * 2^200 + recipient * 2^40 + amount
        uint256 data = (uint256(9) << 200) | (uint256(uint160(depositor)) << 40) | rareAmount;

        // Hoisted. `vm.expectRevert` applies to the very NEXT call, and a `tree.root()` read
        // inside the argument list is that call -- it returns cleanly and the assertion fails
        // having never reached `withdraw`.
        uint256 knownRoot = tree.root();

        vm.expectRevert(
            abi.encodeWithSelector(ShieldedPool.DenominationTooRare.selector, rareAmount, 0, K)
        );
        pool.withdraw(
            [uint256(1), uint256(2)],
            [[uint256(3), uint256(4)], [uint256(5), uint256(6)]],
            [uint256(7), uint256(8)],
            knownRoot,
            0,
            0,
            data
        );
    }

    /// @notice A rung with enough history gets past this gate and on to the next check.
    /// @dev Reverting with `MarketNotRegistered` is the pass condition: it is the check that
    ///      immediately follows, so reaching it proves the rung gate let go.
    function test_withdraw_rungGateOpensAtK() public {
        for (uint256 i = 0; i < K; i++) _deposit(".deposit", 100);
        assertEq(pool.depositsAtDenomination(100), K, "precondition: rung is popular enough");

        uint256 data = (uint256(9) << 200) | (uint256(uint160(depositor)) << 40) | uint256(100);

        uint256 knownRoot = tree.root();

        vm.expectRevert(ShieldedPool.MarketNotRegistered.selector);
        pool.withdraw(
            [uint256(1), uint256(2)],
            [[uint256(3), uint256(4)], [uint256(5), uint256(6)]],
            [uint256(7), uint256(8)],
            knownRoot,
            0,
            0,
            data
        );
    }

    // -----------------------------------------------------------------------
    // Depositing is never gated
    // -----------------------------------------------------------------------

    /// @notice The gate must not lock out the only action that can open it.
    /// @dev Gating deposits on the anonymity set would be a deadlock: nobody could deposit
    ///      until K deposits existed. Stated as a test because it is the kind of thing a later
    ///      "tighten the gates" change would break, and the failure would be total.
    function test_deposit_isNeverGated() public {
        assertEq(pool.totalDeposits(), 0, "precondition: empty pool");
        _deposit(".deposit", 100);
        assertEq(pool.totalDeposits(), 1, "the first deposit into an empty pool must succeed");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _deposit(string memory key, uint256 units) internal {
        vm.prank(depositor);
        pool.deposit(_pA(_name(key)), _pB(_name(key)), _pC(_name(key)), _u(string.concat(key, ".commitment")), units);
    }

    /// @dev Strips the leading "." so the proof-component helpers can rebuild their own paths.
    function _name(string memory key) internal pure returns (string memory) {
        bytes memory b = bytes(key);
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; i++) out[i - 1] = b[i];
        return string(out);
    }

    function _u(string memory k) internal view returns (uint256) {
        return fixtures.readUint(k);
    }

    function _pA(string memory a) internal view returns (uint256[2] memory) {
        return [_u(string.concat(".", a, ".pA[0]")), _u(string.concat(".", a, ".pA[1]"))];
    }

    function _pB(string memory a) internal view returns (uint256[2][2] memory) {
        return [
            [_u(string.concat(".", a, ".pB[0][0]")), _u(string.concat(".", a, ".pB[0][1]"))],
            [_u(string.concat(".", a, ".pB[1][0]")), _u(string.concat(".", a, ".pB[1][1]"))]
        ];
    }

    function _pC(string memory a) internal view returns (uint256[2] memory) {
        return [_u(string.concat(".", a, ".pC[0]")), _u(string.concat(".", a, ".pC[1]"))];
    }
}
