// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {PythResolver} from "../src/PythResolver.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

/// @notice The resolver turns an outcome from a decision into a computation. These tests are
///         mostly about the four things a caller must NOT be able to choose: the question,
///         the timestamp, the price, and the outcome.
contract PythResolverTest is Test {
    MockERC20 internal usdc;
    MockPyth internal pyth;
    PythResolver internal resolver;
    Vault internal vault;

    bytes32 internal constant BTC = bytes32(uint256(0xB7C));
    bytes32 internal constant ETH = bytes32(uint256(0xE7A));

    uint256 internal constant DENOM = 1e6;
    address internal constant STRANGER = address(0x57A);

    uint64 internal bettingClose;
    uint64 internal resolutionStart;
    uint64 internal targetTime;

    PythResolver.Spec internal spec;

    function setUp() public {
        usdc = new MockERC20();
        pyth = new MockPyth();
        resolver = new PythResolver(IPyth(address(pyth)));

        bettingClose = uint64(block.timestamp + 1 days);
        resolutionStart = bettingClose + 2 hours;
        targetTime = bettingClose + 1 hours;

        // "Will BTC be above 63,000 at targetTime?"
        spec = PythResolver.Spec({
            priceId: BTC,
            threshold: 63_000_00000000, // 63,000 with expo -8
            thresholdExpo: -8,
            targetTime: targetTime,
            windowSeconds: 60,
            greaterThan: true
        });

        vault = _newVault(resolver.hashSpec(spec), address(resolver));

        // A price above the threshold, inside the window.
        pyth.setPrice(BTC, 64_000_00000000, 1_00000000, -8, targetTime + 1);
    }

    function _newVault(bytes32 specHash_, address resolver_) internal returns (Vault) {
        return new Vault(IERC20(address(usdc)), DENOM, resolver_, specHash_, bettingClose, resolutionStart);
    }

    function _resolve() internal {
        vm.warp(resolutionStart);
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
    }

    // -----------------------------------------------------------------------
    // The caller cannot choose the QUESTION
    // -----------------------------------------------------------------------

    /// @notice THE binding. A spec that is not the one the market committed to is refused,
    ///         so a caller cannot answer a different question than the one people bet on.
    function test_rejectsASpecTheMarketDidNotCommitTo() public {
        PythResolver.Spec memory evil = spec;
        evil.threshold = 1; // "will BTC be above 0.00000001?" -- always YES

        vm.warp(resolutionStart);
        vm.expectRevert(
            abi.encodeWithSelector(PythResolver.SpecMismatch.selector, resolver.hashSpec(spec), resolver.hashSpec(evil))
        );
        resolver.resolve{value: 1 wei}(vault, abi.encode(evil), new bytes[](1));
    }

    /// @notice Every field is inside the hash, so none of them can be swapped later.
    function test_everySpecFieldIsBinding() public view {
        bytes32 base = resolver.hashSpec(spec);

        PythResolver.Spec memory s = spec;
        s.priceId = ETH;
        assertTrue(resolver.hashSpec(s) != base, "priceId not bound");

        s = spec;
        s.threshold += 1;
        assertTrue(resolver.hashSpec(s) != base, "threshold not bound");

        s = spec;
        s.thresholdExpo = -6;
        assertTrue(resolver.hashSpec(s) != base, "thresholdExpo not bound");

        s = spec;
        s.targetTime += 1;
        assertTrue(resolver.hashSpec(s) != base, "targetTime not bound");

        s = spec;
        s.windowSeconds += 1;
        assertTrue(resolver.hashSpec(s) != base, "windowSeconds not bound");

        s = spec;
        s.greaterThan = false;
        assertTrue(resolver.hashSpec(s) != base, "greaterThan not bound");
    }

    /// @notice The external entrypoint agrees with the typed helper used at market creation.
    function test_specHashEntrypointMatchesTheTypedHelper() public view {
        assertEq(resolver.specHash(abi.encode(spec)), resolver.hashSpec(spec));
    }

    // -----------------------------------------------------------------------
    // The caller cannot choose the TIMESTAMP
    // -----------------------------------------------------------------------

    /// @notice A market must not settle on a price that was already knowable while people
    ///         were still betting -- that is a payout to whoever checked, not a prediction.
    function test_rejectsATargetBeforeBettingClosed() public {
        PythResolver.Spec memory early = spec;
        early.targetTime = bettingClose - 1;

        Vault v = _newVault(resolver.hashSpec(early), address(resolver));
        pyth.setPrice(BTC, 64_000_00000000, 1_00000000, -8, early.targetTime);

        vm.warp(resolutionStart);
        vm.expectRevert(
            abi.encodeWithSelector(PythResolver.TargetBeforeBettingClose.selector, early.targetTime, bettingClose)
        );
        resolver.resolve{value: 1 wei}(v, abi.encode(early), new bytes[](1));
    }

    /// @notice The window handed to Pyth is exactly the committed one, not a widened version.
    function test_passesTheCommittedWindowToPythUnchanged() public {
        _resolve();
        assertEq(pyth.lastMinPublishTime(), targetTime, "min publish time was not the target");
        assertEq(pyth.lastMaxPublishTime(), targetTime + spec.windowSeconds, "window was widened");
    }

    /// @notice A price outside the window is refused by Pyth, not silently accepted. This is
    ///         the liveness edge that `voidMarket` exists to catch.
    function test_revertsWhenNoUpdateLandsInTheWindow() public {
        pyth.setPrice(BTC, 64_000_00000000, 1_00000000, -8, targetTime + 1 hours);
        vm.warp(resolutionStart);
        vm.expectRevert(bytes("PriceFeedNotFoundWithinRange"));
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
    }

    // -----------------------------------------------------------------------
    // The caller cannot choose the OUTCOME
    // -----------------------------------------------------------------------

    function test_resolvesYesWhenAbove() public {
        _resolve();
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.Yes));
    }

    function test_resolvesNoWhenBelow() public {
        pyth.setPrice(BTC, 62_000_00000000, 1_00000000, -8, targetTime + 1);
        _resolve();
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.No));
    }

    /// @notice Equality is NO under `>`, and NO under `<` too. Any other reading lets a pair
    ///         of complementary markets both pay out on the same price.
    function test_equalityResolvesNoUnderBothDirections() public {
        pyth.setPrice(BTC, 63_000_00000000, 1_00000000, -8, targetTime + 1);
        _resolve();
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.No), "equality paid out under >");

        PythResolver.Spec memory below = spec;
        below.greaterThan = false;
        Vault v = _newVault(resolver.hashSpec(below), address(resolver));

        resolver.resolve{value: 1 wei}(v, abi.encode(below), new bytes[](1));
        assertEq(uint8(v.outcome()), uint8(Vault.Outcome.No), "equality paid out under <");
    }

    function test_resolvesLessThanDirection() public {
        PythResolver.Spec memory below = spec;
        below.greaterThan = false;
        Vault v = _newVault(resolver.hashSpec(below), address(resolver));

        pyth.setPrice(BTC, 62_000_00000000, 1_00000000, -8, targetTime + 1);
        vm.warp(resolutionStart);
        resolver.resolve{value: 1 wei}(v, abi.encode(below), new bytes[](1));
        assertEq(uint8(v.outcome()), uint8(Vault.Outcome.Yes));
    }

    // -----------------------------------------------------------------------
    // Exponent normalisation -- where a wrong answer would be silent
    // -----------------------------------------------------------------------

    /// @notice Pyth's exponent is per-feed and can differ from the threshold's. Comparing the
    ///         raw integers would be off by orders of magnitude with no error anywhere.
    function test_normalisesWhenPriceExponentIsCoarser() public {
        // Price 64,000 at expo -2; threshold 63,000 at expo -8. Raw ints: 6,400,000 vs
        // 6,300,000,000,000 -- naive comparison says NO. Correct answer is YES.
        PythResolver.Spec memory s = spec;
        Vault v = _newVault(resolver.hashSpec(s), address(resolver));

        pyth.setPrice(BTC, 64_000_00, 100, -2, targetTime + 1);
        vm.warp(resolutionStart);
        resolver.resolve{value: 1 wei}(v, abi.encode(s), new bytes[](1));
        assertEq(uint8(v.outcome()), uint8(Vault.Outcome.Yes), "coarse price exponent mis-compared");
    }

    function test_normalisesWhenThresholdExponentIsCoarser() public {
        // Threshold 63,000 at expo -2, price 64,000 at expo -8.
        PythResolver.Spec memory s = spec;
        s.threshold = 63_000_00;
        s.thresholdExpo = -2;
        Vault v = _newVault(resolver.hashSpec(s), address(resolver));

        pyth.setPrice(BTC, 64_000_00000000, 1_00000000, -8, targetTime + 1);
        vm.warp(resolutionStart);
        resolver.resolve{value: 1 wei}(v, abi.encode(s), new bytes[](1));
        assertEq(uint8(v.outcome()), uint8(Vault.Outcome.Yes), "coarse threshold exponent mis-compared");
    }

    /// @notice Negative prices are representable and must compare correctly. Oil futures went
    ///         negative in 2020; the type allows it, so nothing may assume positivity.
    function test_handlesNegativePrices() public {
        PythResolver.Spec memory s = spec;
        s.threshold = -1_00000000; // -1
        Vault v = _newVault(resolver.hashSpec(s), address(resolver));

        pyth.setPrice(BTC, -2_00000000, 1, -8, targetTime + 1); // -2 is NOT above -1
        vm.warp(resolutionStart);
        resolver.resolve{value: 1 wei}(v, abi.encode(s), new bytes[](1));
        assertEq(uint8(v.outcome()), uint8(Vault.Outcome.No), "negative comparison inverted");
    }

    /// @notice A malformed spec is refused rather than overflowing the scaling.
    function test_rejectsAnAbsurdExponentGap() public {
        PythResolver.Spec memory s = spec;
        s.thresholdExpo = 90;
        Vault v = _newVault(resolver.hashSpec(s), address(resolver));

        pyth.setPrice(BTC, 1, 1, -8, targetTime + 1);
        vm.warp(resolutionStart);
        vm.expectRevert(abi.encodeWithSelector(PythResolver.ExponentOutOfRange.selector, int32(-8), int32(90)));
        resolver.resolve{value: 1 wei}(v, abi.encode(s), new bytes[](1));
    }

    // -----------------------------------------------------------------------
    // Fees
    // -----------------------------------------------------------------------

    function test_revertsWhenTheFeeIsShort() public {
        pyth.setFee(100);
        vm.warp(resolutionStart);
        vm.expectRevert(abi.encodeWithSelector(PythResolver.InsufficientFee.selector, 100, 99));
        resolver.resolve{value: 99}(vault, abi.encode(spec), new bytes[](1));
    }

    /// @notice Overpayment is refunded. The exact fee is only knowable at call time, so
    ///         callers necessarily over-send; keeping the difference would be a silent toll.
    function test_refundsTheExcessAndForwardsExactlyTheFee() public {
        pyth.setFee(100);
        vm.deal(STRANGER, 1 ether);

        uint256 before = STRANGER.balance;
        vm.warp(resolutionStart);
        vm.prank(STRANGER);
        resolver.resolve{value: 5_000}(vault, abi.encode(spec), new bytes[](1));

        assertEq(before - STRANGER.balance, 100, "caller was charged more than the fee");
        assertEq(pyth.lastValueReceived(), 100, "resolver forwarded the wrong amount");
        assertEq(address(resolver).balance, 0, "resolver kept a balance");
    }

    function test_exactPaymentNeedsNoRefund() public {
        pyth.setFee(100);
        vm.deal(STRANGER, 1 ether);
        uint256 before = STRANGER.balance;

        vm.warp(resolutionStart);
        vm.prank(STRANGER);
        resolver.resolve{value: 100}(vault, abi.encode(spec), new bytes[](1));
        assertEq(before - STRANGER.balance, 100);
    }

    // -----------------------------------------------------------------------
    // Wiring and sanity
    // -----------------------------------------------------------------------

    /// @notice Resolution is permissionless on purpose -- a market must not be hostage to one
    ///         address choosing never to act.
    function test_anyoneCanResolve() public {
        vm.deal(STRANGER, 1 ether);
        vm.warp(resolutionStart);
        vm.prank(STRANGER);
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.Yes));
    }

    /// @notice Fails early and clearly when pointed at a vault it does not resolve, rather
    ///         than burning the fee and surfacing a confusing revert from Vault.
    function test_rejectsAVaultItDoesNotResolve() public {
        Vault other = _newVault(resolver.hashSpec(spec), address(0xBEEF));
        vm.warp(resolutionStart);
        vm.expectRevert(abi.encodeWithSelector(PythResolver.NotThisResolver.selector, address(0xBEEF)));
        resolver.resolve{value: 1 wei}(other, abi.encode(spec), new bytes[](1));
    }

    /// @notice Pyth returns feeds in the requested order, but this contract decides who gets
    ///         paid, so the id is checked rather than trusted.
    function test_rejectsAFeedItDidNotAskFor() public {
        pyth.setOverrideReturnedId(ETH);
        vm.warp(resolutionStart);
        vm.expectRevert(abi.encodeWithSelector(PythResolver.WrongFeedReturned.selector, BTC, ETH));
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
    }

    function test_rejectsAnEmptyFeedArray() public {
        pyth.setReturnEmpty(true);
        vm.warp(resolutionStart);
        vm.expectRevert(PythResolver.NoFeedReturned.selector);
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
    }

    /// @notice Resolving twice is refused by the Vault, so the event cannot be replayed and
    ///         a second caller cannot overwrite the first one's answer.
    function test_cannotResolveTwice() public {
        _resolve();
        vm.expectRevert(Vault.AlreadyResolved.selector);
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
    }

    /// @notice Before resolution opens, the Vault refuses -- the resolver does not get to
    ///         settle a market early even with a valid price in hand.
    function test_cannotResolveBeforeResolutionOpens() public {
        vm.warp(resolutionStart - 1);
        vm.expectRevert(Vault.TooEarlyToResolve.selector);
        resolver.resolve{value: 1 wei}(vault, abi.encode(spec), new bytes[](1));
    }

    function test_constructorRejectsAZeroPyth() public {
        vm.expectRevert(abi.encodeWithSelector(PythResolver.NotThisResolver.selector, address(0)));
        new PythResolver(IPyth(address(0)));
    }

    function test_resolutionFeeReportsPythsFee() public {
        pyth.setFee(4_242);
        assertEq(resolver.resolutionFee(new bytes[](1)), 4_242);
    }
}
