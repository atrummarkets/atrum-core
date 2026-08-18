# Atrum — measurements, Phase 0 to Phase 2

Everything here was measured by this repo's own tooling against **live Monad nodes**
on 30 July 2026, not copied from `nisi-master-reference.md`. Where our number
disagrees with the reference, both are shown and the disagreement is called out.
Where a later measurement corrected an earlier claim *in this file*, that is called
out too — see the [CORRECTION] blocks in §1b and §3, and **§0 for the V2 corrections
of 18 August 2026, which change how several figures below must be read.**

Labels follow the reference's convention:

| Label | Meaning |
|---|---|
| **[MEASURED]** | We ran it. Reproduce with the command given. |
| **[SUPERSEDED]** | A later measurement overturned this. Both are shown, with the newer one authoritative. |
| **[DERIVED]** | Arithmetic on our own measured values. Arithmetic shown. |
| **[UNVERIFIED]** | We could not confirm it. Do not rely on it. |
| **[CONTRADICTS]** | Our measurement disagrees with `nisi-master-reference.md`. |
| **[CORRECTION]** | An earlier claim *in this file* was wrong. Both are shown. |
| **[DECIDED]** | An open design question, settled by a measurement below. |

Reproduce everything:

```bash
make circuits    # compile 5 circuits, Groth16 setup, export verifiers
make prove       # ElGamal mechanism correctness
make fixtures    # real deposit/bet/redeem proofs
make verifiers   # copy generated verifiers into contracts/src
make test        # 81 contract tests under the Monad gas schedule
make gate        # verify gas, all 5 verifiers, live chain
make uniformity  # anti-fingerprinting guard
make measure     # chain params + precompiles, live chain
```

Order matters on a clean checkout — the contract suite replays real proofs, so the
circuits and fixtures must exist before `make test`.

---

## 0. Corrections from the V2 measurement work, 18 August 2026

Four findings from `V2_EVIDENCE.md` change how figures in this file must be read. They are
here rather than only in that file so this document is not quietly wrong in isolation.

### 0.1 [SUPERSEDED] §1c's "local understates by 32–41%" does not generalise

§1c is correct for the workload it measured — `deposit`, `bet` and `betEncrypted`, all of
which cross five contracts and carry proof calldata. It does **not** describe storage-bound
code, where local forge runs the other way:

| Workload | Dominant cost | Local vs live |
|---|---|---|
| Cross-contract, calldata-heavy actions | call overhead, calldata | local **understates** 32–41% |
| Contiguous storage | cold SLOAD | local **overstates** ~2× |

"Local is a lower bound" is true for actions and **false** for storage sweeps. Never apply a
fixed multiplier without first asking which kind of code is being measured.

### 0.2 [CONTRADICTS §3] Contiguous slots are nearly free on the live chain

§3's `[UNVERIFIED]` note on local cold *account* access flagged that local numbers should
not be trusted without checking. Checked, and the gap is larger than that note implies.

`SlotProbe` (`contracts/src/probe/SlotProbe.sol`), live marginal cost per slot:

| | reads | writes |
|---|---|---|
| Contiguous (consecutive slots) | **261** | **252** |
| Scattered (keccak-derived mapping keys) | **8,357** | **11,174** |

Scattered reproduces the documented 8,100 cold SLOAD plus ~257 loop overhead; contiguous
reproduces the loop overhead and nothing else. Four sizes, two independent RPCs, exact
agreement.

`ElGamalAccumulator`'s comment states that MIP-8 page-sharing "does not" explain the extended
cost and that "Monad charges the full per-slot surcharge", citing `StorageContiguity.t.sol`.
That test is local. On the chain, adjacency is discounted ~32×.

**This did NOT change the affine-versus-extended decision.** Re-measured directly, live, same
market, same ciphertext, cold slots:

| | Live |
|---|---|
| `accumulateExtended` — 8 slots, no inversion | 149,151 |
| `accumulateAffine` — 4 slots, one `modexp` | **123,722** |

Affine still wins by 25,429. **`accumulateAffine` remains the production path.** A derivation
from `SlotProbe` predicted the opposite and was wrong: the flat-array result does not transfer
to a struct at a keccak-derived base inside a nested mapping, and the shape under which the
discount applies is **not established**. Do not settle a layout question from `SlotProbe`;
measure the real contract.

### 0.3 [MEASURED] A receipt reports the DECLARED gas limit, not gas used

The same call broadcast at three declared limits:

| Declared | Receipt `gasUsed` | Status |
|---|---|---|
| 12,000,000 | 12,000,000 | success |
| 3,000,000 | 3,000,000 | success |
| 200,000 | 200,000 | success |

This follows from Monad charging the declared limit — the property `ActionGasPolicy` is built
around — but its measurement consequence was undocumented. **The live figures in §1c and §1e
are unaffected**, because `forge script` derives its limit from `eth_estimateGas`. The trap is
a manual `cast send --gas-limit`, whose receipt means nothing.

Measure with `eth_estimateGas`, and prefer marginal cost across two sizes.

### 0.4 [SUPERSEDED] `deposit` no longer has 3 public signals

The build-hash guard (`make bind`) reports `DepositVerifier` at **`nPublic = 2`**. This file
records 3 signals at 998,574 gas in §1, §1c and §5.

The per-signal figure confirms which is stale: `bet` at 4 signals costs 1,029,454, and
30,756 × 1 subtracted gives 998,698 — within 124 gas of the recorded 998,574. **That
measurement was taken against a 3-signal deposit circuit which no longer exists.** At 2
signals the verifier should cost roughly 967,900.

