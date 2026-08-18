# V2 sealed order — circuit spec

What must exist in the circuit set **before the ceremony**, because
`TRANSCRIPT.md` §1 requires ceremony-first-then-deploy-once and every item here changes
the verification key.

Status: **specification.** Nothing here is built. Gas figures are measured; circuit sizes
are not yet.

---

## 0. The rule this document exists to satisfy

> New zkeys produce new verification keys, which produce new Solidity verifiers, which
> change every contract's bytecode and therefore its address. **Ceremony first, then deploy
> once.**

Anything absent from the circuits when the ceremony runs costs a second ceremony to add. So
fields are **reserved now and set to zero**, rather than added when they are needed. A
reserved-but-unused public signal costs 30,756 gas per action forever
(`MEASUREMENTS.md` §1). A second ceremony costs the credibility of the first.

Three things must be reserved: the **relayer fee**, the **protocol fee**, and the
**order routing commitment** (§3).

---

## 1. Conservation, extended

`withdraw.circom` already carries the load-bearing constraint:

```circom
units === amount + change;
```

with the comment: *"Without this the holder withdraws the full note and keeps a full-value
change note, minting collateral out of nothing."*

Every V2 action extends it to:

```circom
units === amount + change + relayerFee + protocolFee;
```

Both fees are **range-constrained exactly like `amount` and `change` are**, for the reason
that file already gives — without `Num2Bits` on each term, a prover supplies a huge field
element and its negative complement, satisfying the sum while paying out more than the note
holds. A fee term is no different, and an unconstrained `protocolFee` is a *negative* fee:
a mint.

## 2. The two fees are different shapes, deliberately

### Relayer fee — FLAT, no new public signal

The relayer needs a known, predictable amount, and the amount must leak nothing. A flat fee
does both: it is uniform across every action, so it carries exactly as much information as
the uniform 2,000,000 declared gas limit does — none.

```circom
relayerFee === RELAYER_FEE();   // compile-time constant, like NULLIFIER_DOMAIN()
```

No public signal, no verify cost. Changing the constant later is a new circuit — which is
why it should be set generously and the surplus refunded off-chain, rather than set tightly
and revised.

**This is what removes the unbounded gas subsidy** identified in `ATRUM-V2-RESCOPE.md` §1.2:
protocol spend per user drops from ~1.20 MON to ~0.11 MON.

### Protocol fee — PROPORTIONAL, one new public signal

A flat protocol fee is regressive: it taxes a small position as hard as a large one, and
small positions are the anonymity set. A proportional fee has to be hidden, because a
publicly visible percentage reveals the size it was a percentage of — the one thing the
system exists to hide.

The mechanism that keeps it hidden already exists in the note format. The fee becomes a
**second change note, owned by the protocol**:

```circom
signal input feeCommitment;   // PUBLIC -- reserve this signal now

component feeNote = NoteCommitment();
feeNote.nullifier <== protocolNullifier;   // derived from a protocol viewing key
feeNote.secret    <== protocolSecret;
feeNote.marketId  <== 0;                   // NO_MARKET: liquid, withdrawable
feeNote.outcome   <== 0;                   // unbet collateral
feeNote.units     <== protocolFee;
feeCommitment === feeNote.commitment;
```

The fee amount never appears on chain. The protocol accumulates fee notes as ordinary
leaves and withdraws them like any other holder, through the same `withdraw` path with the
same anonymity set. Revenue collection is not a privileged operation and needs no new
contract surface.

**Set `protocolFee === 0` for launch.** The signal exists, the constraint is live, the rate
is zero. Turning it on later is a contract parameter, not a ceremony.

### Cost of reserving both — MEASURED

**Constraints** [MEASURED]: `probe_fee.circom` is `withdraw.circom` with both fee fields and
nothing else changed.

| | Non-linear | Public inputs |
|---|---|---|
| `withdraw` as shipped | 6,997 | 4 |
| `withdraw` + both fees | **7,872** | **5** |
| **Delta** | **+875** | **+1** |

875 constraints is 12.5% on `withdraw` and stays well inside its ptau power. Of it, 729 is
the fee note's three Poseidons and ~80 the two `Num2Bits` range checks. **The constraint cost
is not the problem; the public signal is.**

**Verify gas** [MEASURED, live testnet]. A real 9-public-signal circuit was built, set up,
proved, deployed and called. Both verifiers below **returned `true` on chain before any gas
figure was taken** — a Groth16 verifier returns `false` for a bad proof without reverting, so
a rejected proof yields a plausible number that means nothing.

