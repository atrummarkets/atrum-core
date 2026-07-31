// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {Vault} from "./Vault.sol";
import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";
import {INullifierSet} from "./INullifierSet.sol";
import {ParimutuelPool} from "./ParimutuelPool.sol";
import {ElGamalAccumulator} from "./ElGamalAccumulator.sol";

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

/// @notice Phase 2's encrypted bet. Eight public signals, not four.
///
/// @dev The signature is a separate interface rather than a widened `IActionVerifier`
///      because snarkjs sizes the generated verifier's `pubSignals` array to the
///      circuit's exact public-signal count -- `uint256[8]` and `uint256[4]` are
///      different types, not a generic one.
///
///      Eight is not a slipped budget. `atrum-build-plan.md` caps circuits at 4 public
///      signals because each costs a measured 30,776 gas, and every other action packs
///      its fields to obey that. The ciphertext cannot be packed: it is four field
///      elements the contract has to ADD to the accumulator, so it needs the actual
///      values. Hashing them and passing the points as calldata would save 3 signals
///      (~92,000) and cost 3 on-chain Poseidon calls (~87,000) -- a wash, for materially
///      more moving parts. Measured cost of the four extra signals: 123,105 gas.
/// @notice Minimal read surface of `EncryptedParimutuelPool`, for private redemption.
/// @dev A one-directional interface rather than an import: `EncryptedParimutuelPool` already
///      takes `ShieldedPool` in its constructor, so importing it here would be circular.
interface IEncryptedTotals {
    function settled(uint32 marketId) external view returns (bool);
    function finalYesTotal(uint32 marketId) external view returns (uint256);
    function finalNoTotal(uint32 marketId) external view returns (uint256);
}

interface IActionVerifier8 {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[8] calldata pubSignals
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

    /// @notice BN254 scalar field, for reducing derived fillers into range.
    uint256 internal constant FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Domain tag for derived padding leaves.
    bytes32 internal constant PAD_DOMAIN = keccak256("atrum.shielded.padding.v1");

    // -----------------------------------------------------------------------
    // Wiring
    // -----------------------------------------------------------------------

    IncrementalMerkleTree public immutable tree;
    INullifierSet public immutable nullifiers;
    ParimutuelPool public immutable parimutuel;

    /// @notice Phase 2's encrypted pool total. Holds ciphertext only and cannot decrypt.
    ElGamalAccumulator public immutable accumulator;

    IDepositVerifier public immutable depositVerifier;
    IActionVerifier public immutable betVerifier;
    IActionVerifier8 public immutable betEncryptedVerifier;

    /// @notice Verifier for `redeemPrivate`. Four public signals: root, nullifierHash,
    ///         newCommitment, redeemMeta.
    IActionVerifier public redeemPrivateVerifier;

    /// @notice Verifier for `withdraw`. Four public signals: root, nullifierHash,
    ///         changeCommitment, withdrawData.
    IActionVerifier public withdrawVerifier;

    /// @notice Where settled pool totals are read from, for private redemption.
    /// @dev Bound once, after construction, because the dependency is circular:
    ///      `EncryptedParimutuelPool` needs this pool's address to be constructed. Binding is
    ///      irreversible, so the privileged window is exactly one call and there is no
    ///      standing authority over settlement afterwards -- the same shape as
    ///      `MappingNullifierSet.bindPool`.
    IEncryptedTotals public encryptedTotals;

    /// @notice Allowed to call `flushBatch`. Trusted for liveness and ordering only --
    ///         it can stall the queue, but `flushBatch` checks the leaves so it cannot
    ///         forge one, and it never learns which note a bet spent.
    address public immutable sequencer;

    address public immutable admin;

    /// @notice marketId -> Vault. Many markets share one tree, so they share one
    ///         anonymity set. One market per pool would make the tree an index of that
    ///         market's participants.
    mapping(uint32 => Vault) public marketVault;

