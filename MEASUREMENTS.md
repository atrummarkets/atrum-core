# Atrum — Phase 0 measurements

Everything here was measured by this repo's own tooling against **live Monad nodes**
on 30 July 2026, not copied from `nisi-master-reference.md`. Where our number
disagrees with the reference, both are shown and the disagreement is called out.

Labels follow the reference's convention:

| Label | Meaning |
|---|---|
| **[MEASURED]** | We ran it. Reproduce with the command given. |
| **[DERIVED]** | Arithmetic on our own measured values. Arithmetic shown. |
| **[UNVERIFIED]** | We could not confirm it. Do not rely on it. |
| **[CONTRADICTS]** | Our measurement disagrees with `nisi-master-reference.md`. |

Reproduce everything:

```bash
python3 tools/monad_gas.py all --network mainnet     # chain params + precompiles
python3 tools/measure_verifier.py --network mainnet  # the Phase 0 gate
cd circuits && node scripts/prove.mjs               # mechanism correctness
cd contracts && forge test --network monad          # Vault suite
```

---

## 1. The Phase 0 gate — PASSED

The build plan's stop-line: if a production-shaped BabyJubJub-ElGamal Groth16
verify exceeds **~1.5M gas**, stop and reassess the architecture.

| Circuit variant | Public signals | Verify gas | % of 1.5M budget | Verdict |
|---|---|---|---|---|
| `probe_fixed_key` (key compiled in) | 4 | **1,029,454** | 68.6% | **PASS** |
| `probe_pubkey_input` (key as input) | 6 | **1,090,965** | 72.7% | **PASS** |

[MEASURED] Identical on mainnet (143) and testnet (10143) — the gas schedule does
not differ between them. Both figures are the *warm* per-call cost; the verifier
was confirmed to **return `true`** before gas was recorded, so these are
acceptance-path costs, not rejection-path costs.

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

**Unbatched insertion does not fit:** 1,107,646 + 1,029,454 verify = **2,137,100 —
106% of the envelope.** Confirms the reference's "sequencer always batches" rule
with a hard number.

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

| | Ours | Reference | |
|---|---|---|---|
| `ecPairing` 0x08 (BN254) | **225,000 + 170,000k** | same | ok |
| `bls12_pairing` 0x0f | **37,700 + 32,600k** | same | ok |

[MEASURED] Linear fit **exact** across k=0..5 — five identical deltas, no residual.
BN254 pairing is repriced ~5x while EIP-2537 BLS12-381 is untouched. **The single
fact the whole architecture rests on reproduces perfectly.**

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
- Not yet measured: `ElGamalAccumulator` storage costs (the reference's ~68,000/bet
  single and ~2,375/bet batched figures). That is Phase 2 work and is the next
  number to nail down, because it is what makes batching mandatory.
- Not yet measured: end-to-end transaction gas including calldata and the nullifier
  tree. The gate covers verify only.

---

## 7. Verdict

**Phase 0's risk is killed.** The gate passes at 68.6% of budget on both networks,
with more headroom than the reference projected because the predicted 15–25%
production padding does not materialise. The curve choice (BN254 + BabyJubJub) is
confirmed as the right one, the 5x BN254 repricing is real and priced in, and the
homomorphic mechanism is demonstrated working rather than assumed.

Nothing measured here argues for reassessing the architecture. Proceed to Phase 1.
