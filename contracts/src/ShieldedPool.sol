// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {Vault} from "./Vault.sol";
import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";
import {INullifierSet} from "./INullifierSet.sol";
import {ParimutuelPool} from "./ParimutuelPool.sol";

interface IDepositVerifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[3] calldata pubSignals
    ) external view returns (bool);
}

interface IActionVerifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[4] calldata pubSignals
    ) external view returns (bool);
}

/// @title ShieldedPool
/// @notice The Phase 1 milestone: shielded positions over a public parimutuel pool.
///
/// @dev WHAT IS AND IS NOT PRIVATE HERE
///
///      Private: which note a bet spent, and therefore which deposit funded it. The
///      anonymity set is every other note in the commitment tree.
///
///      Public: deposit amounts and depositor addresses, the pool totals, and
///      redemption payouts. `atrum-build-plan.md` is explicit that a public redemption
///      path makes the privacy claim FALSE rather than degraded, and that it is the one
///      item never to cut. It is public here because this is an internal milestone --
///      "shielded positions, public pool total" -- and Phase 2 moves redemption inside
///      the pool. Nothing built on this should be described as a private prediction
///      market yet.
///
///      WHY COMMITMENT INSERTION IS NOT IN THE USER'S TRANSACTION
///
///      A depth-20 insertion costs ~1,107,646 gas on its own (MEASUREMENTS.md §1b).
///      Added to a ~1,029,454 verify that is 2,137,100 -- 106% of the 2,000,000 action
///      envelope. It does not fit. So an action only records its commitment, and the
///      sequencer grafts 64 at a time at 38,034 gas per leaf, a 15.9x saving. Batching
///      is a correctness requirement of the gas budget, not an optimisation.
///
///      Queued commitments are stored rather than only emitted, so `flushBatch` can
///      prove it inserted exactly what users queued, in order. Emitting alone would
///      leave the sequencer free to graft arbitrary leaves. The extra SSTORE is ~22,000
///      gas, and the array slots are contiguous so the sequencer reads them near-warm
///      (MIP-8: 128 contiguous slots share a page).
///
///      HEADROOM IS TIGHTER THAN LOCAL TESTS SUGGEST
///
///      Local `forge` reports `deposit` at 1,378,641. The real testnet transaction is
///      **1,816,031 -- 91% of the envelope** (MEASUREMENTS.md §1c). Local pricing does
///      not charge calldata, the intrinsic cost, or true cross-contract cold access, and
///      `deposit` crosses five contracts. Roughly **184,000 gas** of headroom remains,
///      not the ~900,000 the local figures imply. Phase 2's accumulator has to fit in
///      that; if it does not, optimise the action (move `Vault.split` out of `deposit`)
///      rather than raising the envelope, which is publicly observable and shrinks the
///      anonymity set of everything submitted before the change.
///
///      UNIFORM GAS LIMIT
///
///      Every entry point below must be submitted with
///      `ActionGasPolicy.UNIFORM_ACTION_GAS_LIMIT` declared, never an estimate. Monad
///      charges the declared limit and it is a public field, so a snug per-action limit
///      identifies which private action was taken even though the proof stays sealed.
contract ShieldedPool {
    // -----------------------------------------------------------------------
    // Packing layout -- must match circuits/src/note.circom exactly
    // -----------------------------------------------------------------------

    uint256 internal constant UNIT_BITS = 64;
    uint256 internal constant UNIT_MASK = (1 << UNIT_BITS) - 1;
    uint256 internal constant OUTCOME_MASK = 3;

    uint8 internal constant OUTCOME_UNBET = 0;
    uint8 internal constant OUTCOME_YES = 1;
    uint8 internal constant OUTCOME_NO = 2;

    /// @notice Batches must be a power of two and aligned to their own size.
    uint256 public constant BATCH_SIZE = 64;

    // -----------------------------------------------------------------------
    // Wiring
    // -----------------------------------------------------------------------

    IncrementalMerkleTree public immutable tree;
    INullifierSet public immutable nullifiers;
    ParimutuelPool public immutable parimutuel;

    IDepositVerifier public immutable depositVerifier;
    IActionVerifier public immutable betVerifier;
    IActionVerifier public immutable redeemVerifier;

    /// @notice Allowed to call `flushBatch`. Trusted for liveness and ordering only --
    ///         it can stall the queue, but `flushBatch` checks the leaves so it cannot
    ///         forge one, and it never learns which note a bet spent.
    address public immutable sequencer;

    address public immutable admin;

    /// @notice marketId -> Vault. Many markets share one tree, so they share one
    ///         anonymity set. One market per pool would make the tree an index of that
    ///         market's participants.
    mapping(uint32 => Vault) public marketVault;

    uint256[] public pendingCommitments;
    uint256 public insertedCount;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event MarketRegistered(uint32 indexed marketId, address vault);
    event CommitmentQueued(uint256 indexed commitment, uint256 queueIndex);
    event BatchInserted(uint256 startIndex, uint256 count, uint256 newRoot);
    event Spent(uint256 indexed nullifierHash);
    event Redeemed(address indexed recipient, uint32 indexed marketId, uint256 payoutUnits);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error NotSequencer();
    error NotAdmin();
    error InvalidProof();
    error UnknownRoot();
    error NullifierAlreadySpent();
    error MarketNotRegistered();
    error MarketAlreadyRegistered();
    error NotEnoughQueued();
    error ZeroUnits();
    error BettingClosed();
    error NotResolved();
    error LosingPosition();
    error InvalidOutcome();
    error TransferFailed();
    error NullifierSetCannotEnforce();
    error InvalidRecipient();

    modifier onlySequencer() {
        if (msg.sender != sequencer) revert NotSequencer();
        _;
    }

    constructor(
        IncrementalMerkleTree tree_,
        INullifierSet nullifiers_,
        ParimutuelPool parimutuel_,
        IDepositVerifier depositVerifier_,
        IActionVerifier betVerifier_,
        IActionVerifier redeemVerifier_,
        address sequencer_,
        address admin_
    ) {
        // Refuse a nullifier set that cannot answer `isSpent` on-chain. Without this,
        // deploying against TreeNullifierSet would compile, deploy, and silently permit
        // unlimited double-spends -- see that contract's notice.
        if (!nullifiers_.enforcesOnChain()) revert NullifierSetCannotEnforce();

        tree = tree_;
        nullifiers = nullifiers_;
        parimutuel = parimutuel_;
        depositVerifier = depositVerifier_;
        betVerifier = betVerifier_;
        redeemVerifier = redeemVerifier_;
        sequencer = sequencer_;
        admin = admin_;
    }

    function registerMarket(uint32 marketId, Vault vault) external {
        if (msg.sender != admin) revert NotAdmin();
        if (address(marketVault[marketId]) != address(0)) revert MarketAlreadyRegistered();
        marketVault[marketId] = vault;
        emit MarketRegistered(marketId, address(vault));
    }

    // -----------------------------------------------------------------------
    // DEPOSIT -- public amount, hidden owner
    // -----------------------------------------------------------------------

    /// @notice Lock `units` denominations of collateral and publish a shielded note.
    ///
    /// @dev The proof binds the commitment to the amount actually paid. Without it a
    ///      user could pay for one unit and publish a commitment claiming a hundred.
    ///
    ///      The complete set minted by `Vault.split` is held by THIS contract, not the
    ///      depositor. That is what lets redemption be decided by a proof later rather
    ///      than by an address now.
    function deposit(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 commitment,
        uint32 marketId,
        uint256 units
    ) external {
        if (units == 0) revert ZeroUnits();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();
        if (block.timestamp >= vault.bettingCloseTime()) revert BettingClosed();

        if (!depositVerifier.verifyProof(pA, pB, pC, [commitment, uint256(marketId), units])) {
            revert InvalidProof();
        }

        uint256 amount = units * vault.denomination();
        IERC20 collateral = vault.collateral();

        if (!collateral.transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
        if (!collateral.approve(address(vault), amount)) revert TransferFailed();
        vault.split(units);

        _queue(commitment);
    }

    // -----------------------------------------------------------------------
    // BET -- the action the privacy claim rests on
    // -----------------------------------------------------------------------

    /// @notice Spend an unbet note and commit the same stake to a side.
    /// @dev `betData` packs marketId, outcome and units into one public signal, because
    ///      each public input costs a measured 30,756 gas and the plan caps circuits at
    ///      four. Unpacking here is free by comparison.
    function bet(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 root,
        uint256 nullifierHash,
        uint256 newCommitment,
        uint256 betData
    ) external {
        (uint32 marketId, uint8 outcome, uint256 units) = _unpackBetData(betData);

        if (outcome != OUTCOME_YES && outcome != OUTCOME_NO) revert InvalidOutcome();
        if (units == 0) revert ZeroUnits();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();
        if (block.timestamp >= vault.bettingCloseTime()) revert BettingClosed();

        // Accept any root in the history window. Without it, every batch insertion
        // would invalidate all in-flight proofs and users would race the sequencer.
        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        if (nullifiers.isSpent(nullifierHash)) revert NullifierAlreadySpent();

        if (!betVerifier.verifyProof(pA, pB, pC, [root, nullifierHash, newCommitment, betData])) {
            revert InvalidProof();
        }

        // Burn before any external effect.
        nullifiers.spend(nullifierHash);
        emit Spent(nullifierHash);

        parimutuel.addStake(marketId, outcome, units);
        _queue(newCommitment);
    }

    // -----------------------------------------------------------------------
    // REDEEM -- public payout, a known and stated hole
    // -----------------------------------------------------------------------

    /// @notice Claim a winning position, or refund an unbet note, after resolution.
    ///
    /// @dev Two payout regimes, and both are needed for solvency:
    ///        - outcome 0 (never bet): refund 1:1. Depositing and changing your mind
    ///          must not burn the stake.
    ///        - outcome == resolved winner: pro rata across the whole staked pool.
    ///        - outcome == loser: nothing. The note is simply worth zero.
    /// @dev Split into verify-then-settle purely to keep the stack shallow enough for
    ///      the non-IR codegen. `via_ir` would fix it too, but turning it on changes
    ///      every gas figure in MEASUREMENTS.md, and those numbers are the point of
    ///      this repo.
    function redeem(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 root,
        uint256 nullifierHash,
        uint256 payoutData,
        uint256 marketMeta
    ) external {
        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        if (nullifiers.isSpent(nullifierHash)) revert NullifierAlreadySpent();

        if (!redeemVerifier.verifyProof(pA, pB, pC, [root, nullifierHash, payoutData, marketMeta])) {
            revert InvalidProof();
        }

        _settleRedeem(nullifierHash, payoutData, marketMeta);
    }

    function _settleRedeem(uint256 nullifierHash, uint256 payoutData, uint256 marketMeta) private {
        (address recipient, uint256 units) = _unpackPayoutData(payoutData);
        (uint32 marketId, uint8 outcome) = _unpackMarketMeta(marketMeta);

        if (units == 0) revert ZeroUnits();
        if (recipient == address(0)) revert InvalidRecipient();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();

        uint256 owed = _owedUnits(vault, marketId, outcome, units);

        nullifiers.spend(nullifierHash);
        emit Spent(nullifierHash);

        // The pool holds one complete set per deposited unit, so it always holds enough
        // of the winning token to cover `owed`: pro-rata payouts sum to exactly the
        // staked total, and refunds to exactly the unbet total.
        vault.redeem(owed);

        if (!vault.collateral().transfer(recipient, owed * vault.denomination())) {
            revert TransferFailed();
        }

        emit Redeemed(recipient, marketId, owed);
    }

    function _owedUnits(Vault vault, uint32 marketId, uint8 outcome, uint256 units) private view returns (uint256) {
        Vault.Outcome resolved = vault.outcome();
        if (resolved == Vault.Outcome.Unresolved) revert NotResolved();

        if (outcome == OUTCOME_UNBET) return units;

        uint8 winning = resolved == Vault.Outcome.Yes ? OUTCOME_YES : OUTCOME_NO;
        if (outcome != winning) revert LosingPosition();

        return parimutuel.payoutUnits(marketId, winning, units);
    }

    // -----------------------------------------------------------------------
    // Sequencer
    // -----------------------------------------------------------------------

    /// @notice Graft the next `BATCH_SIZE` queued commitments into the tree.
    ///
    /// @dev The sequencer supplies the leaves as calldata and this checks them against
    ///      the stored queue, rather than reading storage into memory and trusting it --
    ///      calldata is far cheaper than 64 SLOADs, and the comparison is what stops a
    ///      malicious sequencer grafting leaves nobody queued.
    ///
    ///      Fixed batch size is deliberate. The batch IS the anonymity set, so a fixed
    ///      size means a fixed anonymity set rather than one that leaks how busy the
    ///      market currently is. Partial batches wait; they are not grafted early.
    function flushBatch(uint256[] calldata leaves) external onlySequencer {
        if (leaves.length != BATCH_SIZE) revert NotEnoughQueued();

        uint256 start = insertedCount;
        if (start + BATCH_SIZE > pendingCommitments.length) revert NotEnoughQueued();

        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            if (leaves[i] != pendingCommitments[start + i]) revert InvalidProof();
        }

        insertedCount = start + BATCH_SIZE;
        tree.insertSubtree(leaves);

        emit BatchInserted(start, BATCH_SIZE, tree.root());
    }

    /// @notice Queue sequencer-supplied filler commitments so a partial batch can graft.
    ///
    /// @dev Without this the queue deadlocks: `flushBatch` needs exactly BATCH_SIZE
    ///      leaves, so the last 63 users of a quiet market would wait indefinitely for a
    ///      64th to appear.
    ///
    ///      Fillers MUST be drawn from the same distribution as real commitments -- the
    ///      sequencer generates notes with random secrets and simply never spends them.
    ///      A recognisable constant would be worse than useless: it would mark exactly
    ///      which slots in each batch are real, shrinking the anonymity set to the
    ///      number of genuine actions instead of BATCH_SIZE.
    ///
    ///      Fillers are unspendable by construction -- no one, including the sequencer,
    ///      can produce a bet proof for a note that was never funded through `deposit`,
    ///      because the deposit circuit is what binds a commitment to paid collateral.
    function queuePadding(uint256[] calldata fillers) external onlySequencer {
        for (uint256 i = 0; i < fillers.length; i++) {
            _queue(fillers[i]);
        }
    }

    // -----------------------------------------------------------------------
    // Views and helpers
    // -----------------------------------------------------------------------

    function queuedCount() external view returns (uint256) {
        return pendingCommitments.length;
    }

    function pendingBatchReady() external view returns (bool) {
        return pendingCommitments.length - insertedCount >= BATCH_SIZE;
    }

    function _queue(uint256 commitment) private {
        pendingCommitments.push(commitment);
        emit CommitmentQueued(commitment, pendingCommitments.length - 1);
    }

    /// @dev betData = marketId * 2^66 + outcome * 2^64 + units
    function _unpackBetData(uint256 betData) internal pure returns (uint32 marketId, uint8 outcome, uint256 units) {
        units = betData & UNIT_MASK;
        outcome = uint8((betData >> UNIT_BITS) & OUTCOME_MASK);
        marketId = uint32(betData >> (UNIT_BITS + 2));
    }

    /// @dev payoutData = recipient * 2^64 + units
    function _unpackPayoutData(uint256 payoutData) internal pure returns (address recipient, uint256 units) {
        units = payoutData & UNIT_MASK;
        recipient = address(uint160(payoutData >> UNIT_BITS));
    }

    /// @dev marketMeta = marketId * 4 + outcome
    function _unpackMarketMeta(uint256 marketMeta) internal pure returns (uint32 marketId, uint8 outcome) {
        outcome = uint8(marketMeta & OUTCOME_MASK);
        marketId = uint32(marketMeta >> 2);
    }
}
