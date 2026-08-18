# V2 — the evidence register

Every measurement taken while designing V2, and the decision each one supports.

Labels follow `MEASUREMENTS.md`: **[MEASURED]** we ran it, **[DERIVED]** arithmetic on our
own measured values, **[UNVERIFIED]** could not confirm, **[CONTRADICTS]** disagrees with an
existing document.

Measured 17–18 August 2026 against Monad testnet (chain 10143) and the circom 2.2.3
compiler. Local contract figures are `forge test --network monad`; live figures are
`eth_estimateGas` against `https://testnet-rpc.monad.xyz`, cross-checked on a second RPC
where noted.

---

## 1. Decision register

Every V2 design decision, and the number it rests on. Nothing here was decided by argument
alone.

| Decision | Evidence | §|
|---|---|---|
| Clearing keeps orders encrypted rather than opening the batch | Grid clears flat at ~13M/batch; opening costs ~1.2M **per order**. Crossover ≈ 11 orders; batches are 64 | 4 |
| Price grid **L = 20**, not 100 | Sweep 472,591 vs 2,288,973 live · routing 5,504 vs 26,112 constraints · coarser buckets = larger anonymity set | 4, 6 |
| Batch bound by **hash chain**, not per-order Merkle paths | 15,552 vs 314,880 constraints at N=64 — and paths give soundness *without* completeness | 7 |
| Commitment and chain fold stay **separate** (2 hashes, ptau 16) | Sharing serialises order submission on the chain head; 15,552 constraints is not worth a throughput ceiling | 7, 11 |
| Batch size **N = 64** | 36,608 constraints, ptau 16, ~5 s proving. N=256 forces ptau 18 and ~20 s | 11 |
| Fold the chain **at batch close**, not per order | Moves 28,980/order off the user's critical path; envelope 97.8% → 96.4% | 9, 11 |
| Batch commitments stored as a **contiguous array**, not a mapping | 261 vs 8,357 gas per slot — 535k vs 17k on a 64-order close | 3 |
| Relayer fee **flat**, protocol fee a **second change note** | +875 constraints total, +1 public signal; flat fee leaks nothing, proportional fee stays hidden | 8 |
| Nine public signals is affordable — keep `feeCommitment` | Sealed order composes to ~1,956,100, **97.8%** of envelope | 9 |
| `accumulateAffine` **stays** the production path | Live: affine 123,722 vs extended 149,151 | 3 |
| Sorting-in-ZK **not built** | Routing is O(N·L) at 4.08 constraints per pair — the grid is the structure sorting would have to discover | 6 |

---

## 2. Receipts report the declared gas limit [MEASURED]

The same `addOrder` call, broadcast three times at three declared limits:

| Declared | Receipt `gasUsed` | Status |
|---|---|---|
| 12,000,000 | 12,000,000 | success |
| 3,000,000 | 3,000,000 | success |
| 200,000 | 200,000 | success |

A receipt can never say what a transaction consumed. This follows from Monad charging the
declared limit — the property `ActionGasPolicy` is built around — but its measurement
consequence was undocumented.

**Not a contradiction of existing figures.** `forge script` derives its limit from
`eth_estimateGas`, so MEASUREMENTS.md's live numbers are sound. The trap is a manual
`cast send --gas-limit`, which produces a receipt that means nothing.

**Method that works:** `eth_estimateGas`, and marginal cost across two sizes to cancel
calldata, intrinsic cost and dispatch — the same reasoning `tools/monad_gas.py` already uses
to avoid baking in the 10,100 cold-account charge.

## 3. Storage contiguity [MEASURED] [CONTRADICTS MEASUREMENTS.md §1b]

`SlotProbe` reads and writes `n` slots two ways with identical arithmetic. The only
difference is adjacency.

**Reads**, live:

| n | contiguous | scattered |
|---|---|---|
| 32 | 38,012 | 290,253 |
| 64 | 46,157 | 557,670 |
| 96 | 54,700 | 825,088 |
| 128 | 62,860 | 1,092,505 |