    /// @notice Markets whose pool total lives in the accumulator, not in `parimutuel`.
    ///
    /// @dev A market cannot have both. `ParimutuelPool` keeps plaintext running totals and
    ///      `ElGamalAccumulator` keeps ciphertext ones, and the published odds have to
    ///      derive from exactly one of them -- two sources of truth for the same market
    ///      is a settlement bug waiting to happen, not a redundancy. So the mode is fixed
    ///      once at registration and each entry point refuses the other mode's markets.
    ///
    ///      Without this, Phase 1's `bet()` would happily call `parimutuel.addStake` on a
    ///      market whose real odds are encrypted, silently building a second, wrong total
    ///      that nothing reconciles.
    mapping(uint32 => bool) public encryptedMarket;

    /// @notice Once set, no new plaintext market can be registered.
    ///
    /// @dev Phase 2 retires the plaintext path for NEW markets. Existing markets keep
    ///      working -- flipping this does not touch them, and `bet`/`redeem` stay in the
    ///      contract for them and for the regression suite that replays their proofs.
    ///
    ///      It is a switch rather than a deletion because "shielded positions, public
    ///      pool" is a real, honestly-describable configuration that should stay
    ///      available until the encrypted path has been exercised on a live network. It
    ///      is on-chain rather than a policy note so that retiring the path is an
    ///      auditable act instead of a convention someone forgets.
    bool public legacyMarketsFrozen;

    uint256[] public pendingCommitments;
    uint256 public insertedCount;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event MarketRegistered(uint32 indexed marketId, address vault);
    event EncryptedMarketRegistered(uint32 indexed marketId, address vault);
    event LegacyMarketsFrozen();
    event CommitmentQueued(uint256 indexed commitment, uint256 queueIndex);
    event BatchInserted(uint256 startIndex, uint256 count, uint256 newRoot);
    event Spent(uint256 indexed nullifierHash);
    event Redeemed(address indexed recipient, uint32 indexed marketId, uint256 payoutUnits);

    /// @notice Emitted when collateral actually leaves the pool.
    /// @dev The amount and recipient are public here, and must be -- a transfer is visible.
    ///      Privacy comes from unlinkability, not from hiding this event.
    event Withdrawn(address indexed recipient, uint32 indexed marketId, uint256 amount);

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
    error NotSettled2();
    error AlreadyBound();
    error TotalsMismatch();
    error LosingOrSettledPosition();
    error ZeroAmount();
    error WrongActionForMarket();
    error LegacyMarketsAreFrozen();

    modifier onlySequencer() {
        if (msg.sender != sequencer) revert NotSequencer();
        _;
    }

    constructor(
        IncrementalMerkleTree tree_,
        INullifierSet nullifiers_,
        ParimutuelPool parimutuel_,
        ElGamalAccumulator accumulator_,
        IDepositVerifier depositVerifier_,
        IActionVerifier betVerifier_,
        IActionVerifier8 betEncryptedVerifier_,
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
        accumulator = accumulator_;
        depositVerifier = depositVerifier_;
        betVerifier = betVerifier_;
        betEncryptedVerifier = betEncryptedVerifier_;
        sequencer = sequencer_;
        admin = admin_;
    }

    /// @notice DEPRECATED. Register a Phase 1 market: shielded positions over a PUBLIC pool.
    ///
    /// @dev DO NOT USE. Call `freezeLegacyMarkets()` immediately after deployment instead.
    ///
    ///      COLLATERAL DEPOSITED INTO A LEGACY MARKET CANNOT BE RECOVERED. The public
    ///      `redeem()` was removed because it published a recipient and an amount, which both
    ///      build plans forbid. Nothing replaced it for this market type: `redeemPrivate`
    ///      requires `encryptedMarket[marketId]` and reads settled totals from
    ///      `EncryptedParimutuelPool`, which a legacy market does not have -- its total lives
    ///      in `ParimutuelPool` as plaintext. So a legacy market supports deposit and bet, and
    ///      then the funds are stuck.
    ///
    ///      Kept only so existing test fixtures, whose Merkle tree contains legacy leaves, can
    ///      still be replayed. It is scheduled for removal together with `bet()` and the
    ///      `ParimutuelPool` wiring once the fixture lifecycle is regenerated as
    ///      all-encrypted.
    ///
    ///      Legacy markets also leak what Phase 2 exists to hide: the bet SIZE is public in
    ///      `betData`, the running pool total is public, and the odds move live -- which
    ///      reintroduces the late-money problem encryption solves.
    function registerMarket(uint32 marketId, Vault vault) external {
        if (msg.sender != admin) revert NotAdmin();
        if (legacyMarketsFrozen) revert LegacyMarketsAreFrozen();
        if (address(marketVault[marketId]) != address(0)) revert MarketAlreadyRegistered();
        marketVault[marketId] = vault;
        emit MarketRegistered(marketId, address(vault));
    }

