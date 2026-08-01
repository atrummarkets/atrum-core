// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BabyJubJub} from "./BabyJubJub.sol";

/// @title ElGamalAccumulator
/// @notice Homomorphic per-outcome pool totals. Adds encrypted stakes without ever
///         decrypting one.
///
/// @dev THE PROPERTY THIS EXISTS FOR
///
///      Exponential ElGamal ciphertexts add:
///        Enc(m1) + Enc(m2) = ([r1+r2]G, [m1+m2]G + [r1+r2]H) = Enc(m1 + m2)
///      so the contract totals the pool with elliptic-curve point additions and never
///      holds a plaintext. Verified end to end in `circuits/scripts/prove.mjs`:
///      Enc(50) + Enc(20) decrypts to exactly 70.
///
///      It is ONLY addition -- no comparison, no multiplication. That is why the market
///      mechanism must be parimutuel, and it is also why this is not FHE.
///
///      WHY THIS IS NOT PHASE 1's `ParimutuelPool` WITH A DIFFERENT TYPE
///
///      Phase 1 keeps `uint128` running totals, which are public. This keeps ciphertexts,
///      which nobody -- including the operator -- can read without the decryption key.
///      Hiding the aggregate is what fixes parimutuel's one real weakness: with a visible
///      running total, late bettors get a free read on everyone else's information.
///
///      STORAGE LAYOUT IS THE WHOLE COST
///
///      The point arithmetic is nearly free -- 9 `mulmod` per addition, ~8 gas each.
///      What costs is storage, and Monad charges **8,100 per cold SLOAD, 4x Ethereum**.
///      So the layout decision dominates, and it is measured rather than assumed:
///
///        - EXTENDED coordinates (X,Y,T,Z): no modular inversion, but 4 slots per point,
///          8 per ciphertext.
///        - AFFINE (x,y): 2 slots per point, 4 per ciphertext, but every update needs one
///          inversion to project back -- a `modexp` call, measured at 4,048 gas on Monad.
///
///      MEASURED, against genuinely cold storage -- the state a real bet finds, since each
///      bet is its own transaction:
///
///                                        cold      warm
///        extended (8 slots)           185,399    15,799
///        affine   (4 slots)           122,270    18,870
///
///      A real testnet deposit leaves 183,969 gas of envelope headroom, so **extended does
///      not fit and affine does**, with 61,699 to spare. `accumulateAffine` is the
///      production path. The extended variant is kept and still measured so the decision
///      stays evidence-backed and a future gas change that reverses it fails CI.
///
///      Two guesses that measurement killed, recorded so they are not re-guessed:
///        - We expected Monad's 4x cold SLOAD to flip the usual extended-beats-affine
///          answer. It does not: affine wins at Ethereum pricing too (53,485 vs 89,894).
///        - We then expected MIP-8 page-sharing to explain why extended costs the same on
///          both chains. It does not either -- `StorageContiguity.t.sol` measures
///          contiguity at only ~2,600 gas, and Monad charges the full per-slot surcharge.
///          The real explanation was a flawed measurement: `initMarket` had warmed the
///          slots before the "cold" figure was taken.
contract ElGamalAccumulator {
    using BabyJubJub for BabyJubJub.Point;

    /// @notice The only contract allowed to accumulate. Set once, at construction.
    address public immutable pool;

    /// @dev A ciphertext in extended coordinates: 8 slots.
    struct CiphertextExt {
        BabyJubJub.Point c1;
        BabyJubJub.Point c2;
    }

    /// @dev A ciphertext in affine coordinates: 4 slots.
    struct CiphertextAffine {
        uint256 c1x;
        uint256 c1y;
        uint256 c2x;
        uint256 c2y;
    }

    /// @notice marketId -> outcome (1 = YES, 2 = NO) -> running encrypted total.
    mapping(uint32 => mapping(uint8 => CiphertextExt)) private _extended;
    mapping(uint32 => mapping(uint8 => CiphertextAffine)) private _affine;

    /// @notice Whether a market's accumulator has been initialised to Enc(0).
    /// @dev Enc(0) is the identity point, and the identity is `(0, 1)` -- NOT all-zeros.
    ///      An uninitialised slot reads as `(0,0,0,0)`, which is not a curve point, so
    ///      adding to it would corrupt the total irrecoverably. This flag is what stops
    ///      that; `initMarket` must be called before the first stake.
    mapping(uint32 => mapping(uint8 => bool)) public initialised;

    event StakeAccumulated(uint32 indexed marketId, uint8 outcome);

    /// @notice Encrypted bets accumulated for a market, both sides combined.
    ///
    /// @dev Stored rather than counted from `StakeAccumulated` logs, because NEITHER RPC on
    ///      Monad will serve the scan. Measured: the public endpoint caps `eth_getLogs` at a
    ///      100-block range, and Alchemy's free tier at NINE. A market a week old spans over
    ///      a million blocks, so counting from logs would need six figures of requests.
    ///
    ///      The publisher needs this to pace itself. Its cadence policy gates on how many
    ///      bets have landed since the last publication -- that is what keeps a sequence of
    ///      ratios from being solvable for individual stakes -- so an uncountable bet count
    ///      means a publisher that cannot safely publish at all.
    ///
    ///      It reveals nothing new. Every encrypted bet is already a visible transaction and
    ///      already emits an event; this only makes the count readable without a log scan.
    mapping(uint32 => uint256) public betCount;
    event MarketInitialised(uint32 indexed marketId, uint8 outcome);

    error NotPool();
    error InvalidOutcome();
    error NotOnCurve();
    error NotInitialised();
    error DegenerateCiphertext();
    error AlreadyInitialised();

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool();
        _;
    }

    modifier validOutcome(uint8 outcome) {
        // 0 is unbet collateral and is not stake -- it must never move the odds.
        if (outcome != 1 && outcome != 2) revert InvalidOutcome();
        _;
    }

    constructor(address pool_) {
        pool = pool_;
    }

    // -----------------------------------------------------------------------
    // Initialisation
    // -----------------------------------------------------------------------

    /// @notice Set a market's running total to Enc(0), the curve identity.
    /// @dev Callable by anyone: it is idempotent-by-guard, takes no arguments that could
    ///      be chosen maliciously, and gating it would just be another liveness
    ///      dependency. The identity is public knowledge.
    function initMarket(uint32 marketId, uint8 outcome) external validOutcome(outcome) {
        if (initialised[marketId][outcome]) revert AlreadyInitialised();

        BabyJubJub.Point memory id = BabyJubJub.identity();

        CiphertextExt storage ext = _extended[marketId][outcome];
        ext.c1 = id;
        ext.c2 = id;

        CiphertextAffine storage aff = _affine[marketId][outcome];
        aff.c1x = 0;
        aff.c1y = 1;
        aff.c2x = 0;
        aff.c2y = 1;

        initialised[marketId][outcome] = true;
        emit MarketInitialised(marketId, outcome);
    }

    // -----------------------------------------------------------------------
    // Accumulate -- extended coordinates (8 slots, no inversion)
    // -----------------------------------------------------------------------

    /// @notice Add an encrypted stake, keeping the total in extended coordinates.
    /// @param c1x,c1y,c2x,c2y The ciphertext, affine, as emitted by the bet circuit.
    ///
    /// @dev Both points are curve-checked. An off-curve "ciphertext" is not a group
    ///      element, so adding it corrupts the running total in a way no decryption can
    ///      undo -- the pool total would become permanently unrecoverable. The circuit
    ///      constrains this too, but the contract must not depend on a proof it did not
    ///      verify itself for a property this destructive.
    function accumulateExtended(uint32 marketId, uint8 outcome, uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)
        external
        onlyPool
        validOutcome(outcome)
    {
        if (!initialised[marketId][outcome]) revert NotInitialised();
        if (!BabyJubJub.isOnCurve(c1x, c1y) || !BabyJubJub.isOnCurve(c2x, c2y)) {
            revert NotOnCurve();
        }

        // Incremented HERE, before the point arithmetic allocates its locals -- doing it
        // beside the event at the end pushes this function over the stack limit. A revert
        // later in the call rolls this back with everything else, so the early write is not
        // an over-count.
        betCount[marketId] += 1;

        _rejectDegenerateC1(c1x, c1y);

        CiphertextExt storage acc = _extended[marketId][outcome];

        BabyJubJub.Point memory newC1 = BabyJubJub.add(acc.c1, BabyJubJub.fromAffine(c1x, c1y));
        BabyJubJub.Point memory newC2 = BabyJubJub.add(acc.c2, BabyJubJub.fromAffine(c2x, c2y));

        acc.c1 = newC1;
        acc.c2 = newC2;

        emit StakeAccumulated(marketId, outcome);
    }

    // -----------------------------------------------------------------------
    // Accumulate -- affine (4 slots, one inversion per point)
    // -----------------------------------------------------------------------

    /// @notice Add an encrypted stake, keeping the total in affine coordinates.
    /// @dev Half the storage of the extended variant, at the cost of two modular
    ///      inversions (one per point) to project back. Which wins is a Monad-specific
    ///      question -- see the contract notice.
    function accumulateAffine(uint32 marketId, uint8 outcome, uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)
        external
        onlyPool
        validOutcome(outcome)
    {
        if (!initialised[marketId][outcome]) revert NotInitialised();
        if (!BabyJubJub.isOnCurve(c1x, c1y) || !BabyJubJub.isOnCurve(c2x, c2y)) {
            revert NotOnCurve();
        }

        // Incremented HERE, before the point arithmetic allocates its locals -- doing it
        // beside the event at the end pushes this function over the stack limit. A revert
        // later in the call rolls this back with everything else, so the early write is not
        // an over-count.
        betCount[marketId] += 1;
        _rejectDegenerateC1(c1x, c1y);

        CiphertextAffine storage acc = _affine[marketId][outcome];

        BabyJubJub.Point memory sum1 =
            BabyJubJub.add(BabyJubJub.fromAffine(acc.c1x, acc.c1y), BabyJubJub.fromAffine(c1x, c1y));
        BabyJubJub.Point memory sum2 =
            BabyJubJub.add(BabyJubJub.fromAffine(acc.c2x, acc.c2y), BabyJubJub.fromAffine(c2x, c2y));

        (uint256 x1, uint256 y1) = BabyJubJub.toAffine(sum1);
        (uint256 x2, uint256 y2) = BabyJubJub.toAffine(sum2);

        acc.c1x = x1;
        acc.c1y = y1;
        acc.c2x = x2;
        acc.c2y = y2;

        emit StakeAccumulated(marketId, outcome);
    }

    /// @notice Refuse a ciphertext whose C1 is the identity.
    ///
    /// @dev `C1 = [r]G`, and it equals the identity only when `r = 0` -- in which case
    ///      `C2 = [units]G` and anyone can recover the stake by discrete log. The
    ///      ciphertext is not a ciphertext.
    ///
    ///      `bet_encrypted.circom` already constrains `r != 0`, so an honest prover cannot
    ///      reach this. It is checked again here because the consequence is silent: a
    ///      degenerate ciphertext accumulates perfectly well and simply publishes the
    ///      bettor's stake, and neither the contract nor the bettor would see an error.
    ///      Second layer, for a failure mode with no other alarm.
    function _rejectDegenerateC1(uint256 c1x, uint256 c1y) private pure {
        if (c1x == 0 && c1y == 1) revert DegenerateCiphertext();
    }

    // -----------------------------------------------------------------------
    // Views -- for the publisher, which decrypts off-chain
    // -----------------------------------------------------------------------

    /// @notice The running encrypted total, affine. This is all the publisher needs.
    /// @dev Returns ciphertext only. Nothing here reveals a plaintext, and the contract
    ///      has no way to compute one -- the decryption key exists only off-chain.
    function totalExtended(uint32 marketId, uint8 outcome)
        external
        view
        returns (uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)
    {
        CiphertextExt storage acc = _extended[marketId][outcome];
        (c1x, c1y) = BabyJubJub.toAffine(acc.c1);
        (c2x, c2y) = BabyJubJub.toAffine(acc.c2);
    }

    function totalAffine(uint32 marketId, uint8 outcome)
        external
        view
        returns (uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)
    {
        CiphertextAffine storage acc = _affine[marketId][outcome];
        return (acc.c1x, acc.c1y, acc.c2x, acc.c2y);
    }
}