**Marginal per slot:**

| | reads | writes |
|---|---|---|
| Contiguous | **261** | **252** |
| Scattered | **8,357** | **11,174** |

Scattered reproduces the documented 8,100 cold SLOAD plus ~257 loop overhead. Contiguous
reproduces the loop overhead and nothing else — **a 32× gap**. Every interval agrees exactly
(8,356.8 per slot in all three read intervals); both figures reproduce on a second RPC.

§1b concluded *"Monad charges the full per-slot surcharge"* from `StorageContiguity.t.sol`,
which is local. It does not hold on the chain.

### Consequence for local↔live

| Workload | Dominant cost | Local vs live |
|---|---|---|
| Cross-contract, calldata-heavy actions | call overhead, calldata | local **understates** 32–41% (§1c) |
| Contiguous storage | cold SLOAD | local **overstates** ~2× |

"Local is a lower bound" is true for actions and false for storage sweeps.

### The derivation this produced, and its refutation [MEASURED]

From the contiguity result we derived that `ElGamalAccumulator` should switch from affine to
extended coordinates — affine pays a 4,048 `modexp` to save 4 slots apparently worth ~1,044.

Tested directly, same market, same ciphertext, cold slots:

| | Live |
|---|---|
| `accumulateExtended` — 8 slots, no inversion | 149,151 |
| `accumulateAffine` — 4 slots, one `modexp` | **123,722** |

**Affine wins by 25,429. The production path is correct and must not be changed.**

The fallback explanation — that the discount applies to SLOAD but not SSTORE — was also
tested and is also wrong (writes get the same discount). **The flat-array result does not
transfer to a struct at a keccak-derived base inside a nested mapping**, and the shape under
which the discount applies is *not established*. Until it is, no layout decision may be made
from `SlotProbe`; measure the real contract.

## 4. Price-grid clearing [MEASURED]

Design: quantise price into L levels. The demand curve is non-increasing, so an order's step
function is nonzero at exactly one level — **one write per order**, not one per level beneath
it. Aggregate demand at any price is a suffix sum computed at clearing.

### Per order

| | Local | Live |
|---|---|---|
| Production `accumulateAffine`, cold | 122,270 | 123,722 |
| Price grid `addOrder`, cold | 142,398 | **115,589** |
| Price grid `addOrder`, warm | 19,098 | — |

The +20,128 local delta over production is one cold `orderCount` SSTORE, not the grid.
Indexing by price level costs one extra keccak for the mapping slot and nothing measurable.

### Clearing sweep

| L | Local, one side | Live, one side | Live, both sides |
|---|---|---|---|
| 20 | 948,760 | **472,591** | 945,182 |
| 50 | 2,340,340 | **1,144,663** | 2,289,326 |
| 100 | 4,659,641 | **2,288,973** | 4,577,946 |

Live marginal: **22,886 per level**, against local's 46,386. Each level is 4 contiguous slots
(one cold SLOAD plus three at ~261) plus two `toAffine` inversions at 4,048 — which
reconstructs the live figure and not the local one.

Flat per-level cost across a 5× range in L confirms the sweep is linear and reads each level
once.

**Control [MEASURED]:** a never-initialised market (id 99) estimates identically at L=50
(1,144,663, exact) and within 1% at L=100. Initialisation state does not affect gas, ruling
out a truncated `initRange` as an explanation for the local↔live gap.

### Per batch

| Component | Gas |
|---|---|
| Suffix sweep, both sides, L=100 | 4,577,946 [MEASURED] |
| ~7 proven decryptions @ ~1.2M | ~8,400,000 [DERIVED from `publishFinalTotals` 2,410,578 ÷ 2] |
| **Total** | **~13,000,000** → ~1.3 MON at the 100 gwei floor |

At L=20 the sweep term drops to ~945,182 and the total to roughly **9.3M**.

### The result that decides the design [DERIVED]

```
transparent clearing:  N × 1.2M      (one proven decryption per order)
price grid:            ~13M, flat in N
                       equal at N ≈ 11
```

