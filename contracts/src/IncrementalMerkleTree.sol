// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @dev circomlib's generated Poseidon contract. Deployed from bytecode rather than
///      compiled from Solidity -- circomlib emits it as raw EVM assembly.
interface IPoseidonT3 {
    function poseidon(uint256[2] calldata input) external pure returns (uint256);
}

/// @title IncrementalMerkleTree
/// @notice Append-only Poseidon Merkle tree keeping ONLY a root on-chain, with
///         batched subtree insertion.
///
/// @dev Why the design is shaped this way, in measured numbers:
///
///      Poseidon(2) costs **28,980 gas** on Monad (measured, MEASUREMENTS.md).
///      Monad charges **8,100 per cold SLOAD**, 4x Ethereum. A naive one-leaf-at-a-
///      time insertion at depth 20 therefore costs roughly:
///
///          20 x 28,980 (hashes) + 20 x 8,100 (sibling path) + writes = ~750,000
///
///      Add the Groth16 verify at ~1,030,000 and a single bet is ~1.78M gas -- 89%
///      of the 2,000,000 uniform action envelope, before calldata, nullifiers or the
///      Phase 2 accumulator. It does not fit.
///
///      Batching is therefore mandatory, not an optimisation. Inserting a batch of
///      N leaves builds one subtree and updates the shared upper path once, so the
///      per-leaf hash count falls from `depth` to roughly:
///
///          (N - 1 + depth - log2(N)) / N   ->  ~1.2 hashes/leaf at N = 64
///
///      i.e. from 20 hashes/leaf to ~1.2, a ~16x reduction in the dominant cost.
contract IncrementalMerkleTree {
    /// @notice Tree depth. 20 gives 1,048,576 leaves.
    /// @dev Depth is a direct multiplier on insertion cost, so it is chosen as the
    ///      smallest value comfortably beyond realistic volume rather than the
    ///      largest that "feels safe". Going to 32 would add 12 x 28,980 = ~348,000
    ///      gas to every unbatched path update for capacity that will not be used.
    uint256 public constant DEPTH = 20;
    uint256 public constant MAX_LEAVES = 2 ** DEPTH;

    /// @notice BN254 scalar field. Leaves must be field elements or Poseidon is
    ///         being fed values it cannot represent, and in-circuit and on-chain
    ///         hashes would diverge.
    uint256 internal constant FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IPoseidonT3 public immutable hasher;

    /// @notice Current root. The ONLY tree state a proof needs to reference.
    uint256 public root;

    /// @notice Number of leaves inserted so far.
    uint256 public nextIndex;

    /// @dev Rightmost filled node per level -- the "frontier" an append-only tree
    ///      needs to extend without storing the whole tree. `DEPTH` slots total,
    ///      declared contiguously so they share storage pages (MIP-8: 128
    ///      contiguous slots share one 4 KB page and are warm after one cold touch).
    uint256[DEPTH] internal filledSubtrees;

    /// @dev Precomputed hashes of empty subtrees, one per level.
    uint256[DEPTH] internal zeros;

    /// @notice Historical roots, so a proof built against a slightly stale root
    ///         still verifies.
    /// @dev Without this, every batch insertion would invalidate all in-flight
    ///      proofs -- users would race the sequencer and mostly lose. The window is
    ///      also an anonymity feature: it decouples "when the proof was made" from
    ///      "when it landed".
    uint256 public constant ROOT_HISTORY_SIZE = 64;
    uint256[ROOT_HISTORY_SIZE] public rootHistory;
    uint256 public currentRootIndex;

    error TreeFull();
    error LeafNotInField();
    error EmptyBatch();
    error BatchTooLarge();
    error BatchNotPowerOfTwo();
    error BatchNotAligned();

    event LeavesInserted(uint256 startIndex, uint256 count, uint256 newRoot);

    constructor(IPoseidonT3 hasher_, uint256 zeroValue) {
        hasher = hasher_;

        // Build the empty-subtree hashes bottom-up. Done once at construction so
        // insertion never has to hash an empty subtree at runtime.
        uint256 current = zeroValue;
        for (uint256 i = 0; i < DEPTH; i++) {
            zeros[i] = current;
            filledSubtrees[i] = current;
            current = _hash(current, current);
        }

        root = current;
        rootHistory[0] = current;
    }

    function _hash(uint256 left, uint256 right) internal view returns (uint256) {
        return hasher.poseidon([left, right]);
    }

    /// @notice Append a single leaf.
    /// @dev Present for completeness and for measuring the unbatched cost. Real
    ///      traffic must go through `insertBatch` -- see the note above on why a
    ///      single insertion plus a verify does not fit the action envelope.
    function insert(uint256 leaf) external returns (uint256 index) {
        uint256[] memory leaves = new uint256[](1);
        leaves[0] = leaf;
        return _insertBatch(leaves);
    }

    /// @notice Append many leaves one at a time. Kept only as a reference
    ///         implementation and as the equivalence oracle for `insertSubtree`.
    /// @dev Do NOT use in production. This costs `DEPTH` hashes per leaf; batching
    ///      saves almost nothing here (measured: 691,341 -> 603,556 per leaf from
    ///      N=1 to N=128, a mere 13%, and that only from storage warming). Use
    ///      `insertSubtree`.
    function insertBatchSequential(uint256[] calldata leaves)
        external
        returns (uint256 start)
    {
        if (leaves.length == 0) revert EmptyBatch();
        uint256[] memory copied = new uint256[](leaves.length);
        for (uint256 i = 0; i < leaves.length; i++) {
            copied[i] = leaves[i];
        }
        return _insertBatch(copied);
    }

    /// @notice Insert `2^k` leaves as one aligned subtree. This is the production path.
    ///
    /// @dev Builds the subtree bottom-up and grafts it in at level k, so the shared
    ///      upper path is walked ONCE for the whole batch instead of once per leaf:
    ///
    ///          hashes = (N - 1) + (DEPTH - log2(N))
    ///
    ///      At N = 64, DEPTH = 20 that is 63 + 14 = 77 hashes for 64 leaves, i.e.
    ///      ~1.2 hashes/leaf against 20 for sequential insertion. At the measured
    ///      28,980 gas per Poseidon that is the difference between a bet fitting the
    ///      action envelope and overflowing it.
    ///
    ///      The cost is operational rigidity, and it is the reason the sequencer must
    ///      batch on a fixed cadence: the batch has to be a power of two AND aligned
    ///      to a multiple of its own size. A half-full batch cannot be grafted, so
    ///      the sequencer pads to the batch size. That padding is not waste -- the
    ///      batch is also the anonymity set, so a fixed batch size means a fixed,
    ///      predictable anonymity set rather than one that leaks how busy the market
    ///      currently is.
    function insertSubtree(uint256[] calldata leaves) external returns (uint256 start) {
        uint256 n = leaves.length;
        if (n == 0) revert EmptyBatch();

        // Power of two: exactly one bit set.
        if (n & (n - 1) != 0) revert BatchNotPowerOfTwo();

        uint256 k = _log2(n);
        if (k > DEPTH) revert BatchTooLarge();

        start = nextIndex;
        if (start + n > MAX_LEAVES) revert TreeFull();
        // Alignment: a subtree can only be grafted at its own boundary.
        if (start % n != 0) revert BatchNotAligned();

        uint256[] memory level = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (leaves[i] >= FIELD_SIZE) revert LeafNotInField();
            level[i] = leaves[i];
        }

        // Collapse the subtree bottom-up, in place: N-1 hashes total.
        uint256 width = n;
        while (width > 1) {
            for (uint256 i = 0; i < width / 2; i++) {
                level[i] = _hash(level[2 * i], level[2 * i + 1]);
            }
            width /= 2;
        }

        // Graft the subtree root in at level k and walk the frontier to the top:
        // DEPTH - k hashes, paid once for the whole batch.
        uint256 currentHash = level[0];
        uint256 currentIndex = start >> k;

        for (uint256 lvl = k; lvl < DEPTH; lvl++) {
            if (currentIndex % 2 == 0) {
                filledSubtrees[lvl] = currentHash;
                currentHash = _hash(currentHash, zeros[lvl]);
            } else {
                currentHash = _hash(filledSubtrees[lvl], currentHash);
            }
            currentIndex /= 2;
        }

        nextIndex = start + n;
        root = currentHash;

        uint256 nextRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        currentRootIndex = nextRootIndex;
        rootHistory[nextRootIndex] = currentHash;

        emit LeavesInserted(start, n, currentHash);
    }

    function _log2(uint256 x) internal pure returns (uint256 r) {
        while (x > 1) {
            x >>= 1;
            r++;
        }
    }

    function _insertBatch(uint256[] memory leaves) internal returns (uint256 start) {
        uint256 count = leaves.length;
        start = nextIndex;

        if (start + count > MAX_LEAVES) revert TreeFull();

        for (uint256 i = 0; i < count; i++) {
            if (leaves[i] >= FIELD_SIZE) revert LeafNotInField();
        }

        // Walk each leaf up the frontier. `filledSubtrees` is read and written in
        // level order, so after the first leaf in a batch the upper levels are
        // already warm -- which is where the batching saving actually comes from on
        // Monad, given the 8,100 cold SLOAD.
        uint256 index = start;
        uint256 newRoot = root;

        for (uint256 leafIdx = 0; leafIdx < count; leafIdx++) {
            uint256 currentHash = leaves[leafIdx];
            uint256 currentIndex = index;

            for (uint256 level = 0; level < DEPTH; level++) {
                if (currentIndex % 2 == 0) {
                    // Left child: remember it and stop -- the right sibling is not
                    // known yet, so nothing above this level can be finalised.
                    filledSubtrees[level] = currentHash;
                    currentHash = _hash(currentHash, zeros[level]);
                } else {
                    // Right child: the left sibling is already on the frontier.
                    currentHash = _hash(filledSubtrees[level], currentHash);
                }
                currentIndex /= 2;
            }

            newRoot = currentHash;
            index++;
        }

        nextIndex = index;
        root = newRoot;

        uint256 nextRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        currentRootIndex = nextRootIndex;
        rootHistory[nextRootIndex] = newRoot;

        emit LeavesInserted(start, count, newRoot);
    }

    /// @notice Is `candidate` a known (current or recent) root?
    /// @dev Walks backwards from the newest so the common case -- proving against
    ///      the latest root -- exits on the first iteration.
    function isKnownRoot(uint256 candidate) external view returns (bool) {
        if (candidate == 0) return false;

        uint256 i = currentRootIndex;
        for (uint256 n = 0; n < ROOT_HISTORY_SIZE; n++) {
            if (rootHistory[i] == candidate) return true;
            i = i == 0 ? ROOT_HISTORY_SIZE - 1 : i - 1;
        }
        return false;
    }
}
