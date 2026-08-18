// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title SlotProbe -- PROBE
/// @notice Is Monad's cold SLOAD charge per-slot, or does contiguity discount it LIVE?
///
/// @dev MEASUREMENTS.md 1b concluded "Monad charges the full per-slot surcharge", citing
///      `StorageContiguity.t.sol` -- a LOCAL measurement. `V2_CLEARING_PROBE.md` then found
///      live `eth_estimateGas` charging ~22,886 per grid level where four cold SLOADs alone
///      should cost 32,400, which that conclusion cannot explain.
///
///      If contiguity IS discounted on the live chain, then local forge overstates every
///      storage-heavy figure in this repo -- the opposite direction to MEASUREMENTS.md 1c's
///      finding that local UNDERSTATES call-heavy actions by 32-41%. Both can hold at once:
///      they are different cost drivers, and which one dominates depends on the workload.
///
///      Both read paths below touch `n` slots and do identical arithmetic. The ONLY
///      difference is adjacency. Marginal cost (n=200 minus n=100) cancels calldata,
///      intrinsic cost and dispatch -- the same method `tools/monad_gas.py` uses, and for
///      the same reason: a single absolute reading silently bakes in the 10,100 cold-account
///      charge.
contract SlotProbe {
    uint256[256] private contiguous;
    mapping(uint256 => uint256) private scattered;

    /// @dev Values are non-zero so both paths read populated slots. A zero slot and a
    ///      written slot cost the same to READ, but keeping them identical removes the
    ///      question.
    function fill(uint256 from, uint256 to) external {
        for (uint256 i = from; i < to; i++) {
            contiguous[i] = i + 1;
            scattered[i] = i + 1;
        }
    }

    /// @dev Adjacent storage slots: 0, 1, 2, ... Whatever page-sharing discount exists
    ///      applies here.
    function readContiguous(uint256 n) external view returns (uint256 s) {
        for (uint256 i = 0; i < n; i++) {
            s += contiguous[i];
        }
    }

    /// @dev keccak-derived keys: adjacent indices land in unrelated slots, so no discount
    ///      can apply. This is the control.
    function readScattered(uint256 n) external view returns (uint256 s) {
        for (uint256 i = 0; i < n; i++) {
            s += scattered[i];
        }
    }

    // -----------------------------------------------------------------------
    // WRITES. Added after the read result above was over-generalised.
    //
    // Estimating `accumulateExtended` (8 slots, no inversion) against
    // `accumulateAffine` (4 slots, one modexp) on the live chain gave 149,151 vs 123,722 --
    // affine wins by 25,429, the OPPOSITE of what the read figures predicted. Four extra
    // slots cost ~6,357 each there, not the ~261 reads cost.
    //
    // The read probe measured SLOAD. An accumulator is dominated by SSTORE. These functions
    // separate the write paths so the distinction is measured rather than inferred.
    // -----------------------------------------------------------------------

    function writeContiguous(uint256 from, uint256 to) external {
        for (uint256 i = from; i < to; i++) {
            contiguous[i] = i + 7;
        }
    }

    function writeScattered(uint256 from, uint256 to) external {
        for (uint256 i = from; i < to; i++) {
            scattered[i] = i + 7;
        }
    }
}