Above ~11 orders per batch, keeping every order encrypted is **cheaper** than opening the
batch. At N=64 transparent clearing costs ~76.8M and does not fit a transaction.

## 5. Poseidon and note primitives [MEASURED]

| | Non-linear constraints |
|---|---|
| `Poseidon(2)` | **243** |
| `NoteCommitment` (3 × Poseidon(2)) | **729** |
| Merkle path, depth 20 | **4,920** |

Per-hash cost identical at N=16 and N=64.

## 6. Routing proof [MEASURED]

`circuits/src/probe_route.circom`. Proves N committed orders route to L per-level totals
without opening any order.

| N | L | Non-linear | Linear |
|---|---|---|---|
| 16 | 20 | 1,376 | 696 |
| 32 | 20 | 2,752 | 1,352 |
| **64** | **20** | **5,504** | 2,664 |
| 16 | 100 | 6,528 | 3,416 |
| 32 | 100 | 13,056 | 6,632 |
| **64** | **100** | **26,112** | 13,064 |
| 64 | 256 | 66,112 | 33,344 |

**4.08 non-linear constraints per (order, level)**, flat across a 16× range in N·L. Cost is
`O(N·L)` — linear, not the `N log²N` of a sorting network, because the price grid is the
fixed structure sorting would otherwise have to discover.

For scale: `bet_encrypted`, the largest circuit currently shipped, is 21,252.

## 7. Batch binding [MEASURED]

`circuits/src/probe_batchbind.circom`.

| N | Per-order Merkle paths (depth 20) | Batch hash chain | ratio |
|---|---|---|---|
| 16 | 78,720 (4,920/order) | 3,888 (243/order) | 20× |
| 32 | 157,440 | 7,776 | 20× |
| **64** | **314,880** | **15,552** | **20×** |

### The finding is not the ratio

The proof must establish **soundness** (no invented orders) and **completeness** (no dropped
orders — solver censorship is worth money).

**A per-order Merkle path gives soundness and NOT completeness.** Proving 64 orders are in
the tree says nothing about a 65th that was submitted and quietly omitted. The expensive
option buys the weaker property.

The hash chain gives both: it is order- and length-sensitive, so dropping, adding or
reordering changes the result, and the contract's own accumulator is the reference.

**Spend authority is a separate question already answered.** Whether the owner was entitled
to place the order is proven at *order* time by the sealed-order circuit, which carries its
own Merkle path exactly as `bet_encrypted` does. Re-proving global tree membership at
clearing would be proving something already proven, N times over.

## 8. Fee fields [MEASURED]

`circuits/src/probe_fee.circom` — `withdraw.circom` with both fees added, nothing else
changed.

| | Non-linear | Linear | Public |
|---|---|---|---|
| `withdraw` as shipped | 6,997 | 7,411 | 4 |
| `withdraw` + both fees | 7,872 | 8,238 | 5 |
| **Delta** | **+875** | +827 | **+1** |

Of the 875: 729 is the fee note's three Poseidons, ~80 the two `Num2Bits` range checks.

**The constraint cost is negligible; the public signal is the entire cost.**

Design: relayer fee is a compile-time constant (flat, uniform, leaks nothing — same argument
as the uniform 2,000,000 declared limit, and no public signal). Protocol fee is a second
change note owned by the protocol at `marketId=0, outcome=0`, so revenue is collected through
the ordinary `withdraw` path with the ordinary anonymity set, and the amount never appears
on chain.

## 9. The nine-signal verifier [MEASURED, live]

A real 9-public-signal circuit was compiled, set up against ptau 13, contributed, proved,
deployed and called. **Both verifiers returned `true` on chain before any gas figure was
recorded** — a Groth16 verifier returns `false` for a bad proof without reverting, so a
rejected proof yields a plausible number that means nothing.

| Verifier | Signals | Live `eth_estimateGas` |
|---|---|---|
| `BetEncryptedVerifier` (real circuit) | 8 | 1,191,975 |
| `Sig9Verifier` (probe) | 9 | **1,220,750** |
| **Marginal** | +1 | **28,775** |

