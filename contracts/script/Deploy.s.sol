// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {
    ShieldedPool,
    IDepositVerifier,
    IActionVerifier,
    IActionVerifier8,
    IEncryptedTotals
} from "../src/ShieldedPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {EncryptedParimutuelPool} from "../src/EncryptedParimutuelPool.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";
import {RedeemPrivateVerifier} from "../src/verifiers/RedeemPrivateVerifier.sol";
import {WithdrawVerifier} from "../src/verifiers/WithdrawVerifier.sol";
import {PythResolver} from "../src/PythResolver.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploy the Phase 1 stack.
///
/// @dev Usage:
///        forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast --network monad
///
///      Requires PRIVATE_KEY. On testnet the collateral is a MockERC20 the script mints
///      to the deployer; on mainnet it would be native USDC
///      (0x754704Bc059F8C67012fEd69BC8A327a5aafb603, 6 decimals) and this script would
///      need the real address wired in instead.
contract Deploy is Script {
    /// keccak256("atrum.shielded.empty") reduced into the BN254 scalar field.
    /// MUST match circuits/scripts/atrum.mjs and sequencer/src/tree.ts.
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty"))
        % 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint32 constant MARKET_ID = 7;

    /// @dev A second market on the Phase 2 path, so a deployment exercises both. Its own
    ///      Vault, not a shared one: a Vault owns its collateral and its resolution, and
    ///      pointing two markets at one would double-count both.
    uint32 constant ENCRYPTED_MARKET_ID = 8;

    /// @dev An ORACLE-resolved market, alongside the manually-resolved one above.
    ///
    ///      Both exist deliberately. Market 8 keeps a human resolver so the recorded fixture
    ///      lifecycle can still be replayed on demand; market 10 is the shape a real market
    ///      takes, where the outcome is a computation over signed price data and no address
    ///      has the power to decide it.
    uint32 constant ORACLE_MARKET_ID = 10;

    /// @notice Pyth on Monad testnet. VERIFIED LIVE: `getValidTimePeriod()` returns 60 and
    ///         `getPriceUnsafe` returns a real BTC/USD aggregate at this address.
    /// @dev Overridable, because this is the one address that differs per chain. The beta
    ///      feed contract the Monad docs list (`0xad2B…d0B5`) has NO CODE deployed -- checked
    ///      with `cast code`, which returns `0x` -- so there is no MON/USD feed to point at.
    address constant PYTH_MONAD_TESTNET = 0x2880aB155794e7179c9eE2e38200202908C17B43;

    /// @notice Pyth's BTC/USD feed id.
    bytes32 constant BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    uint256 constant DENOM = 1e6;

    /// @dev Odds are published hourly, never continuously -- see the contract's notice.
    uint256 constant MIN_PUBLISH_INTERVAL = 1 hours;

    /// @dev Grouped so `run` stays inside the stack limit without `via_ir`. Turning IR
    ///      on would shift every gas figure in MEASUREMENTS.md, and those numbers are
    ///      the point of this repo.
    struct Deployed {
        address poseidon;
        address collateral;
        address vault;
        address encryptedVault;
        address depositVerifier;
        address betVerifier;
        address betEncryptedVerifier;
        address pythResolver;
        address oracleVault;
        address redeemPrivateVerifier;
        address withdrawVerifier;
        address tree;
        address parimutuel;
        address accumulator;
        address encryptedParimutuel;
        address nullifiers;
        address pool;
    }

    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address sequencer = vm.envOr("SEQUENCER", deployer);

        console.log("deployer :", deployer);
        console.log("sequencer:", sequencer);

        vm.startBroadcast(pk);

        d.poseidon = _deployPoseidon();
        d.collateral = _deployCollateral(deployer);
        d.vault = _deployVault(d.collateral, deployer);
        d.encryptedVault = _deployVault(d.collateral, deployer);

        d.depositVerifier = address(new DepositVerifier());
        d.betVerifier = address(new BetVerifier());
        d.betEncryptedVerifier = address(new BetEncryptedVerifier());
        d.redeemPrivateVerifier = address(new RedeemPrivateVerifier());
        d.withdrawVerifier = address(new WithdrawVerifier());

        _deployPool(d, deployer, sequencer);

        vm.stopBroadcast();

        _report(d);
    }

    function _deployCollateral(address deployer) internal returns (address) {
        MockERC20 usdc = new MockERC20();
        usdc.mint(deployer, 10_000_000 * DENOM);
        return address(usdc);
    }

    /// @notice The disclosed committee decryption key.
    ///
    /// @dev READ, NEVER HARDCODED. This used to be a pair of constants copied out of
    ///      `circuits/build/committee-key.json`. That file is REGENERATED by `make keygen`,
    ///      so the constants silently went stale, and the first testnet deployment shipped a
    ///      committee key nobody holds the secret for.
    ///
    ///      The consequence was not cosmetic. `publishFinalTotals` requires a
    ///      Chaum-Pedersen proof that the decryption share matches the committee key, so a
    ///      market deployed against the wrong key can NEVER be settled -- and a market that
    ///      cannot settle cannot pay out. Bets in, nothing out. It surfaced as
    ///      `InvalidDecryptionProof()` on a real testnet settlement attempt.
    ///
    ///      `COMMITTEE_KEY_X`/`_Y` in the environment override the file, which is how a real
    ///      ceremony key gets in without the artifact being present at all.
    ///
    ///      Phase 2 ships a single key in the open on purpose -- the privacy claim rests on
    ///      the ciphertext, not on hiding whose key it is. But the file's secret sits on a
    ///      developer machine, so it protects nothing. A real deployment needs a ceremony.
    function _committeeKey() internal view returns (uint256 x, uint256 y) {
        x = vm.envOr("COMMITTEE_KEY_X", uint256(0));
        y = vm.envOr("COMMITTEE_KEY_Y", uint256(0));
        if (x != 0 && y != 0) return (x, y);

        string memory json = vm.readFile("../circuits/build/committee-key.json");
        x = vm.parseJsonUint(json, ".pubKey[0]");
        y = vm.parseJsonUint(json, ".pubKey[1]");
        if (x == 0 || y == 0) revert("committee key is zero -- run `make keygen`");
    }

    /// @dev `EXERCISE_MODE=1` back-dates the schedule so betting is already closed and the
    ///      market can be resolved immediately. That is the only way to drive the full
    ///      lifecycle -- settle, redeemPrivate, withdraw -- through a real chain, where
    ///      `vm.warp` does not exist and the default schedule is seven days out.
    ///
    ///      TESTNET ONLY. A back-dated market accepts no bets, because betting closed before
    ///      it was deployed. It exists to measure gas on the exit path, not to trade.
    function _deployVault(address collateral, address deployer) internal returns (address) {
        bool exercise = vm.envOr("EXERCISE_MODE", uint256(0)) == 1;
        // Betting must still be OPEN when the exercise places its bets, and resolution
        // cannot begin until MIN_RESOLUTION_GAP (1 hour) after betting closes -- the Vault
        // constructor enforces that, and it is a safety invariant rather than a knob. So the
        // shortest honest schedule is a few minutes of betting followed by a one-hour wait,
        // which is why the exercise runs in two phases.
        uint64 bettingClose = exercise ? uint64(block.timestamp + 6 minutes) : uint64(block.timestamp + 7 days);
        return address(
            new Vault(
                IERC20(collateral),
                DENOM,
                deployer,
                keccak256("Will Atrum ship Phase 2? -- resolves manually, testnet only"),
                bettingClose,
                exercise ? bettingClose + 1 hours : bettingClose + 2 hours
            )
        );
    }

    /// @dev The oracle market's schedule, which differs from the others in one way that
    ///      matters: resolution must open AFTER the price being asked about exists. A vault
    ///      whose resolution window opens before its own `targetTime` can never be resolved,
    ///      because no signed update for a future moment exists yet -- and it would then sit
    ///      unresolvable until `voidMarket` refunds everyone, which is a working system
    ///      producing a useless market.
    function _deployOracleVault(address collateral, address resolver, bytes32 specHash) internal returns (address) {
        uint64 bettingClose = uint64(block.timestamp + 7 days);
        return address(
            new Vault(
                IERC20(collateral),
                DENOM,
                resolver,
                specHash,
                bettingClose,
                // targetTime is bettingClose + 30 minutes, so resolution opening at
                // +2 hours leaves the price comfortably in the past by then.
                bettingClose + 2 hours
            )
        );
    }

    function _deployPool(Deployed memory d, address deployer, address sequencer) internal {
        // The pool's address is needed by the tree, the parimutuel pool and the
        // accumulator, all of which are constructed before it. Predicting keeps every one
        // of those roles immutable rather than leaving a standing setter over the
        // anonymity set.
        //
        // The offset counts the deploys between here and the pool -- tree, parimutuel,
        // nullifiers, accumulator -- so adding a contract to that list means bumping it.
        // The `require` below is what catches a stale count.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 4);

        d.tree = address(new IncrementalMerkleTree(IPoseidonT3(d.poseidon), ZERO_VALUE, predicted));
        d.parimutuel = address(new ParimutuelPool(predicted));
        d.nullifiers = address(new MappingNullifierSet());
        d.accumulator = address(new ElGamalAccumulator(predicted));

        ShieldedPool pool = new ShieldedPool(
            IncrementalMerkleTree(d.tree),
            MappingNullifierSet(d.nullifiers),
            ParimutuelPool(d.parimutuel),
            ElGamalAccumulator(d.accumulator),
            IDepositVerifier(d.depositVerifier),
            IActionVerifier(d.betVerifier),
            IActionVerifier8(d.betEncryptedVerifier),
            sequencer,
            deployer
        );
        require(address(pool) == predicted, "pool address prediction failed");
        d.pool = address(pool);

        MappingNullifierSet(d.nullifiers).bindPool(d.pool);

        // The encrypted market is the product. `registerEncryptedMarket` also initialises the
        // accumulator to Enc(0) for both outcomes -- see its notice for why that is not left
        // to a separate call.
        pool.registerEncryptedMarket(ENCRYPTED_MARKET_ID, Vault(d.encryptedVault));

        // AN ORACLE-RESOLVED MARKET. This is the shape a real market takes.
        //
        // The Vault's resolver is the PythResolver CONTRACT, not a person, and its
        // `resolutionSpecHash` commits to the exact question before betting opens. After
        // this call nobody -- not the deployer, not the admin -- can decide the outcome:
        // it becomes a comparison against a signed price at a committed timestamp, and
        // anyone at all may trigger it.
        //
        // That is also what unblocks user-created markets later. Creation stays admin-only
        // for now, deliberately, because opening it raises separate questions (who pays to
        // initialise the accumulator, how market spam is bounded) that are not answered by
        // having a trustworthy resolver.
        d.pythResolver = address(new PythResolver(IPyth(vm.envOr("PYTH", PYTH_MONAD_TESTNET))));

        PythResolver.Spec memory oracleSpec = PythResolver.Spec({
            priceId: BTC_USD,
            // "Will BTC be above 100,000 at the target time?" 100,000 with Pyth's -8 exponent.
            threshold: 100_000_00000000,
            thresholdExpo: -8,
            // AFTER betting closes, which the resolver enforces -- a market settled on a
            // price that was knowable while people were still betting is a payout to
            // whoever checked, not a prediction.
            targetTime: uint64(block.timestamp + 7 days + 30 minutes),
            windowSeconds: 60,
            greaterThan: true
        });

        d.oracleVault =
            _deployOracleVault(d.collateral, d.pythResolver, PythResolver(d.pythResolver).hashSpec(oracleSpec));
        pool.registerEncryptedMarket(ORACLE_MARKET_ID, Vault(d.oracleVault));

        // MARKET_ID is a DEPRECATED plaintext market, registered only so `Exercise.s.sol` can
        // replay the recorded fixture lifecycle, whose Merkle tree contains legacy leaves.
        // Anything deposited into it is unrecoverable: the public `redeem()` was removed for
        // leaking a recipient and an amount, and `redeemPrivate` cannot serve this market
        // because it reads settled totals from `EncryptedParimutuelPool`, which a plaintext
        // market has none of.
        pool.registerMarket(MARKET_ID, Vault(d.vault));

        // ...and then the door is shut, irreversibly, in the same transaction that opened it.
        // This is the enforced half of the deprecation: the two markets above are the last
        // plaintext and encrypted markets this deployment will ever have from `registerMarket`,
        // so no future operator can strand funds in a third. `registerEncryptedMarket` is
        // deliberately NOT affected -- see `freezeLegacyMarkets`.
        pool.freezeLegacyMarkets();

        // Settlement reads from here, and only from here. Deployed after the pool because
        // it takes the pool's real address rather than a predicted one.
        (uint256 keyX, uint256 keyY) = _committeeKey();
        d.encryptedParimutuel = address(
            new EncryptedParimutuelPool(ElGamalAccumulator(d.accumulator), pool, keyX, keyY, MIN_PUBLISH_INTERVAL)
        );

        // THE EXIT PATH. Without this the pool accepts deposits and bets and can never pay
        // anything out: `redeemPrivate` and `withdraw` both revert on a zero verifier, and
        // the public `redeem()` was removed. A deployment missing this call is a one-way
        // vault, and the first testnet deploy shipped exactly that -- all three of these
        // slots were address(0) on chain.
        //
        // It is a separate call rather than a constructor argument because the dependency is
        // circular: `EncryptedParimutuelPool` takes the pool's real address, so it cannot
        // exist before the pool does. `bindEncryptedTotals` is one-shot and irreversible.
        pool.bindEncryptedTotals(
            IEncryptedTotals(d.encryptedParimutuel),
            IActionVerifier(d.redeemPrivateVerifier),
            IActionVerifier(d.withdrawVerifier)
        );
    }

    function _report(Deployed memory d) internal view {
        console.log("PoseidonT3           :", d.poseidon);
        console.log("Collateral (mock)    :", d.collateral);
        console.log("Vault (plaintext)    :", d.vault);
        console.log("Vault (encrypted)    :", d.encryptedVault);
        console.log("DepositVerifier      :", d.depositVerifier);
        console.log("BetVerifier          :", d.betVerifier);
        console.log("BetEncryptedVerifier :", d.betEncryptedVerifier);
        console.log("RedeemPrivateVerifier:", d.redeemPrivateVerifier);
        console.log("WithdrawVerifier     :", d.withdrawVerifier);
        console.log("PythResolver         :", d.pythResolver);
        console.log("Vault (oracle, mkt 10):", d.oracleVault);
        console.log("IncrementalMerkleTree:", d.tree);
        console.log("ParimutuelPool       :", d.parimutuel);
        console.log("ElGamalAccumulator   :", d.accumulator);
        console.log("EncryptedParimutuel  :", d.encryptedParimutuel);
        console.log("MappingNullifierSet  :", d.nullifiers);
        console.log("ShieldedPool         :", d.pool);
        console.log("initial root         :", IncrementalMerkleTree(d.tree).root());
    }

    /// @dev Wrap runtime bytecode in initcode that copies and returns it:
    ///
    ///        61 LLLL  PUSH2 len
    ///        80       DUP1
    ///        60 0a    PUSH1 10        (runtime starts at byte 10)
    ///        3d       RETURNDATASIZE  (cheap 0)
    ///        39       CODECOPY        dest=0, offset=10, len
    ///        3d       RETURNDATASIZE  (cheap 0)
    ///        f3       RETURN          offset=0, len
    function _deployPoseidon() internal returns (address deployed) {
        bytes memory runtime = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));

        bytes memory initcode = abi.encodePacked(hex"61", uint16(runtime.length), hex"80600a3d393df3", runtime);

        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "poseidon deploy failed");

        // The etched digest is checked against circomlibjs in the test suite; check the
        // deployed one too, because a truncated or mis-wrapped runtime would deploy
        // cleanly and then disagree with every in-circuit hash.
        require(
            IPoseidonT3(deployed).poseidon([uint256(1), uint256(2)])
                == 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a,
            "deployed Poseidon disagrees with circomlibjs"
        );
    }
}