**Every `deposit` verify figure in this document is stale until `make gate` is re-run.**
Rows are left in place rather than deleted so the discrepancy stays visible.

---

## 1. The Phase 0 gate — PASSED

The build plan's stop-line: if a production-shaped BabyJubJub-ElGamal Groth16
verify exceeds **~1.5M gas**, stop and reassess the architecture.

| Circuit variant | Public signals | Verify gas (warm) | Cold first call | % of 1.5M budget | Verdict |
|---|---|---|---|---|---|
| `probe_fixed_key` (key compiled in) | 4 | **1,029,454** | 1,039,706 | 68.6% | **PASS** |
| `probe_pubkey_input` (key as input) | 6 | **1,090,965** | **1,101,216** | 72.7% | **PASS** |
| `deposit` | 3 | **998,574** | 1,008,826 | 66.6% | **PASS** — [SUPERSEDED, see §0.4: the artifact now has 2 signals] |
| `bet` | 4 | **1,029,454** | 1,039,706 | 68.6% | **PASS** |
| `redeem` | 4 | **1,029,454** | 1,039,706 | 68.6% | **PASS** |

[MEASURED] Identical on mainnet (143) and testnet (10143) — the gas schedule does
not differ between them. Each verifier was confirmed to **return `true`** before gas
was recorded, so these are acceptance-path costs, not rejection-path costs. A Groth16
verifier returns `false` for a bad proof without reverting, so measuring a rejected
proof yields a plausible number that means nothing.

Verify cost depends only on the public-signal count, not circuit size: `bet` has 14,194
constraints against `probe_fixed_key`'s 6,834 and costs exactly the same to verify.
That is the property that makes the uniform action envelope achievable at all.

**The cold column matters and was previously unrecorded.** `ActionGasPolicy.sol` anchors
the envelope on **1,101,216**, citing this section — but only the warm 1,090,965 was
ever written down here. The cold figure is the one a declared transaction limit has to
cover, because the first touch of the verifier in a transaction pays Monad's ~10,100
cold-account charge. `tools/measure_verifier.py` emits it as
`verify_gas_cold_first_call`; it is now in the table.

### [CONTRADICTS] the reference's 15–25% production padding

> "My 1,031,828 is the verifier core; a production circuit adds field arithmetic
> and input validation. [ESTIMATE] +15% to 25%."

A real snarkjs-generated verifier with 4 public signals costs **1,029,454** —
**2,374 gas *less* than the core estimate (−0.2%)**, not 15–25% more. The predicted
padding does not exist.

Why: verify cost is almost entirely precompile cost (one `ecMul` per public input
plus one 4-pair `ecPairing`), and snarkjs emits tight assembly, so the surrounding
Solidity contributes almost nothing. **This buys back the entire safety margin the
reference reserved** — real headroom against the 1.5M gate is 32%, not ~10%.

### Cost per public input

**30,756 gas** [MEASURED], from the 4→6 signal delta (61,511 / 2).
[DERIVED] = `ecMul` 30,000 + `ecAdd` 300 + ~456 of dispatch. Consistent with the
reference's ~30,000/input guidance, so "keep public inputs ≤ 4" remains sound —
though at 30,756 each, the 6-input variant is affordable and buys committee-key
rotation without a new trusted setup. See §5.

---

## 1b. Phase 1 gate — the trees — PASSED, but only with subtree grafting

Phase 1's hidden risk was never the circuits; it was the commitment tree. Poseidon
is cheap *inside* a circuit and comparatively expensive *on-chain*, and every
insertion pays for one per tree level — against Monad's 8,100 cold SLOAD.

### Poseidon, on-chain [MEASURED]

| | Gas | Runtime bytecode |
|---|---|---|
| `Poseidon(2)` — commitment/nullifier hash | **28,980** | 9,743 B |
| `Poseidon(3)` | **45,085** | 12,463 B |

circomlib's generated contract. **Digests verified identical to `circomlibjs`** for
both arities before any gas figure was trusted — if on-chain and in-circuit hashes
diverged, every proof would fail while the gas numbers still looked fine.

### Subtree grafting is mandatory, not an optimisation

| Batch | Total gas | Per leaf | + verify | % of 2M envelope |
|---|---|---|---|---|
| 1 | 691,282 | 691,282 | 1,720,736 | 86% |
| 2 | 691,966 | 345,983 | 1,375,437 | 68% |
| 8 | 815,357 | 101,919 | 1,131,373 | 56% |
| 32 | 1,487,856 | 46,495 | 1,075,949 | 53% |
| **64** | **2,434,232** | **38,034** | **1,067,488** | **53%** |
| 128 | 4,356,852 | 34,037 | 1,063,491 | 53% |

[MEASURED] under `forge test --network monad`, whose pricing is validated against
the live chain for both precompiles and cold SLOAD (§3).

### [CORRECTION] "Unbatched insertion" was two different numbers

An earlier revision of this section quoted **1,107,646** in the text and **691,282**
in the table above for the same thing, reaching opposite conclusions (106% of the
envelope versus 86%). A third figure, **750,300**, appears in
`circuits/build/poseidon-gas.json` and in a comment in `IncrementalMerkleTree.sol`.

All three are real. They are three different quantities:

