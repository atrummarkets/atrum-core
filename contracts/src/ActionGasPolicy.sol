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
    ///      SET ONCE, FROM MEASUREMENT. 2,000,000 was chosen before any action had been
    ///      broadcast. Every user action has now been measured on real Monad testnet
    ///      transactions -- see `deployments/monad-testnet-10143/` for the receipts:
    ///
    ///        betEncrypted   1,904,445   95.2% of 2,000,000
    ///        deposit        1,815,993   90.8%
    ///        withdraw       1,804,341   90.2%
    ///        redeemPrivate  1,671,108   83.6%
    ///
    ///      At 2,000,000 the binding action had 95,555 gas of headroom -- and two
    ///      `betEncrypted` calls in the same run measured 1,904,445 and 1,859,711, a
    ///      44,734 spread from cold/warm variation alone. Roughly half the headroom was
    ///      consumed by ordinary variance, before any code change.
    ///
    ///      That margin is not survivable, because overrunning is worse than expensive:
    ///      the transaction reverts out of gas AND the user still pays the full declared
    ///      limit, so they lose the fee and get nothing.
    ///
    ///      2,500,000 puts the binding action at 76% with 595,555 of headroom, about 13x
    ///      the observed variance, leaving room for the threshold committee and resolver
    ///      work without moving this number again.
    ///
    ///      IT COSTS USERS REAL MONEY, and that is measured too, not assumed: a
    ///      21,000-gas transfer declared at 2,000,000 was charged for 2,114,412 gas on
    ///      testnet. Monad bills the DECLARED limit, so raising the envelope raises the
    ///      price of every action -- roughly 0.275 MON against 0.220 at 110 gwei. That
    ///      is the price of the uniformity property, paid on every action including
    ///      cheap ones.
    ///
    ///      DO NOT MOVE IT AGAIN. Every change is publicly observable and shrinks the
    ///      anonymity set of everything submitted before it. An action that does not fit
    ///      gets optimised; the envelope does not move to accommodate it.
    uint256 internal constant UNIFORM_ACTION_GAS_LIMIT = 2_500_000;

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

    /// @notice Lowest measured ratio of REAL testnet gas to local `forge` gas, as a
    ///         percentage. Use it to project a local figure before comparing it to the
    ///         envelope.
    ///
    /// @dev Local `forge` charges neither calldata, nor the intrinsic transaction cost,
    ///      nor true cross-contract cold access, so every local number in this repo is a
    ///      LOWER BOUND. Measured across all four user actions on real testnet
    ///      transactions: deposit 1.32x, betEncrypted 1.41x, redeemPrivate 1.48x,
    ///      withdraw 1.55x.
    ///
    ///      The MINIMUM is kept rather than the mean or the max, deliberately. This
    ///      constant is used to prove that something does NOT fit, so the conservative
    ///      choice is the one that makes fitting easiest -- if a path overruns even at
    ///      1.32x, it overruns.
    uint256 internal constant MIN_LOCAL_TO_TESTNET_PCT = 132;

    /// @notice Block gas limit measured on Monad mainnet.
    /// @dev Docs claim 200,000,000; that figure is stale. Measured at 150,000,000.
    uint256 internal constant BLOCK_GAS_LIMIT = 150_000_000;

    /// @notice Actions per block if every one is padded to the uniform envelope.
    function actionsPerBlock() internal pure returns (uint256) {
        return BLOCK_GAS_LIMIT / UNIFORM_ACTION_GAS_LIMIT;
    }
}
