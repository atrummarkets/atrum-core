// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

/// @notice Does MIP-8 page-sharing neutralise Monad's cold SLOAD surcharge for
///         contiguous storage?
///
/// @dev This started as a wrong hypothesis. Comparing the two accumulator layouts, we
///      expected Monad's 8,100 cold SLOAD (4x Ethereum) to punish the 8-slot extended
///      layout far harder than the 4-slot affine one. Measured, the extended layout cost
///      essentially the SAME on both chains -- 89,799 on Monad against 89,894 at Ethereum
///      pricing -- when eight cold SLOADs should have cost ~48,000 more.
///
///      The reference documents why: MIP-8 states 128 contiguous slots share one 4 KB
///      page, so a struct pays ONE cold access rather than one per slot. If that holds,
///      the "root-only on-chain state" pressure is materially weaker than the raw 8,100
///      figure implies -- provided the slots are contiguous.
///
///      That is a design-shaping claim, so it is measured rather than inferred:
///      8 contiguous slots against 8 slots deliberately scattered across distant pages.
contract StorageContiguityTest is Test {
    ContiguousStore contiguous;
    ScatteredStore scattered;

    function setUp() public {
        contiguous = new ContiguousStore();
        scattered = new ScatteredStore();
        contiguous.fill();
        scattered.fill();
    }

    function test_report_contiguousVsScatteredColdReads() public {
        // Fresh call frames, so both start cold.
        uint256 g = gasleft();
        contiguous.readAll();
        uint256 contiguousGas = g - gasleft();

        g = gasleft();
        scattered.readAll();
        uint256 scatteredGas = g - gasleft();

        console.log("=== 8 cold slot reads ===");
        console.log("contiguous (one struct) :", contiguousGas);
        console.log("scattered  (8 pages)    :", scatteredGas);
        console.log("difference              :", scatteredGas > contiguousGas ? scatteredGas - contiguousGas : 0);
        console.log("");
        console.log("If contiguous is ~7 cold SLOADs cheaper, MIP-8 page-sharing is real");
        console.log("and struct layout matters far more than slot count.");
    }

    /// @notice Contiguous storage must not be more expensive than scattered.
    /// @dev Deliberately weak: it asserts the direction, not a magnitude, because the
    ///      magnitude is what the report above is for. A failure here would mean
    ///      contiguity actively hurts, which would invalidate the accumulator's layout
    ///      comment and MIP-8 both.
    function test_contiguousIsNotWorseThanScattered() public {
        uint256 g = gasleft();
        contiguous.readAll();
        uint256 contiguousGas = g - gasleft();

        g = gasleft();
        scattered.readAll();
        uint256 scatteredGas = g - gasleft();

        assertLe(
            contiguousGas,
            scatteredGas,
            "contiguous storage cost MORE than scattered -- MIP-8 page-sharing assumption is wrong"
        );
    }
}

/// @dev Eight slots in one struct, guaranteed contiguous.
contract ContiguousStore {
    struct Eight {
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 d;
        uint256 e;
        uint256 f;
        uint256 g;
        uint256 h;
    }

    Eight internal s;

    function fill() external {
        s = Eight(1, 2, 3, 4, 5, 6, 7, 8);
    }

    function readAll() external view returns (uint256 total) {
        Eight storage p = s;
        total = p.a + p.b + p.c + p.d + p.e + p.f + p.g + p.h;
    }
}

/// @dev Eight slots at hashed, widely separated addresses -- one mapping entry each, so
///      no two share a 4 KB page.
contract ScatteredStore {
    mapping(uint256 => uint256) internal m;

    function fill() external {
        for (uint256 i = 0; i < 8; i++) {
            m[uint256(keccak256(abi.encode("scatter", i)))] = i + 1;
        }
    }

    function readAll() external view returns (uint256 total) {
        for (uint256 i = 0; i < 8; i++) {
            total += m[uint256(keccak256(abi.encode("scatter", i)))];
        }
    }
}
