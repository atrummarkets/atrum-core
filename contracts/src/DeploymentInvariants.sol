// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Vault} from "./Vault.sol";
import {ShieldedPool} from "./ShieldedPool.sol";
import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";
import {ElGamalAccumulator} from "./ElGamalAccumulator.sol";
import {EncryptedParimutuelPool} from "./EncryptedParimutuelPool.sol";
import {ParimutuelPool} from "./ParimutuelPool.sol";
import {MappingNullifierSet} from "./MappingNullifierSet.sol";

/// @title DeploymentInvariants
/// @notice What a correct deployment looks like, in one place.
///
/// @dev WHY THIS EXISTS
///
///      Two of the bugs this project has actually shipped came from `Deploy.s.sol`, and both
///      had the same shape: the script wrote state that nothing verified.
///
///        1. `bindEncryptedTotals` was never called, so `encryptedTotals`,
///           `redeemPrivateVerifier` and `withdrawVerifier` were all address(0). Collateral
///           could be deposited and bet, and NOTHING could ever be paid out. A one-way vault.
///        2. The committee key was a constant copied from a file that `make keygen`
///           regenerates. It went stale, so the market was bound to a key nobody held the
///           secret for, and settlement was impossible. Discovered by `InvalidDecryptionProof()`
///           on a real testnet settlement, 65 minutes after the bets landed.
///
///      Both were invisible to a passing test suite of over 200 tests, because the tests
///      asserted what the CONTRACTS do and nobody asserted what the DEPLOYMENT is.
///
///      The lesson is not "write more tests". A test only runs when someone runs it, and
///      `forge script --broadcast` does not. So these checks live in a library that runs
///      inside the deployment itself: a broken deployment REVERTS instead of shipping.
///
///      The same function backs three callers, which is the point -- one list of invariants,
///      not three that drift:
///        - `Deploy.s.sol`, at the end of `run()`, so a bad deploy cannot be broadcast;
///        - `VerifyDeployment.s.sol`, pointed at any live address, at any time;
///        - `DeployConfig.t.sol`, in CI.
library DeploymentInvariants {
    error ExitPathUnbound();
    error WrongTotalsSource();
    error CommitteeKeyMismatch(uint256 expectedX, uint256 actualX);
    error LegacyMarketsNotFrozen();
    error MarketNotRegistered(uint32 marketId);
    error MarketNotEncrypted(uint32 marketId);
    error MiswiredPool(address component);
    error MiswiredSequencer(address expected, address actual);
    error TreeNotAtGenesis(uint256 root);
    error PublicRedeemStillPresent();
    error ResolverIsNotAContract(address resolver);
    error VerifierHasNoCode(address verifier);

    struct Expected {
        address pool;
        address tree;
        address accumulator;
        address encryptedParimutuel;
        address parimutuel;
        address nullifiers;
        address sequencer;
        uint32 encryptedMarketId;
        uint32 oracleMarketId;
        /// @dev The committee key the PROOFS were generated with, read from the artifact by
        ///      the caller. Compared against what is deployed -- never against another
        ///      constant, since two constants agreeing only proves they were copied together.
        uint256 committeeKeyX;
        uint256 committeeKeyY;
        /// @dev Genesis root, or 0 to skip. A live deployment that has already been exercised
        ///      is not at genesis and must not be asserted to be.
        uint256 expectedRoot;
    }

    /// @notice Reverts unless every invariant holds. Called at deploy time, so a broken
    ///         deployment cannot be broadcast.
    function check(Expected memory e) internal view {
        ShieldedPool pool = ShieldedPool(e.pool);

        // 1. THE EXIT PATH. Without this the pool is a one-way vault: deposits and bets
        //    work, and nothing can ever be withdrawn. This is bug #1 above.
        if (
            address(pool.encryptedTotals()) == address(0) || address(pool.redeemPrivateVerifier()) == address(0)
                || address(pool.withdrawVerifier()) == address(0)
        ) revert ExitPathUnbound();

        // Bound to the RIGHT thing, not merely non-zero.
        if (address(pool.encryptedTotals()) != e.encryptedParimutuel) revert WrongTotalsSource();

        // 2. THE COMMITTEE KEY. A market bound to a key nobody holds the secret for can
        //    never settle, and a market that cannot settle cannot pay out. This is bug #2.
        EncryptedParimutuelPool enc = EncryptedParimutuelPool(e.encryptedParimutuel);
        if (enc.committeeKeyX() != e.committeeKeyX || enc.committeeKeyY() != e.committeeKeyY) {
            revert CommitteeKeyMismatch(e.committeeKeyX, enc.committeeKeyX());
        }

        // 3. Cross-contract wiring. Each of these is an immutable set at construction from a
        //    PREDICTED pool address; a prediction that silently drifted would leave a
        //    component pointing at nothing and every action reverting.
        if (ElGamalAccumulator(e.accumulator).pool() != e.pool) revert MiswiredPool(e.accumulator);
        if (ParimutuelPool(e.parimutuel).pool() != e.pool) revert MiswiredPool(e.parimutuel);
        if (address(enc.pool()) != e.pool) revert MiswiredPool(e.encryptedParimutuel);
        if (MappingNullifierSet(e.nullifiers).pool() != e.pool) revert MiswiredPool(e.nullifiers);

        // The tree only accepts grafts from the pool. Wrong here and no commitment is ever
        // inserted, so no proof can ever reference a real leaf.
        address treeSequencer = IncrementalMerkleTree(e.tree).sequencer();
        if (treeSequencer != e.pool) revert MiswiredSequencer(e.pool, treeSequencer);

        // 4. The deprecation is live and irreversible.
        if (!pool.legacyMarketsFrozen()) revert LegacyMarketsNotFrozen();

        // 5. Markets exist with the right MODE. An encrypted market registered as plaintext
        //    would accept deposits and then refuse every private action.
        _checkEncrypted(pool, e.encryptedMarketId);
        _checkEncrypted(pool, e.oracleMarketId);

        // 6. The oracle market's outcome must not be decidable by a person. An EOA resolver
        //    on a market anyone can create is a licence to resolve your own market wrongly
        //    and take the pool.
        address oracleResolver = pool.marketVault(e.oracleMarketId).resolver();
        if (oracleResolver.code.length == 0) revert ResolverIsNotAContract(oracleResolver);

        // 7. Verifiers must actually be contracts. A zero-code address passes an
        //    `address(0)` check and then makes every proof "valid" or every call revert,
        //    depending on the call type.
        if (address(pool.depositVerifier()).code.length == 0) {
            revert VerifierHasNoCode(address(pool.depositVerifier()));
        }
        if (address(pool.betEncryptedVerifier()).code.length == 0) {
            revert VerifierHasNoCode(address(pool.betEncryptedVerifier()));
        }
        if (address(pool.redeemPrivateVerifier()).code.length == 0) {
            revert VerifierHasNoCode(address(pool.redeemPrivateVerifier()));
        }
        if (address(pool.withdrawVerifier()).code.length == 0) {
            revert VerifierHasNoCode(address(pool.withdrawVerifier()));
        }

        // 8. The removed public payout path must be absent from DEPLOYED bytecode, not just
        //    from source. Guards against shipping a stale artifact.
        if (_containsSelector(e.pool.code, ShieldedPool.deposit.selector) == false) {
            // Sanity: the scan must be able to FIND something that is present, or a miss
            // below would prove nothing. `deposit` is always there.
            revert VerifierHasNoCode(e.pool);
        }
        bytes4 removedRedeem =
            bytes4(keccak256("redeem(uint256[2],uint256[2][2],uint256[2],uint256,uint256,uint256,uint256)"));
        if (_containsSelector(e.pool.code, removedRedeem)) revert PublicRedeemStillPresent();

        // 9. A fresh deployment starts at the genesis root the prover assumes. Skipped when
        //    the caller passes 0, because an already-exercised deployment is legitimately
        //    past it.
        if (e.expectedRoot != 0) {
            uint256 root = IncrementalMerkleTree(e.tree).root();
            if (root != e.expectedRoot) revert TreeNotAtGenesis(root);
        }
    }

    function _checkEncrypted(ShieldedPool pool, uint32 marketId) private view {
        if (address(pool.marketVault(marketId)) == address(0)) revert MarketNotRegistered(marketId);
        if (!pool.encryptedMarket(marketId)) revert MarketNotEncrypted(marketId);
    }

    function _containsSelector(bytes memory code, bytes4 sel) private pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}