| Figure | What it actually is | Label |
|---|---|---|
| **1,107,646** | `insert()` on a fresh tree — the `_insertBatch` path, paying all 20 frontier slots cold | [MEASURED] |
| **691,282** | `insertSubtree([leaf])` — the grafting path at k=0, warm | [MEASURED] |
| **750,300** | `20 × 28,980 + 20 × 8,100` arithmetic, never executed | [DERIVED] |

Both measured figures reproduce exactly, and both are now asserted in
`IncrementalMerkleTree.t.sol` rather than printed, so neither can drift again.

**The conclusion is unchanged and holds on the higher figure:** a user action that
inserts its own commitment costs 1,107,646 + 1,029,454 verify = **2,137,100, 106% of
the envelope.** It does not fit. This is what forces the sequencer to batch, and it is
why `ShieldedPool` only queues a commitment and grafts separately.

Grafting a bottom-up subtree gives a **15.9x** reduction over the naive
per-leaf loop (38,034 vs 604,315 per leaf at N=64), because hash count drops from
`depth` per leaf to `(N-1 + depth - log2 N)/N` ≈ 1.2 per leaf.

**Correctness is tested, not assumed:** `insertSubtree` is asserted to produce
byte-identical roots to one-at-a-time insertion, for N = 1, 2, 8, 64 and across
consecutive batches. Without that the saving would be meaningless — batching would
be building a different tree while every off-chain Merkle proof was built against
the sequential shape.

Cost of grafting: batches must be a power of two **and** aligned to their own size,
so the sequencer pads partial batches. That padding is not waste — the batch *is*
the anonymity set, so a fixed size means a fixed anonymity set instead of one that
leaks how busy the market currently is.

### [CONTRADICTS] the reference's "indexed nullifier tree"

| Nullifier strategy | Gas per bet |
|---|---|
| `mapping(bytes32 => bool)`, one fresh SSTORE | **28,945** |
| Indexed Merkle tree insertion, depth 20 | **690,733** |
| **Saving** | **661,788** |

The reference specifies an indexed nullifier tree to keep on-chain state root-only.
At 28,980 gas per Poseidon that costs **24x** a mapping, and 661,788 gas per bet is
the difference between fitting the envelope and not.

An indexed tree earns its cost only if non-membership must be proved *in-circuit*.
Plain double-spend prevention needs set membership, which a mapping gives directly.
**Recommendation: mapping for nullifiers, Merkle tree only for commitments.** The
tradeoff accepted is unbounded state growth (one slot per nullifier, forever) versus
661,788 gas per bet — revisit only if state rent ever appears on Monad.

### Resulting architecture [DERIVED from the above]

Per-user action transaction:

| Component | Gas |
|---|---|
| Groth16 verify | 1,029,454 |
| Nullifier mapping write | 28,945 |
| **Subtotal** | **1,058,399** |
| Uniform envelope | 2,000,000 (53%) |

Commitment insertion is **not** in the user's transaction — the sequencer grafts
subtrees separately at 2,434,232 per 64 leaves. That keeps the user's action cheap
and uniform, and matches the reference's "sequencer maintains the trees".

Note the tx gas limit is 30,000,000, so at ~1.03M per verify a single transaction
can hold at most ~28 proofs. Batch size is therefore bounded by the transaction
limit, not the block limit, if proofs are ever aggregated into one transaction.

**Envelope decision deferred:** at 53% utilisation, 2M wastes ~940,000 gas on every
action, and Monad charges the declared limit. Tightening to ~1.4M looks right once
the Phase 2 ElGamal accumulator cost is measured — that is the last unknown, and
raising the envelope later is publicly observable, so it should only be set once.

---

## 1c. Phase 1 — the actions, measured end to end [MEASURED]

Everything above measures components. This measures the real thing: a full
`deposit → bet → redeem` lifecycle through `ShieldedPool`, with real Groth16 proofs
generated by `circuits/scripts/gen_action_fixtures.mjs` running through the real
snarkjs-generated verifiers.

Reproduce: `make circuits && make fixtures && make verifiers && make test`

| Action | Gas | % of 2,000,000 envelope |
|---|---|---|
| `deposit` | **1,378,641** | 69% |
| `bet` | **1,165,715** | 58% |
| `redeem` | **1,137,382** | 57% |
| Sequencer `flushBatch(64)` | **2,791,576** (43,618/leaf) | separate tx, 9% of the 30M tx limit |

`deposit` is the most expensive despite having the *cheapest* verifier (998,574, three
public signals) because it also moves ERC20 collateral and calls `Vault.split`. Verify
cost is not the dominant term once an action does real work.

**Nothing here is mocked.** Earlier phases could measure a verifier in isolation; these
numbers only mean something if the proofs actually verify against the deployed
verifiers, the packing layout agrees between circom and Solidity, and the contract's
Merkle root equals the one the prover built its path against. That last one is asserted
directly in `test_contractRootMatchesProverRoot`.

### [MEASURED] Real testnet transactions — and local is optimistic by 30–60%

Deployed to Monad testnet (chain 10143) on 30 July 2026 and exercised end to end.
Deployment and exercise receipts are in `contracts/broadcast/`.

| Contract | Address |
|---|---|
| `ShieldedPool` | `0x2E6603e2c5B3DeDD4910bd38D41B740675a2Af32` |
| `IncrementalMerkleTree` | `0xd4ae7009f8B60685DEAA1a827670ce5F6Cc8c441` |
| `ParimutuelPool` | `0xD184083A3BF95D52de74143edBe74dc80B745501` |
| `MappingNullifierSet` | `0x13EEad89A13358e7e3F2e106Fa1b24d0eA3A8Dc7` |
| `Vault` | `0xd42dbe0b1373B0FBBb78E01a9489362187858a7f` |
| `PoseidonT3` | `0x05A74dc13A6E4B2E166393558357485bD76bBf3c` |
| `DepositVerifier` / `BetVerifier` / `RedeemVerifier` | `0x55d098…39F3` / `0x9cE77A…f175` / `0xc1d8ef…fF03` |

