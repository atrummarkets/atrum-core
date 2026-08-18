# V2 routing proof — measured

Reproduce: `cd circuits && circom build/route/main_<N>_<L>.circom --r1cs -o build/route -l node_modules/circomlib/circuits`

Circuit: `circuits/src/probe_route.circom`. Constraint counts are [MEASURED] by the circom
compiler. Proving times are [DERIVED] and flagged as such.

---

## What was unknown

`V2_CIRCUIT_SPEC.md` §3 called this V2's largest unknown. The price-grid clearing design
adds an order to `levels[side][limitPrice]` — but those are mapping keys, so a contract
doing the routing must be told side and limit, which is exactly what a sealed order hides.

The escape is to route off-chain and prove it: a solver takes N committed orders and
produces L per-level totals, proving each order landed in the level its own private limit
specifies, without opening any order.

Nobody had a number for what that proof costs. Now there is one.

## The routing argument [MEASURED]

| N | L | Non-linear | Linear |
|---|---|---|---|
| 16 | 20 | 1,376 | 696 |
| 32 | 20 | 2,752 | 1,352 |
| **64** | **20** | **5,504** | 2,664 |
| 16 | 100 | 6,528 | 3,416 |
| 32 | 100 | 13,056 | 6,632 |
| **64** | **100** | **26,112** | 13,064 |
| 64 | 256 | 66,112 | 33,344 |

**Exactly 4.08 non-linear constraints per (order, level)**, flat across a 16× range in N×L.
The cost is `O(N·L)` — linear, not the `N log²N` a sorting network would have cost, because
the price grid is the fixed structure sorting would otherwise have to discover.

For scale, the largest circuit this project currently builds is `bet_encrypted` at **21,252**
constraints.

## Binding orders to their commitments [MEASURED]

Routing is sound only if each routed order is the one actually committed on-chain, which
means recomputing its commitment in-circuit.

`Poseidon(2)` costs **243 non-linear constraints**, measured at N=16 and N=64 with identical
per-hash cost.

`NoteCommitment` is three of them — `ownerHash`, `dataHash`, `leaf` — so **729 per order**
if orders reuse the note format. A purpose-built single-hash order commitment costs **243**.

**This dominates the routing at small L**, which is the result worth acting on:

| Design | Routing | Binding | Total | ptau power |
|---|---|---|---|---|
| N=64, L=20, single-hash | 5,504 | 15,552 | **21,056** | **15** |
| N=64, L=20, `NoteCommitment` | 5,504 | 46,656 | 52,160 | 16 |
| N=64, L=100, single-hash | 26,112 | 15,552 | 41,664 | 16 |
| N=64, L=100, `NoteCommitment` | 26,112 | 46,656 | 72,768 | 17 |

## The result

**A 64-order batch on a 20-level grid with a single-hash order commitment is 21,056
constraints — within 200 of `bet_encrypted`, which this repo already builds, proves and
verifies today.**

It fits **powers-of-tau power 15**, which is already downloaded and already in
`build.sh`'s pipeline. No new ptau file, no new provenance question, no larger ceremony
artifact.

The design holds. Routing was the largest unknown in V2 and it is not expensive.

## What this decides

**L=20, not L=100.** A 5¢ grid over a 0–1 probability range. This was already the better
choice on two other axes — `V2_CLEARING_PROBE.md` measures the clearing sweep at a fifth of
L=100's cost, and a coarse grid buckets more orders per level, which is a larger anonymity
set. It is now also the difference between reusing power 15 and needing power 16 or 17.
Three independent arguments, same answer.

**Use a purpose-built order commitment, not `NoteCommitment`.** 243 constraints against 729.
At L=20 the binding is three quarters of the circuit, so this choice matters more than the
routing does. It costs a new template and the discipline of keeping in-circuit and on-chain
hashing in one place — which `note.circom` already establishes as the pattern, and
`prove.mjs` already checks.

## Proving time [DERIVED — not measured]

