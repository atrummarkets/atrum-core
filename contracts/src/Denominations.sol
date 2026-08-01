// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title Denominations
/// @notice The allowed sizes for anything whose size becomes public.
///
/// @dev WHY THIS IS A CONSENSUS RULE AND NOT A WALLET CONVENTION
///
///      `deposit` publishes the depositor's address and the exact amount -- it has to, real
///      collateral moves and a transfer is visible. Privacy does not come from hiding that.
///      It comes from UNLINKABILITY: a later bet proves it owns SOME note in the tree without
///      revealing which, so an observer knows a deposit is being bet but not whose.
///
///      That only works if your deposit looks like everyone else's. Deposit 137 when everyone
///      else deposits 100 and you are the only note of that size; the very next bet is
///      unmistakably yours. `deposit.circom` already says this in its own notice -- "fixed
///      denominations are what stop `units` itself being an identifier" -- and until now
///      nothing enforced it. The only amount check was `units != 0`.
///
///      A client-side ladder does not fix it, for a reason that is easy to miss: an odd
///      deposit does not only expose that user. Each distinct amount is its own anonymity
///      bucket, so one non-standard deposit **shrinks the set for everyone else too**. That
///      makes it a shared-safety property, and shared-safety properties belong in consensus,
///      not in a wallet that a power user can bypass by calling the contract directly.
///
///      WHERE IT APPLIES
///
///      Two places, and only two -- the points where a size becomes public:
///        - `deposit`, where `units` is a public signal.
///        - `withdraw`, where `amount` is packed into public `withdrawData`.
///
///      It deliberately does NOT apply to the change note a withdrawal leaves behind, or to a
///      redeemed payout. Those stay inside the pool and are never published, and a parimutuel
///      payout is whatever the arithmetic produced -- 1,041, an odd number -- so forcing it
///      onto a ladder would be impossible rather than merely inconvenient.
///
///      THE COST, STATED PLAINLY
///
///      `bet_encrypted` spends a note WHOLE; there is no partial-bet path. So a note's value
///      is its deposit's value, and a ladder on deposits is a ladder on bets. Staking 370
///      means several transactions at roughly 0.275 MON each rather than one. That is a real
///      UX cost, paid to make the privacy claim structural instead of conventional.
///
///      Powers of ten are chosen over a denser 1-2-5 ladder for exactly that reason: fewer
///      rungs means fewer, larger anonymity sets. Every extra denomination splits the crowd.
library Denominations {
    /// @notice Largest exponent on the ladder. 10^9 units.
    uint256 internal constant MAX_EXPONENT = 9;

    /// @notice True if `units` is a power of ten in [1, 10^MAX_EXPONENT].
    ///
    /// @dev Computed rather than stored. A mapping lookup would cost a cold SLOAD -- 8,100 on
    ///      Monad, 4x Ethereum -- on an action already at 72% of the envelope, where this loop
    ///      is a few hundred gas and cannot be misconfigured after deployment.
    function isValid(uint256 units) internal pure returns (bool) {
        if (units == 0) return false;

        uint256 rung = 1;
        for (uint256 i = 0; i <= MAX_EXPONENT; i++) {
            if (units == rung) return true;
            if (units < rung) return false; // sorted ascending, so no later rung can match
            rung *= 10;
        }
        return false;
    }
}
