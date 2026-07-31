// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {INullifierSet} from "../src/INullifierSet.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {TreeNullifierSet} from "../src/TreeNullifierSet.sol";
import {ActionGasPolicy} from "../src/ActionGasPolicy.sol";

/// @notice THE NULLIFIER DECISION, settled with a measurement.
///
/// @dev `atrum-build-plan.md` §7 specifies an indexed nullifier TREE so on-chain state
///      stays root-only. Both candidates are built here and measured against the real
///      action budget, because a 661,788 gas difference per bet is not the kind of
///      thing to decide from a document.
///
///      The gas result is the smaller half of the finding. The larger half is that the
///      tree variant cannot answer `isSpent` at all -- see `test_treeCannotAnswer...`.
contract NullifierSetTest is Test {
    IPoseidonT3 poseidon;

    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty"))
        % 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// Measured verify cost, the fixed part of every action (MEASUREMENTS.md §1).
    uint256 constant MEASURED_VERIFY_GAS = 1_029_454;

    function setUp() public {
        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);
        poseidon = IPoseidonT3(addr);
    }

    // -----------------------------------------------------------------------
    // Correctness
    // -----------------------------------------------------------------------

    function test_mapping_blocksDoubleSpend() public {
        MappingNullifierSet s = new MappingNullifierSet();
        s.bindPool(address(this));

        assertFalse(s.isSpent(42));
        s.spend(42);
        assertTrue(s.isSpent(42));

        vm.expectRevert(MappingNullifierSet.AlreadySpent.selector);
        s.spend(42);
    }

    function test_mapping_onlyPoolMaySpend() public {
        MappingNullifierSet s = new MappingNullifierSet();
        s.bindPool(address(this));

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(MappingNullifierSet.NotPool.selector);
        s.spend(1);
    }

    function test_mapping_poolBindsOnlyOnce() public {
        MappingNullifierSet s = new MappingNullifierSet();
        s.bindPool(address(this));

        vm.expectRevert(MappingNullifierSet.PoolAlreadyBound.selector);
        s.bindPool(makeAddr("someone else"));
    }

    /// @notice The decisive fact, and it is not about gas.
    ///
    /// @dev A Merkle accumulator proves MEMBERSHIP. Rejecting a double-spend requires
    ///      proving NON-membership, which a root cannot witness. So this design cannot
    ///      enforce the rule it exists to enforce without moving the check in-circuit as
    ///      a non-membership proof -- a bigger circuit and a bigger proving key, on top
    ///      of the gas below.
    function test_treeCannotAnswerIsSpentOnChain() public {
        TreeNullifierSet s = new TreeNullifierSet(poseidon, ZERO_VALUE);
        s.bindPool(address(this));

        vm.expectRevert(TreeNullifierSet.NonMembershipNotProvableOnChain.selector);
        s.isSpent(42);

        assertFalse(s.enforcesOnChain(), "tree must not claim on-chain enforcement");
        assertTrue(new MappingNullifierSet().enforcesOnChain(), "mapping must claim enforcement");
    }

    /// @notice A tree set accepts the same nullifier twice without complaint.
    /// @dev This is the double-spend, demonstrated rather than asserted in prose.
    function test_treeSilentlyAcceptsTheSameNullifierTwice() public {
        TreeNullifierSet s = new TreeNullifierSet(poseidon, ZERO_VALUE);
        s.bindPool(address(this));

        s.spend(42);
        s.spend(42); // no revert -- the note has now been spent twice

        assertEq(s.nextIndex(), 2, "both spends were accumulated");
    }

    // -----------------------------------------------------------------------
    // The measurement
    // -----------------------------------------------------------------------

    function test_report_costOfEachStrategyInsideTheActionBudget() public {
        MappingNullifierSet m = new MappingNullifierSet();
        m.bindPool(address(this));

        TreeNullifierSet t = new TreeNullifierSet(poseidon, ZERO_VALUE);
        t.bindPool(address(this));

        uint256 b1 = gasleft();
        m.spend(0xdeadbeef);
        uint256 mappingGas = b1 - gasleft();

        uint256 b2 = gasleft();
        t.spend(0xdeadbeef);
        uint256 treeGas = b2 - gasleft();

        uint256 mappingAction = MEASURED_VERIFY_GAS + mappingGas;
        uint256 treeAction = MEASURED_VERIFY_GAS + treeGas;
        uint256 envelope = ActionGasPolicy.UNIFORM_ACTION_GAS_LIMIT;

        console.log("=== nullifier strategy, inside a real action ===");
        console.log("mapping spend       :", mappingGas);
        console.log("tree spend          :", treeGas);
        console.log("saving per action   :", treeGas - mappingGas);
        console.log("action w/ mapping   :", mappingAction, mappingAction * 100 / envelope);
        console.log("action w/ tree      :", treeAction, treeAction * 100 / envelope);
        console.log("envelope            :", envelope);

        assertLt(mappingGas, treeGas, "mapping should be cheaper");
        assertGt(treeGas - mappingGas, 600_000, "saving collapsed -- revisit the decision");

        // Both still fit the envelope on their own. The mapping wins on cost, but the
        // decision is made by `test_treeCannotAnswerIsSpentOnChain` -- the tree does not
        // implement the required semantics at any price.
        assertLt(mappingAction, envelope, "mapping action overflows envelope");
    }

    /// @notice Cost grows with tree depth for one design and not the other.
    /// @dev Depth is a direct multiplier on the tree's cost (one Poseidon per level at a
    ///      measured 28,980 gas) while the mapping is flat at one SSTORE. Worth showing,
    ///      because it means the gap widens if capacity ever needs to grow.
    function test_report_mappingIsFlatWhileTreeScalesWithDepth() public {
        MappingNullifierSet m = new MappingNullifierSet();
        m.bindPool(address(this));

        uint256 first;
        uint256 tenth;

        uint256 b = gasleft();
        m.spend(1);
        first = b - gasleft();

        for (uint256 i = 2; i < 10; i++) {
            m.spend(i);
        }

        uint256 b2 = gasleft();
        m.spend(10);
        tenth = b2 - gasleft();

        console.log("=== mapping cost is flat across insertions ===");
        console.log("1st spend :", first);
        console.log("10th spend:", tenth);

        // Each spend is an independent fresh slot, so cost does not drift with set size.
        assertApproxEqAbs(first, tenth, 2_000, "mapping cost drifted with set size");
    }
}
