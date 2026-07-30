// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

/// @notice Does the local EVM implement Monad's repriced STORAGE costs?
///
/// We already proved `--network monad` applies Monad's BN254 precompile pricing
/// (PrecompileRepricing.t.sol). Storage is a separate question and it decides how
/// much of Phase 1 can be measured locally.
///
/// It matters more here than the precompiles did. A commitment-tree insertion
/// touches one storage slot per tree level, and Monad charges **8,100 for a cold
/// SLOAD versus Ethereum's 2,100**. At depth 20 that difference alone is
/// 20 x 6,000 = 120,000 gas per insertion -- the gap between fitting the uniform
/// action envelope and blowing it.
///
/// If local storage pricing is Ethereum's, every tree design decision has to be
/// made against tools/monad_gas.py instead.
contract StorageRepricingTest is Test {
    /// Documented Monad values (nisi-master-reference.md 1.1).
    uint256 constant MONAD_COLD_SLOAD = 8_100;
    uint256 constant MONAD_COLD_ACCOUNT = 10_100;
    uint256 constant ETHEREUM_COLD_SLOAD = 2_100;
    uint256 constant WARM_ACCESS = 100;

    /// Slots are written in setUp so reads hit *non-zero* values -- the realistic
    /// case for a live tree, and the one the reference's ~68,000/bet figure assumes.
    uint256 slot0 = 1;
    uint256 slot1 = 2;
    uint256 slot2 = 3;

    Reader reader;

    function setUp() public {
        reader = new Reader();
    }

    function _coldSload() private view returns (uint256) {
        uint256 before = gasleft();
        uint256 v = slot0;
        uint256 used = before - gasleft();
        v; // silence unused
        return used;
    }

    function test_report_coldVsWarmSload() public view {
        uint256 cold = _coldSload();

        // Second read of the same slot is warm.
        uint256 before = gasleft();
        uint256 v = slot0;
        uint256 warm = before - gasleft();
        v;

        console.log("cold SLOAD local  :", cold);
        console.log("warm SLOAD local  :", warm);
        console.log("cold Monad        :", MONAD_COLD_SLOAD);
        console.log("cold Ethereum     :", ETHEREUM_COLD_SLOAD);
        console.log("cold - warm       :", cold - warm);
    }

    /// @notice The assertion that decides whether local storage numbers are usable.
    /// @dev Compares the cold/warm *delta*, which isolates the surcharge from the
    ///      surrounding opcode noise. Monad's surcharge is ~8,000; Ethereum's is
    ///      ~2,000. The gap is far too wide to be confused by overhead.
    function test_localEvmUsesMonadColdSloadPricing() public view {
        uint256 cold = _coldSload();

        uint256 before = gasleft();
        uint256 v = slot0;
        uint256 warm = before - gasleft();
        v;

        uint256 surcharge = cold - warm;
        console.log("cold SLOAD surcharge:", surcharge);

        assertGt(
            surcharge,
            ETHEREUM_COLD_SLOAD * 2,
            "local EVM appears to use ETHEREUM cold SLOAD pricing -- tree gas "
            "measured locally will understate Monad by ~6,000 per level; " "use tools/monad_gas.py instead"
        );
    }

    function test_report_coldAccountAccess() public view {
        uint256 before = gasleft();
        reader.ping();
        uint256 cold = before - gasleft();

        uint256 before2 = gasleft();
        reader.ping();
        uint256 warm = before2 - gasleft();

        console.log("cold call local   :", cold);
        console.log("warm call local   :", warm);
        console.log("delta             :", cold - warm);
        console.log("Monad cold account:", MONAD_COLD_ACCOUNT);
    }
}

contract Reader {
    function ping() external pure returns (uint256) {
        return 1;
    }
}
