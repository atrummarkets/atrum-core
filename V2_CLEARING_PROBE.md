# V2 clearing — what it costs to never decrypt an order

Reproduce: `cd contracts && forge test --network monad --match-contract PriceGridProbe -vv`

Labels follow `MEASUREMENTS.md`.

> **[CORRECTION] An earlier revision of this file applied ×1.41 to every local figure**, on
> §1c's finding that live Monad runs 32–41% above local. That is wrong for this workload and
> the live figures below are measured, not scaled. §0 explains why, and the reason turns out
> to matter more than the probe it was blocking.

---

## 0. Two measurement findings that outrank the probe

Both were forced by this probe's numbers refusing to reconcile. Both change how every
figure in this repository should be read.

### [MEASURED] A Monad receipt reports the DECLARED gas limit, not gas used

The same `addOrder` call, broadcast three times to testnet at three declared limits:

| Declared | Receipt `gasUsed` | Status |
|---|---|---|
| 12,000,000 | 12,000,000 | success |
| 3,000,000 | 3,000,000 | success |
| 200,000 | 200,000 | success |

A receipt can never say what a transaction actually consumed. This follows from Monad
charging the declared limit — the same property `ActionGasPolicy` and the uniformity guard
are built around — but its consequence for measurement was not written down: **any "live"
figure taken from a receipt is a declared limit wearing a measurement's clothes.**
`eth_estimateGas` is the live source, and marginal cost across two sizes is the honest form
of it, for the reason `tools/monad_gas.py` already gives.

### [CONTRADICTS §1b] Contiguous storage slots are nearly free on the live chain

`SlotProbe` (`contracts/src/probe/SlotProbe.sol`, deployed at
`0x2c053298358607Aa44a1f46E41ed015aCa267DB8`) reads `n` slots two ways with identical
arithmetic. The only difference is adjacency.

| n | `readContiguous` | `readScattered` |
|---|---|---|
| 32 | 38,012 | 290,253 |
| 64 | 46,157 | 557,670 |
| 96 | 54,700 | 825,088 |
| 128 | 62,860 | 1,092,505 |

Marginal cost per slot, which cancels calldata, intrinsic cost and dispatch:

| | per slot |
|---|---|
| Scattered (keccak-derived mapping keys) | **8,357** |
| Contiguous (consecutive array slots) | **261** |

Scattered reproduces the documented 8,100 cold SLOAD plus ~257 of loop overhead. Contiguous
reproduces the loop overhead **and nothing else** — a 32× gap. All three intervals agree
exactly (8,356.8 per slot in every case), and both figures reproduce on a second independent
RPC.

**§1b concluded the opposite:** *"`StorageContiguity.t.sol` measures contiguity at only
~2,600 gas, and Monad charges the full per-slot surcharge."* That measurement is local, and
it does not hold on the chain.

### What this does to local↔live

§1c established local forge **understating** live by 32–41%, measured on `deposit`, `bet`
and `betEncrypted` — all of which cross several contracts and carry proof calldata. That
finding stands for that workload. It does not generalise:

| Workload | Dominant cost | Local vs live |
|---|---|---|
| Cross-contract, calldata-heavy actions | call overhead, calldata | local **understates** ~32–41% |
| Contiguous-storage reads | cold SLOAD | local **overstates** ~2× |

Local forge charges every slot the full cold rate; the live chain discounts adjacency.
Which direction the error runs depends on what the code does, so "local is a lower bound" is
true for actions and false for storage sweeps.

### [CORRECTION] The production decision was re-measured directly. It is CORRECT.

The derivation below predicted that extended coordinates would beat affine on the live
chain. **It was tested and it is wrong.** `ElGamalAccumulator` deployed to testnet at
`0x458555b8e700e8Da4f1a76136a1a1E053CB2c29D` with `pool_` set to an EOA so both paths could
be called directly, same market, same ciphertext, cold slots:

| | Live `eth_estimateGas` |
|---|---|
| `accumulateExtended` — 8 slots, no inversion | **149,151** |
| `accumulateAffine` — 4 slots, one `modexp` | **123,722** |

**Affine wins by 25,429.** `accumulateAffine` stays the production path and nothing should
move. The local decision and the live chain agree.

Why the derivation failed is *not* the obvious answer either. The first guess was that the
contiguity discount applies to SLOAD but not SSTORE — an accumulator being write-dominated.
`SlotProbe` was extended to measure writes (`0x4DFDC93F0C81b533895AAC33Aa8325586Fed8B8f`),
and writes get the same discount:

