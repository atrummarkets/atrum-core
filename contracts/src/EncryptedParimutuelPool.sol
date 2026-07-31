// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BabyJubJub} from "./BabyJubJub.sol";
import {ChaumPedersen} from "./ChaumPedersen.sol";
import {ElGamalAccumulator} from "./ElGamalAccumulator.sol";
import {ShieldedPool} from "./ShieldedPool.sol";
import {Vault} from "./Vault.sol";

/// @title EncryptedParimutuelPool
/// @notice The Phase 2 sibling of `ParimutuelPool`: the thing settlement reads, when the
///         pool total is a ciphertext instead of a running `uint128`.
///
/// @dev WHAT THIS CONTRACT IS DEFENDING AGAINST
///
///      Encrypting the pool creates a hole that Phase 1 did not have. In Phase 1 the
///      contract computed payouts from totals it had summed itself, so the operator could
///      not lie about them. Here the contract cannot read its own pool total -- only the
///      key holder can -- so somebody has to tell it what the total was, and that somebody
///      could lie. A total favouring one side overpays its holders out of the other side's
///      collateral. Nothing else on-chain would notice.
///
///      So every number payouts depend on is verified twice over:
///
///        1. `ChaumPedersen.verify` proves the decryption share `D` really is `[s]C1` for
///           the same `s` as the disclosed committee key `H`. This stops a forged share.
///
///        2. The claimed plaintext is bound to the ciphertext algebraically. This is the
///           step that does NOT come free with (1), and it is the one worth reading
///           carefully -- see `_checkClaimedPlaintext`.
///
///      TWO PUBLISHING PATHS, AND ONLY ONE OF THEM IS TRUSTED WITH MONEY
///
///      `publishFinalTotals` is verified end to end and is the ONLY thing settlement
///      reads. `publishAttestedRatio` is an operator attestation that is deliberately NOT
///      verifiable on-chain, and no payout may ever derive from it. The asymmetry is not
///      an oversight; it is forced, and the reason is worth stating plainly:
///
///      To verify a RATIO against the ciphertexts, the contract would need the two
///      plaintext totals -- that is what a verification equation consumes. Putting them in
///      calldata publishes them, which is precisely what this phase exists to prevent. A
///      ratio is a division, and additive ElGamal offers no division. So mid-market odds
///      are an attestation by whoever holds the key, and the honest description is that
///      they are informational.
///
///      That is tolerable only because the attestation moves no funds: a dishonest
///      mid-market ratio misleads bettors about the odds, but payouts are computed from
///      `publishFinalTotals`, which cannot be lied about. If a future change ever makes a
///      payout read `attestedRatioBps`, this contract's entire security argument is void.
contract EncryptedParimutuelPool {
    /// @notice Where the ciphertext totals live.
    ElGamalAccumulator public immutable accumulator;

    /// @notice Used to resolve `marketId -> Vault`, so resolution state is read from the
    ///         same registry the shielded actions use rather than a second, driftable one.
    ShieldedPool public immutable pool;

    /// @notice The disclosed committee public key `H = [s]G`.
    /// @dev Immutable and public. Phase 2 ships a single key, disclosed plainly -- the
    ///      privacy claim rests on the ciphertext, not on hiding whose key it is. Phase 3
    ///      replaces this with a 3-of-5 committee, which changes how `D` is produced but
    ///      not a single line of the verification below.
    uint256 public immutable committeeKeyX;
    uint256 public immutable committeeKeyY;

    /// @notice Shortest gap between two attested-ratio publications, in seconds.
    ///
    /// @dev A PRIVACY CONTROL, NOT RATE LIMITING. `atrum-build-plan.md` §6 requires odds be
    ///      published "on a cadence, never continuously", because continuous revelation
    ///      reintroduces the late-money problem the encryption exists to solve: an observer
    ///      diffing the odds after each bet learns roughly what that bet was, and the
    ///      encrypted total stops being encrypted in any way that matters.
    ///
    ///      Enforced on-chain rather than left to the off-chain worker's timer, because a
    ///      privacy property that depends on an operator remembering to sleep is not a
    ///      property.
    uint256 public immutable minPublishInterval;

    /// @notice Last attested ratio, in basis points of YES. INFORMATIONAL ONLY.
    mapping(uint32 => uint256) public attestedRatioBps;
    mapping(uint32 => uint256) public lastAttestedAt;

    /// @notice Verified final totals. These are what settlement reads.
    mapping(uint32 => uint256) public finalYesTotal;
    mapping(uint32 => uint256) public finalNoTotal;
    mapping(uint32 => bool) public settled;

    /// @notice A decryption share plus the proof that it was honestly derived.
    struct Decryption {
        uint256 dx;
        uint256 dy;
        ChaumPedersen.Proof proof;
    }

    event RatioAttested(uint32 indexed marketId, uint256 ratioBps);
    event MarketSettled(uint32 indexed marketId, uint256 yesTotal, uint256 noTotal);

    error InvalidDecryptionProof();
    error ClaimedPlaintextMismatch();
    error AlreadySettled();
    error NotSettled();
    error BettingStillOpen();
    error MarketNotResolved();
    error PublishedTooSoon();
    error InvalidRatio();

    constructor(
        ElGamalAccumulator accumulator_,
        ShieldedPool pool_,
        uint256 committeeKeyX_,
        uint256 committeeKeyY_,
        uint256 minPublishInterval_
    ) {
        // A key that is not on the curve is not a public key, and every proof verified
        // against it would be meaningless.
        require(BabyJubJub.isOnCurve(committeeKeyX_, committeeKeyY_), "committee key not on curve");

        accumulator = accumulator_;
        pool = pool_;
        committeeKeyX = committeeKeyX_;
        committeeKeyY = committeeKeyY_;
        minPublishInterval = minPublishInterval_;
    }

    // -----------------------------------------------------------------------
    // Mid-market odds -- attested, NOT verified
    // -----------------------------------------------------------------------

    /// @notice Publish the current YES probability in basis points.
    ///
    /// @dev UNVERIFIED BY CONSTRUCTION. See the contract notice: checking a ratio against
    ///      the ciphertexts requires the plaintext totals, and publishing those defeats the
    ///      phase. No payout reads this value.
    ///
    ///      Permissionless on purpose. Gating it would suggest the value is authoritative,
    ///      which it is not, and the cadence guard below is the only property that actually
    ///      needs enforcing.
    function publishAttestedRatio(uint32 marketId, uint256 ratioBps) external {
        if (ratioBps > 10_000) revert InvalidRatio();

        uint256 last = lastAttestedAt[marketId];
        if (last != 0 && block.timestamp < last + minPublishInterval) revert PublishedTooSoon();

        attestedRatioBps[marketId] = ratioBps;
        lastAttestedAt[marketId] = block.timestamp;

        emit RatioAttested(marketId, ratioBps);
    }

    // -----------------------------------------------------------------------
    // Settlement -- verified, and the only thing payouts may read
    // -----------------------------------------------------------------------

    /// @notice Reveal and prove the final pool totals, once, after resolution.
    ///
    /// @dev Revealing the exact totals here is a deliberate, bounded relaxation of "hide
    ///      the aggregate". It is required for solvency -- a pro-rata division needs real
    ///      numbers, not a rounded ratio -- and it is safe precisely because it happens
    ///      after betting has closed AND the outcome is known, so nobody can act on it.
    ///      The mid-market path never reveals magnitudes.
    ///
    ///      Both gates are load-bearing. Without `bettingCloseTime`, revealing the totals
    ///      would hand late bettors exactly the read the encryption exists to deny. Without
    ///      resolution, an operator could reveal early and then let betting continue.
    function publishFinalTotals(
        uint32 marketId,
        uint256 yesTotal,
        uint256 noTotal,
        Decryption calldata yes,
        Decryption calldata no
    ) external {
        if (settled[marketId]) revert AlreadySettled();

        Vault vault = pool.marketVault(marketId);
        if (block.timestamp < vault.bettingCloseTime()) revert BettingStillOpen();
        if (vault.outcome() == Vault.Outcome.Unresolved) revert MarketNotResolved();

        _verifySide(marketId, 1, yes, yesTotal);
        _verifySide(marketId, 2, no, noTotal);

        finalYesTotal[marketId] = yesTotal;
        finalNoTotal[marketId] = noTotal;
        settled[marketId] = true;

        emit MarketSettled(marketId, yesTotal, noTotal);
    }

    /// @dev Verify one side: the decryption share is honest, AND the claimed number is the
    ///      number that ciphertext actually encrypts.
    function _verifySide(uint32 marketId, uint8 outcome, Decryption calldata dec, uint256 claimed) private view {
        (uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y) = accumulator.totalAffine(marketId, outcome);

        if (!ChaumPedersen.verify(committeeKeyX, committeeKeyY, c1x, c1y, dec.dx, dec.dy, dec.proof)) {
            revert InvalidDecryptionProof();
        }

        if (!_checkClaimedPlaintext(c2x, c2y, dec.dx, dec.dy, claimed)) {
            revert ClaimedPlaintextMismatch();
        }
    }

    /// @notice Bind a claimed plaintext to the ciphertext it is claimed to decrypt.
    ///
    /// @dev THIS IS THE CHECK THAT CHAUM-PEDERSEN DOES NOT GIVE YOU, and its absence would
    ///      be silent.
    ///
    ///      `ChaumPedersen.verify` proves exactly one thing: that `D` was computed as
    ///      `[s]C1` using the same `s` as the committee key. It says NOTHING about what
    ///      integer the publisher additionally claims the plaintext is. A publisher can
    ///      supply a perfectly honest `D`, a perfectly valid DLEQ proof, and an arbitrary
    ///      `yesTotal` -- and without the equation below, that lie settles the market.
    ///
    ///      The binding is direct. With `C2 = [m]G + [r]H` and `D = [s]C1 = [s][r]G =
    ///      [r]H`:
    ///
    ///          C2 - D = [m]G
    ///
    ///      so the claimed `m` is correct exactly when `[m]G` equals `C2 - D`. One fixed-
    ///      base scalar multiplication and one addition; negation is free on a twisted
    ///      Edwards curve.
    ///
    ///      `m = 0` is handled explicitly rather than left to the ladder: `[0]G` is the
    ///      identity `(0,1)`, and an empty pool is a real case -- a market that closes with
    ///      no bets on one side must still settle.
    function _checkClaimedPlaintext(uint256 c2x, uint256 c2y, uint256 dx, uint256 dy, uint256 claimed)
        private
        view
        returns (bool)
    {
        BabyJubJub.Point memory target =
            BabyJubJub.add(BabyJubJub.fromAffine(c2x, c2y), BabyJubJub.negate(BabyJubJub.fromAffine(dx, dy)));
        (uint256 tx_, uint256 ty) = BabyJubJub.toAffine(target);

        if (claimed == 0) return tx_ == 0 && ty == 1;

        BabyJubJub.Point memory mG =
            BabyJubJub.scalarMulPublic(BabyJubJub.fromAffine(BabyJubJub.BASE8X, BabyJubJub.BASE8Y), claimed);
        (uint256 mx, uint256 my) = BabyJubJub.toAffine(mG);

        return mx == tx_ && my == ty;
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @notice Pro-rata payout for `units` on the winning side, from verified totals.
    /// @dev Mirrors `ParimutuelPool.payoutUnits`. Truncation is down-only, so the sum of
    ///      payouts can never exceed the pool.
    function payoutUnits(uint32 marketId, uint8 winningOutcome, uint256 units) external view returns (uint256) {
        if (!settled[marketId]) revert NotSettled();

        uint256 yes = finalYesTotal[marketId];
        uint256 no = finalNoTotal[marketId];
        uint256 total = yes + no;
        uint256 winning = winningOutcome == 1 ? yes : no;

        if (winning == 0) return 0;
        return (units * total) / winning;
    }

    /// @notice The settled YES probability in basis points, derived from verified totals.
    function finalYesProbabilityBps(uint32 marketId) external view returns (uint256) {
        if (!settled[marketId]) revert NotSettled();

        uint256 total = finalYesTotal[marketId] + finalNoTotal[marketId];
        if (total == 0) return 0;
        return (finalYesTotal[marketId] * 10_000) / total;
    }
}
