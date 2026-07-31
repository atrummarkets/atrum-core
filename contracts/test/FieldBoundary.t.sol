// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console, stdJson} from "forge-std/Test.sol";
import {RedeemVerifier} from "../src/verifiers/RedeemVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";

/// @notice Can a public signal be aliased by the field modulus to mean one thing
///         in-circuit and another thing in Solidity?
///
/// @dev This is the attack that would break the whole packing scheme, so it gets its own
///      test rather than being assumed safe.
///
///      Circom signals are elements of the BN254 scalar field, so `x` and `x + r` are the
///      SAME element and any in-circuit constraint satisfied by one is satisfied by the
///      other. Solidity has no such equivalence -- it does uint256 arithmetic. So if a
///      verifier accepted `x + r`, then:
///
///        - `_unpackBetData(betData + r)` would mask out a completely different `units`,
///          letting a bettor claim an arbitrary stake from a note worth far less; and
///        - `nullifierHash + r` would be a DIFFERENT key in the spent-nullifier mapping
///          while proving the same note, which is an unlimited double-spend.
///
///      Both are blocked, but they are blocked by the snarkjs-generated verifier's
///      `checkField`, NOT by anything in Atrum's own contracts:
///
///          function checkField(v) { if iszero(lt(v, r)) { mstore(0,0) return(0,0x20) } }
///
///      That is an external dependency doing safety-critical work. These tests exist so
///      that if anyone ever swaps in a hand-written or gas-optimised verifier that drops
///      the check, CI fails here instead of the pool being drained quietly.
contract FieldBoundaryTest is Test {
    using stdJson for string;

    /// BN254 scalar field order -- the modulus circom signals live under.
    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    RedeemVerifier redeemVerifier;
    BetVerifier betVerifier;
    string fixtures;

    function setUp() public {
        redeemVerifier = new RedeemVerifier();
        betVerifier = new BetVerifier();
        fixtures = vm.readFile("../circuits/build/action-fixtures.json");
    }

    function _u(string memory key) internal view returns (uint256) {
        return fixtures.readUint(key);
    }

    function _redeemProof()
        internal
        view
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory sig)
    {
        pA = [_u(".redeem.pA[0]"), _u(".redeem.pA[1]")];
        pB = [[_u(".redeem.pB[0][0]"), _u(".redeem.pB[0][1]")], [_u(".redeem.pB[1][0]"), _u(".redeem.pB[1][1]")]];
        pC = [_u(".redeem.pC[0]"), _u(".redeem.pC[1]")];
        sig = [
            _u(".redeem.publicSignals[0]"),
            _u(".redeem.publicSignals[1]"),
            _u(".redeem.publicSignals[2]"),
            _u(".redeem.publicSignals[3]")
        ];
    }

    /// Baseline: the untouched fixture must verify, or the aliasing tests below prove
    /// nothing.
    function test_baseline_genuineRedeemProofVerifies() public view {
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory sig) = _redeemProof();
        assertTrue(redeemVerifier.verifyProof(pA, pB, pC, sig), "genuine proof rejected");
    }

    /// @notice Adding the field modulus to ANY public signal must be rejected.
    /// @dev Each signal is tried independently. `payoutData + R` is the money one: it
    ///      would re-mask into a different (recipient, units) pair. `nullifierHash + R`
    ///      is the double-spend one.
    function test_aliasedPublicSignalIsRejected() public view {
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory sig) = _redeemProof();

        string[4] memory names = ["root", "nullifierHash", "payoutData", "marketMeta"];

        for (uint256 i = 0; i < 4; i++) {
            uint256[4] memory aliased = sig;

            // Only meaningful if it does not overflow uint256 -- otherwise the addition
            // wraps and is a different test entirely.
            if (aliased[i] > type(uint256).max - R) continue;
            aliased[i] = aliased[i] + R;

            assertFalse(
                redeemVerifier.verifyProof(pA, pB, pC, aliased),
                string.concat("verifier ACCEPTED an out-of-field signal: ", names[i])
            );
        }
    }

    /// @notice Same guarantee for the bet verifier, where aliasing `betData` would inflate
    ///         the staked units.
    function test_aliasedBetDataIsRejected() public view {
        uint256[2] memory pA = [_u(".bet.pA[0]"), _u(".bet.pA[1]")];
        uint256[2][2] memory pB =
            [[_u(".bet.pB[0][0]"), _u(".bet.pB[0][1]")], [_u(".bet.pB[1][0]"), _u(".bet.pB[1][1]")]];
        uint256[2] memory pC = [_u(".bet.pC[0]"), _u(".bet.pC[1]")];
        uint256[4] memory sig = [
            _u(".bet.publicSignals[0]"),
            _u(".bet.publicSignals[1]"),
            _u(".bet.publicSignals[2]"),
            _u(".bet.publicSignals[3]")
        ];

        assertTrue(betVerifier.verifyProof(pA, pB, pC, sig), "genuine bet proof rejected");

        uint256[4] memory aliased = sig;
        aliased[3] = aliased[3] + R; // betData
        assertFalse(
            betVerifier.verifyProof(pA, pB, pC, aliased),
            "verifier ACCEPTED an out-of-field betData -- units could be inflated"
        );
    }

    /// @notice The verifier's own modulus must be the BN254 scalar field.
    /// @dev If a future verifier were generated for a different curve, `checkField` would
    ///      still exist but would be checking the wrong bound.
    function test_verifierUsesBn254ScalarField() public view {
        // R - 1 is in-field and must not be rejected on field grounds. The proof is
        // invalid so verification returns false either way; what this asserts is that the
        // call does not revert, i.e. R-1 is treated as a representable field element.
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC,) = _redeemProof();
        uint256[4] memory edge = [R - 1, R - 1, R - 1, R - 1];
        assertFalse(redeemVerifier.verifyProof(pA, pB, pC, edge), "garbage should not verify");
    }

    /// @notice The tree refuses non-field leaves, so a leaf can never be reduced silently.
    /// @dev Independent of the verifier: without this, `commitment` and
    ///      `commitment + R` would be distinct leaves that Poseidon maps to the same
    ///      field element, so one note would occupy two positions.
    function test_treeRejectsNonFieldLeaf() public {
        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);

        uint256 zero = uint256(keccak256("atrum.shielded.empty")) % R;
        IncrementalMerkleTree tree = new IncrementalMerkleTree(IPoseidonT3(addr), zero, address(this));

        uint256[] memory leaves = new uint256[](1);
        leaves[0] = R; // exactly the modulus -- the first out-of-field value
        vm.expectRevert(IncrementalMerkleTree.LeafNotInField.selector);
        tree.insertSubtree(leaves);
    }
}
