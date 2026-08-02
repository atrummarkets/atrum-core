// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {ShieldedPool} from "../src/ShieldedPool.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {IncrementalMerkleTree} from "../src/IncrementalMerkleTree.sol";

/// @notice Exercise the deployed stack with real proofs, on a real chain.
///
/// @dev Local `forge test` pricing is validated against the live chain, but it does not
///      charge calldata or the 21,000 intrinsic cost. This script produces the numbers
///      a user actually pays.
///
///      Covers deposit -> pad -> graft -> bet. It stops short of redeem because
///      `Vault.MIN_RESOLUTION_GAP` enforces at least an hour between betting close and
///      resolution -- deliberately, so last-second bets cannot front-run an already
///      determined outcome. There is no way to exercise redemption on a live chain
///      without waiting that hour out; it is covered locally by
///      `test_fullLifecycle_depositBetResolveRedeem`.
///
///      Usage:
///        POOL=0x.. COLLATERAL=0x.. forge script script/Exercise.s.sol \
///          --rpc-url https://testnet-rpc.monad.xyz --broadcast --network monad --slow
contract Exercise is Script {
    using stdJson for string;

    uint32 constant MARKET_ID = 7;
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

    function run() external {
        fixtures = vm.readFile("../circuits/build/action-fixtures.json");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        ShieldedPool pool = ShieldedPool(vm.envAddress("POOL"));
        IERC20 collateral = IERC20(vm.envAddress("COLLATERAL"));

        uint256[] memory batch1 = fixtures.readUintArray(".batch1");

        vm.startBroadcast(pk);

        collateral.approve(address(pool), type(uint256).max);

        pool.deposit(_pA("deposit"), _pB("deposit"), _pC("deposit"), _u(".deposit.commitment"), UNITS);
        console.log("deposit done, queued:", pool.queuedCount());

        // Only the real commitment is submitted; the contract derives the remaining 63
        // filler leaves itself, so the sequencer cannot choose one.
        uint256[] memory real = new uint256[](1);
        real[0] = batch1[0];
        pool.flushBatch(real);
        console.log("batch grafted, queued:", pool.queuedCount());

        pool.bet(
            _pA("bet"),
            _pB("bet"),
            _pC("bet"),
            _u(".bet.root"),
            _u(".bet.nullifierHash"),
            _u(".bet.newCommitment"),
            _u(".bet.betData")
        );

        vm.stopBroadcast();

        IncrementalMerkleTree tree = pool.tree();
        ParimutuelPool parimutuel = pool.parimutuel();

        console.log("--- state after exercise ---");
        console.log("on-chain root  :", tree.root());
        console.log("expected root  :", _u(".rootAfterBatch1"));
        console.log("YES units      :", parimutuel.totalUnits(MARKET_ID));
        console.log("YES prob (bps) :", parimutuel.yesProbabilityBps(MARKET_ID));
        console.log("queued         :", pool.queuedCount());

        require(tree.root() == _u(".rootAfterBatch1"), "on-chain root diverged from prover");
    }
}