**The on-chain root after grafting equalled the root the prover built its Merkle path
against**, exactly:
`15091044500897788679743006247934363757548094238705679309755141770701367595051`.
Three independent implementations of the same hashing rules — circom, Solidity and the
sequencer's TypeScript mirror — agree on a live chain.

| Action | `forge --network monad` | **Live testnet** | Δ | % of 2,000,000 envelope |
|---|---|---|---|---|
| `deposit` | 1,378,641 | **1,816,031** | +32% | **91%** |
| `bet` | 1,165,715 | **1,633,573** | +40% | **82%** |
| `queuePadding(63)` | — | 2,567,903 | — | sequencer tx |
| `flushBatch(64)` | 2,791,576 | **4,439,006** | +59% | sequencer tx |

**[CONTRADICTS] our own §1b figures, and it matters.** Local pricing is validated
against the live chain for precompiles and cold SLOAD, but §3 already flagged that
local cold *account* access is wrong (~18,000 local versus 10,252 live) and warned
that "local numbers for cross-contract call overhead should not be trusted without
checking". This is that warning, quantified. A `deposit` crosses five contracts — pool,
verifier, collateral, vault, and vault-to-collateral again — plus intrinsic cost and
~400 bytes of proof calldata that `forge` does not charge at all.

**Consequence for the envelope, and it reverses a pending decision.** §1b and
`HANDOFF.md` §7.1 both proposed tightening the uniform envelope from 2,000,000 to
~1,400,000 on the grounds that actions were running at ~55%. On real transactions
`deposit` is **1,816,031 — 91% of 2,000,000**. Tightening to 1.4M would have made every
deposit revert.

**The envelope stays at 2,000,000, and the remaining headroom is ~184,000 gas, not
~900,000.** Phase 2's ElGamal accumulator has to fit inside that. Raising the envelope
later is publicly observable and shrinks the anonymity set of everything submitted
before it, so if the accumulator does not fit, the answer is to optimise the action —
most obviously by moving `Vault.split` out of `deposit` — rather than to move the
envelope.

**Measure on-chain before setting any privacy-critical constant.** The local number
would have been wrong by 437,390 gas in the direction that breaks things.

Not yet exercised on testnet: `redeem`. `Vault.MIN_RESOLUTION_GAP` enforces at least an
hour between betting close and resolution — deliberately, so a last-second bet cannot
front-run an already determined outcome — and there is no way to skip that on a live
chain. It is covered locally by `test_fullLifecycle_depositBetResolveRedeem`, and its
verifier is measured in §1.

## 1e. Phase 2 — the encrypted bet, wired and measured [MEASURED]

`bet_encrypted.circom` existed since 30 July but had **never produced a real proof**: it
required a powers-of-tau file of power 15 and only 13 and 14 were present, so there was
no zkey, no verifier, and the 8-public-signal verify cost was an extrapolation. It is now
compiled, proved, wired into `ShieldedPool.betEncrypted`, and measured.

Reproduce: `make circuits && make fixtures && make verifiers && make test && make gate`

### Circuit

| | |
|---|---|
| Constraints | **21,252** (HANDOFF estimated 21,250) |
| Public signals | **8** — `root, nullifierHash, newCommitment, betMeta, c1[2], c2[2]` |
| ptau power | **15** (32,768 ceiling, ~65% utilised) |

Power 14 was not an option: 21,252 clears its 16,384 ceiling. `bet_encrypted` is now in
`circuits/scripts/build.sh`'s pipeline, so `make circuits` builds it like any other.

### [MEASURED] The 8-signal verify — the number that was an extrapolation

| Verifier | signals | warm | cold first call | % of 1.5M gate |
|---|---|---|---|---|
| `BetEncryptedVerifier` | 8 | **1,152,559** | **1,162,809** | 76.8% — **PASS** |
| `BetVerifier` | 4 | 1,029,454 | 1,039,706 | 68.6% |

**Confirms the extrapolation almost exactly.** `HANDOFF.md` predicted ~1,155,000 against
a measured 1,152,559 warm. The four extra signals cost **123,105 gas — 30,776 each**,
a third independent confirmation of the ~30,756 per-signal figure.

`ActionGasPolicy.MAX_MEASURED_VERIFY_GAS` moved from 1,101,216 to **1,162,809**, the new
worst cold verify. The CI uniformity guard caught the stale constant on the first run
rather than needing anyone to remember — it is wired to fail exactly this way.

### [MEASURED] The wired action, locally

| Action | `forge --network monad` | Δ vs plaintext `bet` |
|---|---|---|
| `bet` (Phase 1) | 1,173,880 | — |
| `betEncrypted` (Phase 2) | **1,352,807** | **+178,927** |

The delta decomposes as verify (+123,105) plus the affine accumulator (~122,000 cold)
minus the `parimutuel.addStake` the encrypted path no longer performs. That is
consistent with the accumulator's own standalone gate figure of 122,270 cold.

**The accumulator slots really are cold here**, which is the measurement mistake §1d
records making once already: `registerEncryptedMarket` writes them in `setUp`, so the
test body is a fresh transaction, and nothing in the plaintext lifecycle preceding it
touches the accumulator.

