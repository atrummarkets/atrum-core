// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Vault} from "./Vault.sol";
import {IOracleResolver} from "./IOracleResolver.sol";
import {IPyth, PythPrice, PythPriceFeed} from "./interfaces/IPyth.sol";

/// @title PythResolver
/// @notice Resolves a market from a Pyth price at a COMMITTED past timestamp.
///
/// @dev THE MISTAKE THIS IS BUILT TO AVOID
///
///      Pyth is a PULL oracle: nothing is on-chain until somebody pays to put it there. On
///      Monad testnet the stored BTC/USD aggregate was measured **55.8 hours stale** --
///      $64,198.98 against a live $62,877.01, confirmed to within $3 by Coinbase and Kraken.
///      It was not broken data; it was simply the last value anyone had paid to write.
///
///      So the obvious implementation is silently wrong:
///
///          pyth.getPriceUnsafe(BTC_USD)          // resolves today on Tuesday's price
///
///      A market on "BTC above $63,000?" would have settled YES on that stale value when the
///      true answer was NO. Deterministic, unnoticeable, and holding real money.
///      `getPriceNoOlderThan` at least reverts, but it answers "what is the price NOW", and a
///      prediction market asks "what was the price at 8pm on Friday" -- a different question
///      that no amount of freshness answers.
///
///      Hence `parsePriceFeedUpdatesUnique`: the caller supplies signed data, Pyth verifies
///      the signatures, and the call REVERTS unless an update falls inside the committed
///      window. The price is fetched at the market's own resolution time and nowhere else.
///
///      WHAT THE CALLER CANNOT CHOOSE
///
///      Resolution is permissionless, which is only safe because the caller has no degrees of
///      freedom worth having:
///        - not the QUESTION: `spec` must hash to the vault's immutable `resolutionSpecHash`,
///          fixed when the market was created.
///        - not the TIMESTAMP: it is inside the spec, so it is inside that hash.
///        - not the PRICE: Pyth's signatures are verified on-chain, and `...Unique` pins the
///          result to the FIRST update at or after `targetTime`. The plain variant would
///          leave this open -- at ~400ms between publishes a 60s window offers ~150
///          candidates, and a bettor calling `resolve` could submit whichever one wins them
///          the market.
///        - not the OUTCOME: it is a comparison, not a decision.
///
///      A caller can pick the block they submit in and pay the fee. That is all.
///
///      CONFIDENCE, AND WHY IT DOES NOT GATE THE RESULT
///
///      Pyth returns `price ± conf`. When a threshold sits inside that band the outcome is
///      statistically ambiguous, and it is tempting to refuse.
///
///      It is still not done, though the reason has changed. Before `Vault.Outcome.Void`
///      existed, refusing meant the market stayed Unresolved forever and every stake froze;
///      that argument no longer holds, because refusing now just means the market voids
///      after `VOID_DELAY` and everyone is refunded. Declining on ambiguity would be
///      defensible today.
///
///      It is not done because it is not worth the moving parts. Measured on Monad testnet,
///      BTC/USD carried a confidence of $17.81 against a $62,877.01 price -- 0.03%. For a
///      threshold to land inside that band is rare, and when it does the market was badly
///      specified rather than badly resolved. Adding a `maxConfidence` field would put a new
///      griefable knob in the committed spec to handle a case that belongs at market
///      creation.
///
///      So resolution is strictly on the aggregate price, and `conf` is emitted in the event
///      instead, making ambiguity auditable after the fact.
contract PythResolver is IOracleResolver {
    /// @notice The question a market commits to at creation.
    ///
    /// @dev Encoded, hashed, and stored in `Vault.resolutionSpecHash` before betting opens.
    ///      Every field is inside the hash, so none of them can be chosen later.
    struct Spec {
        /// @dev Pyth feed id, e.g. BTC/USD.
        bytes32 priceId;
        /// @dev Compared against the price. Signed, because prices can be.
        int64 threshold;
        /// @dev The exponent `threshold` is expressed in. Pyth's own exponent is per-feed and
        ///      not guaranteed constant, so the two are normalised at comparison time rather
        ///      than assumed equal.
        int32 thresholdExpo;
        /// @dev The moment the price is read from. Not "now" -- the market's own question.
        uint64 targetTime;
        /// @dev Seconds after `targetTime` an update may still land in. Feeds publish at
        ///      different rates, so this is per-market and committed rather than a constant
        ///      that is too tight for one feed and too loose for another.
        ///
        ///      This is a LIVENESS bound, not a security one: `parsePriceFeedUpdatesUnique`
        ///      already pins the result to the first update at or after `targetTime`, so a
        ///      wider window cannot be used to shop for a better price. It only decides how
        ///      long a market waits for a feed that has gone quiet before giving up -- and
        ///      giving up means `voidMarket`, not a wrong answer.
        uint64 windowSeconds;
        /// @dev true  -> YES when price >  threshold
        ///      false -> YES when price <  threshold
        bool greaterThan;
    }

    /// @dev Domain tag, so a spec built for this adapter cannot be replayed against another
    ///      that happens to share a field layout.
    bytes32 private constant SPEC_DOMAIN = keccak256("atrum.resolver.pyth.v1");

    /// @dev Ceiling on the gap between the two exponents. Real feeds sit in [-12, 0], so a
    ///      larger gap is a malformed spec -- and rejecting it keeps the 10**delta scaling
    ///      far below the point where it could overflow int256.
    uint256 private constant MAX_EXPO_DELTA = 30;

    IPyth public immutable pyth;

    event Resolved(
        address indexed vault,
        bytes32 indexed priceId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint256 publishTime,
        Vault.Outcome outcome
    );

    error SpecMismatch(bytes32 expected, bytes32 supplied);
    error TargetBeforeBettingClose(uint64 targetTime, uint64 bettingCloseTime);
    error NotThisResolver(address expected);
    error InsufficientFee(uint256 required, uint256 supplied);
    error ExponentOutOfRange(int32 priceExpo, int32 thresholdExpo);
    error NoFeedReturned();
    error WrongFeedReturned(bytes32 expected, bytes32 got);
    error RefundFailed();

    constructor(IPyth pyth_) {
        if (address(pyth_) == address(0)) revert NotThisResolver(address(0));
        pyth = pyth_;
    }

    // -----------------------------------------------------------------------
    // Spec binding
    // -----------------------------------------------------------------------

    function specHash(bytes calldata spec) external pure returns (bytes32) {
        return _specHash(abi.decode(spec, (Spec)));
    }

    /// @notice Hash for binding into `Vault.resolutionSpecHash` at market creation.
    function hashSpec(Spec memory s) public pure returns (bytes32) {
        return _specHash(s);
    }

    function _specHash(Spec memory s) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SPEC_DOMAIN, s.priceId, s.threshold, s.thresholdExpo, s.targetTime, s.windowSeconds, s.greaterThan
            )
        );
    }

    // -----------------------------------------------------------------------
    // Resolution
    // -----------------------------------------------------------------------

    function resolutionFee(bytes[] calldata oracleData) external view returns (uint256) {
        return pyth.getUpdateFee(oracleData);
    }

    /// @notice Resolve `vault`. Anyone may call; the caller decides nothing.
    function resolve(Vault vault, bytes calldata spec, bytes[] calldata oracleData) external payable {
        Spec memory s = abi.decode(spec, (Spec));

        // 1. The question must be the one this market committed to before betting opened.
        bytes32 expected = vault.resolutionSpecHash();
        bytes32 supplied = _specHash(s);
        if (expected != supplied) revert SpecMismatch(expected, supplied);

        // 2. This contract must actually be the vault's resolver. Without it a caller could
        //    burn their own fee against a vault that will reject the final call anyway --
        //    and the revert would come from Vault, pointing at the wrong problem.
        if (vault.resolver() != address(this)) revert NotThisResolver(vault.resolver());

        // 3. The price must be from AFTER betting closed. A market whose answer was already
        //    determined while people were still betting is not a prediction market; it is a
        //    payout to whoever checked. Cheap to enforce, and impossible to fix later
        //    because the spec is immutable.
        uint64 close = vault.bettingCloseTime();
        if (s.targetTime < close) revert TargetBeforeBettingClose(s.targetTime, close);

        // 4. Verify the signed update and pull the price from the committed window. Pyth
        //    reverts if nothing lands inside it.
        uint256 fee = pyth.getUpdateFee(oracleData);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = s.priceId;

        // `...Unique`, deliberately. The plain variant accepts any update inside the
        // window, and the CALLER picks what to submit -- with Pyth publishing about every
        // 400ms, a 60-second window offers ~150 candidates to choose from. Since resolution
        // is permissionless, that caller can be a bettor selecting the price that wins them
        // the market. The Unique variant returns only the FIRST update at or after
        // `targetTime` and proves no earlier one exists in range, so there is nothing left
        // to choose.
        PythPriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdatesUnique{value: fee}(oracleData, ids, s.targetTime, s.targetTime + s.windowSeconds);

        if (feeds.length == 0) revert NoFeedReturned();
        // Belt and braces: Pyth returns feeds in the order requested, but this contract
        // decides who gets paid, so the id is checked rather than trusted.
        if (feeds[0].id != s.priceId) revert WrongFeedReturned(s.priceId, feeds[0].id);

        PythPrice memory p = feeds[0].price;

        // 5. The outcome is a comparison, not a decision.
        Vault.Outcome outcome = _outcome(p, s);
        vault.resolve(outcome);

        emit Resolved(address(vault), s.priceId, p.price, p.conf, p.expo, p.publishTime, outcome);

        // 6. Refund the excess. The exact fee is only knowable at call time so callers
        //    necessarily over-send; keeping the difference would be a silent toll. Last,
        //    after every state change, so a refund recipient that re-enters finds nothing
        //    left to do -- `Vault.resolve` already reverts on an already-resolved market.
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    // -----------------------------------------------------------------------
    // Comparison
    // -----------------------------------------------------------------------

    /// @dev Normalises the two exponents and compares. Equality resolves to NO under
    ///      `greaterThan` (strict `>`), and to NO under `<` as well -- "above 63,000" and
    ///      "below 63,000" are both false at exactly 63,000, which is the only reading that
    ///      keeps a pair of complementary markets from both paying out.
    function _outcome(PythPrice memory p, Spec memory s) private pure returns (Vault.Outcome) {
        (int256 lhs, int256 rhs) = _normalise(p.price, p.expo, s.threshold, s.thresholdExpo);
        bool yes = s.greaterThan ? lhs > rhs : lhs < rhs;
        return yes ? Vault.Outcome.Yes : Vault.Outcome.No;
    }

    /// @dev Scales both values to the finer of the two exponents, so the comparison is exact
    ///      integer arithmetic with no division and no truncation. Scaling DOWN would discard
    ///      the digits nearest the threshold, which are precisely the ones that decide a
    ///      close market.
    function _normalise(int64 price, int32 priceExpo, int64 threshold, int32 thresholdExpo)
        private
        pure
        returns (int256 lhs, int256 rhs)
    {
        lhs = int256(price);
        rhs = int256(threshold);
        if (priceExpo == thresholdExpo) return (lhs, rhs);

        if (priceExpo > thresholdExpo) {
            uint256 delta = uint256(int256(priceExpo) - int256(thresholdExpo));
            if (delta > MAX_EXPO_DELTA) revert ExponentOutOfRange(priceExpo, thresholdExpo);
            lhs = lhs * int256(10 ** delta);
        } else {
            uint256 delta = uint256(int256(thresholdExpo) - int256(priceExpo));
            if (delta > MAX_EXPO_DELTA) revert ExponentOutOfRange(priceExpo, thresholdExpo);
            rhs = rhs * int256(10 ** delta);
        }
    }
}
