// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {INullifierSet} from "./INullifierSet.sol";
import {IPoseidonT3} from "./IncrementalMerkleTree.sol";

/// @title TreeNullifierSet
/// @notice The build plan's alternative: accumulate spent nullifiers into a Merkle
///         tree so on-chain state stays root-only.
///
/// @dev BUILT TO BE MEASURED, AND TO MAKE ITS OWN LIMITATION EXPLICIT.
///
///      Two findings come out of this implementation, and the second matters more than
///      the first.
///
///      1. COST. A depth-20 insertion is 20 Poseidon hashes at a measured 28,980 gas
///         each, plus the frontier reads. That lands near 690,733 gas against the
///         mapping's 28,945 -- 661,788 more on every single bet.
///
///      2. IT CANNOT ANSWER THE QUESTION. `isSpent` is unimplementable here. A Merkle
///         accumulator proves MEMBERSHIP; rejecting a double-spend requires proving
///         NON-membership, and there is no way to do that against a root without the
///         full leaf set. A true indexed Merkle tree solves this by storing sorted
///         low-leaf links and proving non-membership IN-CIRCUIT -- which means a
///         larger circuit, more constraints, and a bigger proving key, on top of the
///         661,788 gas.
///
///      So `enforcesOnChain()` returns false and `isSpent` reverts rather than
///      returning a comfortable `false` that would silently disable double-spend
///      prevention. `ShieldedPool` refuses to deploy against a set that reports false.
///
///      The conclusion is not "the tree is slower". It is that the tree only earns its
///      cost if a circuit needs in-circuit non-membership proofs for some other reason,
///      and nothing in Phase 1 or Phase 2 does. Plain membership is what double-spend
///      prevention needs, and a mapping provides it directly.
contract TreeNullifierSet is INullifierSet {
    uint256 public constant DEPTH = 20;

    uint256 internal constant FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IPoseidonT3 public immutable hasher;

    uint256 public root;
    uint256 public nextIndex;

    uint256[DEPTH] internal filledSubtrees;
    uint256[DEPTH] internal zeros;

    address public immutable deployer;
    address public pool;

    error NotPool();
    error PoolAlreadyBound();
    error NotDeployer();
    error InvalidPool();
    error TreeFull();
    error NullifierNotInField();

    /// @dev Thrown, not returned false, so the impossibility is loud.
    error NonMembershipNotProvableOnChain();

    constructor(IPoseidonT3 hasher_, uint256 zeroValue) {
        deployer = msg.sender;
        hasher = hasher_;

        uint256 current = zeroValue;
        for (uint256 i = 0; i < DEPTH; i++) {
            zeros[i] = current;
            filledSubtrees[i] = current;
            current = _hash(current, current);
        }
        root = current;
    }

    function bindPool(address pool_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (pool != address(0)) revert PoolAlreadyBound();
        if (pool_ == address(0)) revert InvalidPool();
        pool = pool_;
    }

    function _hash(uint256 left, uint256 right) internal view returns (uint256) {
        return hasher.poseidon([left, right]);
    }

    /// @inheritdoc INullifierSet
    /// @dev Always reverts. See the contract notice: a Merkle root cannot witness
    ///      absence. Returning `false` here would look like it worked and would let
    ///      every note be spent an unlimited number of times.
    function isSpent(uint256) external pure returns (bool) {
        revert NonMembershipNotProvableOnChain();
    }

    function enforcesOnChain() external pure returns (bool) {
        return false;
    }

    function spend(uint256 nullifierHash) external {
        if (msg.sender != pool) revert NotPool();
        if (nullifierHash >= FIELD_SIZE) revert NullifierNotInField();

        uint256 index = nextIndex;
        if (index >= 2 ** DEPTH) revert TreeFull();

        uint256 currentHash = nullifierHash;
        uint256 currentIndex = index;

        for (uint256 level = 0; level < DEPTH; level++) {
            if (currentIndex % 2 == 0) {
                filledSubtrees[level] = currentHash;
                currentHash = _hash(currentHash, zeros[level]);
            } else {
                currentHash = _hash(filledSubtrees[level], currentHash);
            }
            currentIndex /= 2;
        }

        root = currentHash;
        nextIndex = index + 1;
    }
}