Against 30,756 derived from three independent local deltas (3→4, 4→6, 4→8). The live figure
is lower and **understates**: the probe's public signals are small random integers with many
leading zero bytes at 4 gas each, where a real circuit's are full-width field elements at 16.
**Budget with 30,756.**

### Sealed order envelope [DERIVED from measured parts]

| Term | Gas | Source |
|---|---|---|
| `betEncrypted` action, live | 1,904,506 | MEASUREMENTS.md §1e |
| + 9th public signal | +30,756 | conservative |
| + batch-chain `Poseidon(2)` | +28,980 | MEASUREMENTS.md §1b |
| − price-level write instead of outcome write | −8,133 | 115,589 vs 123,722, both live |
| **Sealed order** | **~1,956,100** | **97.8% of 2,000,000** |
| **…with the chain folded at batch close instead** | **~1,927,100** | **96.4%** |

**It fits.** With the close-time fold, ~73,000 spare.

This is a **composition of measured components, not a measurement of the assembled action**,
and cannot be one until the action exists. §1e records two pre-broadcast estimates on this
exact action both erring optimistic. **Broadcast and re-measure the moment it is assembled.**

## 10. Cost per user [DERIVED from measured parts]

Monad charges the declared limit, and every shielded action must declare the same 2,000,000
(anti-fingerprinting), so **0.2 MON per action, flat**, at the 100 gwei floor.

| | Actions | MON |
|---|---|---|
| Deposit, 3 orders, claim, withdraw | 6 | 1.20 |
| Merkle inserts, ~6 leaves @ 69,359 | | 0.042 |
| Batch clearing share, 3 orders | | 0.061 |
| Settlement share | | ~0.002 |
| **Total per normal user** | | **~1.3 MON** |

92% is the relayer. ~0.15 MON per user (≈11%) is the uniformity premium — actions consume
1.1–1.9M but must all declare 2,000,000. That is the anti-fingerprinting property, priced.

**With the in-circuit relayer fee, protocol spend drops to ~0.11 MON per user — 12×.**

| Users | Now | With in-circuit fee |
|---|---|---|
| 100 | 130 MON | 11 MON |
| 1,000 | 1,300 MON | 110 MON |
| 10,000 | 13,000 MON | 1,100 MON |

At 95 MON of testnet funds, the current design supports **~70 users**.

## 11. Scale and speed [DERIVED — proving time is NOT measured]

Routing is `O(N·L)`, binding `O(N)`, so batch size drives everything:

| N (L=20) | Routing | Binding | Total | ptau | Proving |
|---|---|---|---|---|---|
| **64** | 5,504 | 31,104 | **36,608** | **16** | ~5 s |
| 128 | 11,008 | 62,208 | 73,216 | 17 | ~10 s |
| 256 | 22,016 | 124,416 | 146,432 | 18 | ~20 s |

Proving times scale linearly from MEASUREMENTS.md §4's 995 ms at 6,834 constraints in
snarkjs WASM under Node. **[DERIVED, and snarkjs is not perfectly linear — measure before
setting the batch interval.]** If clearing takes longer than the interval, batches queue
behind their own proofs and latency compounds rather than stabilising.

This is a **solver-side, permissionless** proof, off every user's critical path, so seconds
are cheap here in a way they never are for a browser proof.

Throughput ceiling at N=64 and a ~10 s interval: **~6 orders/second**, per market. Beyond
that the fix is parallel markets, not larger batches, since routing cost is per-market.

### Why the cheaper binding was rejected

Sharing one hash — making the commitment *be* the chain link, `Poseidon(chainHead, content,
blind)` — costs 21,056 constraints, fits ptau 15, and removes the on-chain Poseidon entirely.
It was rejected because **every order's commitment would depend on the previous chain head**,
so concurrent provers race and the loser's proof is stale on arrival. That is a throughput
ceiling built into the cryptography, bought for 15,552 constraints.

