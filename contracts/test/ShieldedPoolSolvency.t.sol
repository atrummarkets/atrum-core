// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, Vm, stdJson} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IncrementalMerkleTree, IPoseidonT3} from "../src/IncrementalMerkleTree.sol";
import {MappingNullifierSet} from "../src/MappingNullifierSet.sol";
import {ParimutuelPool} from "../src/ParimutuelPool.sol";
import {ElGamalAccumulator} from "../src/ElGamalAccumulator.sol";
import {EncryptedParimutuelPool} from "../src/EncryptedParimutuelPool.sol";
import {
    ShieldedPool,
    IDepositVerifier,
    IActionVerifier,
    IActionVerifier8,
    IEncryptedTotals
} from "../src/ShieldedPool.sol";
import {ChaumPedersen} from "../src/ChaumPedersen.sol";
import {DepositVerifier} from "../src/verifiers/DepositVerifier.sol";
import {BetVerifier} from "../src/verifiers/BetVerifier.sol";
import {BetEncryptedVerifier} from "../src/verifiers/BetEncryptedVerifier.sol";
import {RedeemPrivateVerifier} from "../src/verifiers/RedeemPrivateVerifier.sol";
import {WithdrawVerifier} from "../src/verifiers/WithdrawVerifier.sol";

/// @notice Replays the recorded lifecycle in ARBITRARY ORDER and asserts the pool stays solvent.
///
/// @dev WHY THIS FILE EXISTS
///
///      Solvency used to be STRUCTURAL. `Vault.split` was the only way to mint outcome tokens,
///      it pulled collateral atomically, and `deposit` was its only caller -- so there was no
///      mint-without-collateral path anywhere in the system and no arithmetic to get wrong.
///
///      One shared pool deletes that guarantee. A deposit names no market, nothing is minted,
///      and what stops the pool being drained is now a pair of counters checked in
///      `_recordPayout`. That is a strictly weaker kind of safety: code that can be wrong,
///      rather than a shape that cannot be.
///
///      There was no stateful invariant test anywhere in this repo. The change that most needs
///      one had no net. This is the net.
///
///      WHY THE HANDLER REPLAYS FIXED CALLDATA RATHER THAN FUZZING ARGUMENTS
///
///      Every state-changing entry point here demands a valid Groth16 proof. Fuzzed arguments
///      produce `InvalidProof` on literally every call, and the invariant then holds vacuously
///      over a state machine that never moved -- the most dangerous kind of green test, because
///      it looks like coverage.
///
///      So the fuzzer chooses ORDER and TIME, not arguments. The handler holds the encoded
///      calls for the whole recorded lifecycle and executes one per step. Out-of-order calls
///      revert on their own preconditions (`UnknownRoot`, `NullifierAlreadySpent`,
///      `NotSettled2`, `BettingClosed`, ...) and are swallowed. What gets explored is every
///      interleaving of the real actions, which is where an ordering bug in the new accounting
///      would live.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 96
contract ShieldedPoolSolvencyTest is Test {
    using stdJson for string;

    MockERC20 usdc;
    Vault vault;
    Vault encryptedVault;
    IncrementalMerkleTree tree;
    MappingNullifierSet nullifiers;
    ParimutuelPool parimutuel;
    ElGamalAccumulator accumulator;
    EncryptedParimutuelPool encrypted;
    ShieldedPool pool;
    IPoseidonT3 poseidon;
    Handler handler;

    address resolver = makeAddr("resolver");

    uint32 constant NO_MARKET = 0;
    uint32 constant MARKET_ID = 7;
    uint32 constant ENCRYPTED_MARKET_ID = 8;
    uint256 constant DENOM = 1e6;

    /// @dev The test minimum, not the production one. `ShieldedPool` documents 8 as the
    ///      intended value; the recorded lifecycle contains four deposits in total, so a
    ///      suite pinned to 8 could never reach a bet and would only ever prove the gate
    ///      blocks everything. `AnonymitySetGate.t.sol` covers the gate at real values.
    uint256 constant MIN_ANON_SET = 2;

    uint256 constant MIN_PUBLISH_INTERVAL = 1 hours;
    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant ZERO_VALUE = uint256(keccak256("atrum.shielded.empty")) % R;

    string actions;
    string e2e;

    uint64 bettingClose;
    uint64 resolutionStart;

    function setUp() public {
        vm.warp(1_800_000_000);
        actions = vm.readFile("../circuits/build/action-fixtures.json");
        e2e = vm.readFile("../circuits/build/e2e-fixtures.json");

        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("../circuits/build/poseidon2-runtime.hex")));
        address addr = makeAddr("poseidonT3");
        vm.etch(addr, code);
        poseidon = IPoseidonT3(addr);

        usdc = new MockERC20();
        bettingClose = uint64(block.timestamp + 7 days);
        resolutionStart = bettingClose + 2 hours;
        vault = new Vault(IERC20(address(usdc)), DENOM, resolver, keccak256("spec"), bettingClose, resolutionStart);
        encryptedVault =
            new Vault(IERC20(address(usdc)), DENOM, resolver, keccak256("spec-enc"), bettingClose, resolutionStart);

        DepositVerifier dv = new DepositVerifier();
        BetVerifier bv = new BetVerifier();
        BetEncryptedVerifier bev = new BetEncryptedVerifier();
        RedeemPrivateVerifier rpv = new RedeemPrivateVerifier();
        WithdrawVerifier wv = new WithdrawVerifier();

        // The handler is the sequencer AND the depositor. Splitting those across addresses
        // would only mean the fuzzer could never reach any state past the first flush.
        handler = new Handler();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        tree = new IncrementalMerkleTree(poseidon, ZERO_VALUE, predicted);
        parimutuel = new ParimutuelPool(predicted);
        nullifiers = new MappingNullifierSet();
        accumulator = new ElGamalAccumulator(predicted);

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
            address(handler),
            address(this)
        );
        require(address(pool) == predicted, "pool address prediction failed");

        nullifiers.bindPool(address(pool));
        pool.registerMarket(MARKET_ID, vault);
        pool.registerEncryptedMarket(ENCRYPTED_MARKET_ID, encryptedVault);

        encrypted = new EncryptedParimutuelPool(
            accumulator, pool, _e(".committeeKey[0]"), _e(".committeeKey[1]"), MIN_PUBLISH_INTERVAL
        );
        pool.bindEncryptedTotals(
            IEncryptedTotals(address(encrypted)), IActionVerifier(address(rpv)), IActionVerifier(address(wv))
        );

        usdc.mint(address(handler), 1_000_000 * DENOM);

        handler.init(
            pool,
            usdc,
            encrypted,
            encryptedVault,
            resolver,
            resolutionStart,
            ENCRYPTED_MARKET_ID,
            _buildCalls(),
            _settleCall()
        );

        targetContract(address(handler));

        // Without this the fuzzer spends a fifth of its budget calling `init`, which reverts
        // every time because `calls` is already populated -- a fifth of the campaign doing
        // nothing. Only the four state-transition selectors are worth fuzzing.
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Handler.perform.selector;
        selectors[1] = Handler.advanceTime.selector;
        selectors[2] = Handler.resolveMarket.selector;
        selectors[3] = Handler.settleMarket.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Encode the whole recorded lifecycle once. `vm.parseJson` costs ~450,000 gas a call
    ///      and the invariant runner would otherwise pay it thousands of times over.
    ///
    ///      Every step is present, including the ones a shorter list would be tempted to skip.
    ///      The redeem proof was built against the root after batch 5, so omitting batches 2
    ///      and 4 would leave `redeemPrivate` and everything downstream permanently
    ///      unreachable -- and the invariant would pass over a pool that never paid anyone.
    function _buildCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](18);

        calls[0] = abi.encodeCall(
            ShieldedPool.deposit,
            (_pA("deposit"), _pB("deposit"), _pC("deposit"), _a(".deposit.commitment"), _a(".deposit.units"))
        );
        // Batch 1's second deposit, at a different rung and never spent. Without it the pool
        // never satisfies its own anonymity-set gate and every bet below is unreachable --
        // which the invariants would not notice, because they would simply hold over a pool
        // that never bet.
        calls[1] = abi.encodeCall(
            ShieldedPool.deposit,
            (
                _pA("depositLadder"),
                _pB("depositLadder"),
                _pC("depositLadder"),
                _a(".depositLadder.commitment"),
                _a(".depositLadder.units")
            )
        );
        calls[2] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch1Real")));
        calls[3] = abi.encodeCall(
            ShieldedPool.bet,
            (
                _pA("bet"),
                _pB("bet"),
                _pC("bet"),
                _a(".bet.root"),
                _a(".bet.nullifierHash"),
                _a(".bet.newCommitment"),
                _a(".bet.betData")
            )
        );
        calls[4] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch2Real")));
        calls[5] = abi.encodeCall(
            ShieldedPool.deposit,
            (
                _pA("depositEncrypted"),
                _pB("depositEncrypted"),
                _pC("depositEncrypted"),
                _a(".depositEncrypted.commitment"),
                _a(".depositEncrypted.units")
            )
        );
        calls[6] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch3Real")));
        calls[7] = abi.encodeCall(
            ShieldedPool.betEncrypted,
            (
                _pA("betEncrypted"),
                _pB("betEncrypted"),
                _pC("betEncrypted"),
                _a(".betEncrypted.root"),
                _a(".betEncrypted.nullifierHash"),
                _a(".betEncrypted.newCommitment"),
                _a(".betEncrypted.betMeta"),
                _ct("betEncrypted")
            )
        );
        calls[8] = abi.encodeCall(
            ShieldedPool.deposit,
            (
                _pA("depositEncrypted2"),
                _pB("depositEncrypted2"),
                _pC("depositEncrypted2"),
                _a(".depositEncrypted2.commitment"),
                _a(".depositEncrypted2.units")
            )
        );
        calls[9] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch4Real")));
        calls[10] = abi.encodeCall(
            ShieldedPool.betEncrypted,
            (
                _pA("betEncrypted2"),
                _pB("betEncrypted2"),
                _pC("betEncrypted2"),
                _a(".betEncrypted2.root"),
                _a(".betEncrypted2.nullifierHash"),
                _a(".betEncrypted2.newCommitment"),
                _a(".betEncrypted2.betMeta"),
                _ct("betEncrypted2")
            )
        );
        calls[11] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch5Real")));
        calls[12] = abi.encodeCall(
            ShieldedPool.redeemPrivate,
            (
                _pA("redeemPrivate"),
                _pB("redeemPrivate"),
                _pC("redeemPrivate"),
                _a(".redeemPrivate.root"),
                _a(".redeemPrivate.nullifierHash"),
                _a(".redeemPrivate.newCommitment"),
                _a(".redeemPrivate.redeemMeta")
            )
        );
        calls[13] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch6Real")));
        calls[14] = abi.encodeCall(
            ShieldedPool.withdraw,
            (
                _pA("withdraw"),
                _pB("withdraw"),
                _pC("withdraw"),
                _a(".withdraw.root"),
                _a(".withdraw.nullifierHash"),
                _a(".withdraw.changeCommitment"),
                _a(".withdraw.withdrawData")
            )
        );
        calls[15] = abi.encodeCall(
            ShieldedPool.deposit,
            (
                _pA("depositUnbetExit"),
                _pB("depositUnbetExit"),
                _pC("depositUnbetExit"),
                _a(".depositUnbetExit.commitment"),
                _a(".depositUnbetExit.units")
            )
        );
        calls[16] = abi.encodeCall(ShieldedPool.flushBatch, (actions.readUintArray(".batch7Real")));
        // The unbet exit skips every per-market check, so the global bound is the only thing
        // guarding it. It has to be in the reachable set for this invariant to mean anything.
        calls[17] = abi.encodeCall(
            ShieldedPool.withdraw,
            (
                _pA("withdrawUnbet"),
                _pB("withdrawUnbet"),
                _pC("withdrawUnbet"),
                _a(".withdrawUnbet.root"),
                _a(".withdrawUnbet.nullifierHash"),
                _a(".withdrawUnbet.changeCommitment"),
                _a(".withdrawUnbet.withdrawData")
            )
        );
    }

    function _settleCall() internal view returns (bytes memory) {
        return abi.encodeCall(
            EncryptedParimutuelPool.publishFinalTotals,
            (ENCRYPTED_MARKET_ID, _e(".total"), 0, _dec("yes"), _dec("no"))
        );
    }

    // -----------------------------------------------------------------------
    // The invariants
    // -----------------------------------------------------------------------

    /// @notice Every unit of collateral the pool holds is accounted for, exactly.
    /// @dev The replacement for `collateralHeld == yesSupply == noSupply`. Collateral enters
    ///      only through `deposit` and leaves only through `withdraw`, and each updates its
    ///      counter in the same transaction as the transfer -- so the balance is a pure
    ///      function of the two counters, with no slack either way. Slack would mean either an
    ///      unrecorded payout or collateral stranded behind no note.
    function invariant_balanceEqualsDepositsMinusWithdrawals() public view {
        assertEq(
            usdc.balanceOf(address(pool)),
            (pool.totalDepositedUnits() - pool.totalWithdrawnUnits()) * DENOM,
            "pool balance drifted from its own deposit/withdrawal ledger"
        );
    }

    /// @notice The pool can never have paid out more than was ever put in.
    /// @dev Stated separately from the balance invariant because it is the one that survives a
    ///      donation: someone transferring USDC straight to the pool breaks nothing, but it
    ///      must not become spendable, and this bound is what says so.
    function invariant_neverPaysOutMoreThanDeposited() public view {
        assertLe(
            pool.totalWithdrawnUnits(),
            pool.totalDepositedUnits(),
            "cumulative payouts exceeded cumulative deposits"
        );
    }

    /// @notice A settled market never pays out more than its own published total.
    /// @dev The global bound alone would let one market drain another's collateral and only
    ///      trip once the pool was empty, with the loser being whoever withdrew last.
    ///      Per-market accounting localises the failure to the market that caused it.
    function invariant_settledMarketNeverOverdrawn() public view {
        if (!encrypted.settled(ENCRYPTED_MARKET_ID)) return;
        assertLe(
            pool.paidOutUnits(ENCRYPTED_MARKET_ID),
            encrypted.finalYesTotal(ENCRYPTED_MARKET_ID) + encrypted.finalNoTotal(ENCRYPTED_MARKET_ID),
            "market paid out more than its settled total"
        );
    }

    /// @notice The recorded lifecycle is actually reachable through the handler.
    /// @dev Guards against the one failure mode this whole file is vulnerable to: if every
    ///      handler call reverted, all three invariants above would pass over a pool that never
    ///      moved -- green, and worth nothing. Driving the happy path in order, through the
    ///      same handler the fuzzer uses, proves the encoded calldata is live.
    function test_recordedLifecycleIsReachableThroughHandler() public {
        for (uint256 i = 0; i < 12; i++) {
            handler.perform(i); // deposit .. flushBatch(batch5)
        }
        assertGt(pool.totalDepositedUnits(), 0, "no deposit landed -- the encoded calldata is dead");

        // Warped directly rather than through `advanceTime`, whose whole job is to move the
        // clock by a FUZZED amount -- useless when the test needs one specific instant.
        vm.warp(resolutionStart);
        handler.resolveMarket();
        handler.settleMarket();
        assertTrue(encrypted.settled(ENCRYPTED_MARKET_ID), "market never settled through the handler");

        for (uint256 i = 12; i < 18; i++) {
            handler.perform(i); // redeemPrivate .. withdrawUnbet
        }
        assertGt(pool.totalWithdrawnUnits(), 0, "nothing ever left the pool -- invariants would be vacuous");
        assertGt(pool.paidOutUnits(ENCRYPTED_MARKET_ID), 0, "the settled market never paid out");
        assertGt(pool.paidOutUnits(NO_MARKET), 0, "the unbet exit was never reached");
    }

    // -----------------------------------------------------------------------
    // Fixture plumbing
    // -----------------------------------------------------------------------

    function _a(string memory k) internal view returns (uint256) {
        return actions.readUint(k);
    }

    function _e(string memory k) internal view returns (uint256) {
        return e2e.readUint(k);
    }

    function _dec(string memory side) internal view returns (EncryptedParimutuelPool.Decryption memory) {
        return EncryptedParimutuelPool.Decryption({
            dx: _e(string.concat(".", side, ".d[0]")),
            dy: _e(string.concat(".", side, ".d[1]")),
            proof: ChaumPedersen.Proof({
                ax: _e(string.concat(".", side, ".proof.ax")),
                ay: _e(string.concat(".", side, ".proof.ay")),
                bx: _e(string.concat(".", side, ".proof.bx")),
                by: _e(string.concat(".", side, ".proof.by")),
                z: _e(string.concat(".", side, ".proof.z"))
            })
        });
    }

    function _pA(string memory a) internal view returns (uint256[2] memory) {
        return [_a(string.concat(".", a, ".pA[0]")), _a(string.concat(".", a, ".pA[1]"))];
    }

    function _pB(string memory a) internal view returns (uint256[2][2] memory) {
        return [
            [_a(string.concat(".", a, ".pB[0][0]")), _a(string.concat(".", a, ".pB[0][1]"))],
            [_a(string.concat(".", a, ".pB[1][0]")), _a(string.concat(".", a, ".pB[1][1]"))]
        ];
    }

    function _pC(string memory a) internal view returns (uint256[2] memory) {
        return [_a(string.concat(".", a, ".pC[0]")), _a(string.concat(".", a, ".pC[1]"))];
    }

    function _ct(string memory a) internal view returns (uint256[4] memory) {
        return [
            _a(string.concat(".", a, ".ciphertext[0]")),
            _a(string.concat(".", a, ".ciphertext[1]")),
            _a(string.concat(".", a, ".ciphertext[2]")),
            _a(string.concat(".", a, ".ciphertext[3]"))
        ];
    }
}

