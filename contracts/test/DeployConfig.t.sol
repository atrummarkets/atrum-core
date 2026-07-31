// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ShieldedPool} from "../src/ShieldedPool.sol";
import {Vault} from "../src/Vault.sol";

/// @notice The deployment script's END STATE, asserted rather than eyeballed.
///
/// @dev `Deploy.s.sol` had no test. Its correctness was checked by reading the console output
///      of a simulation, which proves nothing about the resulting configuration and re-proves
///      nothing when the script changes.
///
///      The property that matters here is the enforced half of the plaintext deprecation: the
///      script registers the one legacy market the recorded fixtures need and then calls
///      `freezeLegacyMarkets()` in the same transaction, so a deployed instance can never
///      acquire a second one. A legacy market has no redemption path -- the public `redeem()`
///      was removed, and `redeemPrivate` reads settled totals from `EncryptedParimutuelPool`,
///      which a plaintext market does not have -- so collateral deposited into one is stuck.
///      A future operator adding another would strand real funds.
contract DeployConfigTest is Test {
    // anvil account 0 -- a well-known test key, never used for anything real.
    uint256 constant TEST_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    uint32 constant MARKET_ID = 7;
    uint32 constant ENCRYPTED_MARKET_ID = 8;

    Deploy internal script;
    Deploy.Deployed internal d;
    ShieldedPool internal pool;

    function setUp() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(TEST_PK)));
        script = new Deploy();
        d = script.run();
        pool = ShieldedPool(d.pool);
    }

    /// @notice The script leaves legacy market creation permanently shut.
    function test_deploy_freezesLegacyMarkets() public view {
        assertTrue(pool.legacyMarketsFrozen(), "deployment did not freeze legacy markets");
    }

    /// @notice And the freeze is not cosmetic: the admin themselves cannot add another.
    function test_deploy_adminCannotRegisterAnotherPlaintextMarket() public {
        address admin = vm.addr(TEST_PK);
        vm.prank(admin);
        vm.expectRevert(ShieldedPool.LegacyMarketsAreFrozen.selector);
        pool.registerMarket(99, Vault(d.vault));
    }

    /// @notice The freeze must NOT block the market type the product actually uses, or the
    ///         deployment would be inert. This is the half that is easy to break by widening
    ///         the freeze check to cover both registration paths.
    function test_deploy_encryptedMarketsStillRegistrable() public {
        address admin = vm.addr(TEST_PK);
        vm.prank(admin);
        pool.registerEncryptedMarket(99, Vault(d.encryptedVault));
        assertTrue(pool.encryptedMarket(99), "encrypted registration was blocked by the freeze");
    }

    /// @notice Both fixture markets exist, and with the right modes -- the freeze fires AFTER
    ///         registration, not before, or `Exercise.s.sol` would have nothing to replay.
    function test_deploy_bothFixtureMarketsRegistered() public view {
        assertEq(address(pool.marketVault(MARKET_ID)), d.vault, "legacy fixture market missing");
        assertEq(address(pool.marketVault(ENCRYPTED_MARKET_ID)), d.encryptedVault, "encrypted fixture market missing");
        assertFalse(pool.encryptedMarket(MARKET_ID), "legacy market wrongly flagged encrypted");
        assertTrue(pool.encryptedMarket(ENCRYPTED_MARKET_ID), "encrypted market not flagged");
    }

    /// @notice The removed public payout path is gone from the deployed bytecode, not merely
    ///         from the source. Guards against a stale artifact being shipped.
    ///
    /// @dev A scan that finds nothing proves nothing on its own -- a broken scan also finds
    ///      nothing. So the SAME scan is first pointed at `withdraw`, a selector that must be
    ///      present, and required to find it. Only then is a miss on `redeem` meaningful.
    function test_deploy_publicRedeemNotInDeployedCode() public view {
        bytes memory code = address(pool).code;

        bytes4 present =
            bytes4(keccak256("withdraw(uint256[2],uint256[2][2],uint256[2],uint256,uint256,uint256,uint256)"));
        assertTrue(_containsSelector(code, present), "scan is broken: it cannot find a selector that IS present");

        bytes4 removed =
            bytes4(keccak256("redeem(uint256[2],uint256[2][2],uint256[2],uint256,uint256,uint256,uint256)"));
        assertFalse(_containsSelector(code, removed), "removed redeem() selector is still in the deployed bytecode");
    }

    function _containsSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}