| Verifier | Signals | Live `eth_estimateGas` | Address |
|---|---|---|---|
| `BetEncryptedVerifier` | 8 | 1,191,975 | `0xAFDeD60A…941E` |
| `Sig9Verifier` | 9 | **1,220,750** | `0x0e769Bb8…cB34` |
| Marginal | +1 | **28,775** | |

Against the 30,756 derived from local measurements. The live figure is lower and
**understates the true marginal cost**: the probe's nine public signals are small random
integers with many leading zero bytes at 4 gas each, where a real circuit's are full-width
field elements at 16. **Keep using 30,756 for budgeting** — it is the conservative number and
the one three independent local deltas agree on.

### The envelope, composed from measured parts

| Term | Gas | Source |
|---|---|---|
| `betEncrypted` action, live | 1,904,506 | MEASUREMENTS.md §1e |
| + 9th public signal | +30,756 | derived, conservative |
| + batch-chain `Poseidon(2)` per order | +28,980 | MEASUREMENTS.md §1b |
| − price-level write instead of outcome write | −8,133 | 115,589 vs 123,722, both live |
| **Sealed order, projected** | **~1,956,100** | **97.8% of envelope** |

**It fits, with ~44,000 gas spare — 2.2%.**

[DERIVED, and stated as such] This is a composition of measured components, not a
measurement of the assembled action. It cannot be measured properly until the action exists.
But every term is now a live figure rather than a local one, which is what the earlier
~96.6% estimate was not.

**Consequence: there is no room for a tenth public signal, and no margin for a surprise.**
The packing in §4 is mandatory, and the sealed order must be broadcast and re-measured the
moment it is assembled — §1e records two pre-broadcast estimates on this exact action both
erring optimistic.

## 3. The problem this spec surfaced — order routing

`V2_CLEARING_PROBE.md` costs a price-grid accumulator where an order adds `Enc(size)` to
`levels[side][limitPrice]`. **Those two indices are mapping keys, so the contract must know
them — which makes side and limit price PUBLIC.** That defeats the sealed-order property
the whole design is for.

This is a real gap in the probe's framing and it is not fixed by anything above.

The escape is that the per-order write and the per-level accumulation are **different
transactions by different parties**:

| Phase | Who | What | Cost |
|---|---|---|---|
| Order | user, relayed | store one opaque ciphertext + `changeCommitment` + `feeCommitment` | ~115,589 [MEASURED] |
| Clearing | any solver | prove N committed orders route to L level totals, in ZK | not costed |
| Sweep | any solver | suffix sums over levels, on-chain | 2,288,973 at L=100 [MEASURED] |

The routing proof replaces sorting. It proves each committed order was added to the level
its private limit specifies, without opening any order. This is `N × log L` comparisons
rather than a sorting network's `N log²N`, so it should be markedly cheaper — **but it is
not measured, and it is now the largest unknown in V2.**

The measured per-order and sweep figures are unaffected: one opaque ciphertext write is what
was measured, and the sweep reads levels regardless of how they were filled.

**This should be costed before the sealed-order circuit is written**, on the same reasoning
that produced the clearing probe: it is the number that decides whether the design holds,
and finding out after three circuits depend on it is the expensive order.

## 4. Public signal budget

Nine signals against an envelope already at 95.2% does not fit without paying for it. Two
levers, both measured:

**Pack aggressively.** `note.circom` §PUBLIC INPUT PACKING already establishes the pattern,
and `MEASUREMENTS.md` §1e notes `bet`/`redeem` pack four values into single field elements
for exactly this reason. `withdrawData` fits `unbetExit + recipient + amount` into 201 bits
of a 254-bit field. Side and limit price are small — 1 bit and ~7 bits for a 100-level grid
— and must ride inside an existing signal, never take their own. **This is now mandatory,
not an optimisation.**

**Do not hash the ciphertext to save signals.** Already measured as a wash: ~92,000 saved in
signals against ~87,000 spent in on-chain Poseidon (`MEASUREMENTS.md` §1e).

If nine signals still does not fit after packing, the honest options are to raise the
envelope — publicly observable, and it shrinks the anonymity set of everything submitted
before it — or to drop `feeCommitment` and accept a flat protocol fee at zero extra
signals. **Decide this on a measurement before the ceremony, not after.**

## 5. Order of work

1. Cost the routing proof (§3) at N=16/32/64, L=20/100. Constraints and proving time.
2. Cost the sealed-order circuit with 9 packed signals. Broadcast it — the local figure
   will be wrong in whichever direction the workload dictates
   (`local-forge-understates-monad-gas`).
3. Write the circuit set with all three reserved fields.
4. Committee migration.
5. **Then** the ceremony.

Steps 3 and 4 both change the verification key. Neither may follow step 5.