/// @dev Executes one recorded action per fuzzer step. Reverts are swallowed on purpose: most
///      orderings are invalid and their rejection is the system working, not a finding. The
///      invariants are evaluated after every step regardless.
contract Handler {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ShieldedPool pool;
    MockERC20 usdc;
    EncryptedParimutuelPool encrypted;
    Vault encryptedVault;
    address resolver;
    uint64 resolutionStart;
    uint32 marketId;
    bytes[] calls;
    bytes settleCall;

    function init(
        ShieldedPool pool_,
        MockERC20 usdc_,
        EncryptedParimutuelPool encrypted_,
        Vault encryptedVault_,
        address resolver_,
        uint64 resolutionStart_,
        uint32 marketId_,
        bytes[] memory calls_,
        bytes memory settleCall_
    ) external {
        pool = pool_;
        usdc = usdc_;
        encrypted = encrypted_;
        encryptedVault = encryptedVault_;
        resolver = resolver_;
        resolutionStart = resolutionStart_;
        marketId = marketId_;
        calls = calls_;
        settleCall = settleCall_;
        usdc.approve(address(pool), type(uint256).max);
    }

    function perform(uint256 seed) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(pool).call(calls[seed % calls.length]);
        ok; // an invalid ordering reverting is the expected case
    }

    /// @dev Time is a fuzzed dimension, not a fixture. Betting closes at a deadline and
    ///      resolution opens at another, so a handler that could not move the clock would
    ///      leave half the state machine unreachable -- and a handler that jumped straight to
    ///      resolution would leave the other half unreachable instead.
    function advanceTime(uint256 seconds_) external {
        vm.warp(block.timestamp + (seconds_ % 3 days) + 1);
    }

    function resolveMarket() external {
        vm.prank(resolver);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) =
            address(encryptedVault).call(abi.encodeCall(Vault.resolve, (Vault.Outcome.Yes)));
        ok;
    }

    function settleMarket() external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(encrypted).call(settleCall);
        ok;
    }
}
