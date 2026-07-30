// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title ActionGasPolicy
/// @notice The single declared gas limit every shielded action must be submitted
///         with, and the constants the sequencer pads to.
///
/// @dev THIS IS A PRIVACY CONTROL, NOT A COST CONTROL.
///
///      Monad charges the transaction's declared `gas_limit`, not `gas_used`, and
///      `gas_limit` is a public field on every transaction. So if deposit, bet and
///      redeem cost different amounts and each is submitted with a snug limit, the
///      limit alone tells an observer which private action a user just took. The
///      proofs stay sealed and the deanonymisation happens anyway, through
///      transaction metadata.
///
///      Therefore: every shielded action is submitted with the SAME declared limit,
///      padded up to this envelope. The padding is not wasted in the usual sense --
///      it is the price of the anonymity set.
///
///      Two consequences worth stating plainly:
///        1. `eth_estimateGas` must never be used for these transactions. It would
///           return a per-action estimate, which is exactly the leak. (It is also
///           unsafe here for an unrelated reason: you pay the declared limit
///           regardless, and wallets set it absurdly high when estimation reverts.)
///        2. Raising this envelope is a protocol-visible change. A new action that
///           does not fit must either be optimised or force a conscious bump --
///           never a silent per-action limit.
library ActionGasPolicy {
    /// @notice Uniform declared gas limit for every shielded action.
    ///
    /// @dev Derived from measurement, not guessed. Our worst measured verify is
    ///      1,101,216 gas for a 6-public-signal verifier on live Monad
    ///      (MEASUREMENTS.md §1). On top of verification an action also pays:
    ///        - intrinsic tx cost and calldata,
    ///        - nullifier insertion and commitment-tree subtree update,
    ///        - the ElGamal accumulator update (Phase 2),
    ///        - cold storage access, at Monad's 8,100 per cold SLOAD (4x Ethereum).
    ///
    ///      2,000,000 leaves roughly 900,000 gas of headroom over the measured
    ///      verify cost. That is deliberate slack: the envelope should not need to
    ///      move as Phase 1 and Phase 2 add tree and accumulator work, because
    ///      every change to it is publicly observable and shrinks the anonymity set
    ///      of everything submitted before it.
    uint256 internal constant UNIFORM_ACTION_GAS_LIMIT = 2_000_000;

    /// @notice Highest verify cost we have actually measured on Monad, for any
    ///         action. Kept here so the uniformity test has a real anchor.
    ///
    /// @dev This is the COLD first-call figure, which is the one a declared
    ///      transaction limit has to cover: the first touch of the verifier in a
    ///      transaction pays Monad's cold account access charge (~10,100, versus
    ///      2,600 on Ethereum) on top of the warm execution cost. Using the warm
    ///      figure here would under-declare by roughly that amount.
    ///      Warm equivalent, for reference: 1,090,965.
    uint256 internal constant MAX_MEASURED_VERIFY_GAS = 1_101_216;

    /// @notice Block gas limit measured on Monad mainnet.
    /// @dev Docs claim 200,000,000; that figure is stale. Measured at 150,000,000.
    uint256 internal constant BLOCK_GAS_LIMIT = 150_000_000;

    /// @notice Actions per block if every one is padded to the uniform envelope.
    function actionsPerBlock() internal pure returns (uint256) {
        return BLOCK_GAS_LIMIT / UNIFORM_ACTION_GAS_LIMIT;
    }
}