| | per slot, reads | per slot, writes |
|---|---|---|
| Contiguous | 261 | **252** |
| Scattered | 8,357 | **11,174** |

So the discount is real for both, and the flat-array result does not transfer to a struct
sitting at a keccak-derived base inside a nested mapping. **The generalisation is what was
wrong, not the read measurement.** Recorded rather than resolved: the shape under which the
discount applies is not established, and until it is, no layout decision should be made from
`SlotProbe` figures. Direct measurement of the actual contract is the only thing that counts.

This does not touch §2's sweep figures, which are direct live measurements of the real
contract rather than derivations from the probe.

### [SUPERSEDED — see the correction above] The derivation that failed

`ElGamalAccumulator` states that "storage layout is the whole cost" and chose **affine**
over **extended** on local figures — 122,270 vs 185,399 cold. Affine pays a `modexp`
inversion (4,048) to store 4 slots instead of 8.

A ciphertext struct's fields are consecutive slots, so on the live chain the 4 slots affine
saves are worth roughly `4 × 261 = 1,044`, against an inversion costing 4,048 on every
projection. **The trade that decided the production path appears to run the other way live**,
and `accumulateAffine` is on every encrypted bet.

Not a conclusion. This is a derivation from a different contract's probe, and the accumulator
must be estimated directly, live, both variants, before anything moves. But the figure that
settled it is now known to be measuring something the chain does not charge — and §1b's own
`[CORRECTION]` block records this exact decision being revisited once already on a flawed
measurement.

---

## The question

V2 clears a sealed batch at a uniform price. Matching normally means *comparing* orders, and
`ElGamalAccumulator` states the constraint plainly:

> It is ONLY addition — no comparison, no multiplication. That is why the market mechanism
> must be parimutuel.

Three ways out, and the choice decides whether V2's privacy claim survives:

| | Individual orders | Cost scales with |
|---|---|---|
| 1. Sort the batch in a ZK circuit | never decrypt | orders (N log²N constraints) |
| 2. Homomorphic price grid | never decrypt | price levels, **flat in orders** |
| 3. Transparent clearing | **all decrypt** | orders |

Design 3 is not privacy, it is delayed disclosure — and strictly worse than V1, whose
individual bets never decrypt at all. This probe costs design 2.

## The observation design 2 rests on

A clearing price is where aggregate demand crosses aggregate supply. Both are **cumulative
sums**, and summing ciphertexts without decrypting is the property the production
accumulator already has (`Enc(50) + Enc(20) → 70`, asserted in `make prove`).

Quantise price into L levels. The demand curve is **non-increasing** in price, so its step
function is nonzero at exactly one level — the order's limit. An order therefore writes to
**one** level, not to every level beneath it. That single fact is what makes the design
affordable; the naive reading, where an order willing to pay ≤ p touches all p levels,
is ruinous at ~122,000 gas per cold accumulator write.

```
order (buy S @ limit p)  ->  levels[p] += Enc(S)        one write, at order time
aggregate demand at q    ->  sum of levels[q..L-1]      suffix sum, at clearing time
```

---

## 1. Per order — the grid is nearly free relative to V1 [MEASURED]

Live figures are `eth_estimateGas` against testnet, contract
`0xacDCb956a86d45E341D1D78b2B39F81e55391173`.

| | Local | **Live** |
|---|---|---|
| Production `accumulateAffine`, cold | 122,270 | — |
| **Price grid `addOrder`, cold** | 142,398 | **115,589** |
| Price grid `addOrder`, warm | 19,098 | — |

**+20,128 over production**, which is one cold `orderCount` SSTORE — not the grid. Indexing
by price level costs one extra keccak for the mapping slot and nothing measurable.

Envelope check, against the real live figures in §1e:

| | Gas | % of 2,000,000 |
|---|---|---|
| `betEncrypted`, live testnet | 1,904,506 | 95.2% |
| Sealed order = same shape, grid write instead of outcome write | ~1,932,500 [DERIVED] | **~96.6%** |

**It fits, with roughly 67,500 gas to spare.** Two caveats, both load-bearing:

- This assumes side and limit price are **packed into the existing meta field element**, not
  given their own public signals. §1e measures each additional public signal at 30,756 gas;
  two new ones would cost 61,512 and put the action at ~99.7% of envelope. The packing
  pattern already exists — `bet`/`redeem` pack marketId, outcome, units and recipient into
  single field elements for exactly this reason — but it is now mandatory, not an
  optimisation.
