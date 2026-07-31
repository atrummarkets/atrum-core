// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

/// @notice Does `forge test --network monad` actually apply Monad's repriced gas
///         schedule, or does it silently use Ethereum costs?
///
/// This decides whether any local gas assertion can be trusted. Monad prices
/// `ecMul` at 30,000 (Ethereum 6,000) and `ecPairing` at 225,000 + 170,000k
/// (Ethereum 45,000 + 34,000k) -- both verified by us directly against live nodes
/// in MEASUREMENTS.md §3. If the local EVM reports Ethereum numbers, then local
/// gas figures understate reality by ~5x on exactly the operations that dominate
/// proof verification, and every local budget assertion is worthless.
contract PrecompileRepricingTest is Test {
    /// Measured against live Monad mainnet and testnet by tools/monad_gas.py.
    uint256 constant MONAD_ECMUL = 30_000;
    uint256 constant MONAD_ECADD = 300;
    uint256 constant MONAD_PAIRING_K1 = 225_000 + 170_000;

    uint256 constant ETHEREUM_ECMUL = 6_000;

    function _callPrecompile(address target, bytes memory input) private view returns (uint256 gasUsed, bool ok) {
        uint256 before = gasleft();
        (ok,) = target.staticcall(input);
        gasUsed = before - gasleft();
    }

    function test_report_ecMulGas() public view {
        // Zero input decodes as the point at infinity: valid, so the call succeeds
        // and we measure real arithmetic cost rather than a revert.
        (uint256 gasUsed, bool ok) = _callPrecompile(address(0x07), new bytes(96));
        assertTrue(ok, "ecMul reverted");

        console.log("ecMul  local gas :", gasUsed);
        console.log("ecMul  Monad     :", MONAD_ECMUL);
        console.log("ecMul  Ethereum  :", ETHEREUM_ECMUL);
    }

    function test_report_ecAddGas() public view {
        (uint256 gasUsed, bool ok) = _callPrecompile(address(0x06), new bytes(128));
        assertTrue(ok, "ecAdd reverted");
        console.log("ecAdd  local gas :", gasUsed);
        console.log("ecAdd  Monad     :", MONAD_ECADD);
    }

    function test_report_pairingGas() public view {
        (uint256 gasUsed, bool ok) = _callPrecompile(address(0x08), new bytes(192));
        assertTrue(ok, "ecPairing reverted");
        console.log("pairing k=1 local:", gasUsed);
        console.log("pairing k=1 Monad:", MONAD_PAIRING_K1);
    }

    /// @notice The assertion that decides whether local gas is usable at all.
    /// @dev Deliberately allows slack for opcode/memory overhead around the call,
    ///      but the 5x gap between Monad and Ethereum pricing is far larger than
    ///      any plausible overhead, so this cannot pass by accident.
    function test_localEvmUsesMonadPricing() public view {
        (uint256 gasUsed, bool ok) = _callPrecompile(address(0x07), new bytes(96));
        assertTrue(ok, "ecMul reverted");

        assertGe(
            gasUsed,
            MONAD_ECMUL,
            "local EVM is NOT using Monad ecMul pricing -- local gas numbers "
            "understate reality ~5x; trust only tools/monad_gas.py"
        );
    }
}
