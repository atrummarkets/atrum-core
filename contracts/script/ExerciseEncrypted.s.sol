// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {ShieldedPool} from "../src/ShieldedPool.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {IncrementalMerkleTree} from "../src/IncrementalMerkleTree.sol";

/// @notice Exercise the PHASE 2 encrypted path on a real chain, with a real proof.
///
/// @dev What this is for: proving on a live network that a bet enters the pool without the
///      chain ever learning its size. Local `forge` can show the logic works, but it
///      charges neither calldata nor the 21,000 intrinsic cost, and every measured Phase 1
///      action came in 30-40% higher on testnet than locally (MEASUREMENTS.md §1c). The
///      envelope question cannot be closed from local numbers.
///
///      The lifecycle walks the tree forward to where the encrypted deposit's Merkle path
///      was built: deposit -> graft -> bet -> graft -> encrypted deposit -> graft ->
///      betEncrypted. Batches graft sequentially, so the earlier ones are not optional.
///
///      Usage:
///        POOL=0x.. COLLATERAL=0x.. forge script script/ExerciseEncrypted.s.sol \
///          --rpc-url https://testnet-rpc.monad.xyz --broadcast --network monad --slow
contract ExerciseEncrypted is Script {
    using stdJson for string;

    uint32 constant MARKET_ID = 7;
    uint32 constant ENCRYPTED_MARKET_ID = 8;
    uint256 constant UNITS = 100;

    string fixtures;

    function _u(string memory key) internal view returns (uint256) {
        return fixtures.readUint(key);
    }

    function _pA(string memory a) internal view returns (uint256[2] memory) {
        return [_u(string.concat(".", a, ".pA[0]")), _u(string.concat(".", a, ".pA[1]"))];
    }

    function _pB(string memory a) internal view returns (uint256[2][2] memory) {
        return [
            [_u(string.concat(".", a, ".pB[0][0]")), _u(string.concat(".", a, ".pB[0][1]"))],
            [_u(string.concat(".", a, ".pB[1][0]")), _u(string.concat(".", a, ".pB[1][1]"))]
        ];
    }

    function _pC(string memory a) internal view returns (uint256[2] memory) {
        return [_u(string.concat(".", a, ".pC[0]")), _u(string.concat(".", a, ".pC[1]"))];
    }

    function _ciphertext(string memory a) internal view returns (uint256[4] memory) {
        return [
            _u(string.concat(".", a, ".ciphertext[0]")),
            _u(string.concat(".", a, ".ciphertext[1]")),
            _u(string.concat(".", a, ".ciphertext[2]")),
            _u(string.concat(".", a, ".ciphertext[3]"))
        ];
    }

    function _betEncrypted(ShieldedPool pool, string memory a) internal {
        pool.betEncrypted(
            _pA(a),
            _pB(a),
            _pC(a),
            _u(string.concat(".", a, ".root")),
            _u(string.concat(".", a, ".nullifierHash")),
            _u(string.concat(".", a, ".newCommitment")),
            _u(string.concat(".", a, ".betMeta")),
            _ciphertext(a)
        );
    }

    function _flushOne(ShieldedPool pool, uint256 leaf) internal {
        uint256[] memory real = new uint256[](1);
        real[0] = leaf;
        pool.flushBatch(real);
    }

    function run() external {
        fixtures = vm.readFile("../circuits/build/action-fixtures.json");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        ShieldedPool pool = ShieldedPool(vm.envAddress("POOL"));
        IERC20 collateral = IERC20(vm.envAddress("COLLATERAL"));

        vm.startBroadcast(pk);

        collateral.approve(address(pool), type(uint256).max);

        // --- Phase 1 lifecycle, to walk the tree to batch 3 ---
        pool.deposit(_pA("deposit"), _pB("deposit"), _pC("deposit"), _u(".deposit.commitment"), MARKET_ID, UNITS);
        _flushOne(pool, _u(".deposit.commitment"));

        pool.bet(
            _pA("bet"),
            _pB("bet"),
            _pC("bet"),
            _u(".bet.root"),
            _u(".bet.nullifierHash"),
            _u(".bet.newCommitment"),
            _u(".bet.betData")
        );
        _flushOne(pool, _u(".bet.newCommitment"));

        // --- Phase 2: deposit into the ENCRYPTED market ---
        pool.deposit(
            _pA("depositEncrypted"),
            _pB("depositEncrypted"),
            _pC("depositEncrypted"),
            _u(".depositEncrypted.commitment"),
            ENCRYPTED_MARKET_ID,
            UNITS
        );
        _flushOne(pool, _u(".depositEncrypted.commitment"));

        // --- THE ENCRYPTED BET ---
        // Note what is NOT in this calldata: the stake. The contract receives a ciphertext
        // and adds it to a running encrypted total. It never learns the amount.
        _betEncrypted(pool, "betEncrypted");

        // --- A SECOND ENCRYPTED BET, different stake ---
        // One bet shows the ciphertext is accepted. Two show the property the whole
        // design rests on: the contract TOTALS them without decrypting either.
        pool.deposit(
            _pA("depositEncrypted2"),
            _pB("depositEncrypted2"),
            _pC("depositEncrypted2"),
            _u(".depositEncrypted2.commitment"),
            ENCRYPTED_MARKET_ID,
            _u(".depositEncrypted2.units")
        );

        // Two leaves this time, in queue order: the first encrypted bet's position note
        // is still pending, and the queue is consumed strictly in order.
        uint256[] memory batch4 = new uint256[](2);
        batch4[0] = _u(".betEncrypted.newCommitment");
        batch4[1] = _u(".depositEncrypted2.commitment");
        pool.flushBatch(batch4);

        _betEncrypted(pool, "betEncrypted2");

        vm.stopBroadcast();

        _report(pool);
    }

    function _report(ShieldedPool pool) internal view {
        IncrementalMerkleTree tree = pool.tree();
        ParimutuelPool parimutuel = pool.parimutuel();
        ElGamalAccumulator accumulator = pool.accumulator();

        (uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y) = accumulator.totalAffine(ENCRYPTED_MARKET_ID, 1);

        console.log("--- state after encrypted exercise ---");
        console.log("on-chain root       :", tree.root());
        console.log("expected root       :", _u(".rootAfterBatch4"));
        console.log("accumulated C1.x    :", c1x);
        console.log("accumulated C1.y    :", c1y);
        console.log("accumulated C2.x    :", c2x);
        console.log("accumulated C2.y    :", c2y);
        console.log("expected sum C1.x   :", _u(".accumulatorAfterBothBets.ciphertext[0]"));

        // The public pool total for the encrypted market must be untouched -- the stakes
        // never entered it, because the contract was never told what they were.
        console.log("PUBLIC units (enc mkt):", parimutuel.totalUnits(ENCRYPTED_MARKET_ID));
        console.log("PUBLIC units (plain)  :", parimutuel.totalUnits(MARKET_ID));
        console.log("(off-chain, the ciphertext above decrypts to)", _u(".accumulatorAfterBothBets.decryptsTo"));

        require(tree.root() == _u(".rootAfterBatch4"), "on-chain root diverged from prover");

        // THE HOMOMORPHIC CHECK. The accumulator was handed two independent ciphertexts
        // and never a plaintext; its state must equal the ciphertext sum computed
        // off-chain by circomlibjs, field element for field element.
        require(c1x == _u(".accumulatorAfterBothBets.ciphertext[0]"), "accumulated C1.x != off-chain sum");
        require(c1y == _u(".accumulatorAfterBothBets.ciphertext[1]"), "accumulated C1.y != off-chain sum");
        require(c2x == _u(".accumulatorAfterBothBets.ciphertext[2]"), "accumulated C2.x != off-chain sum");
        require(c2y == _u(".accumulatorAfterBothBets.ciphertext[3]"), "accumulated C2.y != off-chain sum");

        require(parimutuel.totalUnits(ENCRYPTED_MARKET_ID) == 0, "encrypted stake leaked into the public pool");
    }
}