    /// @notice Register a Phase 2 market: shielded positions over an ENCRYPTED pool total.
    ///
    /// @dev Initialises the accumulator for both outcomes here rather than leaving it to
    ///      a separate call. An uninitialised accumulator slot reads as `(0,0,0,0)`, which
    ///      is not a curve point -- the identity is `(0,1)` -- so the first `betEncrypted`
    ///      against a forgotten market would revert with `NotInitialised`. Doing it in the
    ///      same transaction as registration makes that state unreachable rather than
    ///      merely guarded.
    function registerEncryptedMarket(uint32 marketId, Vault vault) external {
        if (msg.sender != admin) revert NotAdmin();
        if (address(marketVault[marketId]) != address(0)) revert MarketAlreadyRegistered();

        marketVault[marketId] = vault;
        encryptedMarket[marketId] = true;

        accumulator.initMarket(marketId, OUTCOME_YES);
        accumulator.initMarket(marketId, OUTCOME_NO);

        emit EncryptedMarketRegistered(marketId, address(vault));
    }

    /// @notice Retire the plaintext market path for all future registrations.
    /// @dev One-way. Existing markets are untouched and keep using `bet`/`redeem`.
    function freezeLegacyMarkets() external {
        if (msg.sender != admin) revert NotAdmin();
        legacyMarketsFrozen = true;
        emit LegacyMarketsFrozen();
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
        // An encrypted market's total lives in the accumulator. Staking into
        // `parimutuel` here would build a second, wrong total that nothing reconciles.
        if (encryptedMarket[marketId]) revert WrongActionForMarket();
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
    // BET, PHASE 2 -- the stake goes dark
    // -----------------------------------------------------------------------

    /// @notice Spend an unbet note and commit the same stake to a side, encrypted.
    ///
    /// @dev The difference from `bet` is one signal: `units` is gone. The contract is
    ///      handed a ciphertext instead and adds it to a running encrypted total, so the
    ///      pool total is hidden from everyone including the operator until the committee
    ///      decrypts a ratio. That is what fixes parimutuel's real weakness -- a visible
    ///      running total gives late bettors a free read on everyone else's information.
    ///
    ///      EVERY SOLIDITY GUARD ON A VALUE DIES WHEN THAT VALUE GOES PRIVATE.
    ///
    ///      This is the Phase 2 failure mode worth internalising: the contract still
    ///      compiles, the tests still pass, and the check is simply gone. An audit of all
    ///      ten guards in `bet` found exactly two whose input no longer exists here:
    ///
    ///        - `units == 0`      -> moved into the circuit (`bet_encrypted.circom` §8).
    ///        - `addStake(units)` -> replaced by the ciphertext accumulator below.
    ///
    ///      The other eight operate on values that are still public and are kept verbatim.
    ///      A third gap was found the same way and is guarded in BOTH places: an
    ///      `encRandomness` of 0 makes `C1` the identity and `C2 = [units]G`, publishing
    ///      the stake to anyone who cares to take a discrete log. The circuit constrains
    ///      it and `ElGamalAccumulator` rejects it again, because the failure is silent --
    ///      a degenerate ciphertext accumulates perfectly well.
    ///
    ///      Split verify-from-settle for the same reason `redeem` is: the non-IR codegen
    ///      runs out of stack otherwise, and turning on `via_ir` would change every gas
    ///      figure in MEASUREMENTS.md, which are the point of this repo.
    /// @param ciphertext Enc(units) as (c1x, c1y, c2x, c2y), flat to match the accumulator.
    function betEncrypted(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 root,
        uint256 nullifierHash,
        uint256 newCommitment,
        uint256 betMeta,
        uint256[4] calldata ciphertext
    ) external {
        _checkEncryptedBet(root, nullifierHash, betMeta);

        if (!betEncryptedVerifier.verifyProof(
                pA,
                pB,
                pC,
                [
                    root,
                    nullifierHash,
                    newCommitment,
                    betMeta,
                    ciphertext[0],
                    ciphertext[1],
                    ciphertext[2],
                    ciphertext[3]
                ]
            )) {
            revert InvalidProof();
        }

        _settleEncryptedBet(nullifierHash, newCommitment, betMeta, ciphertext);
    }

    /// @dev Everything checkable before the proof is verified. Note there is no
    ///      `units == 0` check and cannot be -- see the `betEncrypted` notice.
    function _checkEncryptedBet(uint256 root, uint256 nullifierHash, uint256 betMeta) private view {
        (uint32 marketId, uint8 outcome) = _unpackMarketMeta(betMeta);

        if (outcome != OUTCOME_YES && outcome != OUTCOME_NO) revert InvalidOutcome();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();
        // Refuse a plaintext market: its total lives in `parimutuel`, and accumulating
        // here would leave that total permanently short of the encrypted stakes.
        if (!encryptedMarket[marketId]) revert WrongActionForMarket();
        if (block.timestamp >= vault.bettingCloseTime()) revert BettingClosed();

        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        if (nullifiers.isSpent(nullifierHash)) revert NullifierAlreadySpent();
    }

    function _settleEncryptedBet(
        uint256 nullifierHash,
        uint256 newCommitment,
        uint256 betMeta,
        uint256[4] calldata ciphertext
    ) private {
        (uint32 marketId, uint8 outcome) = _unpackMarketMeta(betMeta);

        // Burn before any external effect.
        nullifiers.spend(nullifierHash);
        emit Spent(nullifierHash);

        // Affine, not extended: measured at 122,270 cold against extended's 185,399,
        // and a real testnet deposit leaves only ~184,000 of envelope headroom. The
        // extended variant exists and is still measured so the choice stays
        // evidence-backed, but it does not fit.
        accumulator.accumulateAffine(marketId, outcome, ciphertext[0], ciphertext[1], ciphertext[2], ciphertext[3]);

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
    /// @notice REMOVED: the public redemption path.
    ///
    /// @dev `redeem()` published a recipient address and a payout amount. Both build plans
    ///      forbid that outright -- `atrum-build-plan.md`: *"Never cut private redemption"*;
    ///      `atrum-4day-plan.md` §7: *"Redemption stays inside the shielded pool.
    ///      Non-negotiable."* A public payout retroactively deanonymises every position it
    ///      pays, which makes the privacy claim FALSE rather than weak.
    ///
    ///      `redeemPrivate` + `withdraw` replace it: the payout becomes a shielded note, and
    ///      the exit is a separate action at a time and size of the holder's choosing.
    ///
    ///      Deleted rather than deprecated. A disabled-but-present payout path is one
    ///      `if` away from being re-enabled, and this is the single function whose existence
    ///      invalidates the product's central claim.
    ///
    ///      CONSEQUENCE, STATED PLAINLY: plaintext (Phase 1) markets now have no redemption
    ///      path at all. That is why `registerMarket` is disabled -- see below. Encrypted
    ///      markets are the only supported type.

    // -----------------------------------------------------------------------
    // PRIVATE REDEEM -- the item both build plans refuse to cut
    // -----------------------------------------------------------------------

    /// @notice Bind the settlement source and the private-redeem verifier. Once, by admin.
    /// @dev Two-step rather than constructor injection because `EncryptedParimutuelPool`
    ///      needs this contract's address to exist first. Irreversible: after this call
    ///      nobody, including the admin, can repoint where payouts are computed from.
    function bindEncryptedTotals(
        IEncryptedTotals totals,
        IActionVerifier redeemVerifier_,
        IActionVerifier withdrawVerifier_
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        if (address(encryptedTotals) != address(0)) revert AlreadyBound();
        if (
            address(totals) == address(0) || address(redeemVerifier_) == address(0)
                || address(withdrawVerifier_) == address(0)
        ) revert InvalidRecipient();
        encryptedTotals = totals;
        redeemPrivateVerifier = redeemVerifier_;
        withdrawVerifier = withdrawVerifier_;
    }

    /// @notice Redeem a position into a NEW SHIELDED NOTE. Nothing is paid out here.
    ///
    /// @dev THIS IS WHY IT EXISTS. `redeem` above publishes a recipient address and an
    ///      amount. `atrum-build-plan.md` is blunt that a public payout claim "retroactively
    ///      reveals every position", making the privacy claim FALSE rather than weak, and
    ///      names it the one item never to cut. `atrum-4day-plan.md` §7 repeats it. So the
    ///      payout becomes a note; leaving for public USDC is a separate, later, unlinkable
    ///      action.
    ///
    ///      No collateral moves in this function. That is the point, not an omission.
    ///
    ///      WHAT THE CONTRACT CAN AND CANNOT CHECK
    ///
    ///      It cannot see the position size or the payout -- both are private, which is what
    ///      Phase 1 leaked. So the payout arithmetic is proved in-circuit against divisors
    ///      the contract CAN see, and this function's whole job is to confirm those divisors
    ///      are the real settled totals rather than numbers the prover chose. Everything
    ///      else -- that the note exists, that the payout is the correct quotient, that the
    ///      new note is tagged SETTLED -- is the circuit's.
    ///
    ///      `redeemMeta` packs marketId, outcome, totalPool, winningPool. It is unpacked and
    ///      each total compared against `encryptedTotals`; a mismatch means the prover
    ///      invented a pool size, which would inflate every payout pro rata.
    function redeemPrivate(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 root,
        uint256 nullifierHash,
        uint256 newCommitment,
        uint256 redeemMeta
    ) external {
        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        if (nullifiers.isSpent(nullifierHash)) revert NullifierAlreadySpent();

        _checkRedeemMeta(redeemMeta);

        if (!redeemPrivateVerifier.verifyProof(pA, pB, pC, [root, nullifierHash, newCommitment, redeemMeta])) {
            revert InvalidProof();
        }

        // Burn before any external effect. The payout note is queued, not inserted -- the
        // sequencer grafts it, same as every other action.
        nullifiers.spend(nullifierHash);
        emit Spent(nullifierHash);

        _queue(newCommitment);
    }

    /// @dev Confirm the divisors the proof was built against are the real settled totals.
    function _checkRedeemMeta(uint256 redeemMeta) private view {
        (uint32 marketId, uint8 outcome, uint256 totalPool, uint256 winningPool) = _unpackRedeemMeta(redeemMeta);

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();
        if (!encryptedMarket[marketId]) revert WrongActionForMarket();

        if (address(encryptedTotals) == address(0)) revert AlreadyBound();
        if (!encryptedTotals.settled(marketId)) revert NotSettled2();

        Vault.Outcome resolved = vault.outcome();
        if (resolved == Vault.Outcome.Unresolved) revert NotResolved();

        // A losing position is worth nothing, so there is nothing to redeem. `outcome == 3`
        // is a SETTLED payout note, which the circuit also rejects -- checked here too
        // because the consequence of it slipping through is an unbounded mint.
        uint8 winning = resolved == Vault.Outcome.Yes ? OUTCOME_YES : OUTCOME_NO;
        if (outcome != OUTCOME_UNBET && outcome != winning) revert LosingOrSettledPosition();

        uint256 yes = encryptedTotals.finalYesTotal(marketId);
        uint256 no = encryptedTotals.finalNoTotal(marketId);

        // The claimed divisors must be exactly the settled ones. Without this the prover
        // picks a bigger `totalPool` or a smaller `winningPool` and the in-circuit division
        // faithfully computes an inflated payout from invented inputs.
        if (totalPool != yes + no) revert TotalsMismatch();
        if (winningPool != (winning == OUTCOME_YES ? yes : no)) revert TotalsMismatch();
    }

    // -----------------------------------------------------------------------
    // WITHDRAW -- the exit. Collateral leaves here and nowhere else.
    // -----------------------------------------------------------------------

    /// @notice Spend a SETTLED note: pay `amount` to `recipient`, keep the change as a note.
    ///
    /// @dev WHAT IS PUBLIC HERE, AND WHY THAT IS ACCEPTABLE
    ///
    ///      The amount and the recipient are public, and they have to be -- real collateral
    ///      moves and a transfer is visible on any public chain. No cryptography hides an
    ///      outgoing payment.
    ///
    ///      Privacy comes from UNLINKABILITY instead: which note funded this is hidden (the
    ///      anonymity set is every other note in the tree), `redeemPrivate` already severed
    ///      position from payout, and the timing is the holder's choice rather than the
    ///      moment their position settled.
    ///
    ///      PARTIAL WITHDRAWAL IS A PRIVACY FEATURE, NOT A CONVENIENCE
    ///
    ///      A settled payout is whatever the parimutuel arithmetic produced -- 137, 1,041, an
    ///      odd number -- and that number identifies the position that earned it. If the only
    ///      option were withdrawing a note in full, the public amount would leak precisely
    ///      what `redeemPrivate` protects. Withdrawing round amounts instead makes withdrawals
    ///      look alike; the remainder returns as a change note.
    ///
    ///      The ladder is NOT enforced on-chain. Enforcing it would strand the odd remainder
    ///      permanently as unwithdrawable dust and burn a tree leaf per partial withdrawal,
    ///      against a tree capped at 2^20. The client defaults to round amounts; a user who
    ///      insists on withdrawing an identifying amount is deanonymising only themselves.
    ///
    ///      Conservation (`amount + change == units`) is proved in-circuit, because the
    ///      contract can see neither the note's value nor the change.
    function withdraw(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 root,
        uint256 nullifierHash,
        uint256 changeCommitment,
        uint256 withdrawData
    ) external {
        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        if (nullifiers.isSpent(nullifierHash)) revert NullifierAlreadySpent();

        (uint32 marketId, address recipient, uint256 amount) = _unpackWithdrawData(withdrawData);
        _checkWithdrawable(marketId, recipient, amount);

        if (!withdrawVerifier.verifyProof(pA, pB, pC, [root, nullifierHash, changeCommitment, withdrawData])) {
            revert InvalidProof();
        }

        // Burn, queue the change, THEN move money. Nullifier first so a reentrant call
        // through the collateral token cannot spend the same note twice.
        nullifiers.spend(nullifierHash);
        emit Spent(nullifierHash);
        _queue(changeCommitment);

        Vault vault = marketVault[marketId];
        vault.redeem(amount);

        if (!vault.collateral().transfer(recipient, amount * vault.denomination())) {
            revert TransferFailed();
        }

        emit Withdrawn(recipient, marketId, amount);
    }

    function _checkWithdrawable(uint32 marketId, address recipient, uint256 amount) private view {
        if (recipient == address(0)) revert InvalidRecipient();
        // Rejected in-circuit too. Checked again because a zero withdrawal burns the note and
        // pays nothing -- a silent loss of funds with no error anywhere.
        if (amount == 0) revert ZeroAmount();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();

        // Encrypted markets only. A SETTLED note can today only come from `redeemPrivate`,
        // which is already encrypted-only -- but that is a reachability argument spanning two
        // circuits and a contract, and this is where collateral leaves. Assert it directly.
        if (!encryptedMarket[marketId]) revert WrongActionForMarket();

        if (address(encryptedTotals) == address(0)) revert AlreadyBound();
        if (!encryptedTotals.settled(marketId)) revert NotSettled2();
    }

    /// @dev withdrawData = marketId * 2^200 + recipient * 2^40 + amount
    ///      Must match `withdraw.circom` exactly.
    function _unpackWithdrawData(uint256 withdrawData)
        internal
        pure
        returns (uint32 marketId, address recipient, uint256 amount)
    {
        amount = withdrawData & ((uint256(1) << 40) - 1);
        recipient = address(uint160((withdrawData >> 40) & type(uint160).max));
        marketId = uint32(withdrawData >> 200);
    }

    /// @dev redeemMeta = marketId * 2^130 + outcome * 2^128 + totalPool * 2^64 + winningPool
    ///      Must match `redeem_private.circom` exactly.
    function _unpackRedeemMeta(uint256 redeemMeta)
        internal
        pure
        returns (uint32 marketId, uint8 outcome, uint256 totalPool, uint256 winningPool)
    {
        winningPool = redeemMeta & type(uint64).max;
        totalPool = (redeemMeta >> 64) & type(uint64).max;
        outcome = uint8((redeemMeta >> 128) & OUTCOME_MASK);
        marketId = uint32(redeemMeta >> 130);
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

    /// @notice Graft the next queued commitments into the tree, padding the remainder of
    ///         the subtree with derived fillers.
    ///
    /// @dev The sequencer supplies the real leaves as calldata and this checks them
    ///      against the stored queue, rather than reading storage into memory and
    ///      trusting it -- calldata is far cheaper than 64 SLOADs, and the comparison is
    ///      what stops a malicious sequencer grafting leaves nobody queued.
    ///
    ///      PADDING IS DERIVED ON-CHAIN, NEVER SUPPLIED
    ///
    ///      An earlier design exposed `queuePadding(uint256[])`, letting the sequencer
    ///      push arbitrary field elements onto the same queue `deposit` writes to. Its
    ///      comment asserted fillers were "unspendable by construction", on the grounds
    ///      that only `deposit` binds a commitment to paid collateral.
    ///
    ///      That was false, and it was exploitable for the entire vault. `deposit.circom`
    ///      binds commitment to amount *for deposits*, but nothing forced every leaf to
    ///      have come from a deposit -- and `redeem.circom` proves only Merkle
    ///      membership, the nullifier hash and injective packing. It never checks
    ///      provenance. So a "filler" whose secrets the sequencer knew was a fully
    ///      spendable note, and with `outcome = 0` it took the unbet-refund branch of
    ///      `_owedUnits`, which pays 1:1 without consulting the pool. See
    ///      `test/PaddingExploit.t.sol`, which is kept as a regression test.
    ///
    ///      Fillers are therefore derived here from a domain-separated hash of the
    ///      batch's tree position. Nobody chooses them, so nobody knows a note preimage
    ///      for one, and the sequencer is back to being trusted for liveness only.
    ///
    ///      This costs nothing in privacy. The old justification for sequencer-chosen
    ///      random fillers was that padding must be indistinguishable from real
    ///      commitments -- but in Phase 1 every real action is a public `deposit` or
    ///      `bet` transaction, so an observer already knows exactly which leaves are
    ///      real. Padding never contributed to the anonymity set; it only ever solved
    ///      liveness, which derived fillers solve equally well.
    function flushBatch(uint256[] calldata leaves) external onlySequencer {
        uint256 start = insertedCount;
        uint256 available = pendingCommitments.length - start;
        if (available == 0) revert NotEnoughQueued();

        uint256 real = available >= BATCH_SIZE ? BATCH_SIZE : available;
        if (leaves.length != real) revert NotEnoughQueued();

        uint256[] memory batch = new uint256[](BATCH_SIZE);

        for (uint256 i = 0; i < real; i++) {
            if (leaves[i] != pendingCommitments[start + i]) revert InvalidProof();
            batch[i] = leaves[i];
        }

        // Tree position is unique per batch, so it is a sufficient nonce -- two batches
        // can never derive the same filler.
        uint256 treeStart = tree.nextIndex();
        for (uint256 i = real; i < BATCH_SIZE; i++) {
            batch[i] = _derivedFiller(treeStart, i);
        }

        // Only the real commitments consume the queue; the fillers occupy tree leaves
        // but were never queued by anyone.
        insertedCount = start + real;
        tree.insertSubtree(batch);

        emit BatchInserted(treeStart, real, tree.root());
    }

    /// @notice The filler leaf for slot `slot` of the batch grafted at `treeStart`.
    /// @dev Exposed so the sequencer's tree mirror derives the same values rather than
    ///      reimplementing the rule and drifting from it.
    function derivedFiller(uint256 treeStart, uint256 slot) external pure returns (uint256) {
        return _derivedFiller(treeStart, slot);
    }

    /// @dev keccak, not Poseidon: a filler only has to be a field element that nobody
    ///      knows a note preimage for. It is never hashed in-circuit, so it does not need
    ///      to be ZK-friendly, and Poseidon would cost 28,980 gas per filler against
    ///      roughly 100 here.
    function _derivedFiller(uint256 treeStart, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(PAD_DOMAIN, treeStart, slot))) % FIELD_SIZE;
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