`MEASUREMENTS.md` §4 measures 995 ms median for 6,834 constraints in snarkjs WASM under
Node. Scaling linearly, 21,056 constraints is **~3 seconds**, and 72,768 is ~10 s.

This is a **solver-side** proof, not a user-side one. It runs once per batch, off the
critical path of anyone's trade, and it is permissionless — anyone can produce it. Several
seconds is irrelevant here in a way it would not be for `betEncrypted` in a browser.

Not measured, and it should be before the batch cadence is set: the clearing interval has to
exceed proving time plus verification, or batches queue behind their own proofs.

## Scope — what this probe does NOT include

Stated so the number is not read as more than it is:

- **No ElGamal in-circuit.** Level totals are proof outputs. Per-level aggregates opening is
  the disclosure the design already accepts (§ the same class V1 makes per-outcome); if a
  future variant needs them encrypted, `bet_encrypted` measures one in-circuit ElGamal at
  ~14,000 constraints on top of a Merkle path, and L of them would not be affordable.
- **No public-signal layout.** N commitments plus L totals as public signals would be 84
  signals at 30,756 gas each. They must be hashed or bound to on-chain state; that is a gas
  problem with its own budget, separate from the constraint count.

Merkle membership was the other exclusion and is now resolved — see below.

---

## Batch binding — RESOLVED [MEASURED]

Circuit: `circuits/src/probe_batchbind.circom`.

The open question was whether each routed order needs its own Merkle path proving it is a
real committed order. Measured both ways:

| N | A: per-order paths (depth 20) | B: batch hash chain | ratio |
|---|---|---|---|
| 16 | 78,720 (4,920/order) | 3,888 (243/order) | **20×** |
| 32 | 157,440 | 7,776 | 20× |
| **64** | **314,880** | **15,552** | **20×** |

Option A at N=64 costs 314,880 constraints — **15× the entire routing circuit**, and it
would push the design to ptau power 19 on its own.

### The finding is not the ratio, it is that A answers the wrong question

The routing proof has to establish two things:

- **Soundness** — every routed order is a real committed order, so a solver cannot invent
  one that moves the clearing price.
- **Completeness** — no committed order was omitted, so a solver cannot censor an order it
  dislikes. This is worth money and is the property that actually matters here.

**A per-order Merkle path gives soundness and NOT completeness.** Proving 64 orders sit in
the tree says nothing about a 65th that was also submitted and quietly dropped. The
expensive option buys the weaker property.

The hash chain gives both at once. `ShieldedPool` folds each accepted order into
`batchHash = Poseidon(batchHash, orderCommitment)` as it arrives; the proof replays the same
fold and asserts it lands on the same value. The chain is order-sensitive and
length-sensitive, so dropping, adding or reordering any element changes the result.
Completeness comes free, because the contract's own accumulator is the reference.

**Spend authority is a separate question, already answered.** Whether the owner was entitled
to place the order — their note exists and is unspent — is proven at *order* time by the
sealed-order circuit, which carries its own Merkle path exactly as `bet_encrypted` does. By
clearing time that is settled, and re-proving global tree membership would be proving
something already proven, N times over.

### Cost of the chain

On-chain: one `Poseidon(2)` per order at **28,980 gas** (`MEASUREMENTS.md` §1b), folded into
the order transaction. That takes the measured live order cost from 115,589 to roughly
**144,600** — still far inside the envelope.

In-circuit: 243 constraints per order, which is the same 243 the order-commitment binding
already pays. The two can share one hash rather than costing two.

### Final circuit budget, N=64, L=20

| Component | Constraints |
|---|---|
| Routing | 5,504 |
| Order commitment binding | 15,552 |
| Batch chain binding | 15,552 |
| **Total** | **36,608** |

Above power 15's 32,768 ceiling, so this needs **ptau power 16** (65,536, ~54% utilised) —
not power 17, and not the power 19 option A would have forced. If the commitment binding and
the chain fold share a hash, the total drops to **21,056** and power 15 suffices.

**That sharing is now the decision worth making carefully**, and it is the last open circuit
question in the clearing design.
