// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

/// @notice Does Monad reprice MULMOD/ADDMOD?
///
/// @dev A ladder addition measured 1,314 gas for 9 `mulmod` and 7 `addmod`. At the
///      documented 8 gas apiece that is ~128 gas, so something is charging ~10x more than
///      expected -- and it is not call overhead, because an inline version measured MORE
///      than the function-call version.
///
///      `nisi-master-reference.md` lists Monad's repricings: cold SLOAD 8,100, cold account
///      10,100, memory expansion, and the BN254 precompiles. Arithmetic is not mentioned.
///      If it is repriced anyway, that changes the cost of every hand-written curve
///      operation in this repo -- the accumulator, Chaum-Pedersen, all of it -- so it is
///      worth knowing rather than assuming.
contract ArithRepricingTest is Test {
    uint256 constant Q = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant N = 1000;

    function _mulmods(uint256 seed) internal pure returns (uint256 x) {
        x = seed;
        for (uint256 i = 0; i < N; i++) {
            x = mulmod(x, x, Q);
        }
    }

    function _addmods(uint256 seed) internal pure returns (uint256 x) {
        x = seed;
        for (uint256 i = 0; i < N; i++) {
            x = addmod(x, x, Q);
        }
    }

    function _emptyLoop(uint256 seed) internal pure returns (uint256 x) {
        x = seed;
        for (uint256 i = 0; i < N; i++) {
            x = x ^ 1;
        }
    }

    function test_report_arithmeticCost() public view {
        uint256 g = gasleft();
        _emptyLoop(3);
        uint256 empty = g - gasleft();

        g = gasleft();
        _mulmods(3);
        uint256 mm = g - gasleft();

        g = gasleft();
        _addmods(3);
        uint256 am = g - gasleft();

        console.log("=== per-operation cost over", N, "iterations ===");
        console.log("empty loop, total       :", empty);
        console.log("mulmod loop, total      :", mm);
        console.log("addmod loop, total      :", am);
        console.log("");
        console.log("mulmod, net of loop     :", (mm - empty) / N);
        console.log("addmod, net of loop     :", (am - empty) / N);
        console.log("documented EVM cost     : 8");
    }
}
