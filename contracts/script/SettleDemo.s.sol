// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {ShieldedPool} from "../src/ShieldedPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {EncryptedParimutuelPool} from "../src/EncryptedParimutuelPool.sol";

/// @notice Stand up a settlement rig on a live chain, so the claimed-plaintext binding
///         can be attacked against REAL deployed bytecode.
///
/// @dev WHY A RIG RATHER THAN THE MAIN MARKET.
///
///      Settling the market the main exercise bet into requires waiting out
///      `Vault.MIN_RESOLUTION_GAP` -- at least an hour between betting close and
///      resolution, deliberately, so a last-second bet cannot front-run an already
///      determined outcome. There is no way to skip that on a live chain.
///
///      So this deploys a vault whose schedule is already in the past (the constructor
///      constrains the GAP between close and resolution, not that either is in the
///      future) and drives an accumulator directly, using the ciphertexts from
///      `settlement-fixtures.json` -- sums of five per-bet ciphertexts, totals 425 and
///      350, decrypting correctly in JS before they are ever written here.
///
///      WHAT THIS DOES AND DOES NOT PROVE.
///
///      Proves: the deployed `EncryptedParimutuelPool` bytecode accepts an honest total
///      and rejects a fabricated one carrying a valid Chaum-Pedersen proof.
///      Does not prove: that these particular ciphertexts came from real bets -- the
///      main `ExerciseEncrypted` run is what shows real `betEncrypted` calls
///      accumulating correctly.
///
///      Usage:
///        POOL=0x.. forge script script/SettleDemo.s.sol \
///          --rpc-url https://testnet-rpc.monad.xyz --broadcast --network monad --slow
contract SettleDemo is Script {
    using stdJson for string;

    uint32 constant DEMO_MARKET_ID = 9;
    uint256 constant DENOM = 1e6;
    uint256 constant MIN_PUBLISH_INTERVAL = 1 hours;

    string fx;

    function _u(string memory key) internal view returns (uint256) {
        return fx.readUint(key);
    }

    function run() external {
        fx = vm.readFile("../circuits/build/settlement-fixtures.json");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        ShieldedPool pool = ShieldedPool(vm.envAddress("POOL"));

        vm.startBroadcast(pk);

        // A schedule already in the past, so the market is resolvable immediately.
        uint64 closed = uint64(block.timestamp - 3 hours);
        Vault vault = new Vault(
            IERC20(address(pool.marketVault(7).collateral())),
            DENOM,
            me,
            keccak256("settlement rig -- testnet only"),
            closed,
            closed + 2 hours
        );

        // Registered on the real pool so `EncryptedParimutuelPool` resolves
        // `marketId -> Vault` through the same registry the shielded actions use.
        pool.registerEncryptedMarket(DEMO_MARKET_ID, vault);

        // A standalone accumulator whose `pool` is this EOA, so the fixture ciphertexts
        // can be written directly. The production accumulator only ever accepts writes
        // from `ShieldedPool`, which is why the main exercise had to go through real
        // `betEncrypted` calls to move it.
        ElGamalAccumulator acc = new ElGamalAccumulator(me);
        acc.initMarket(DEMO_MARKET_ID, 1);
        acc.initMarket(DEMO_MARKET_ID, 2);

        acc.accumulateAffine(DEMO_MARKET_ID, 1, _u(".yes.c1[0]"), _u(".yes.c1[1]"), _u(".yes.c2[0]"), _u(".yes.c2[1]"));
        acc.accumulateAffine(DEMO_MARKET_ID, 2, _u(".no.c1[0]"), _u(".no.c1[1]"), _u(".no.c2[0]"), _u(".no.c2[1]"));

        EncryptedParimutuelPool epp = new EncryptedParimutuelPool(
            acc, pool, _u(".committeeKey[0]"), _u(".committeeKey[1]"), MIN_PUBLISH_INTERVAL
        );

        vault.resolve(Vault.Outcome.Yes);

        vm.stopBroadcast();

        console.log("--- settlement rig ready ---");
        console.log("Vault (past-dated)   :", address(vault));
        console.log("Accumulator (rig)    :", address(acc));
        console.log("EncryptedParimutuel  :", address(epp));
        console.log("market id            :", DEMO_MARKET_ID);
        console.log("true YES total       :", _u(".expected.yesTotal"));
        console.log("true NO total        :", _u(".expected.noTotal"));
        console.log("the lie to attempt   :", _u(".honestProofLyingTotal.claimedTotal"));
    }
}
