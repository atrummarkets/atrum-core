// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
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
import {stdJson} from "forge-std/StdJson.sol";

/// @notice The timing defence: an action may not prove against a root that is brand new.
///
/// @dev WHY THIS EXISTS AT ALL
///
///      The anonymity-set gate counts the crowd. It says nothing about WHEN you joined it,
///      and time is the cheapest link an observer has. Deposit, wait for the next batch, bet
///      -- and a watcher who sees a bet land moments after a batch containing exactly one new
///      commitment has linked them without touching any cryptography. That is the unfixed
///      half of this design's own opening example.
///
///      Requiring an older root means a note cannot be spent out of the batch that created
///      it. It has to wait for the crowd to move on.
///
///      THE CONSTANT THAT CAN SILENTLY KILL THE POOL
///
///      Root history is a 64-slot ring buffer. A root older than 64 batches has been
///      overwritten and `isKnownRoot` refuses it. So the admissible window is
///      `[minRootAge, 64 batches]` -- and if `minRootAge` ever exceeds the wall time 64
///      batches take, that window is EMPTY and every action reverts, first with `UnknownRoot`,
///      which names the wrong cause entirely. `test_windowIsNotEmpty` asserts the relationship
///      instead of leaving it to a comment nobody re-reads.
contract RootAgeTest is Test {
    IncrementalMerkleTree tree;
    IPoseidonT3 poseidon;

    address sequencer = makeAddr("sequencer");

    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty")) % R;

    /// @dev The sequencer's `MAX_BATCH_DELAY_MS`, in seconds. The upper bound on how long a
    ///      batch takes when the pool is quiet -- a busy pool batches sooner, which only
    ///      widens the window, so this is the conservative figure.
    uint256 constant BATCH_CADENCE_SECONDS = 20;

    /// @dev A candidate production value for `ShieldedPool.minRootAge`.
    uint256 constant CANDIDATE_MIN_ROOT_AGE = 120;

    function setUp() public {
        vm.warp(1_800_000_000);

        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);
        poseidon = IPoseidonT3(addr);

        tree = new IncrementalMerkleTree(poseidon, ZERO_VALUE, sequencer);
    }

    // -----------------------------------------------------------------------
    // The constant relationship
    // -----------------------------------------------------------------------

    /// @notice `minRootAge` must leave a usable window inside the ring buffer.
    /// @dev The failure this prevents is total and misdiagnosable: every action reverts, and
    ///      the error says `UnknownRoot`, pointing at the tree rather than at the constant.
    ///      A generous safety factor is used because the cadence is an upper bound the
    ///      sequencer chooses, not a chain property -- someone raising it later must see this
    ///      break rather than discover it in production.
    function test_windowIsNotEmpty() public view {
        uint256 historySpan = tree.ROOT_HISTORY_SIZE() * BATCH_CADENCE_SECONDS;

        assertLt(
            CANDIDATE_MIN_ROOT_AGE,
            historySpan / 4,
            "minRootAge leaves too little room inside the 64-root history -- raise the batch "
            "cadence or lower the age, or every action will revert with UnknownRoot"
        );
    }

    // -----------------------------------------------------------------------
    // rootAge itself
    // -----------------------------------------------------------------------

    function test_freshRootHasZeroAge() public {
        _graft(1);
        assertEq(tree.rootAge(tree.root()), 0, "a root recorded this second is not zero-aged");
    }

    function test_ageGrowsWithWallClock() public {
        _graft(1);
        uint256 root = tree.root();

        vm.warp(block.timestamp + 300);
        assertEq(tree.rootAge(root), 300, "age did not track the wall clock");
    }

    /// @notice An older root keeps its own age, not the newest one's.
    /// @dev The whole ring buffer has to be timestamped, not just the head. If only the
    ///      current root carried a timestamp, proving against any earlier root would report
    ///      the head's age and the gate would pass or fail for the wrong root.
    function test_eachRootKeepsItsOwnAge() public {
        _graft(1);
        uint256 first = tree.root();

        vm.warp(block.timestamp + 100);
        _graft(1);
        uint256 second = tree.root();

        vm.warp(block.timestamp + 50);

        assertEq(tree.rootAge(first), 150, "the older root's age is wrong");
        assertEq(tree.rootAge(second), 50, "the newer root's age is wrong");
    }

    /// @notice An unknown root reports age 0.
    /// @dev Ambiguous with "recorded this second" on purpose, and safe because both answers
    ///      fail identically at every call site. `_requireRootAge` is always paired with
    ///      `isKnownRoot`, which is what distinguishes the two.
    function test_unknownRootReportsZeroAge() public view {
        assertEq(tree.rootAge(123456789), 0, "an unknown root must not report an age");
        assertEq(tree.rootAge(0), 0, "the zero root must not report an age");
    }

    /// @notice A root that has aged out of the buffer is no longer known, so it has no age.
    /// @dev This is the upper edge of the admissible window, and the reason `minRootAge`
    ///      cannot be raised freely.
    function test_rootAgedOutOfTheBufferIsForgotten() public {
        _graft(1);
        uint256 oldRoot = tree.root();

        assertTrue(tree.isKnownRoot(oldRoot), "precondition: the root starts out known");

        // One full lap of the ring buffer overwrites it.
        for (uint256 i = 0; i < tree.ROOT_HISTORY_SIZE(); i++) {
            vm.warp(block.timestamp + BATCH_CADENCE_SECONDS);
            _graft(1);
        }

        assertFalse(tree.isKnownRoot(oldRoot), "the root should have been overwritten");
        assertEq(tree.rootAge(oldRoot), 0, "a forgotten root cannot report an age");
    }

    /// @notice The empty tree's root is timestamped at construction.
    /// @dev Left at zero it would read as infinitely old. Harmless while nothing proves
    ///      against an empty tree, but a silent lie the moment something does.
    function test_emptyRootIsTimestampedAtConstruction() public {
        assertEq(tree.rootAge(tree.root()), 0, "the empty root should start at age zero");
        vm.warp(block.timestamp + 42);
        assertEq(tree.rootAge(tree.root()), 42, "the empty root was never timestamped");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Graft a batch of `n` real leaves padded to 64, the way the pool does.
    function _graft(uint256 n) internal {
        uint256[] memory leaves = new uint256[](64);
        for (uint256 i = 0; i < 64; i++) {
            leaves[i] = uint256(keccak256(abi.encode(tree.nextIndex(), i, n))) % R;
        }
        vm.prank(sequencer);
        tree.insertSubtree(leaves);
    }
}

