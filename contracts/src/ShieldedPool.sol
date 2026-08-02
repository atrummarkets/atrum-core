// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {Vault} from "./Vault.sol";
import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";
import {INullifierSet} from "./INullifierSet.sol";
import {ParimutuelPool} from "./ParimutuelPool.sol";
import {ElGamalAccumulator} from "./ElGamalAccumulator.sol";
import {Denominations} from "./Denominations.sol";

/// @dev TWO public signals, not three. `marketId` left the deposit proof when collateral
///      stopped being bound to a market -- see the shared-custody notice in ShieldedPool.
interface IDepositVerifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[2] calldata pubSignals
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
///      not the ~900,000 the local figures imply. Anything added to an action has to fit
///      in that; if it does not, optimise the action rather than raising the envelope,
///      which is publicly observable and shrinks the anonymity set of everything
///      submitted before the change.
///
///      One such optimisation has already happened, for a different reason: `deposit` no
///      longer calls `Vault.split`, because a deposit no longer names a market. That was
///      a privacy change, and the gas it returned is a side effect -- but it means the
///      figure above is now an over-estimate for `deposit` and should be re-measured
///      rather than assumed.
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

    /// @notice The marketId every UNBET note carries, since a deposit names no market.
    ///         Reserved: `registerEncryptedMarket` refuses it, so it can never collide with
    ///         a real market. `deposit.circom` and `bet_encrypted.circom` both pin to it.
    uint32 internal constant NO_MARKET = 0;

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

    // -----------------------------------------------------------------------
    // SHARED COLLATERAL CUSTODY
    //
    // Collateral is held here, by the pool, and is NOT bound to a market. A deposit buys a
    // note that can back a bet in ANY market, so the anonymity set is every unspent note in
    // the system rather than one market's depositors. Under the old design a market with
    // five depositors gave five notes of cover no matter how large the protocol grew.
    //
    // WHAT THIS GIVES UP, AND WHAT REPLACES IT
    //
    // The old design's solvency was STRUCTURAL: `Vault.split` was the only way to mint
    // outcome tokens, it pulled collateral and minted both legs atomically, and so
    // `collateralHeld == yesSupply*denom == noSupply*denom` could not be violated by any
    // sequence of calls. Deposits named a market, so a market could never draw more than was
    // committed to it.
    //
    // That invariant cannot survive a shared pool, because the amount a bet stakes is
    // ENCRYPTED -- `betEncrypted` never learns `units`, by design -- so there is no moment at
    // which the contract could split a known quantity into a known market.
    //
    // Solvency is therefore ARITHMETIC now, and it rests on four properties, each enforced
    // rather than assumed:
    //
    //   1. A bet stakes the WHOLE note. `bet_encrypted.circom` binds `oldNote.units` and
    //      `newNote.units` to the same signal, so stake == note size exactly.
    //   2. Losing positions can never redeem (`LosingOrSettledPosition`), so a market pays
    //      only its winners.
    //   3. The payout division truncates DOWN in-circuit, so the winners of a market sum to
    //      at most that market's total pool, never more.
    //   4. The divisors are pinned to the settled totals, which are cryptographically bound
    //      to the accumulated ciphertexts by the DLEQ proof plus the `C2 - D = [m]G` check.
    //      A prover cannot invent a larger `totalPool`.
    //
    // Per market: units consumed as stakes == totalPool, units produced as payouts <=
    // totalPool. Globally: sum of payouts <= sum of stakes <= sum of deposits.
    //
    // The counters below make that bound explicit and cheap to check rather than leaving it
    // as a proof on paper. `_paidOutUnits` is additionally bounded per market wherever the
    // market's true total is public (i.e. once settled), so a bug that over-pays one market
    // is caught at that market rather than later, when the shared pool runs dry and the
    // victim is whoever withdrew last.
    // -----------------------------------------------------------------------

    /// @notice The single collateral token. One token for the whole pool: two tokens would
    ///         mean two pools and two anonymity sets, which is the thing this design exists
    ///         to stop.
    IERC20 public immutable collateral;

    /// @notice Base units per denomination unit. Pool-level, not per-vault, for the same
    ///         reason -- a note must be spendable in any market, so every market must price
    ///         a unit identically.
    uint256 public immutable denomination;

    /// @notice Total units ever deposited, and ever paid out. The global solvency bound.
    uint256 public totalDepositedUnits;
    uint256 public totalWithdrawnUnits;

    /// @notice Units paid out per market, bounded by that market's settled total.
    mapping(uint32 => uint256) public paidOutUnits;

    /// @notice The smallest crowd this pool will let a user hide in.
    ///
    /// @dev Immutable and set at deploy time, because a settable K is not a security parameter
    ///      at all -- an operator could drop it to 1 the moment a gate became inconvenient,
    ///      and every user who had already relied on it would never know.
    ///
    ///      8 is the intended production value. Lower values exist only so a fresh deployment
    ///      can be exercised end to end without first funding eight deposits per rung, and a
    ///      deployment running below 8 should be described as a test deployment, not as a
    ///      private one. The constructor refuses 1 outright: a set of one is not an anonymity
    ///      set, it is a receipt, and permitting it would let a deployment advertise a gate
    ///      that gates nothing.
    uint256 public immutable minAnonymitySet;

    /// @notice How old the root an action proves against must be, in seconds.
    ///
    /// @dev The timing defence, and the half of the problem the anonymity-set gate does not
    ///      touch. A pool of a thousand notes does not help if you deposit, wait for the next
    ///      batch, and bet: an observer sees a bet land moments after a batch that contained
    ///      exactly one new commitment, and needs no cryptography at all.
    ///
    ///      Requiring an OLDER root means a note cannot be spent out of the batch that
    ///      created it. It has to wait for the crowd to move on first.
    ///
    ///      ⚠️ MUST STAY WELL UNDER `ROOT_HISTORY_SIZE` BATCHES OF WALL TIME. The history is a
    ///      64-slot ring buffer; a root older than 64 batches has been overwritten and
    ///      `isKnownRoot` refuses it. So the admissible window is
    ///      `[minRootAge, 64 batches]`, and if `minRootAge` exceeds the time 64 batches take,
    ///      that window is EMPTY and every action reverts -- first with `UnknownRoot`, which
    ///      names the wrong cause. At the sequencer's 20s cadence, 64 batches is ~21 minutes.
    ///      `RootAge.t.sol` asserts the relationship rather than leaving it to a comment.
    ///
    ///      Immutable for the same reason as `minAnonymitySet`: a settable timing defence is
    ///      one an operator can switch off for a single block.
    uint256 public immutable minRootAge;

    /// @notice How many deposits have EVER been made. Never decremented.
    ///
    /// @dev The gate for BETTING, and deliberately not a per-denomination figure.
    ///
    ///      The original plan gated `betEncrypted` on the count for the note's own
    ///      denomination. That is not implementable, for the same reason the deposit-time
    ///      vault split was not: `betEncrypted` never receives `units`. The stake is
    ///      encrypted -- that is the entire point -- so the contract cannot know which rung
    ///      the spent note sits on.
    ///
    ///      It is also the wrong set. A bet proves membership in the tree and publishes no
    ///      amount, so its anonymity set is every unspent note, not every note of one size.
    ///      Denomination narrows the crowd only where a size becomes PUBLIC, which is
    ///      `withdraw` -- see `depositsAtDenomination`.
    ///
    ///      This is an UPPER BOUND on the live set, not the figure itself: notes get spent and
    ///      this never decrements. It cannot be exact without leaking which notes are still
    ///      live, which is precisely what the pool exists to hide. The error reports the
    ///      number so a caller can see what it actually is rather than inferring precision
    ///      that is not there.
    uint256 public totalDeposits;

    /// @notice Deposits ever made at each rung of the ladder. Never decremented.
    ///
    /// @dev The gate for WITHDRAWING, where `amount` is public and therefore identifying.
    ///      Withdraw 1,000 when yours is the only 1,000 that ever entered the pool and the
    ///      withdrawal names you, whatever the proof hides.
    ///
    ///      Keyed by the amount in units, which is always a ladder rung on both sides:
    ///      `deposit` refuses anything else, and so does `withdraw`.
    mapping(uint256 => uint256) public depositsAtDenomination;

    /// @notice marketId -> Vault. Many markets share one tree, so they share one
    ///         anonymity set. One market per pool would make the tree an index of that
    ///         market's participants.
    ///
    /// @dev The Vault no longer custodies collateral. It remains the authority on RESOLUTION
    ///      (`outcome`) and TIMING (`bettingCloseTime`), which are still per-market.
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

    /// @notice Real (non-filler) leaf count of every batch ever grafted, in graft order.
    ///
    /// @dev Stored rather than left to `BatchInserted` logs, because the sequencer CANNOT
    ///      read those logs on Monad: the public RPC caps `eth_getLogs` at a 100-block range
    ///      (error -32614), and a market a week old spans over a million blocks. Rebuilding
    ///      the mirror from logs would need tens of thousands of requests and be rate-limited
    ///      long before finishing.
    ///
    ///      The mirror needs this and cannot derive it. Batches are always 64 leaves but only
    ///      the first `real` of them were queued; the rest are on-chain fillers. Current state
    ///      gives the totals -- `insertedCount` and `tree.nextIndex()` -- but not how the real
    ///      leaves were DISTRIBUTED across batches, and that distribution is what decides
    ///      where each filler sits. Get it wrong and every Merkle path is wrong.
    ///
    ///      One SSTORE on a 3,637,441-gas sequencer operation, which is not subject to the
    ///      uniform action envelope because nothing about a batch is private.
    uint32[] public batchRealCounts;

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
    /// @dev The amount is not on the denomination ladder, so it would identify its owner.
    error NotADenomination(uint256 amount);
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
    error InvalidCollateral();
    error MarketIdReserved();
    /// @dev The global bound: more units left than ever entered. Should be unreachable.
    error PoolInsolvent();
    /// @dev Reports the real count alongside the requirement, so a caller learns how far off
    ///      the pool is rather than only that it said no.
    error AnonymitySetTooSmall(uint256 have, uint256 need);
    error DenominationTooRare(uint256 amount, uint256 have, uint256 need);
    error MinAnonymitySetTooSmall();
    /// @dev Carries both figures so a client can say "wait another 40 seconds" rather than
    ///      only "no", which is the difference between a retryable error and a dead end.
    error RootTooRecent(uint256 age, uint256 need);
    /// @dev A settled market paid out more than its own published total.
    error MarketOverdrawn(uint32 marketId);

    modifier onlySequencer() {
        if (msg.sender != sequencer) revert NotSequencer();
        _;
    }

    /// @notice The three numbers that define this deployment's privacy posture.
    ///
    /// @dev Grouped into a struct rather than passed as three more arguments because the
    ///      constructor hit `Stack too deep` at thirteen. `via_ir` stays off so the gas
    ///      figures in MEASUREMENTS.md remain comparable across the project's history, which
    ///      makes argument count a real constraint rather than a style preference.
    ///
    ///      All three become immutables. None of them is settable, and that is the point: a
    ///      privacy parameter an operator can lower on demand protects nobody, because the
    ///      people relying on it cannot see the moment it changed.
    struct Policy {
        /// Base units per denomination unit.
        uint256 denomination;
        /// Deposits required before anyone may bet. See `minAnonymitySet`.
        uint256 minAnonymitySet;
        /// Seconds a root must have existed before an action may prove against it.
        /// Zero disables the check. See `minRootAge` for the ring-buffer constraint.
        uint256 minRootAge;
    }

    constructor(
        IncrementalMerkleTree tree_,
        INullifierSet nullifiers_,
        ParimutuelPool parimutuel_,
        ElGamalAccumulator accumulator_,
        IDepositVerifier depositVerifier_,
        IActionVerifier betVerifier_,
        IActionVerifier8 betEncryptedVerifier_,
        IERC20 collateral_,
        Policy memory policy_,
        address sequencer_,
        address admin_
    ) {
        // Refuse a nullifier set that cannot answer `isSpent` on-chain. Without this,
        // deploying against TreeNullifierSet would compile, deploy, and silently permit
        // unlimited double-spends -- see that contract's notice.
        if (!nullifiers_.enforcesOnChain()) revert NullifierSetCannotEnforce();
        if (address(collateral_) == address(0)) revert InvalidCollateral();
        if (policy_.denomination == 0) revert InvalidCollateral();
        // A "minimum anonymity set" of 1 is a contradiction: the gate would pass for the only
        // note in the pool, which is the exact case it exists to refuse.
        if (policy_.minAnonymitySet < 2) revert MinAnonymitySetTooSmall();

        tree = tree_;
        nullifiers = nullifiers_;
        parimutuel = parimutuel_;
        accumulator = accumulator_;
        depositVerifier = depositVerifier_;
        betVerifier = betVerifier_;
        betEncryptedVerifier = betEncryptedVerifier_;
        collateral = collateral_;
        denomination = policy_.denomination;
        minAnonymitySet = policy_.minAnonymitySet;
        minRootAge = policy_.minRootAge;
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
        // Market 0 is NO_MARKET, the sentinel every unbet note carries. Registering it would
        // let a real market's positions be indistinguishable from unbet collateral in the
        // commitment, which `bet_encrypted` relies on to refuse re-staking a position.
        if (marketId == NO_MARKET) revert MarketIdReserved();
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
    /// @dev NO MARKET. The note this creates can back a bet in any market, or none. That is
    ///      the whole point: the anonymity set for a bet becomes every unspent note in the
    ///      system rather than the depositors of one market.
    ///
    ///      Three consequences worth stating, because each is a behaviour change:
    ///
    ///      1. There is no `bettingCloseTime` check here. A deposit is not a bet, so no
    ///         market's deadline applies to it. Depositing is always open.
    ///      2. Unbet collateral is no longer hostage to a market resolving. Under the old
    ///         design, money deposited and never staked sat locked until whichever market it
    ///         was bound to settled; now it was never bound, and `withdraw` can take it out
    ///         at any time.
    ///      3. Nothing is split into outcome tokens here, because there is no market to
    ///         split into. See the shared-custody notice above for what secures the pool
    ///         instead.
    ///
    ///      The proof still binds the commitment to the amount actually paid. Without it a
    ///      user could pay for one unit and publish a commitment claiming a hundred.
    function deposit(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256 commitment,
        uint256 units
    ) external {
        // A deposit's amount is PUBLIC, so an amount nobody else uses is a name tag: the
        // next bet that spends a one-of-a-kind note is unmistakably its owner's. Worse, the
        // odd amount is its own anonymity bucket, so it shrinks the set for everyone else
        // too -- which is why this is a consensus rule and not a wallet convention.
        // Subsumes the old `units == 0` check; zero is not on the ladder.
        if (!Denominations.isValid(units)) revert NotADenomination(units);

        if (!depositVerifier.verifyProof(pA, pB, pC, [commitment, units])) {
            revert InvalidProof();
        }

        if (!collateral.transferFrom(msg.sender, address(this), units * denomination)) {
            revert TransferFailed();
        }

        totalDepositedUnits += units;

        // Both counters are monotonic. A decrementing counter would have to observe notes
        // being spent, and which notes are still live is the thing the pool hides.
        totalDeposits += 1;
        depositsAtDenomination[units] += 1;

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

        _requireAnonymitySet();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();
        // An encrypted market's total lives in the accumulator. Staking into
        // `parimutuel` here would build a second, wrong total that nothing reconciles.
        if (encryptedMarket[marketId]) revert WrongActionForMarket();
        if (block.timestamp >= vault.bettingCloseTime()) revert BettingClosed();

        // Accept any root in the history window. Without it, every batch insertion
        // would invalidate all in-flight proofs and users would race the sequencer.
        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        _requireRootAge(root);
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

        _requireAnonymitySet();

        Vault vault = marketVault[marketId];
        if (address(vault) == address(0)) revert MarketNotRegistered();
        // Refuse a plaintext market: its total lives in `parimutuel`, and accumulating
        // here would leave that total permanently short of the encrypted stakes.
        if (!encryptedMarket[marketId]) revert WrongActionForMarket();
        if (block.timestamp >= vault.bettingCloseTime()) revert BettingClosed();

        if (!tree.isKnownRoot(root)) revert UnknownRoot();
        _requireRootAge(root);
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
        _requireRootAge(root);
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

        Vault.Outcome resolved = vault.outcome();
        if (resolved == Vault.Outcome.Unresolved) revert NotResolved();

        // VOID: everybody is refunded 1:1, whichever side they backed.
        //
        // Deliberately does NOT require settlement. A market voids because something broke,
        // and requiring the committee to publish final totals first would make the escape
        // hatch depend on the same machinery that failed -- if the committee is gone, funds
        // stay frozen and `Void` bought nothing.
        //
        // The refund needs no new circuit path. `redeem_private` computes
        // `payout = units * totalPool / winningPool`, so pinning `totalPool == winningPool`
        // makes that exactly `units` -- a 1:1 refund through arithmetic that already exists
        // and is already constrained. The prover may choose the shared value; every choice
        // yields the same payout, and zero is refused because the circuit's division needs a
        // non-zero divisor.
        if (resolved == Vault.Outcome.Void) {
            if (totalPool != winningPool) revert TotalsMismatch();
            if (winningPool == 0) revert TotalsMismatch();
            // Any real position refunds, winning or losing -- that is what void means. The
            // circuit still refuses `outcome == 3`, which is what closes the mint loop.
            if (outcome != OUTCOME_UNBET && outcome != OUTCOME_YES && outcome != OUTCOME_NO) {
                revert LosingOrSettledPosition();
            }
            return;
        }

        if (!encryptedTotals.settled(marketId)) revert NotSettled2();

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
        _requireRootAge(root);
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

        // Collateral leaves shared custody, not a per-market vault. There is no `redeem` or
        // `merge` to call because no complete sets were ever minted -- see the shared-custody
        // notice for why, and for the arithmetic that bounds this instead.
        //
        // Both bounds are checked BEFORE the transfer, so an over-payout reverts rather than
        // succeeding and leaving the shortfall for whoever withdraws next.
        _recordPayout(marketId, amount);

        if (!collateral.transfer(recipient, amount * denomination)) {
            revert TransferFailed();
        }

        emit Withdrawn(recipient, marketId, amount);
    }

    /// @dev The solvency check that replaces the complete-set invariant.
    ///
    ///      GLOBAL: total paid out can never exceed total deposited. This alone is enough to
    ///      keep the pool from being drained, but it only trips once the damage is done and
    ///      the loser is whoever withdrew last.
    ///
    ///      PER MARKET: once a market is settled its true total is public, so a market can be
    ///      held to it directly and a bug that over-pays one market is caught at that market.
    ///      Deliberately skipped when the market is not settled: a Void market never
    ///      publishes totals, and its refunds are bounded by the notes that exist, which the
    ///      global check already covers. Asserting an unknown bound would just be a revert
    ///      with a made-up number in it.
    function _recordPayout(uint32 marketId, uint256 amount) private {
        totalWithdrawnUnits += amount;
        if (totalWithdrawnUnits > totalDepositedUnits) revert PoolInsolvent();

        paidOutUnits[marketId] += amount;

        if (address(encryptedTotals) != address(0) && encryptedTotals.settled(marketId)) {
            uint256 marketTotal =
                encryptedTotals.finalYesTotal(marketId) + encryptedTotals.finalNoTotal(marketId);
            if (paidOutUnits[marketId] > marketTotal) revert MarketOverdrawn(marketId);
        }
    }

    /// @dev Refuse a bet that cannot be private.
    ///
    ///      A user betting into a pool of two is not making a private bet, they are making a
    ///      public one with extra steps -- and they have no way to know that, because the
    ///      proof looks identical either way. The whole point of putting this on-chain rather
    ///      than in the client is that it cannot be skipped by calling the contract directly,
    ///      and it protects users of clients nobody audited.
    ///
    ///      It also protects the people ALREADY in the pool. Every bet made into a set of two
    ///      is a data point narrowing what the other note can be.
    ///
    ///      Bootstrapping cost, stated plainly: the first `minAnonymitySet` deposits cannot
    ///      bet at all. That is the honest consequence of refusing to let anyone bet into a
    ///      crowd that does not exist, and there is no version of this gate without it.
    /// @dev Refuse an action proving against a root that is too fresh.
    ///
    ///      Always called AFTER `isKnownRoot`, never instead of it: `rootAge` returns 0 for an
    ///      unknown root as well as for a brand-new one, so on its own it would report the
    ///      wrong reason for a root that has simply aged out of the ring buffer.
    function _requireRootAge(uint256 root) private view {
        if (minRootAge == 0) return;
        uint256 age = tree.rootAge(root);
        if (age < minRootAge) revert RootTooRecent(age, minRootAge);
    }

    function _requireAnonymitySet() private view {
        if (totalDeposits < minAnonymitySet) {
            revert AnonymitySetTooSmall(totalDeposits, minAnonymitySet);
        }
    }

    function _checkWithdrawable(uint32 marketId, address recipient, uint256 amount) private view {
        if (recipient == address(0)) revert InvalidRecipient();
        // Rejected in-circuit too. Checked again because a zero withdrawal burns the note and
        // pays nothing -- a silent loss of funds with no error anywhere.
        if (amount == 0) revert ZeroAmount();

        // The withdrawn amount is PUBLIC. A settled payout is whatever the parimutuel
        // arithmetic produced -- 1,041, an odd number -- and withdrawing it in full would
        // publish a value that uniquely identifies the position that earned it, undoing
        // exactly what `redeemPrivate` just protected. So the public leg must be a ladder
        // amount and the remainder stays behind as a private change note.
        //
        // The CHANGE is deliberately unconstrained: it never becomes public, and forcing a
        // parimutuel payout onto a ladder would be impossible rather than inconvenient.
        if (!Denominations.isValid(amount)) revert NotADenomination(amount);

        // A rung nobody else has ever used is an identifier, not a denomination. Being on the
        // ladder is necessary and not sufficient: `10^9` is a legal rung, and if yours is the
        // only 10^9 that ever entered the pool then withdrawing it names you regardless of
        // what the proof hides.
        //
        // Gated per rung, unlike the bet gate above, because here the amount is PUBLIC and so
        // the crowd that matters is the crowd at that size. At bet time no amount is published
        // at all, which is why that gate counts every deposit instead.
        uint256 atRung = depositsAtDenomination[amount];
        if (atRung < minAnonymitySet) revert DenominationTooRare(amount, atRung, minAnonymitySet);

        // NO_MARKET is the unbet exit: collateral that was deposited and never staked. It has
        // no vault, no outcome and no settlement to wait for, so every check below is not
        // merely skippable but meaningless -- there is no market to ask about.
        //
        // The proof is what makes this safe to short-circuit. `withdraw.circom` derives the
        // spent note's outcome from `marketId`, so `marketId == 0` in `withdrawData` can ONLY
        // have come from spending a note whose committed outcome was UNBET. A SETTLED note
        // cannot be routed here, and an unbet note cannot be routed down the settled path.
        //
        // Solvency still holds: an unbet note is backed 1:1 by the deposit that created it,
        // `amount + change == units` is proved in-circuit, and `_recordPayout` applies the
        // global bound against `totalDepositedUnits` regardless of which path was taken.
        if (marketId == NO_MARKET) return;

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
        batchRealCounts.push(uint32(real));
        tree.insertSubtree(batch);

        emit BatchInserted(treeStart, real, tree.root());
    }

    /// @notice How many batches have been grafted.
    function batchCount() external view returns (uint256) {
        return batchRealCounts.length;
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
