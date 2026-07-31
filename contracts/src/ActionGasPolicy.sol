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
    ///      1,162,809 gas for the 8-public-signal Phase 2 encrypted-bet verifier on
    ///      live Monad (MEASUREMENTS.md §1). On top of verification an action also
    ///      pays:
    ///        - intrinsic tx cost and calldata,
    ///        - nullifier insertion and commitment-tree subtree update,
    ///        - the ElGamal accumulator update (Phase 2),
    ///        - cold storage access, at Monad's 8,100 per cold SLOAD (4x Ethereum).
    ///
    ///      DO NOT READ THE REMAINING ~837,000 AS HEADROOM. That subtraction compares
    ///      an isolated `eth_call` verify against the envelope, and a real transaction
    ///      pays for far more than the verify: measured on real testnet transactions,
    ///      `deposit` costs 1,816,031 -- 91% of this envelope -- against a local
    ///      `forge` figure of 1,378,641 (MEASUREMENTS.md §1c). Local pricing charges
    ///      neither calldata nor the intrinsic cost nor true cross-contract cold
    ///      access. The real remaining headroom is closer to 184,000.
    ///
    ///      The envelope stays at 2,000,000 regardless, because every change to it is
    ///      publicly observable and shrinks the anonymity set of everything submitted
    ///      before it. An action that does not fit gets optimised; the envelope does
    ///      not move to accommodate it.
    uint256 internal constant UNIFORM_ACTION_GAS_LIMIT = 2_000_000;

    /// @notice Highest verify cost we have actually measured on Monad, for any
    ///         action. Kept here so the uniformity test has a real anchor.
    ///
    /// @dev This is the COLD first-call figure, which is the one a declared
    ///      transaction limit has to cover: the first touch of the verifier in a
    ///      transaction pays Monad's cold account access charge (~10,100, versus
    ///      2,600 on Ethereum) on top of the warm execution cost. Using the warm
    ///      figure here would under-declare by roughly that amount.
    ///      Warm equivalent, for reference: 1,152,559.
    ///
    ///      Phase 2's `bet_encrypted` now sets this. It carries 8 public signals
    ///      against `bet`'s 4 -- the ciphertext is four field elements the contract
    ///      has to add to the accumulator, so it cannot be packed away -- and the
    ///      four extra signals cost a measured 123,105 gas, 30,776 each. That is the
    ///      per-signal price the whole packing discipline exists to avoid paying.
    uint256 internal constant MAX_MEASURED_VERIFY_GAS = 1_162_809;

    /// @notice Block gas limit measured on Monad mainnet.
    /// @dev Docs claim 200,000,000; that figure is stale. Measured at 150,000,000.
    uint256 internal constant BLOCK_GAS_LIMIT = 150_000_000;

    /// @notice Actions per block if every one is padded to the uniform envelope.
    function actionsPerBlock() internal pure returns (uint256) {
        return BLOCK_GAS_LIMIT / UNIFORM_ACTION_GAS_LIMIT;
    }
}
