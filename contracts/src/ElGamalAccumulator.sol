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
///      On Ethereum, avoiding inversion is the obvious call. On Monad the cold-SLOAD
///      surcharge is 4x while `modexp` is unchanged, so 4 fewer slots buys roughly
///      4 x 8,100 = 32,400 gas against ~4,048 for the inversion. **The usual answer may
///      invert here.** Both are implemented so the comparison is a measurement.
///
///      Slots are declared contiguously on purpose: MIP-8 states 128 contiguous slots
///      share one 4 KB page and are warm after a single cold touch.
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
    event MarketInitialised(uint32 indexed marketId, uint8 outcome);

    error NotPool();
    error InvalidOutcome();
    error NotOnCurve();
    error NotInitialised();
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
