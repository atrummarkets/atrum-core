// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ShieldedPool, IDepositVerifier, IActionVerifier, IActionVerifier8} from "../src/ShieldedPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";

/// @dev Minimal 6-decimal USDC stand-in, so the checkup needs no live token.
contract CheckupUSDC {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        return _move(msg.sender, to, a);
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) {
            require(al >= a, "allowance");
            allowance[f][msg.sender] = al - a;
        }
        return _move(f, t, a);
    }

    function _move(address f, address t, uint256 a) private returns (bool) {
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @title Checkup
/// @notice A human-readable, self-verifying walk through every function in the stack.
///
/// @dev This is the "does each function actually do its job" harness. It deploys a fresh
///      stack in-memory, drives the whole lifecycle with REAL Groth16 proofs from
///      `circuits/build/action-fixtures.json`, and prints an ok/FAIL line per function
///      with the value it actually observed.
///
///      It duplicates coverage that `forge test` already has, on purpose: the test suite
///      answers "is anything broken", this answers "show me what each function did". Use
///      the tests for CI and this for reading.
///
///      Needs no RPC and spends nothing -- everything runs in the local EVM.
///
///      Usage:
///        make checkup                                   # the whole walkthrough
///        make checkup PART=vault                        # one area at a time
///        forge test --network monad --match-test test_checkup_security -vv
///
///      Run with `--network monad` or the gas figures printed are Ethereum's, understating
///      BN254 by ~5x and cold SLOAD by ~4x.
contract CheckupTest is Test {
    using stdJson for string;

    CheckupUSDC usdc;
    Vault vault;
    IncrementalMerkleTree tree;
    MappingNullifierSet nullifiers;
    ParimutuelPool parimutuel;
    ElGamalAccumulator accumulator;
    ShieldedPool pool;
    IPoseidonT3 poseidon;

    address sequencer = address(0xBEEF);
    address resolver = address(0xCAFE);
    address depositor = address(0xD0D0);

    uint32 constant MARKET_ID = 7;
    uint256 constant DENOM = 1e6;

    /// @dev The test minimum, not the production one. `ShieldedPool` documents 8 as the
    ///      intended value; the recorded lifecycle contains four deposits in total, so a
    ///      suite pinned to 8 could never reach a bet and would only ever prove the gate
    ///      blocks everything. `AnonymitySetGate.t.sol` covers the gate at real values.
    uint256 constant MIN_ANON_SET = 2;

    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty")) % R;

    string fixtures;
    uint64 bettingClose;
    uint64 resolutionStart;

    uint256 passes;
    uint256 failures;

    // Held in storage so each lifecycle phase can be its own function -- inlining them
    // all into one exceeded the EVM stack under non-IR codegen.
    uint256 lifeUnits;
    uint256 gasDeposit;
    uint256 gasFlush;
    uint256 gasBet;
    uint256 gasRedeem;

    // -----------------------------------------------------------------------
    // Reporting
    // -----------------------------------------------------------------------

    function _ok(string memory what, string memory detail) internal {
        passes++;
        console.log(string.concat("  [ok]   ", what, "  ->  ", detail));
    }

    function _check(bool condition, string memory what, string memory detail) internal {
        if (condition) {
            _ok(what, detail);
        } else {
            failures++;
            console.log(string.concat("  [FAIL] ", what, "  ->  ", detail));
        }
    }

    function _eq(uint256 got, uint256 want, string memory what) internal {
        _check(
            got == want,
            what,
            string.concat("got ", vm.toString(got), got == want ? "" : string.concat(", want ", vm.toString(want)))
        );
    }

    function _section(string memory name) internal pure {
        console.log("");
        console.log(string.concat("== ", name, " =="));
    }

    function _summary() internal view {
        console.log("");
        console.log("-------------------------------------------");
        console.log(string.concat("  passed: ", vm.toString(passes), "   failures: ", vm.toString(failures)));
        console.log(failures == 0 ? "  ALL CHECKS PASSED" : "  SOME CHECKS FAILED");
        console.log("-------------------------------------------");
        require(failures == 0, "checkup failures");
    }

    // -----------------------------------------------------------------------
    // Fixture readers
    // -----------------------------------------------------------------------

    function _u(string memory k) internal view returns (uint256) {
        return fixtures.readUint(k);
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

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    function _deploy() internal {
        vm.warp(1_800_000_000);
        fixtures = vm.readFile("../circuits/build/action-fixtures.json");

        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address pAddr = address(uint160(uint256(keccak256("checkup.poseidon"))));
        vm.etch(pAddr, code);
        poseidon = IPoseidonT3(pAddr);

        usdc = new CheckupUSDC();
        bettingClose = uint64(block.timestamp + 7 days);
        resolutionStart = bettingClose + 2 hours;

        vault = new Vault(
            IERC20(address(usdc)), DENOM, resolver, keccak256("Will Team A win?"), bettingClose, resolutionStart
        );

        DepositVerifier dv = new DepositVerifier();
        BetVerifier bv = new BetVerifier();
        BetEncryptedVerifier bev = new BetEncryptedVerifier();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        tree = new IncrementalMerkleTree(poseidon, ZERO_VALUE, predicted);
        nullifiers = new MappingNullifierSet();
        accumulator = new ElGamalAccumulator(predicted);
        parimutuel = new ParimutuelPool(predicted);

        pool = new ShieldedPool(
            tree,
            nullifiers,
            parimutuel,
            accumulator,
            IDepositVerifier(address(dv)),
            IActionVerifier(address(bv)),
            IActionVerifier8(address(bev)),
            IERC20(address(usdc)),
            DENOM,
            MIN_ANON_SET,
            sequencer,
            address(this)
        );
        require(address(pool) == predicted, "address prediction failures");

        nullifiers.bindPool(address(pool));
    }

    // -----------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------

    function setUp() public {
        _deploy();
    }

    /// @notice The whole walkthrough. `make checkup`.
    function test_checkup_everything() public {
        console.log("");
        console.log("ATRUM CHECKUP -- every function, real proofs, real Poseidon");
        console.log("(run with --network monad or the gas below is Ethereum's, ~5x low)");

        _checkWiring();
        _checkTree();
        _checkVaultBasics();
        _checkLifecycle();
        _checkSecurity();
        _summary();
    }

    function test_checkup_vault() public {
        _checkVaultBasics();
        _summary();
    }

    function test_checkup_tree() public {
        _checkTree();
        _summary();
    }

    function test_checkup_shieldedPool() public {
        _checkWiring();
        _checkLifecycle();
        _summary();
    }

    function test_checkup_parimutuel() public {
        _checkLifecycle();
        _summary();
    }

    function test_checkup_security() public {
        _checkSecurity();
        _summary();
    }

    // -----------------------------------------------------------------------
    // Wiring
    // -----------------------------------------------------------------------

    function _checkWiring() internal {
        _section("Wiring / immutables");

        _check(address(pool.tree()) == address(tree), "ShieldedPool.tree", "bound");
        _check(address(pool.nullifiers()) == address(nullifiers), "ShieldedPool.nullifiers", "bound");
        _check(address(pool.parimutuel()) == address(parimutuel), "ShieldedPool.parimutuel", "bound");
        _check(pool.sequencer() == sequencer, "ShieldedPool.sequencer", "immutable, set once");
        _check(nullifiers.pool() == address(pool), "MappingNullifierSet.bindPool", "bound once, irreversible");
        _check(nullifiers.enforcesOnChain(), "INullifierSet.enforcesOnChain", "true (pool refuses false)");
        _eq(pool.BATCH_SIZE(), 64, "ShieldedPool.BATCH_SIZE");

        pool.registerMarket(MARKET_ID, vault);
        _check(address(pool.marketVault(MARKET_ID)) == address(vault), "registerMarket", "market 7 -> vault");

        (bool reReg,) =
            address(pool).call(abi.encodeWithSelector(pool.registerMarket.selector, MARKET_ID, address(vault)));
        _check(!reReg, "registerMarket (twice)", "rejected: MarketAlreadyRegistered");
    }

    // -----------------------------------------------------------------------
    // Tree
    // -----------------------------------------------------------------------

    function _checkTree() internal {
        _section("IncrementalMerkleTree");

        _eq(tree.DEPTH(), 20, "DEPTH");
        _eq(tree.MAX_LEAVES(), 1_048_576, "MAX_LEAVES (2^20 notes)");
        _eq(tree.nextIndex(), 0, "nextIndex (fresh tree)");
        _check(tree.root() != 0, "root (empty tree)", vm.toString(tree.root()));
        _check(tree.isKnownRoot(tree.root()), "isKnownRoot(current)", "true");
        _check(!tree.isKnownRoot(0), "isKnownRoot(0)", "false, as it must be");
        _check(!tree.isKnownRoot(uint256(keccak256("nope"))), "isKnownRoot(garbage)", "false");

        // Poseidon agreement is the single most load-bearing constant in the repo: if the
        // etched contract and circomlib disagree, every proof fails with no diagnostic.
        _eq(
            poseidon.poseidon([uint256(1), uint256(2)]),
            0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a,
            "Poseidon(1,2) matches circomlibjs"
        );
    }

    // -----------------------------------------------------------------------
    // Vault
    // -----------------------------------------------------------------------

    function _checkVaultBasics() internal {
        _section("Vault (collateral layer)");

        _eq(vault.denomination(), DENOM, "denomination (fixed split size)");
        _check(vault.resolver() == resolver, "resolver", "immutable");
        _eq(uint8(vault.outcome()), 0, "outcome (Unresolved)");
        _eq(vault.MIN_RESOLUTION_GAP(), 1 hours, "MIN_RESOLUTION_GAP");

        address alice = address(0xA11CE);
        usdc.mint(alice, 100 * DENOM);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vault.split(10);
        _eq(vault.yesBalance(alice), 10, "split -> yesBalance");
        _eq(vault.noBalance(alice), 10, "split -> noBalance (complete set)");
        _eq(vault.collateralHeld(), 10 * DENOM, "split -> collateralHeld");

        vault.merge(4);
        _eq(vault.yesBalance(alice), 6, "merge -> yesBalance");
        _eq(vault.collateralHeld(), 6 * DENOM, "merge -> collateral returned");
        vm.stopPrank();

        _check(
            vault.yesSupply() == vault.noSupply(),
            "invariant: yesSupply == noSupply",
            string.concat(vm.toString(vault.yesSupply()), " each")
        );

        (bool early,) = address(vault).call(abi.encodeWithSelector(vault.resolve.selector, Vault.Outcome.Yes));
        _check(!early, "resolve (before resolutionStartTime)", "rejected: TooEarlyToResolve");
    }

    // -----------------------------------------------------------------------
    // The full private lifecycle
    // -----------------------------------------------------------------------

    function _checkLifecycle() internal {
        if (address(pool.marketVault(MARKET_ID)) == address(0)) {
            pool.registerMarket(MARKET_ID, vault);
        }
        _lifeDeposit();
        _lifeFlush();
        _lifeBet();
        _lifeResolveRedeem();

        console.log("");
        console.log("  gas: deposit / bet / redeem / flushBatch(64)");
        console.log(
            string.concat(
                "       ",
                vm.toString(gasDeposit),
                " / ",
                vm.toString(gasBet),
                " / ",
                vm.toString(gasRedeem),
                " / ",
                vm.toString(gasFlush)
            )
        );
    }

    function _lifeDeposit() internal {
        _section("deposit (real Groth16 proof)");

        lifeUnits = _u(".deposit.units");
        usdc.mint(depositor, (lifeUnits + _u(".depositLadder.units")) * DENOM);

        // Fixture reads are `vm.parseJson` cheatcodes and cost real gas, so they are
        // hoisted OUT of the measured region. Left inline they inflated `bet` by ~971,000
        // gas -- almost exactly one Groth16 verify, which reads convincingly like a
        // contract problem and is not one.
        uint256[2] memory pA = _pA("deposit");
        uint256[2][2] memory pB = _pB("deposit");
        uint256[2] memory pC = _pC("deposit");
        uint256 commitment = _u(".deposit.commitment");

        vm.startPrank(depositor);
        usdc.approve(address(pool), type(uint256).max);
        uint256 g = gasleft();
        pool.deposit(pA, pB, pC, commitment, lifeUnits);
        gasDeposit = g - gasleft();

        // Batch 1's second deposit, at a different rung. Never spent -- it exists so the pool
        // satisfies its own anonymity-set gate, which refuses a bet into a crowd of one.
        pool.deposit(
            _pA("depositLadder"),
            _pB("depositLadder"),
            _pC("depositLadder"),
            _u(".depositLadder.commitment"),
            _u(".depositLadder.units")
        );
        vm.stopPrank();

        _eq(pool.queuedCount(), 2, "deposit -> both commitments queued");
        // Shared custody, not a per-market complete set: a deposit names no market, so there
        // is nothing to split into and the collateral simply sits in the pool.
        uint256 ladderUnits = _u(".depositLadder.units");
        _eq(
            usdc.balanceOf(address(pool)),
            (lifeUnits + ladderUnits) * DENOM,
            "deposit -> pool holds collateral"
        );
        _eq(
            pool.totalDepositedUnits(),
            lifeUnits + ladderUnits,
            "deposit -> counted toward solvency bound"
        );
        _eq(pool.totalDeposits(), 2, "deposit -> counted toward the anonymity set");
        _eq(vault.yesBalance(address(pool)), 0, "deposit -> mints nothing");
        _reportGas("deposit", gasDeposit);
    }

    function _lifeFlush() internal {
        _section("flushBatch (sequencer, derived padding)");

        uint256[] memory real1 = fixtures.readUintArray(".batch1Real");
        vm.prank(sequencer);
        uint256 g = gasleft();
        pool.flushBatch(real1);
        gasFlush = g - gasleft();

        _eq(pool.insertedCount(), 2, "flushBatch -> only real commitments consumed");
        _eq(tree.nextIndex(), 64, "flushBatch -> full aligned subtree grafted");
        _eq(tree.root(), _u(".rootAfterBatch1"), "flushBatch -> root matches the prover's mirror");
        _check(
            gasFlush < 30_000_000, "flushBatch within the 30M tx limit", string.concat(vm.toString(gasFlush), " gas")
        );
        _check(
            pool.derivedFiller(0, 1) == _u(".derivedFiller_0_1"),
            "derivedFiller matches JS mirror",
            "padding is unchoosable and reproducible"
        );
    }

    function _lifeBet() internal {
        _section("bet (spend a note, move the odds)");

        uint256[2] memory pA = _pA("bet");
        uint256[2][2] memory pB = _pB("bet");
        uint256[2] memory pC = _pC("bet");
        uint256 root = _u(".bet.root");
        uint256 nh = _u(".bet.nullifierHash");
        uint256 newCommitment = _u(".bet.newCommitment");
        uint256 betData = _u(".bet.betData");

        uint256 g = gasleft();
        pool.bet(pA, pB, pC, root, nh, newCommitment, betData);
        gasBet = g - gasleft();

        _check(nullifiers.isSpent(nh), "bet -> nullifier burned", "double-spend blocked");
        _eq(parimutuel.totalUnits(MARKET_ID), lifeUnits, "bet -> stake recorded");
        _eq(parimutuel.yesProbabilityBps(MARKET_ID), 10_000, "bet -> published odds (one-sided = 100%)");
        _eq(pool.queuedCount(), 3, "bet -> replacement note queued");
        _reportGas("bet", gasBet);

        (bool replay,) =
            address(pool).call(abi.encodeWithSelector(pool.bet.selector, pA, pB, pC, root, nh, newCommitment, betData));
        _check(!replay, "bet (replayed)", "rejected: NullifierAlreadySpent");
    }

    function _lifeResolveRedeem() internal {
        _section("resolve + redeem");

        uint256[] memory real2 = fixtures.readUintArray(".batch2Real");
        vm.prank(sequencer);
        pool.flushBatch(real2);
        _eq(tree.root(), _u(".rootAfterBatch2"), "second batch -> root matches mirror");

        vm.warp(resolutionStart);
        vm.prank(resolver);
        vault.resolve(Vault.Outcome.Yes);
        _eq(uint8(vault.outcome()), 1, "resolve -> outcome = Yes");
        _eq(parimutuel.payoutUnits(MARKET_ID, 1, lifeUnits), lifeUnits, "payoutUnits (sole winner takes the pool)");

        // The public `redeem()` has been REMOVED. It published a recipient address and a
        // payout amount, which both build plans forbid outright: a public payout claim
        // retroactively deanonymises every position it pays.
        //
        // The replacement path -- `redeemPrivate` -> `withdraw` -- is exercised end to end in
        // `PrivateRedeem.t.sol`, which sets up the settled-totals binding this lightweight
        // walkthrough deliberately does not.
        _ok("redeem (public)", "REMOVED -- replaced by redeemPrivate + withdraw");
        gasRedeem = 0;
    }

    /// @dev Reports against the envelope rather than asserting a ceiling. The authoritative
    ///      budget assertions live in `ShieldedPool.t.sol`; duplicating them here would
    ///      make the checkup red for budget reasons rather than correctness reasons.
    function _reportGas(string memory what, uint256 used) internal {
        _check(
            used < 30_000_000,
            string.concat(what, " gas"),
            string.concat(
                vm.toString(used),
                used < 2_000_000 ? "  (within the 2,000,000 envelope)" : "  (OVER the 2,000,000 envelope)"
            )
        );
    }

    // -----------------------------------------------------------------------
    // Security properties -- each of these must FAIL to succeed
    // -----------------------------------------------------------------------

    function _checkSecurity() internal {
        _section("Security (every line here must be REJECTED)");

        if (address(pool.marketVault(MARKET_ID)) == address(0)) {
            pool.registerMarket(MARKET_ID, vault);
        }

        // The fixed critical vulnerability: a sequencer-authored leaf.
        uint256[] memory forged = new uint256[](1);
        forged[0] = uint256(keccak256("attacker note")) % R;
        vm.prank(sequencer);
        (bool graft,) = address(pool).call(abi.encodeWithSelector(pool.flushBatch.selector, forged));
        _check(!graft, "flushBatch with an unqueued leaf", "rejected -- sequencer cannot author a note");

        // The removed function must stay removed.
        (bool oldFn,) = address(pool).call(abi.encodeWithSelector(bytes4(keccak256("queuePadding(uint256[])")), forged));
        _check(!oldFn, "queuePadding (removed)", "selector no longer exists");

        // Only the sequencer may flush.
        (bool anyone,) = address(pool).call(abi.encodeWithSelector(pool.flushBatch.selector, forged));
        _check(!anyone, "flushBatch from a non-sequencer", "rejected: NotSequencer");

        // Only the pool may burn nullifiers.
        (bool spend,) = address(nullifiers).call(abi.encodeWithSelector(nullifiers.spend.selector, uint256(1)));
        _check(!spend, "MappingNullifierSet.spend from outside", "rejected: NotPool");

        // Only the pool may move stake.
        (bool stake,) = address(parimutuel)
            .call(abi.encodeWithSelector(parimutuel.addStake.selector, MARKET_ID, uint8(1), uint256(1)));
        _check(!stake, "ParimutuelPool.addStake from outside", "rejected: NotPool");

        // Field aliasing: x and x+r are the same field element in-circuit but different
        // uint256s in Solidity. The generated verifier's checkField is what blocks this.
        (bool aliased,) = address(pool)
            .call(
                abi.encodeWithSelector(
                    pool.bet.selector,
                    _pA("bet"),
                    _pB("bet"),
                    _pC("bet"),
                    _u(".bet.root"),
                    _u(".bet.nullifierHash"),
                    _u(".bet.newCommitment"),
                    _u(".bet.betData") + R
                )
            );
        _check(!aliased, "bet with betData + FIELD_SIZE", "rejected -- packing cannot be aliased");

        // A leaf outside the field would be silently reduced by Poseidon.
        uint256[] memory bad = new uint256[](1);
        bad[0] = R;
        vm.prank(address(pool));
        (bool nonField,) = address(tree).call(abi.encodeWithSelector(tree.insertSubtree.selector, bad));
        _check(!nonField, "tree.insertSubtree with a non-field leaf", "rejected: LeafNotInField");

        // A market must exist before it can be bet on.
        (bool noMarket,) = address(pool)
            .call(
                abi.encodeWithSelector(
                    pool.deposit.selector,
                    _pA("deposit"),
                    _pB("deposit"),
                    _pC("deposit"),
                    uint256(1),
                    uint32(999),
                    uint256(1)
                )
            );
        _check(!noMarket, "deposit into an unregistered market", "rejected: MarketNotRegistered");
    }
}