### [MEASURED] It fits on a real transaction — the gate is now closed

Broadcast on Monad testnet on 31 July 2026. Full transaction record with explorer
links: [`PHASE2_TESTNET_REPORT.md`](PHASE2_TESTNET_REPORT.md).

| Action | local `forge` | **live testnet** | Δ | % of 2,000,000 |
|---|---|---|---|---|
| `deposit` | 1,378,641 | 1,816,159 | +32% | 91% |
| `bet` | 1,173,880 | 1,644,303 | +40% | 82% |
| **`betEncrypted` (cold accumulator)** | 1,352,807 | **1,904,506** | **+41%** | **95.2%** |
| `betEncrypted` (warm accumulator) | — | 1,859,677 | — | 93.0% |

**It fits, with 95,494 gas to spare.** The envelope stays at 2,000,000.

The estimates written here before broadcasting were 1,825,000 (additive) and 1,883,000
(multiplicative), i.e. 91–94%. The real figure is 1,904,506 — **both estimates erred
optimistically**, the same direction as the 437,390-gas error §1c records. Local
reasoning about this chain's costs keeps landing short; only broadcasting settles it.

`deposit` reproduced at 1,816,159 against the 1,816,031 measured on the previous
deployment — 128 gas apart, which is a useful check that the methodology is stable.

One correction worth recording: `HANDOFF.md` §7.1's stated fallback — "if the
accumulator does not fit, move `Vault.split` out of `deposit`" — **does not apply to
this action.** `betEncrypted` never calls `Vault.split`; that cost belongs to `deposit`.
Had the number landed over budget, the stated fallback would not have helped, and the
obvious alternative is already ruled out: hashing the ciphertext to save 3 public
signals (~92,000) costs ~87,000 in on-chain Poseidon, a wash. Worth keeping in mind at
95.2% utilisation — there is no cheap lever in reserve for this action.

### [MEASURED] Settlement, and a check neither source document specifies

`publishFinalTotals` costs **2,410,578** gas on testnet — two Chaum-Pedersen verifies
plus two plaintext bindings, once per market at settlement. It is above the 2,000,000
action envelope and correctly so: it is a public publisher transaction, not a shielded
action, so the anti-fingerprinting uniformity rule does not apply to it.

**Chaum-Pedersen alone does not bind a claimed total to a ciphertext.** It proves the
decryption share came from the committee key and nothing more. A publisher can pair an
honest share and a valid proof with a fabricated total. Demonstrated on-chain: a claim
of 1275 against a true 425 reverted with `ClaimedPlaintextMismatch` (`0x3923e9b5`),
**not** `InvalidDecryptionProof` — the proof verified; only the `C2 - D = [m]G` binding
caught it. With the binding removed in a local mutation test, the same input settles
the market at 1275.

`nisi-master-reference.md` §V6 and `HANDOFF.md` both treat the decryption proof as
sufficient. It is not, and the gap is silent.

### [DECIDED] Nullifiers — mapping, and not only on gas

`atrum-build-plan.md` §7 specifies an indexed nullifier tree. Both were built behind
`INullifierSet` and measured inside a real action:

| Strategy | Spend gas | Action total | % envelope |
|---|---|---|---|
| `MappingNullifierSet` | **29,107** | 1,058,561 | 52% |
| `TreeNullifierSet` | **632,196** | 1,661,650 | 83% |

The 603,089 gas gap is the smaller half of the finding. The larger half:
**a Merkle accumulator cannot answer `isSpent` at all.** It proves membership;
rejecting a double-spend requires proving *non*-membership, which a root cannot
witness. `test_treeSilentlyAcceptsTheSameNullifierTwice` demonstrates the resulting
double-spend rather than asserting it in prose.

A true indexed Merkle tree solves this with sorted low-leaf links and an **in-circuit**
non-membership proof — a larger circuit and a bigger proving key, on top of the
603,089 gas. It earns that only if some circuit needs in-circuit non-membership for
another reason. Nothing in Phase 1 or Phase 2 does.

**Decision: mapping.** `TreeNullifierSet` is kept rather than deleted, because
`ShieldedPool`'s constructor refuses any set whose `enforcesOnChain()` is false — and
keeping the loser makes that guard something a test can exercise instead of a comment.
Accepted tradeoff: unbounded state growth, one slot per nullifier forever. Revisit only
if state rent appears on Monad.

### [MEASURED] Public inputs, confirmed a third time

| Verifier | Public signals | Verify gas |
|---|---|---|
| `deposit` | 3 → **2** [SUPERSEDED §0.4] | 998,574 |
| `bet` / `redeem` | 4 | 1,029,454 |
| `probe_pubkey_input` | 6 | 1,090,965 |

3→4 costs 30,880; 4→6 costs 61,511 (30,756 each). Consistent across five independently
generated verifiers, which is why `bet` and `redeem` pack marketId, outcome, units and
recipient into single field elements rather than spending a signal on each.

### [MEASURED] Anti-fingerprinting guard now covers actions

`make uniformity` previously checked only the two Phase 0 probes. It now covers all
five verifiers:

```
ok   PubKeyInputVerifier       1,101,216   headroom    898,784
ok   FixedKeyVerifier          1,039,706   headroom    960,294
ok   BetVerifier               1,039,706   headroom    960,294
ok   RedeemVerifier            1,039,706   headroom    960,294
ok   DepositVerifier           1,008,826   headroom    991,174
worst measured action  1,101,216      utilisation 55.1%      actions/block 75
PASSED -- all actions fit one uniform declared gas limit
```

