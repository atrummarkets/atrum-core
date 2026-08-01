// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title Vault -- collateral and outcome-token layer for a single-event Atrum market
/// @notice Phase 0 skeleton. Splits collateral into a complete set of YES/NO outcome
///         tokens, merges them back, and redeems the winning side after resolution.
///
/// @dev Scope, deliberately: this is the *public* collateral layer for a **plain,
///      single-event** market. There is no nesting -- no `A_YES -> {A&B, A&NOT_B}`.
///      Conditional markets are a separate architecture, not a flag on this one.
///
///      Phase 0 holds positions as public balances. That is temporary and is the
///      whole reason Phase 0 is an internal milestone rather than a launch: with
///      public balances there is no privacy claim to make yet. In Phase 1 the
///      balance mappings here are replaced by a Poseidon commitment tree in the
///      ShieldedPool, and this contract keeps only custody of collateral.
///
///      Redemption MUST eventually move inside the ShieldedPool. A public payout
///      claim retroactively deanonymises every position, which makes the privacy
///      claim false rather than merely weak. The public `redeem` below exists only
///      while balances are already public; it is not a shippable end state.
contract Vault {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    enum Outcome {
        Unresolved,
        Yes,
        No,
        /// @dev The question could not be answered, so nobody wins and everybody is refunded.
        ///
        ///      This is the system's ONLY emergency control, and it is deliberately not a
        ///      control at all -- there is no key, no committee and no judgement behind it.
        ///      `voidMarket` is permissionless and purely mechanical.
        ///
        ///      Without it an unanswerable market is unanswerable FOREVER: `resolve` refuses
        ///      `Unresolved`, `redeemPrivate` requires resolution, and every stake stays
        ///      frozen for good. That is not hypothetical with an oracle resolver -- if no
        ///      signed price lands in the committed window, `parsePriceFeedUpdates` reverts
        ///      permanently by design. A market that pays the wrong side is bad; one that
        ///      pays nobody is worse.
        Void
    }

    // -----------------------------------------------------------------------
    // Immutable market definition
    // -----------------------------------------------------------------------

    /// @notice Collateral asset. Native USDC (CCTP) on Monad mainnet is
    ///         0x754704Bc059F8C67012fEd69BC8A327a5aafb603, 6 decimals.
    IERC20 public immutable collateral;

    /// @notice The one legal split size, in collateral base units.
    /// @dev Fixed denominations are a privacy requirement, not an ergonomic choice.
    ///      Arbitrary split sizes leak participation and position size even when the
    ///      amounts themselves are hidden, because the split amount is public.
    uint256 public immutable denomination;

    /// @notice Sole address permitted to resolve. Committed at construction and
    ///         immutable thereafter.
    address public immutable resolver;

    /// @notice keccak256 of the full off-chain resolution spec.
    /// @dev Committed at construction so the rules cannot be reinterpreted after
    ///      bets are placed. Spec text lives off-chain; only its hash is on-chain.
    bytes32 public immutable resolutionSpecHash;

    /// @notice No new splits at or after this timestamp.
    uint64 public immutable bettingCloseTime;

    /// @notice Resolution cannot be submitted before this timestamp.
    /// @dev There must be a gap between betting close and resolution start.
    ///      Without it, last-second bets front-run information that is already
    ///      determined, and unlike ordinary parimutuel bets that trade *is*
    ///      profitable -- which breaks the order-independence the mechanism relies on.
    uint64 public immutable resolutionStartTime;

    /// @notice Minimum enforced gap between betting close and resolution start.
    uint64 public constant MIN_RESOLUTION_GAP = 1 hours;

    /// @notice How long after resolution opens before anyone may void an unresolved market.
    ///
    /// @dev Long enough that a slow-but-working resolver is never pre-empted, short enough
    ///      that funds are not hostage to a resolver that will never come. It cannot be
    ///      abused in either direction: `voidMarket` refuses a market that is already
    ///      resolved, so nobody can void one whose outcome they dislike, and it refuses
    ///      early, so nobody can race a pending resolution.
    uint64 public constant VOID_DELAY = 7 days;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    Outcome public outcome;

    /// @dev Phase 1 replaces both mappings with a single commitment-tree root.
    mapping(address => uint256) public yesBalance;
    mapping(address => uint256) public noBalance;

    /// @notice Outstanding outcome tokens, denominated in units (not base units).
    uint256 public yesSupply;
    uint256 public noSupply;

    /// @notice Collateral held, in base units.
    uint256 public collateralHeld;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Split(address indexed account, uint256 units);
    event Merge(address indexed account, uint256 units);
    event Resolved(Outcome outcome);
    event Voided(uint64 votableAt);
    event Redeem(address indexed account, uint256 units, uint256 payout);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroUnits();
    error BettingClosed();
    error NotResolver();
    error AlreadyResolved();
    error NotResolved();
    error TooEarlyToResolve();
    error InvalidOutcome();
    error MarketVoided();
    error TooEarlyToVoid(uint64 votableAt);
    error InsufficientPosition();
    error TransferFailed();
    error InvalidDenomination();
    error InvalidSchedule();
    error InvalidResolver();

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    constructor(
        IERC20 collateral_,
        uint256 denomination_,
        address resolver_,
        bytes32 resolutionSpecHash_,
        uint64 bettingCloseTime_,
        uint64 resolutionStartTime_
    ) {
        if (denomination_ == 0) revert InvalidDenomination();
        if (resolver_ == address(0)) revert InvalidResolver();
        if (resolutionStartTime_ < bettingCloseTime_ + MIN_RESOLUTION_GAP) {
            revert InvalidSchedule();
        }

        collateral = collateral_;
        denomination = denomination_;
        resolver = resolver_;
        resolutionSpecHash = resolutionSpecHash_;
        bettingCloseTime = bettingCloseTime_;
        resolutionStartTime = resolutionStartTime_;
    }

    // -----------------------------------------------------------------------
    // Collateral <-> complete sets
    // -----------------------------------------------------------------------

    /// @notice Lock `units * denomination` collateral, receive `units` of YES and
    ///         `units` of NO.
    /// @dev A complete set is always worth exactly one denomination regardless of
    ///      outcome, which is what makes the vault solvent by construction.
    function split(uint256 units) external {
        if (units == 0) revert ZeroUnits();
        if (block.timestamp >= bettingCloseTime) revert BettingClosed();
        if (outcome != Outcome.Unresolved) revert AlreadyResolved();

        uint256 amount = units * denomination;

        yesBalance[msg.sender] += units;
        noBalance[msg.sender] += units;
        yesSupply += units;
        noSupply += units;
        collateralHeld += amount;

        _pullCollateral(msg.sender, amount);

        emit Split(msg.sender, units);
    }

    /// @notice Burn `units` of YES and `units` of NO, recover the collateral.
    /// @dev Restricted to pre-resolution. Post-resolution the winning side redeems
    ///      instead, and allowing both paths at once would mean two ways to value
    ///      the same token.
    function merge(uint256 units) external {
        if (units == 0) revert ZeroUnits();
        // Allowed while unresolved, and again once VOID -- a voided market refunds through
        // merge rather than redeem. Burning one YES and one NO per unit is the only
        // solvent way to refund both sides: the vault holds exactly one unit of collateral
        // per (YES, NO) pair, so paying each side 1:1 through `redeem` would need twice the
        // collateral that exists.
        if (outcome != Outcome.Unresolved && outcome != Outcome.Void) revert AlreadyResolved();

        if (yesBalance[msg.sender] < units || noBalance[msg.sender] < units) {
            revert InsufficientPosition();
        }

        uint256 amount = units * denomination;

        yesBalance[msg.sender] -= units;
        noBalance[msg.sender] -= units;
        yesSupply -= units;
        noSupply -= units;
        collateralHeld -= amount;

        _pushCollateral(msg.sender, amount);

        emit Merge(msg.sender, units);
    }

    // -----------------------------------------------------------------------
    // Resolution
    // -----------------------------------------------------------------------

    /// @notice Record the real-world outcome.
    /// @dev The resolver only ever flips this flag. It never touches collateral and,
    ///      once the encrypted pool exists, it is strictly separate from the
    ///      decryption committee: resolution selects a branch, the committee reveals
    ///      numbers. Keeping those trust surfaces independent is the point.
    function resolve(Outcome outcome_) external {
        if (msg.sender != resolver) revert NotResolver();
        if (outcome != Outcome.Unresolved) revert AlreadyResolved();
        if (outcome_ == Outcome.Unresolved) revert InvalidOutcome();
        // The resolver may pick a winner. It may NOT declare the market void -- that would
        // hand it a discretionary refund switch, and the whole point of `Void` being
        // deadline-gated is that no role can reach for it.
        if (outcome_ == Outcome.Void) revert InvalidOutcome();
        if (block.timestamp < resolutionStartTime) revert TooEarlyToResolve();

        outcome = outcome_;
        emit Resolved(outcome_);
    }

    /// @notice Burn `units` of the winning outcome token for `units * denomination`.
    /// @dev Losing tokens are simply worth nothing; they are never burned, so the
    ///      accounting deliberately leaves them outstanding.
    /// @notice Declare a market void once it is clear nobody is going to resolve it.
    ///
    /// @dev PERMISSIONLESS AND MECHANICAL, which is the entire design.
    ///
    ///      Anyone may call, but only after `resolutionStartTime + VOID_DELAY`, and only
    ///      while the market is still unresolved. Both bounds matter:
    ///
    ///        - refusing an already-resolved market means nobody can void an outcome they
    ///          dislike after seeing it;
    ///        - refusing before the deadline means nobody can race a resolver that is simply
    ///          slow.
    ///
    ///      So there is no discretion to capture. The caller cannot influence WHETHER a
    ///      market voids, only observe that it already has by the clock.
    ///
    ///      Refunds then flow through `merge`, not `redeem` -- see the note there.
    function voidMarket() external {
        if (outcome != Outcome.Unresolved) revert AlreadyResolved();

        uint64 votableAt = resolutionStartTime + VOID_DELAY;
        if (block.timestamp < votableAt) revert TooEarlyToVoid(votableAt);

        outcome = Outcome.Void;
        emit Voided(votableAt);
    }

    function redeem(uint256 units) external {
        if (units == 0) revert ZeroUnits();
        if (outcome == Outcome.Unresolved) revert NotResolved();
        // A void market has no winning side, so there is nothing to redeem against. Refunds
        // go through `merge`. Without this the branch below would silently treat NO as the
        // winner, because it is the `else` of a two-way check.
        if (outcome == Outcome.Void) revert MarketVoided();

        mapping(address => uint256) storage winning = outcome == Outcome.Yes ? yesBalance : noBalance;

        if (winning[msg.sender] < units) revert InsufficientPosition();

        uint256 payout = units * denomination;

        winning[msg.sender] -= units;
        if (outcome == Outcome.Yes) {
            yesSupply -= units;
        } else {
            noSupply -= units;
        }
        collateralHeld -= payout;

        _pushCollateral(msg.sender, payout);

        emit Redeem(msg.sender, units, payout);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @notice Outstanding units of the winning side, or 0 while unresolved.
    function winningSupply() external view returns (uint256) {
        if (outcome == Outcome.Yes) return yesSupply;
        if (outcome == Outcome.No) return noSupply;
        return 0;
    }

    // -----------------------------------------------------------------------
    // Internal transfer helpers
    // -----------------------------------------------------------------------

    /// @dev Handles both reverting and `false`-returning ERC20s. USDC returns a bool.
    function _pullCollateral(address from, uint256 amount) private {
        if (!collateral.transferFrom(from, address(this), amount)) {
            revert TransferFailed();
        }
    }

    function _pushCollateral(address to, uint256 amount) private {
        if (!collateral.transfer(to, amount)) revert TransferFailed();
    }
}