## 12. Build-hash guard [MEASURED]

`circuits/scripts/gen_manifest.mjs`. A snarkjs verifier is a pure function of its
verification key, so the guard parses the vkey constants back out of each committed `.sol`
and compares them to `<circuit>_vkey.json` field by field — no trust in a recorded hash, no
need for the gitignored zkey.

Mutation test: incrementing **one digit of one constant** in `BetVerifier.sol` was caught,
the exact constant named, exit 1. Clean tree passes.

**Drift found on its first run:** `DepositVerifier` reports `nPublic = 2`; MEASUREMENTS.md §1
and §1e record deposit at **3 public signals**, 998,574 gas. The 30,756-per-signal figure
confirms which is stale — 3 signals derives to 998,698, within 124 gas of the record. **The
recorded figure describes a circuit that no longer exists.** Re-run `make gate`.

Wired into `make verifiers` (so the manifest can never describe a build it was not derived
from) and `make verify-all` (so CI fails on a stale committed verifier).

---

## 13. Deployed probes — Monad testnet, chain 10143

| Contract | Address |
|---|---|
| `PriceGridAccumulator` | `0xacDCb956a86d45E341D1D78b2B39F81e55391173` |
| `SlotProbe` (reads) | `0x2c053298358607Aa44a1f46E41ed015aCa267DB8` |
| `SlotProbe` (reads + writes) | `0x4DFDC93F0C81b533895AAC33Aa8325586Fed8B8f` |
| `ElGamalAccumulator` (probe copy, pool = EOA) | `0x458555b8e700e8Da4f1a76136a1a1E053CB2c29D` |
| `Sig9Verifier` | `0x0e769Bb8624E701F54eB50e070aeAD75eF67cB34` |
| `BetEncryptedVerifier` (standalone) | `0xAFDeD60A8057c9605b62228cc7600F4CaDd1941E` |

Deployer `0x364EDC06254874e62FF4AD8fA4d9a45238cb5609`. Total spend ~4 MON of 95.

**These are probes. They must not reach a production deployment** — no access control, no
curve validation on read paths, no `initialised` guards. Exclude `src/probe/` from the deploy
script.

## 14. Errors caught during measurement

Recorded because the repository's discipline is that a wrong number is worse than no number,
and every one of these looked plausible.

| Error | How it presented | Caught by |
|---|---|---|
| Sweeps measured sequentially in one test body | L=20/50/100 showed 47,438 → 33,646 → 30,416 per level, an "improving" curve; and a loaded book clearing *cheaper* than an empty one | Arithmetic impossibility of the second result. Fix: one sweep per test function |
| `sed` mutation matched nothing | Guard "passed" a corrupted verifier, proving nothing | Exit 0 where a failure was expected |
| `pathElements` mis-indexed in the binding probe | Depth-20 path collapsed to one hash; reported 3,888 where truth is 78,720 — a 20× error | Per-order figure equalled exactly one Poseidon |
| Contiguity generalised from a flat array to a nested-mapping struct | Predicted extended coordinates would beat affine | Direct measurement of the real contract |
| Manual `--gas-limit` on `cast send` | Receipt reported the limit, not the cost | Three limits, three identical readings |

Two of these produced numbers that would have driven a wrong decision if trusted.

## 15. What remains unmeasured

- **The assembled sealed-order action.** §9 is a composition. It must be broadcast.
- **Proving time** for the routing circuit at any N. §11 is scaled from a different circuit.
- **Public-signal layout** for the routing proof. N commitments plus L totals would be 84
  signals at 30,756 each; they must be hashed or bound to on-chain state.
- **In-circuit ElGamal for level totals.** Not needed if per-level aggregates open — the
  same disclosure class V1 already makes per-outcome — but unpriced if a variant needs them.
- **The shape under which the contiguity discount applies** (§3). Blocks any layout decision
  made from `SlotProbe` rather than from the real contract.
- **MON price.** Every rupee figure anywhere in this project rests on it, and it has never
  been measured.