The rule is about the **declared** limit, not gas used. The three actions genuinely
cost different amounts (1,378,641 / 1,165,715 / 1,137,382); they must all be submitted
declaring 2,000,000, because Monad charges the declared limit and that field is public.
A snug per-action limit would identify which private action a user took while the proof
stayed sealed.

---

## 1d. Security review — one critical vulnerability, found and fixed

An independent review of the Phase 1 branch. Circuits, contracts, nullifier sets and
the sequencer were read line by line, and every gas claim was re-measured rather than
taken from the commit message. **All action gas figures reproduced exactly.** One
critical vulnerability was found.

### [CRITICAL, FIXED] `queuePadding` let the sequencer drain the entire vault

`ShieldedPool` exposed `queuePadding(uint256[])`, letting the sequencer push arbitrary
field elements onto the same commitment queue `deposit` writes to. Its comment
asserted:

> "Fillers are unspendable by construction -- no one, including the sequencer, can
> produce a bet proof for a note that was never funded through `deposit`, because the
> deposit circuit is what binds a commitment to paid collateral."

**That was false.** `deposit.circom` binds commitment to amount *for deposits*, but
nothing forced every leaf in the tree to have originated from a deposit — and
`redeem.circom` proves only Merkle membership, the nullifier hash, and injective
packing. It never checks provenance.

So a filler whose secrets the sequencer knew was a fully spendable note. With
`outcome = 0` it took the unbet-refund branch of `_owedUnits`, which pays `units` 1:1
without consulting the parimutuel pool at all.

**Demonstrated, not argued.** `circuits/scripts/gen_padding_exploit.mjs` produced a
real Groth16 redeem proof for a note that was never deposited, verified by snarkjs, and
replayed through the real verifier:

| | |
|---|---|
| Collateral deposited by honest users | 5,000,000,000 |
| Collateral deposited by attacker | **0** |
| Attacker received | **5,000,000,000** |
| Pool complete sets remaining | 0 |

Theft was bounded by what the pool held (`Vault.redeem` reverts otherwise), so it was
not unlimited minting — it was appropriation of other depositors' collateral, up to the
whole vault. Honest depositors were then unpayable.

**This broke the documented trust model.** `atrum-build-plan.md` states a broken
sequencer "can't steal funds, only halt the market" — safety was not supposed to depend
on it. The shipped sequencer used uniform random field elements and did not exploit
this; the contract permitted it, so a compromised sequencer key was a full drain.

### The fix, and why it is free

`queuePadding` is removed. `flushBatch` now derives the remainder of the subtree
itself:

```
filler = keccak256(PAD_DOMAIN, treeStart, slot) % FIELD_SIZE
```

Nobody chooses a filler, so nobody knows a note preimage for one. `treeStart` is unique
per batch, so two batches can never derive the same value.

**Privacy cost: none.** The old justification for sequencer-chosen random fillers was
that padding must be indistinguishable from real commitments. That never held — in
Phase 1 every real action is a public `deposit` or `bet` transaction, so an observer
already knows exactly which leaves are real. Padding only ever bought liveness, which
derived fillers buy equally well.

**Gas cost: negative.** [MEASURED] `flushBatch(64)` went **2,791,576 → 2,788,274**.
Submitting one real leaf instead of 64 saves more calldata than 63 keccaks cost. Action
gas is unchanged: deposit 1,378,641 / bet 1,165,715 / redeem 1,137,360.

keccak rather than Poseidon deliberately: a filler is never hashed in-circuit, so it
does not need to be ZK-friendly, and Poseidon would cost 28,980 gas per filler against
roughly 100.

The derivation now exists in three implementations — `ShieldedPool._derivedFiller`,
`circuits/scripts/atrum.mjs`, and `sequencer/src/tree.ts`. All three were checked to
produce identical values, and `test_derivedFillerMatchesJsMirror` asserts contract
against mirror, because a silent divergence would break every Merkle path with no
diagnostic.

`contracts/test/PaddingExploit.t.sol` is kept as a regression test: it now asserts the
attack is unreachable rather than that it works.

### [MEASURED] Field aliasing is blocked — but by the verifier, not by us

Circom signals are BN254 scalar field elements, so `x` and `x + r` are the SAME element
and any in-circuit constraint satisfied by one is satisfied by the other. Solidity does
uint256 arithmetic and has no such equivalence. If a verifier accepted `x + r`:

- `_unpackBetData(betData + r)` would mask out a different `units`, inflating a stake
  from a note worth far less; and
- `nullifierHash + r` would be a **different key** in the spent-nullifier mapping while
  proving the same note — an unlimited double-spend.

Both are rejected, and `contracts/test/FieldBoundary.t.sol` proves it for every public
signal of both action verifiers. But they are rejected by the snarkjs-generated
verifier's `checkField`:

```solidity
function checkField(v) { if iszero(lt(v, r)) { mstore(0, 0) return(0, 0x20) } }
```

**That is an external dependency doing safety-critical work.** The tests exist so that
if anyone ever swaps in a hand-written or gas-optimised verifier that drops the check,
CI fails there instead of the pool draining quietly.

### Reviewed and found sound

