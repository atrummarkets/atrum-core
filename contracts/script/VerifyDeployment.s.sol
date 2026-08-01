// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ShieldedPool} from "../src/ShieldedPool.sol";
import {EncryptedParimutuelPool} from "../src/EncryptedParimutuelPool.sol";
import {DeploymentInvariants} from "../src/DeploymentInvariants.sol";

/// @title VerifyDeployment
/// @notice Point this at a LIVE deployment and it reverts unless every invariant holds.
///
/// @dev `Deploy.s.sol` already runs these checks on itself, so a broken deployment cannot be
///      broadcast. This exists for the cases that check cannot cover:
///
///        - a deployment made before the self-check existed. The first testnet deploy was a
///          one-way vault and nobody knew for hours;
///        - a deployment someone else made, or one whose provenance you no longer trust;
///        - re-checking after any admin action, since `registerEncryptedMarket` and
///          `bindEncryptedTotals` can still be called after deployment;
///        - CI against a long-lived testnet address, so drift is caught by a schedule rather
///          than by a user losing money.
///
///      It derives nearly everything from the pool, so the only inputs are the pool address
///      and the market ids. Passing a full component list would let a caller "verify" a
///      deployment by describing a different one.
///
///      Usage:
///        POOL=0x.. forge script script/VerifyDeployment.s.sol --rpc-url monad_testnet
contract VerifyDeployment is Script {
    function run() external view {
        address pool = vm.envAddress("POOL");
        uint32 encryptedMarketId = uint32(vm.envOr("ENCRYPTED_MARKET_ID", uint256(8)));
        uint32 oracleMarketId = uint32(vm.envOr("ORACLE_MARKET_ID", uint256(10)));

        ShieldedPool p = ShieldedPool(pool);
        address enc = address(p.encryptedTotals());
        require(enc != address(0), "exit path unbound: encryptedTotals is address(0)");

        // The committee key comes from the ARTIFACT the proofs were generated with, never
        // from the chain -- comparing the chain against itself would always pass.
        string memory json = vm.readFile("../circuits/build/committee-key.json");
        uint256 keyX = vm.parseJsonUint(json, ".pubKey[0]");
        uint256 keyY = vm.parseJsonUint(json, ".pubKey[1]");

        DeploymentInvariants.check(
            DeploymentInvariants.Expected({
                pool: pool,
                tree: address(p.tree()),
                accumulator: address(p.accumulator()),
                encryptedParimutuel: enc,
                parimutuel: address(p.parimutuel()),
                nullifiers: address(p.nullifiers()),
                sequencer: pool,
                encryptedMarketId: encryptedMarketId,
                oracleMarketId: oracleMarketId,
                committeeKeyX: keyX,
                committeeKeyY: keyY,
                // A live deployment has usually been exercised, so the root has legitimately
                // moved. Skipped rather than asserted wrongly.
                expectedRoot: 0
            })
        );

        console.log("DEPLOYMENT OK");
        console.log("  pool                :", pool);
        console.log("  encryptedTotals     :", enc);
        console.log("  committee key       : matches circuits/build/committee-key.json");
        console.log("  legacy markets      : frozen");
        console.log("  exit path           : bound");
        console.log("  oracle market %s resolver is a contract", oracleMarketId);
    }
}