/// @notice The gate as `ShieldedPool` enforces it, rather than as the tree reports it.
///
/// @dev Deliberately drives the gate with the EMPTY-tree root. It is a known root from
///      construction, so `isKnownRoot` admits it and the only thing that can reject the call
///      is the age check -- no proofs, no fixture chain, and no way for the test to pass for
///      an unrelated reason.
contract RootAgeEnforcementTest is Test {
    using stdJson for string;

    string fixtures;
    address depositor = makeAddr("depositor");

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

    uint32 constant MARKET_ID = 7;
    uint256 constant DENOM = 1e6;
    uint256 constant MIN_ROOT_AGE = 120;

    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty")) % R;

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
            IActionVerifier8(address(0xB8)),
            IERC20(address(usdc)),
            ShieldedPool.Policy({denomination: DENOM, minAnonymitySet: 2, minRootAge: MIN_ROOT_AGE}),
            sequencer,
            address(this)
        );
        require(address(pool) == predicted, "pool address prediction failed");

        nullifiers.bindPool(address(pool));
        pool.registerMarket(MARKET_ID, vault);

        // Real deposits, with real proofs, so the ANONYMITY gate is already satisfied and the
        // only gate left to observe is the one this suite is about. Without them every test
        // below would revert with `AnonymitySetTooSmall` and prove nothing about timing.
        usdc.mint(depositor, 1_000_000 * DENOM);
        vm.startPrank(depositor);
        usdc.approve(address(pool), type(uint256).max);
        _deposit(".deposit");
        _deposit(".depositLadder");
        vm.stopPrank();
    }

    function _deposit(string memory key) internal {
        pool.deposit(
            [_u(string.concat(key, ".pA[0]")), _u(string.concat(key, ".pA[1]"))],
            [
                [_u(string.concat(key, ".pB[0][0]")), _u(string.concat(key, ".pB[0][1]"))],
                [_u(string.concat(key, ".pB[1][0]")), _u(string.concat(key, ".pB[1][1]"))]
            ],
            [_u(string.concat(key, ".pC[0]")), _u(string.concat(key, ".pC[1]"))],
            _u(string.concat(key, ".commitment")),
            _u(string.concat(key, ".units"))
        );
    }

    function _u(string memory k) internal view returns (uint256) {
        return fixtures.readUint(k);
    }

    function test_policyIsReadableOnChain() public view {
        assertEq(pool.minRootAge(), MIN_ROOT_AGE, "minRootAge is not what the deployment claims");
    }

    /// @notice A too-fresh root is refused, and the revert says how long to wait.
    function test_bet_revertsAgainstATooFreshRoot() public {
        uint256 root = tree.root();

        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.RootTooRecent.selector, 0, MIN_ROOT_AGE));
        pool.bet(_garbageA(), _garbageB(), _garbageC(), root, 1, 2, _betData());
    }

    /// @notice The age is reported as it accrues, so a client can say how long is left.
    function test_bet_revertReportsTheActualAge() public {
        uint256 root = tree.root();
        vm.warp(block.timestamp + 90);

        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.RootTooRecent.selector, 90, MIN_ROOT_AGE));
        pool.bet(_garbageA(), _garbageB(), _garbageC(), root, 1, 2, _betData());
    }

    /// @notice Once the root is old enough, the age gate stops being the objection.
    /// @dev `InvalidProof` is the pass condition: it is the next check in line, so reaching it
    ///      proves the age gate let go. Asserting "no revert" would be wrong -- the proof here
    ///      is garbage on purpose, and a test that demanded success would be testing the
    ///      verifier rather than the gate.
    function test_bet_ageGateOpensAtMinRootAge() public {
        uint256 root = tree.root();
        vm.warp(block.timestamp + MIN_ROOT_AGE);

        vm.expectRevert(ShieldedPool.InvalidProof.selector);
        pool.bet(_garbageA(), _garbageB(), _garbageC(), root, 1, 2, _betData());
    }

    /// @notice An unknown root still fails as UNKNOWN, not as too recent.
    /// @dev `rootAge` returns 0 for both cases, so the order of the two checks is what keeps
    ///      the diagnosis honest. Swap them and every aged-out root reports the wrong cause,
    ///      sending an operator to look at a timing constant instead of at the ring buffer.
    function test_unknownRootFailsAsUnknownNotAsTooRecent() public {
        vm.warp(block.timestamp + MIN_ROOT_AGE * 10);

        vm.expectRevert(ShieldedPool.UnknownRoot.selector);
        pool.bet(_garbageA(), _garbageB(), _garbageC(), 999999, 1, 2, _betData());
    }

    /// @dev betData = marketId * 2^66 + outcome * 2^64 + units, per `bet.circom`.
    function _betData() internal pure returns (uint256) {
        return (uint256(MARKET_ID) << 66) | (uint256(1) << 64) | uint256(100);
    }

    function _garbageA() internal pure returns (uint256[2] memory) {
        return [uint256(1), uint256(2)];
    }

    function _garbageB() internal pure returns (uint256[2][2] memory) {
        return [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
    }

    function _garbageC() internal pure returns (uint256[2] memory) {
        return [uint256(7), uint256(8)];
    }
}