| Component | Finding |
|---|---|
| `note.circom` packing | Injective. `units` 64-bit, `outcome` 2-bit, `marketId` 32-bit, `recipient` 160-bit, all range-constrained |
| `bet.circom` | Spent note's outcome hardcoded to 0, so a position cannot be re-bet after news lands. New commitment forced to differ from old |
| `redeem.circom` | `recipient` bound in-circuit — a mempool watcher cannot swap in their own address |
| `merkle.circom` | `DualMux` constrains the path bit boolean *inside* the template; root equality enforced |
| `ParimutuelPool` | Solvency correct: payouts sum to `winning × total / winning = total`, truncation only rounds down, dust retained |
| `MappingNullifierSet` | One-time irreversible `bindPool`, only-pool `spend` |
| `ShieldedPool` constructor | Refuses a nullifier set that cannot enforce `isSpent` on-chain |
| Action ordering | Nullifier burned before every external call |

### [CORRECTION] A measurement mistake of our own

The first run of the new checkup reported `bet` at 2,137,211 gas — over the envelope.
That was the measurement, not the contract. Fixture reads are `vm.parseJson`
cheatcodes and cost real gas; left inline as call arguments they land inside the
`gasleft()` bracket. The inflation was ~971,000 gas, almost exactly one Groth16 verify,
which reads convincingly like a contract problem. Hoisted out, `bet` is 1,147,713.

`ShieldedPool.t.sol` already carried a comment warning about this. Heed it: **always
hoist cheatcode calls out of a measured region.**

---

## 2. Chain parameters [MEASURED]

Monad mainnet, chain 143, at block 91,560,339:

| Parameter | Measured | Reference | |
|---|---|---|---|
| Chain ID | 143 | 143 | ok |
| Block gas limit | 150,000,000 | 150,000,000 | ok |
| Base fee | 100 gwei (at floor) | 100 gwei | ok |
| Block utilisation | 7.39% | ~4% | same order; still nearly empty |
| Txs in sampled block | 16 | 7 | both tiny — see anonymity-set note below |

Testnet is chain 10143. Confirmed reachable and on the same gas schedule.

**Utilisation is a demand signal, not just cheap blockspace.** At 7% full, blockspace
is abundant *because little is happening*. This is the reference's §11 risk showing
up in a measurement.

---

## 3. Precompiles [MEASURED]

`python3 tools/monad_gas.py precompiles --network mainnet`

| Precompile | Ours | Reference | |
|---|---|---|---|
| `ecRecover` 0x01 | 6,000 | 6,000 | ok |
| `ecAdd` 0x06 | 300 | 300 | ok |
| `ecMul` 0x07 | 30,000 | 30,000 | ok |
| `bls12_g1_add` 0x0b | 375 | 375 | ok |
| `bls12_g2_add` 0x0d | 600 | 600 | ok |
| `p256_verify` 0x0100 | 6,900 | 6,900 | ok |
| `modexp` 0x05, 256-bit inverse | **4,048** | 4,712 | **[CONTRADICTS]** |

### Pairings — the central asymmetry, confirmed

| | Ours | Reference | Label | |
|---|---|---|---|---|
| `ecPairing` 0x08 (BN254) | **225,000 + 170,000k** | same | [MEASURED] | ok |
| `bls12_pairing` 0x0f, slope | **32,600** | same | [MEASURED] | ok |
| `bls12_pairing` 0x0f, base | **37,700** | same | **[DERIVED]** | see below |

BN254: [MEASURED], linear fit **exact** across k=0..5 — six points, five identical
deltas, no residual. BN254 pairing is repriced ~5x while EIP-2537 BLS12-381 is
untouched. **The single fact the whole architecture rests on reproduces perfectly.**

### [CORRECTION] the BLS12-381 base is derived, not measured

An earlier revision labelled both pairing rows [MEASURED] "exact across k=0..5". For
BLS12-381 that is not true: the k=0 probe fails, returning

> `inner call consumed all forwarded gas -- it reverted; input is invalid for this target`

An empty input is not a valid `bls12_pairing` call, so only k=1..5 are measured — four
deltas, all exactly 32,600. The base of 37,700 is extrapolated from the fit
(70,300 − 32,600), which agrees with the reference but is [DERIVED], not observed. It
is also not load-bearing: nothing in Atrum calls `bls12_pairing`, since moving the
verifier to BLS12-381 would break the BabyJubJub field alignment the circuits depend on.

### [CONTRADICTS] modexp

We measure **4,048**, the reference says 4,712. Ours is exactly `16 × 253`, which is
EIP-7883's formula (`multiplication_complexity` 16 for ≤32-byte operands ×
`iteration_count` = `bit_length(p−2) − 1` = 253, no `/3` divisor). Our zero-length
probe also returned exactly **500**, EIP-7883's raised minimum. Both are consistent
with this chain implementing EIP-7883, so we trust our figure.

**Not blocking.** `modexp` is only needed for field inversion, and the accumulator
design mandates no inversion in the hot path. Recorded for completeness.

### [MEASURED] Local forge pricing is trustworthy — with the right flag

`forge test --network monad` versus the same tests without the flag:

| | `--network monad` | no flag | real Monad |
|---|---|---|---|
| `ecMul` | 30,383 | **6,393** | 30,000 |
| `ecPairing` k=1 | 395,391 | **79,408** | 395,000 |
| cold SLOAD | **8,115** | **2,115** | 8,100 |

Without the flag the local EVM reports **Ethereum's prices** — BN254 understated
~5x and cold SLOAD ~4x. With it, both match the live chain to within ~390 gas of
opcode overhead, so local measurement is valid for tree work.

Guarded by `PrecompileRepricing.t.sol` and `StorageRepricing.t.sol`, which **fail**
if the flag is missing.

