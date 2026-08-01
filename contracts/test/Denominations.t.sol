// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Denominations} from "../src/Denominations.sol";

/// @notice Every case is either "this amount must be allowed" or "this amount must be
///         refused because it would tag its owner".
contract DenominationsTest is Test {
    function test_acceptsEveryRungOnTheLadder() public pure {
        uint256 rung = 1;
        for (uint256 i = 0; i <= Denominations.MAX_EXPONENT; i++) {
            assertTrue(Denominations.isValid(rung), "a rung on the ladder was refused");
            rung *= 10;
        }
    }

    function test_rejectsZero() public pure {
        // A zero deposit mints a worthless note and consumes a tree leaf.
        assertFalse(Denominations.isValid(0));
    }

    /// @notice The amounts the original fixtures used, which is how this gap was found.
    function test_rejectsTheAmountsThatWouldTagTheirOwner() public pure {
        assertFalse(Denominations.isValid(37), "37 must be refused -- a bucket of one");
        assertFalse(Denominations.isValid(60), "60 must be refused -- a bucket of one");
        assertFalse(Denominations.isValid(137), "137 must be refused");
    }

    function test_rejectsNeighboursOfEveryRung() public pure {
        uint256 rung = 1;
        for (uint256 i = 0; i <= Denominations.MAX_EXPONENT; i++) {
            if (rung > 1) assertFalse(Denominations.isValid(rung - 1), "rung-1 accepted");
            assertFalse(Denominations.isValid(rung + 1), "rung+1 accepted");
            rung *= 10;
        }
    }

    function test_rejectsMultiplesThatAreNotThemselvesRungs() public pure {
        // 200 is a round number and still a distinct bucket from 100. Roundness is not the
        // property; being ON the ladder is.
        assertFalse(Denominations.isValid(200));
        assertFalse(Denominations.isValid(500));
        assertFalse(Denominations.isValid(2500));
    }

    function test_rejectsAboveTheTopRung() public pure {
        uint256 top = 10 ** Denominations.MAX_EXPONENT;
        assertTrue(Denominations.isValid(top));
        assertFalse(Denominations.isValid(top * 10), "above the ladder was accepted");
        assertFalse(Denominations.isValid(type(uint256).max), "max uint accepted");
    }

    /// @notice The early-exit must not skip a valid rung.
    ///
    /// @dev `isValid` returns false as soon as `units < rung`, relying on the ladder being
    ///      ascending. If that reasoning were wrong it would refuse legitimate deposits, which
    ///      fails closed but bricks the product.
    function testFuzz_earlyExitAgreesWithAnExhaustiveScan(uint256 units) public pure {
        vm.assume(units <= 10 ** (Denominations.MAX_EXPONENT + 1));

        bool exhaustive = false;
        uint256 rung = 1;
        for (uint256 i = 0; i <= Denominations.MAX_EXPONENT; i++) {
            if (units == rung) {
                exhaustive = true;
                break;
            }
            rung *= 10;
        }

        assertEq(Denominations.isValid(units), exhaustive, "early exit disagrees with a full scan");
    }

    /// @notice No overflow at the top of the ladder.
    /// @dev `rung *= 10` runs once more after the last comparison; 10^10 is far below
    ///      2^256, so it cannot wrap, but a raised MAX_EXPONENT could. This pins it.
    function test_ladderCannotOverflow() public pure {
        assertLt(Denominations.MAX_EXPONENT, 77, "10^MAX_EXPONENT must fit in uint256");
    }
}
