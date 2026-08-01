// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The system's only emergency control, and the tests that it cannot be used as one.
///
/// @dev `Void` exists because an unanswerable market is otherwise unanswerable forever:
///      `resolve` refuses `Unresolved`, `redeemPrivate` requires resolution, and every stake
///      stays frozen. With an oracle resolver that is not hypothetical -- if no signed price
///      lands in the committed window, resolution reverts permanently by design.
///
///      The danger of adding an escape hatch is that it becomes a discretionary refund
///      switch. Most of what follows is about proving it is not one.
contract VoidTest is Test {
    MockERC20 internal usdc;
    Vault internal vault;

    address internal constant RESOLVER = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant STRANGER = address(0x57A);

    uint256 internal constant DENOM = 1e6;
    uint64 internal bettingClose;
    uint64 internal resolutionStart;

    function setUp() public {
        usdc = new MockERC20();
        bettingClose = uint64(block.timestamp + 1 days);
        resolutionStart = bettingClose + 2 hours;

        vault = new Vault(
            IERC20(address(usdc)), DENOM, RESOLVER, keccak256("will it void?"), bettingClose, resolutionStart
        );

        usdc.mint(ALICE, 1_000 * DENOM);
        vm.prank(ALICE);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _split(uint256 units) internal {
        vm.prank(ALICE);
        vault.split(units);
    }

    // -----------------------------------------------------------------------
    // It cannot be used as a discretionary switch
    // -----------------------------------------------------------------------

    /// @notice Nobody can void early, so a slow-but-working resolver is never pre-empted.
    function test_cannotVoidBeforeTheDeadline() public {
        vm.warp(resolutionStart + vault.VOID_DELAY() - 1);
        vm.expectRevert(abi.encodeWithSelector(Vault.TooEarlyToVoid.selector, resolutionStart + vault.VOID_DELAY()));
        vault.voidMarket();
    }

    /// @notice THE one that matters. Nobody can void an outcome they dislike after seeing it.
    function test_cannotVoidAnAlreadyResolvedMarket() public {
        vm.warp(resolutionStart);
        vm.prank(RESOLVER);
        vault.resolve(Vault.Outcome.Yes);

        // Well past the deadline -- the deadline is not what stops this, the outcome is.
        vm.warp(resolutionStart + vault.VOID_DELAY() + 365 days);
        vm.expectRevert(Vault.AlreadyResolved.selector);
        vault.voidMarket();
    }

    /// @notice The resolver cannot declare a void directly, which would be exactly the
    ///         discretionary refund switch this design refuses to hand anyone.
    function test_resolverCannotResolveToVoid() public {
        vm.warp(resolutionStart);
        vm.prank(RESOLVER);
        vm.expectRevert(Vault.InvalidOutcome.selector);
        vault.resolve(Vault.Outcome.Void);
    }

    /// @notice And a voided market cannot then be resolved to a winner.
    function test_cannotResolveAfterVoid() public {
        vm.warp(resolutionStart + vault.VOID_DELAY());
        vault.voidMarket();

        vm.prank(RESOLVER);
        vm.expectRevert(Vault.AlreadyResolved.selector);
        vault.resolve(Vault.Outcome.Yes);
    }

    /// @notice Voiding twice is refused, so the event cannot be replayed.
    function test_cannotVoidTwice() public {
        vm.warp(resolutionStart + vault.VOID_DELAY());
        vault.voidMarket();
        vm.expectRevert(Vault.AlreadyResolved.selector);
        vault.voidMarket();
    }

    // -----------------------------------------------------------------------
    // It works, and anyone can trigger it
    // -----------------------------------------------------------------------

    /// @notice Permissionless on purpose: funds must not be hostage to one address choosing
    ///         never to act. A total stranger can free them.
    function test_anyoneCanVoidAfterTheDeadline() public {
        vm.warp(resolutionStart + vault.VOID_DELAY());
        vm.prank(STRANGER);
        vault.voidMarket();
        assertEq(uint8(vault.outcome()), uint8(Vault.Outcome.Void), "market did not void");
    }

    // -----------------------------------------------------------------------
    // Refunds, and the solvency question
    // -----------------------------------------------------------------------

    /// @notice `redeem` must refuse a void market -- there is no winning side to redeem
    ///         against, and the branch would otherwise silently treat NO as the winner
    ///         because it is the `else` of a two-way check.
    function test_redeemIsRefusedOnAVoidMarket() public {
        _split(100);
        vm.warp(resolutionStart + vault.VOID_DELAY());
        vault.voidMarket();

        vm.prank(ALICE);
        vm.expectRevert(Vault.MarketVoided.selector);
        vault.redeem(100);
    }

    /// @notice Refunds come out through `merge`, which normally closes at resolution.
    function test_mergeReopensOnVoidAndRefundsExactly() public {
        _split(100);
        uint256 before = usdc.balanceOf(ALICE);

        vm.warp(resolutionStart + vault.VOID_DELAY());
        vault.voidMarket();

        vm.prank(ALICE);
        vault.merge(100);

        assertEq(usdc.balanceOf(ALICE) - before, 100 * DENOM, "refund was not 1:1");
        assertEq(vault.yesBalance(ALICE), 0, "YES not burned");
        assertEq(vault.noBalance(ALICE), 0, "NO not burned");
    }

    /// @notice SOLVENCY. Refunding both sides 1:1 through `redeem` would need twice the
    ///         collateral that exists; burning a (YES, NO) pair per unit needs exactly what
    ///         is there. This asserts the vault can be drained to zero and no further.
    function test_voidRefundsAreExactlySolvent() public {
        _split(100);
        assertEq(usdc.balanceOf(address(vault)), 100 * DENOM, "collateral not held");

        vm.warp(resolutionStart + vault.VOID_DELAY());
        vault.voidMarket();

        vm.prank(ALICE);
        vault.merge(100);

        assertEq(usdc.balanceOf(address(vault)), 0, "vault should be empty");

        // And not a unit more.
        vm.prank(ALICE);
        vm.expectRevert(Vault.InsufficientPosition.selector);
        vault.merge(1);
    }

    /// @notice A market resolved normally is unaffected -- `merge` still closes at
    ///         resolution, so the void path cannot be used to escape a lost bet.
    function test_mergeStillClosesOnANormalResolution() public {
        _split(100);
        vm.warp(resolutionStart);
        vm.prank(RESOLVER);
        vault.resolve(Vault.Outcome.No);

        vm.prank(ALICE);
        vm.expectRevert(Vault.AlreadyResolved.selector);
        vault.merge(100);
    }

    /// @notice The losing side of a normally-resolved market gets nothing. Void is the only
    ///         path that pays a loser, and only because nobody won.
    function test_loserGetsNothingWhenTheMarketActuallyResolves() public {
        _split(100);
        vm.warp(resolutionStart);
        vm.prank(RESOLVER);
        vault.resolve(Vault.Outcome.Yes);

        // Alice holds both sides here, so redeem(100) succeeds on YES; the NO units are
        // simply worthless and there is no second redemption.
        vm.prank(ALICE);
        vault.redeem(100);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault should be empty");

        vm.prank(ALICE);
        vm.expectRevert(Vault.InsufficientPosition.selector);
        vault.redeem(1);
    }
}