[UNVERIFIED] One discrepancy: local cold *account* access measured ~18,000, while
the live chain shows 10,252 (matching the documented 10,100). The live figure is
treated as authoritative. It is a per-call constant, not per-tree-level, so it does
not affect tree design — but it means local numbers for cross-contract call
overhead should not be trusted without checking.

### [MEASURED] Cold account access ≈ 10,100 — confirmed indirectly

The first call to an injected contract cost **+10,252** over the warm marginal cost.
That matches the documented 10,100 cold-account charge (4x Ethereum's 2,600) plus
~150 of dispatch. Precompiles show only a ~250 premium, i.e. **precompiles are
exempt from the cold-account charge**.

This is why `tools/monad_gas.py` uses marginal cost (`gas(N=2) − gas(N=1)`) rather
than a single absolute reading — a naive reading silently bakes in 10,100 gas.

---

## 4. Mechanism correctness [MEASURED]

`cd circuits && node scripts/prove.mjs` — all checks pass.

Beyond `snarkjs verify` (which only says the witness satisfied *some* constraint
system), the circuit's outputs were recomputed independently with `circomlibjs`:

| Check | Result |
|---|---|
| Groth16 proof verifies (both variants) | pass |
| Circuit `C1` matches independent computation | pass |
| Circuit `C2` matches independent computation | pass |
| Decrypt round-trip recovers plaintext | pass |
| Tampered public signal is rejected | pass |
| **`Enc(50) + Enc(20)` decrypts to `70`** | **pass** |
| Published ratio = YES 70% | pass |
| Zero plaintext round-trips (identity edge case) | pass |

The homomorphic row is the load-bearing one: it is what lets the accumulator total
the pool with two point additions and never a decryption. The reference's worked
example (§3) now has a passing test behind it.

### Circuit size and proving time

| | `probe_fixed_key` | `probe_pubkey_input` |
|---|---|---|
| Non-linear constraints | 6,834 | 6,840 |
| Linear constraints | 222 | 216 |
| Wires | 7,056 | 7,058 |
| Public signals | 4 | 6 |
| Verifier runtime bytecode | 1,635 B | 1,817 B |

[MEASURED] Proving time **995 ms median** (5 runs: 967/988/995/1033/1409 ms),
snarkjs WASM in Node 24 on this machine. Browser proving will be slower; treat
~1s as a floor, not a target. Well inside a usable UX budget, and the circuit is
small enough (~6.8k constraints) that a power-13 ptau suffices.

---

## 5. [DERIVED] Throughput and cost, from our own numbers

Using our measured 1,029,454 gas/verify and the measured 150M block limit:

| | Value | Arithmetic |
|---|---|---|
| Proofs per block | **145** | 150,000,000 / 1,029,454 |
| Proofs per second | **485** | 145 / 0.3s block time |
| Cost per proof at floor | **0.103 MON** | 1,029,454 × 100 gwei |

Matches the reference's derived 484/sec. **Verification throughput is not the
constraint** — the reference's conclusion holds on our own measurements.

---

## 6. Open items

- [UNVERIFIED] Full `snarkjs powersoftau verify` on `powersOfTau28_hez_final_13.ptau`
  did not complete within our timeout. The file is the published Hermez ceremony
  output and setup succeeded against it, but we have **not** independently verified
  the ceremony transcript. Do that before any deployment that holds value.
- The Phase 0 zkeys have a **single phase-2 contribution made by this machine**.
  Whoever holds that randomness can forge proofs. Measurement-only; a real
  deployment needs a multi-party ceremony.
- The committee key in `circuits/build/committee-key.json` is a **test key** with a
  known secret. Phase 2 ships a single disclosed key by design; Phase 3 replaces it
  with 3-of-5 threshold decryption.
- The Phase 1 zkeys carry the same **single phase-2 contribution** problem, and
  `bet`/`redeem` additionally use `powersOfTau28_hez_final_14.ptau`, whose transcript
  is unverified for the same reason as power 13.
- Not yet measured: `ElGamalAccumulator` storage costs (the reference's ~68,000/bet
  single and ~2,375/bet batched figures). Phase 2 work, and the last number needed
  before the envelope can be finalised.
- ~~Not yet measured: end-to-end transaction gas.~~ **Now measured — see §1c.**
- Not yet measured: real testnet transaction gas including calldata and intrinsic
  cost. Everything in §1c is `forge --network monad`, whose pricing is validated
  against the live chain but which does not charge calldata or the 21,000 intrinsic.

---

## 7. Verdict

**Phase 0's risk is killed.** The gate passes at 68.6% of budget on both networks,
with more headroom than the reference projected because the predicted 15–25%
production padding does not materialise. The curve choice (BN254 + BabyJubJub) is
confirmed as the right one, the 5x BN254 repricing is real and priced in, and the
homomorphic mechanism is demonstrated working rather than assumed.

**Phase 1 is built and fits.** All three actions verify real proofs and land between
57% and 69% of the envelope, with the worst declared cost at 55.1%. The commitment
tree, the nullifier decision and the batching requirement are each settled by a
measurement rather than by the plan's estimate — and in two cases the measurement
overturned the plan (mapping over indexed tree; padding does not exist).

What is **not** settled: redemption is still public, which per `atrum-build-plan.md`
makes the privacy claim false rather than degraded. Until Phase 2 moves it inside the
pool, the honest description is *anonymous-participant parimutuel market*, not
*private prediction market*.

Nothing measured here argues for reassessing the architecture. Proceed to Phase 2.
