// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BabyJubJub} from "../BabyJubJub.sol";

/// @title PriceGridAccumulator -- PROBE, NOT PRODUCTION
/// @notice Costs the V2 sealed-batch clearing design that keeps individual orders encrypted.
///
/// @dev WHAT QUESTION THIS ANSWERS
///
///      V2 clears a sealed batch at a uniform price. Matching normally means COMPARING
///      orders, and `ElGamalAccumulator` says plainly why that is the hard part:
///
///        "It is ONLY addition -- no comparison, no multiplication. That is why the market
///         mechanism must be parimutuel."
///
///      The obvious escape is to sort the batch inside a ZK circuit and prove the clearing
///      price correct. Sorting networks cost roughly N log^2 N constraints, against a
///      current largest circuit of 21,252 -- likely an order of magnitude more, plus a
///      bigger ptau and slower proving. That is design (1), costed separately in circom.
///
///      This contract probes design (2), which avoids comparison entirely.
///
///      THE OBSERVATION IT RESTS ON
///
///      A clearing price is where aggregate demand crosses aggregate supply. Both are
///      CUMULATIVE SUMS over a price grid -- and summing without decrypting is exactly the
///      property the production accumulator already has.
///
///      Quantise price into L levels (Polymarket quotes in cents, so a 1c grid discards
///      nothing real). The demand curve D(p) is NON-INCREASING in p: a buyer willing to pay
///      p is willing to pay anything below p. So its step function is nonzero at exactly one
///      level -- the order's limit. An order therefore writes to ONE level, not to every
///      level beneath it, which is what would have made this ruinous.
///
///          order (buy S @ limit p)  ->  levels[p] += Enc(S)          <- one write
///          aggregate demand at q    ->  sum of levels[q..L-1]        <- read at clearing
///
///      The suffix sum is computed at clearing time, over ciphertexts, on-chain. Point
///      addition is ~9 mulmod at ~8 gas each, so the sweep is a STORAGE cost, not an
///      arithmetic one -- which is the same finding the production accumulator records.
///
///      WHAT THIS BUYS, IF THE GAS FITS
///
///      Individual orders never decrypt. Only per-level aggregates do, and only the few
///      probed while locating the crossing point. That is the same class of disclosure V1
///      already makes (per-outcome totals) moved onto a price grid -- so V2 would keep V1's
///      size-secrecy AND add side-secrecy, rather than trading one for the other.
///
///      NOT PRODUCTION. No access control, no curve validation on the read path, no
///      degenerate-ciphertext rejection, no `initialised` guard on every level. Those all
///      cost gas and belong in the real thing; leaving them out here would understate the
///      real figure, so the ones that touch the MEASURED path -- the per-order write -- are
///      kept, and only the clearing-path checks are omitted. Noted so the number is read
///      with the right caveat: the sweep figure is a floor.
contract PriceGridAccumulator {
    struct CiphertextAffine {
        uint256 c1x;
        uint256 c1y;
        uint256 c2x;
        uint256 c2y;
    }

    /// @notice marketId -> side (1 = bid, 2 = ask) -> price level -> encrypted size at that level.
    mapping(uint32 => mapping(uint8 => mapping(uint16 => CiphertextAffine))) private _levels;

    /// @notice Orders accepted per market. Same rationale as the production `betCount`:
    ///         neither Monad RPC will serve a log scan wide enough to count them.
    mapping(uint32 => uint256) public orderCount;

    event OrderAccumulated(uint32 indexed marketId, uint8 side);

    error NotOnCurve();
    error DegenerateCiphertext();

    /// @notice Initialise a level to Enc(0). The identity is (0,1), NOT all-zeros -- an
    ///         untouched slot reads (0,0) which is not a curve point, and adding to it
    ///         corrupts the total irrecoverably.
    function initLevel(uint32 marketId, uint8 side, uint16 level) external {
        CiphertextAffine storage c = _levels[marketId][side][level];
        c.c1x = 0;
        c.c1y = 1;
        c.c2x = 0;
        c.c2y = 1;
    }

    /// @notice Initialise a contiguous range, for broadcast setup.
    ///
    /// @dev Setup convenience only, never a measured path. Batching it does not contaminate
    ///      the sweep figure: cold/warm accounting resets at every transaction boundary, so
    ///      a sweep broadcast afterwards finds these slots cold regardless of how many
    ///      transactions wrote them.
    function initRange(uint32 marketId, uint8 side, uint16 from, uint16 to) external {
        for (uint16 i = from; i < to; i++) {
            CiphertextAffine storage c = _levels[marketId][side][i];
            c.c1x = 0;
            c.c1y = 1;
            c.c2x = 0;
            c.c2y = 1;
        }
    }

    /// @notice One order -> one level. THE MEASURED PATH.
    ///
    /// @dev Deliberately mirrors `ElGamalAccumulator.accumulateAffine` instruction for
    ///      instruction, including the curve check, the degenerate-C1 rejection and the
    ///      counter write, so the two figures are comparable. If this costs what the
    ///      production encrypted bet costs, the price grid is free relative to V1.
    function addOrder(uint32 marketId, uint8 side, uint16 level, uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)
        external
    {
        if (!BabyJubJub.isOnCurve(c1x, c1y) || !BabyJubJub.isOnCurve(c2x, c2y)) revert NotOnCurve();

        orderCount[marketId] += 1;

        // C1 = [r]G is the identity only when r = 0, in which case C2 = [size]G and anyone
        // recovers the size by discrete log. Same guard as production.
        if (c1x == 0 && c1y == 1) revert DegenerateCiphertext();

        CiphertextAffine storage acc = _levels[marketId][side][level];

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

        emit OrderAccumulated(marketId, side);
    }

    /// @notice Aggregate demand at every price level, in one sweep. THE CLEARING PATH.
    ///
    /// @dev Returns suffix sums: out[q] = sum of levels[q..L-1], the total size willing to
    ///      trade at price q or better. One pass, accumulating downward, so each level is
    ///      read exactly once -- L*4 cold SLOADs and nothing quadratic.
    ///
    ///      Written as non-view ON PURPOSE. A `view` called from a test is not a
    ///      transaction and its storage reads are not charged the way a real one is; this
    ///      has to be broadcast-shaped to measure what a publisher actually pays.
    function sweepSuffix(uint32 marketId, uint8 side, uint16 levels)
        external
        returns (uint256[] memory xs, uint256[] memory ys)
    {
        xs = new uint256[](levels);
        ys = new uint256[](levels);

        // Running total, walking down from the top level. Starts at Enc(0) = identity.
        BabyJubJub.Point memory run1 = BabyJubJub.fromAffine(0, 1);
        BabyJubJub.Point memory run2 = BabyJubJub.fromAffine(0, 1);

        for (uint16 i = levels; i > 0;) {
            unchecked {
                --i;
            }
            CiphertextAffine storage c = _levels[marketId][side][i];
            run1 = BabyJubJub.add(run1, BabyJubJub.fromAffine(c.c1x, c.c1y));
            run2 = BabyJubJub.add(run2, BabyJubJub.fromAffine(c.c2x, c.c2y));

            // Only C2 carries the plaintext ([m]G + [r]H); C1 is needed to decrypt but the
            // caller reconstructs it the same way. Both projected so the figure includes
            // the inversions a real publisher pays.
            (uint256 ax, uint256 ay) = BabyJubJub.toAffine(run2);
            (uint256 bx,) = BabyJubJub.toAffine(run1);
            xs[i] = ax;
            ys[i] = ay;
            bx;
        }
    }
}
