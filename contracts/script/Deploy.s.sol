// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ShieldedPool, IDepositVerifier, IActionVerifier} from "../src/ShieldedPool.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {RedeemVerifier} from "../src/verifiers/RedeemVerifier.sol";
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
    uint256 constant DENOM = 1e6;

    /// @dev Grouped so `run` stays inside the stack limit without `via_ir`. Turning IR
    ///      on would shift every gas figure in MEASUREMENTS.md, and those numbers are
    ///      the point of this repo.
    struct Deployed {
        address poseidon;
        address collateral;
        address vault;
        address depositVerifier;
        address betVerifier;
        address redeemVerifier;
        address tree;
        address parimutuel;
        address nullifiers;
        address pool;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address sequencer = vm.envOr("SEQUENCER", deployer);

        console.log("deployer :", deployer);
        console.log("sequencer:", sequencer);

        vm.startBroadcast(pk);

        Deployed memory d;
        d.poseidon = _deployPoseidon();
        d.collateral = _deployCollateral(deployer);
        d.vault = _deployVault(d.collateral, deployer);

        d.depositVerifier = address(new DepositVerifier());
        d.betVerifier = address(new BetVerifier());
        d.redeemVerifier = address(new RedeemVerifier());

        _deployPool(d, deployer, sequencer);

        vm.stopBroadcast();

        _report(d);
    }

    function _deployCollateral(address deployer) internal returns (address) {
        MockERC20 usdc = new MockERC20();
        usdc.mint(deployer, 10_000_000 * DENOM);
        return address(usdc);
    }

    function _deployVault(address collateral, address deployer) internal returns (address) {
        uint64 bettingClose = uint64(block.timestamp + 7 days);
        return address(
            new Vault(
                IERC20(collateral),
                DENOM,
                deployer,
                keccak256("Will Atrum ship Phase 2? -- resolves manually, testnet only"),
                bettingClose,
                bettingClose + 2 hours
            )
        );
    }

    function _deployPool(Deployed memory d, address deployer, address sequencer) internal {
        // The pool's address is needed by the tree and the parimutuel pool, which are
        // constructed before it. Predicting keeps both roles immutable rather than
        // leaving a standing setter over the anonymity set.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);

        d.tree = address(new IncrementalMerkleTree(IPoseidonT3(d.poseidon), ZERO_VALUE, predicted));
        d.parimutuel = address(new ParimutuelPool(predicted));
        d.nullifiers = address(new MappingNullifierSet());

        ShieldedPool pool = new ShieldedPool(
            IncrementalMerkleTree(d.tree),
            MappingNullifierSet(d.nullifiers),
            ParimutuelPool(d.parimutuel),
            IDepositVerifier(d.depositVerifier),
            IActionVerifier(d.betVerifier),
            IActionVerifier(d.redeemVerifier),
            sequencer,
            deployer
        );
        require(address(pool) == predicted, "pool address prediction failed");
        d.pool = address(pool);

        MappingNullifierSet(d.nullifiers).bindPool(d.pool);
        pool.registerMarket(MARKET_ID, Vault(d.vault));
    }

    function _report(Deployed memory d) internal view {
        console.log("PoseidonT3           :", d.poseidon);
        console.log("Collateral (mock)    :", d.collateral);
        console.log("Vault                :", d.vault);
        console.log("DepositVerifier      :", d.depositVerifier);
        console.log("BetVerifier          :", d.betVerifier);
        console.log("RedeemVerifier       :", d.redeemVerifier);
        console.log("IncrementalMerkleTree:", d.tree);
        console.log("ParimutuelPool       :", d.parimutuel);
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