- §1e already warned there is **no cheap lever in reserve** for this action at 95.2%.
  Hashing the ciphertext to save signals is a measured wash. That warning now binds.

## 2. Per batch — clearing [MEASURED]

One sweep per transaction, cold state. Measuring several sweeps in one test body warms the
low levels and produces a falsely improving curve; the first draft of this probe did exactly
that, and MEASUREMENTS.md §1d records the same class of error being made before.

| L | Local, one side | **Live, one side** | Live, both sides |
|---|---|---|---|
| 20 | 948,760 | **472,591** | 945,182 |
| 50 | 2,340,340 | **1,144,663** | 2,289,326 |
| **100** | 4,659,641 | **2,288,973** | **4,577,946** |

Live marginal cost is **22,886 per level** (L=100 minus L=50, ÷50), against local's 46,386 —
the ~2× gap §0 explains. Each level is 4 contiguous slots (one cold SLOAD plus three at
~261) plus two `toAffine` inversions at 4,048 each, which reconstructs the live figure and
not the local one.

Per-level cost is flat in L, so the sweep is linear and reads each level exactly once. A 1¢
grid over both sides clears in **4.58M gas** against the 30,000,000 transaction limit — 15%
of one transaction.

Locating the crossing point needs only a few *proven* decryptions, not L of them.
`publishFinalTotals` costs 2,410,578 live for two Chaum-Pedersen-proven decryptions, so
~1.2M each [DERIVED]. Binary search over 100 levels is ~7 probes:

| Component | Gas |
|---|---|
| Suffix sweep, both sides, L=100 | 4,577,946 [MEASURED, live] |
| ~7 proven decryptions @ ~1.2M | ~8,400,000 [DERIVED] |
| **Per batch, total** | **~13,000,000** |

At the 100 gwei floor that is **~1.3 MON per batch cleared**, independent of how many orders
the batch held. The decryption half now dominates the sweep, so it is the half worth
optimising — the reverse of what the pre-correction figures suggested.

## 3. The result that decides it [MEASURED + DERIVED]

Design 3 costs one proven decryption **per order** — ~1.2M gas each. Design 2 costs
~21.5M **per batch**, flat.

```
transparent clearing:  N × 1.2M
price grid:            ~13M, flat in N
                       equal at N ≈ 11
```

**Above ~11 orders per batch, keeping every order encrypted is CHEAPER than opening the
batch.** Privacy is not a premium in this design; past a threshold far below the batch size
the tree already uses (64), it is a discount. Transparent clearing at N=64 costs ~76.8M gas
and does not fit a transaction at all.

This also removes the unbounded-subsidy shape §1 of the re-scope identifies in relayed gas.
Clearing cost is set by the grid, which is fixed at design time — a batch of 64 and a batch
of 6,400 clear for the same gas.

---

## What this changes

**V2 keeps V1's size-secrecy and adds side-secrecy.** V1 emits
`StakeAccumulated(marketId, outcome)` on every bet, so which side you took is public today.
Under design 2 no individual order decrypts and only per-level aggregates open — the same
class of disclosure V1 already makes, moved onto a price grid. V2 is **more** private than
V1, not less.

**Design 1 need not be built.** Sorting in-circuit was the expensive route to the same
property. It is not costed here because design 2 reaches the property at a per-order cost
within 20,128 gas of what the production accumulator already pays.

## Open, and not to be assumed

- [UNVERIFIED] Nothing here has been broadcast. Every figure is local, and this repo's
  record is that local reasoning about Monad lands optimistically — §1e's two pre-broadcast
  estimates both erred low. The ~96.6% envelope figure is close enough to 100% that it must
  be settled on-chain before the sealed-order circuit is written.
- The sweep can likely be **halved**: clearing needs the aggregate at and above the clearing
  price, not the whole curve, so a partial sweep from the crossing point upward reads ~L/2
  levels on average. Not measured.
- Grid granularity is a **privacy parameter as well as a cost one**. A coarse grid buckets
  more orders per level and hides more; a fine grid prices better. L=20 clears at a fifth of
  L=100's cost and is likely the better starting point on both axes.
- The probe contract omits access control and the `initialised` guard on the clearing path.
  Both cost gas, so the sweep figure is a floor even before the ×1.41.
- Partial fills at the marginal price level still leak: a filled order's limit was on the
  winning side of the clearing price. Irreducible in any batch auction, small, and belongs
  in the disclosure rather than in a mitigation.
