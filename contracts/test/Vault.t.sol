// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract VaultTest is Test {
    MockERC20 usdc;
    Vault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address resolver = makeAddr("resolver");

    /// 1 USDC at 6 decimals -- the fixed split unit.
    uint256 constant DENOM = 1e6;

    uint64 bettingClose;
    uint64 resolutionStart;

    bytes32 constant SPEC_HASH = keccak256("Will Team A win? -- resolves via Pyth feed X");

    function setUp() public {
        // Start from a sane wall-clock so `bettingClose` arithmetic cannot underflow.
        vm.warp(1_800_000_000);

        usdc = new MockERC20();
        bettingClose = uint64(block.timestamp + 7 days);
        resolutionStart = bettingClose + 2 hours;

        vault = new Vault(
            IERC20(address(usdc)),
            DENOM,
            resolver,
            SPEC_HASH,
            bettingClose,
            resolutionStart
        );

        _fund(alice, 1_000 * DENOM);
        _fund(bob, 1_000 * DENOM);
    }

    function _fund(address who, uint256 amount) private {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev The only invariant that really matters: the vault can always pay
    ///      everyone it owes. Pre-resolution every complete set is redeemable for one
    ///      denomination, so held collateral must cover the full set supply.
    ///      Post-resolution only the winning side has a claim.
    function _assertSolvent() private view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.collateralHeld(),
            "accounting drifted from the actual token balance"
        );

        uint256 owed = vault.outcome() == Vault.Outcome.Unresolved
            ? vault.yesSupply() * DENOM
            : vault.winningSupply() * DENOM;

        assertGe(vault.collateralHeld(), owed, "vault is insolvent");
    }

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    function test_constructor_recordsImmutableMarketDefinition() public view {
        assertEq(address(vault.collateral()), address(usdc));
        assertEq(vault.denomination(), DENOM);
        assertEq(vault.resolver(), resolver);
        assertEq(vault.resolutionSpecHash(), SPEC_HASH);
        assertEq(vault.bettingCloseTime(), bettingClose);
        assertEq(vault.resolutionStartTime(), resolutionStart);
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.Unresolved));
    }

    function test_constructor_rejectsZeroDenomination() public {
        vm.expectRevert(Vault.InvalidDenomination.selector);
        new Vault(IERC20(address(usdc)), 0, resolver, SPEC_HASH, bettingClose, resolutionStart);
    }

    function test_constructor_rejectsZeroResolver() public {
        vm.expectRevert(Vault.InvalidResolver.selector);
        new Vault(IERC20(address(usdc)), DENOM, address(0), SPEC_HASH, bettingClose, resolutionStart);
    }

    /// The gap between betting close and resolution start is mandatory: without it,
    /// last-second bets front-run already-determined information.
    function test_constructor_rejectsInsufficientResolutionGap() public {
        // Read the constant *before* arming expectRevert: it applies to the next
        // call, and an external view read would otherwise consume it.
        uint64 gap = vault.MIN_RESOLUTION_GAP();

        vm.expectRevert(Vault.InvalidSchedule.selector);
        new Vault(
            IERC20(address(usdc)),
            DENOM,
            resolver,
            SPEC_HASH,
            bettingClose,
            bettingClose + gap - 1
        );
    }

    function test_constructor_acceptsExactlyMinimumGap() public {
        uint64 gap = vault.MIN_RESOLUTION_GAP();

        Vault tight = new Vault(
            IERC20(address(usdc)), DENOM, resolver, SPEC_HASH, bettingClose, bettingClose + gap
        );
        assertEq(tight.resolutionStartTime(), bettingClose + gap);
    }

    // -----------------------------------------------------------------------
    // split
    // -----------------------------------------------------------------------

    function test_split_mintsCompleteSetAndPullsCollateral() public {
        vm.prank(alice);
        vault.split(10);

        assertEq(vault.yesBalance(alice), 10);
        assertEq(vault.noBalance(alice), 10);
        assertEq(vault.yesSupply(), 10);
        assertEq(vault.noSupply(), 10);
        assertEq(vault.collateralHeld(), 10 * DENOM);
        assertEq(usdc.balanceOf(alice), 990 * DENOM);
        _assertSolvent();
    }

    function test_split_accumulatesAcrossCallsAndAccounts() public {
        vm.prank(alice);
        vault.split(3);
        vm.prank(alice);
        vault.split(4);
        vm.prank(bob);
        vault.split(5);

        assertEq(vault.yesBalance(alice), 7);
        assertEq(vault.yesBalance(bob), 5);
        assertEq(vault.yesSupply(), 12);
        assertEq(vault.collateralHeld(), 12 * DENOM);
        _assertSolvent();
    }

    function test_split_revertsOnZeroUnits() public {
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroUnits.selector);
        vault.split(0);
    }

    function test_split_revertsAtBettingClose() public {
        vm.warp(bettingClose);
        vm.prank(alice);
        vm.expectRevert(Vault.BettingClosed.selector);
        vault.split(1);
    }

    function test_split_succeedsOneSecondBeforeClose() public {
        vm.warp(bettingClose - 1);
        vm.prank(alice);
        vault.split(1);
        assertEq(vault.yesSupply(), 1);
    }

    function test_split_revertsWithoutApproval() public {
        address carol = makeAddr("carol");
        usdc.mint(carol, 10 * DENOM);
        vm.prank(carol);
        vm.expectRevert(bytes("allowance"));
        vault.split(1);
    }

    // -----------------------------------------------------------------------
    // merge
    // -----------------------------------------------------------------------

    function test_merge_burnsCompleteSetAndReturnsCollateral() public {
        vm.prank(alice);
        vault.split(10);
        vm.prank(alice);
        vault.merge(4);

        assertEq(vault.yesBalance(alice), 6);
        assertEq(vault.noBalance(alice), 6);
        assertEq(vault.yesSupply(), 6);
        assertEq(vault.collateralHeld(), 6 * DENOM);
        assertEq(usdc.balanceOf(alice), 994 * DENOM);
        _assertSolvent();
    }

    function test_merge_revertsWhenMergingMoreThanHeld() public {
        vm.prank(alice);
        vault.split(5);

        vm.prank(alice);
        vm.expectRevert(Vault.InsufficientPosition.selector);
        vault.merge(6);
    }

    function test_merge_revertsOnZeroUnits() public {
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroUnits.selector);
        vault.merge(0);
    }

    /// @dev In Phase 0 a holder's two legs can never diverge: `split` and `merge`
    ///      move both equally, and `redeem` (which burns only the winner) is reachable
    ///      only after resolution, when `merge` is already blocked. So over-merging is
    ///      the only way to reach `InsufficientPosition` here.
    ///
    ///      This stops being true the moment positions become transferable, which is
    ///      exactly what Phase 1 introduces. When that lands, the incomplete-set case
    ///      needs its own test.
    function test_merge_legsCannotDivergeInPhase0() public {
        vm.prank(alice);
        vault.split(9);
        vm.prank(alice);
        vault.merge(4);

        assertEq(vault.yesBalance(alice), vault.noBalance(alice));

        _resolveYes();
        vm.prank(alice);
        vault.redeem(5);

        // Post-resolution the legs DO diverge, which is why merge is closed by then.
        assertEq(vault.yesBalance(alice), 0);
        assertEq(vault.noBalance(alice), 5);
    }

    function test_merge_revertsAfterResolution() public {
        vm.prank(alice);
        vault.split(5);
        _resolveYes();

        vm.prank(alice);
        vm.expectRevert(Vault.AlreadyResolved.selector);
        vault.merge(1);
    }

    /// Merging is still legal after betting closes but before resolution -- it is an
    /// exit, not a new position, so it must not be gated on the betting window.
    function test_merge_allowedBetweenCloseAndResolution() public {
        vm.prank(alice);
        vault.split(5);

        vm.warp(bettingClose + 1);
        vm.prank(alice);
        vault.merge(5);

        assertEq(vault.collateralHeld(), 0);
        assertEq(usdc.balanceOf(alice), 1_000 * DENOM);
    }

    // -----------------------------------------------------------------------
    // resolve
    // -----------------------------------------------------------------------

    function _resolveYes() private {
        vm.warp(resolutionStart);
        vm.prank(resolver);
        vault.resolve(Vault.Outcome.Yes);
    }

    function test_resolve_setsOutcome() public {
        _resolveYes();
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.Yes));
    }

    function test_resolve_revertsForNonResolver() public {
        vm.warp(resolutionStart);
        vm.prank(alice);
        vm.expectRevert(Vault.NotResolver.selector);
        vault.resolve(Vault.Outcome.Yes);
    }

    function test_resolve_revertsBeforeResolutionStart() public {
        vm.warp(resolutionStart - 1);
        vm.prank(resolver);
        vm.expectRevert(Vault.TooEarlyToResolve.selector);
        vault.resolve(Vault.Outcome.Yes);
    }

    function test_resolve_revertsOnUnresolvedOutcome() public {
        vm.warp(resolutionStart);
        vm.prank(resolver);
        vm.expectRevert(Vault.InvalidOutcome.selector);
        vault.resolve(Vault.Outcome.Unresolved);
    }

    function test_resolve_isOneShot() public {
        _resolveYes();
        vm.prank(resolver);
        vm.expectRevert(Vault.AlreadyResolved.selector);
        vault.resolve(Vault.Outcome.No);
    }

    // -----------------------------------------------------------------------
    // redeem
    // -----------------------------------------------------------------------

    function test_redeem_paysWinningSide() public {
        vm.prank(alice);
        vault.split(10);
        _resolveYes();

        vm.prank(alice);
        vault.redeem(10);

        assertEq(vault.yesBalance(alice), 0);
        assertEq(usdc.balanceOf(alice), 1_000 * DENOM);
        assertEq(vault.collateralHeld(), 0);
        // The losing leg is deliberately left outstanding -- it is simply worthless.
        assertEq(vault.noBalance(alice), 10);
        assertEq(vault.noSupply(), 10);
    }

    function test_redeem_revertsForLosingSide() public {
        vm.prank(alice);
        vault.split(10);

        vm.warp(resolutionStart);
        vm.prank(resolver);
        vault.resolve(Vault.Outcome.No);

        // Alice holds 10 NO, which won -- so redeeming 10 works, but her YES is dead
        // weight and cannot be redeemed even though the balance is non-zero.
        vm.prank(alice);
        vault.redeem(10);
        assertEq(vault.noBalance(alice), 0);
        assertEq(vault.yesBalance(alice), 10);

        vm.prank(alice);
        vm.expectRevert(Vault.InsufficientPosition.selector);
        vault.redeem(1);
    }

    function test_redeem_revertsBeforeResolution() public {
        vm.prank(alice);
        vault.split(1);
        vm.prank(alice);
        vm.expectRevert(Vault.NotResolved.selector);
        vault.redeem(1);
    }

    function test_redeem_revertsOnZeroUnits() public {
        _resolveYes();
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroUnits.selector);
        vault.redeem(0);
    }

    /// Two holders, one winner each way: the vault must pay the winners in full and
    /// still be exactly empty afterwards.
    function test_redeem_multipleHoldersFullyDrainsVault() public {
        vm.prank(alice);
        vault.split(10);
        vm.prank(bob);
        vault.split(6);
        _assertSolvent();

        _resolveYes();
        _assertSolvent();

        vm.prank(alice);
        vault.redeem(10);
        _assertSolvent();

        vm.prank(bob);
        vault.redeem(6);

        assertEq(vault.collateralHeld(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(alice), 1_000 * DENOM);
        assertEq(usdc.balanceOf(bob), 1_000 * DENOM);
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    function testFuzz_splitMergeRoundTripIsLossless(uint96 units) public {
        units = uint96(bound(units, 1, 1_000));

        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.split(units);
        vm.prank(alice);
        vault.merge(units);

        assertEq(usdc.balanceOf(alice), before);
        assertEq(vault.collateralHeld(), 0);
        assertEq(vault.yesSupply(), 0);
        assertEq(vault.noSupply(), 0);
    }

    function testFuzz_vaultStaysSolventAcrossSplitAndRedeem(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, 500));
        b = uint96(bound(b, 1, 500));

        vm.prank(alice);
        vault.split(a);
        vm.prank(bob);
        vault.split(b);
        _assertSolvent();

        _resolveYes();
        _assertSolvent();

        vm.prank(alice);
        vault.redeem(a);
        _assertSolvent();

        vm.prank(bob);
        vault.redeem(b);
        _assertSolvent();

        assertEq(vault.collateralHeld(), 0);
    }

    /// Splitting can never leave the two legs unequal -- that equality is what makes
    /// a complete set worth exactly one denomination regardless of outcome.
    function testFuzz_completeSetSupplyStaysBalanced(uint96 a, uint96 b, uint96 m) public {
        a = uint96(bound(a, 1, 500));
        b = uint96(bound(b, 1, 500));
        m = uint96(bound(m, 0, a));

        vm.prank(alice);
        vault.split(a);
        vm.prank(bob);
        vault.split(b);

        if (m > 0) {
            vm.prank(alice);
            vault.merge(m);
        }

        assertEq(vault.yesSupply(), vault.noSupply());
        assertEq(vault.collateralHeld(), vault.yesSupply() * DENOM);
        _assertSolvent();
    }
}
