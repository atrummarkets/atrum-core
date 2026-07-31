# Atrum — Handoff

**As of 30 July 2026.** What has been claimed, what has actually been verified, and
what stands between here and hosting a real private prediction market.

Written to be read by someone who has not seen the earlier conversation.

---

## 1. Where we are

Phase 0 and Phase 1 are both complete. Every Phase 1 deliverable in
`atrum-build-plan.md` §7 is built, and each is exercised by a test that replays a real
Groth16 proof.

| Phase | Scope | Status |
|---|---|---|
| **0** — kill the risk | Vault skeleton, ElGamal circuit, real gas measurement | **complete, gate passed** |
| **1** — market, public pools | Vault, ShieldedPool, 3 circuits, parimutuel, sequencer, CI | **complete, 1 critical fixed** |
| **2** — encrypted pools | Accumulator, `Enc(m)` in-circuit, private redeem, publisher | **~85%** — encrypted bet, settlement and **private redemption** all wired and tested end to end; `withdraw` circuit built but its contract path is not; publisher and `cancel` unbuilt |
| **3** — product | Frontend, resolver, seeded markets, threshold committee | not started |

**183 Solidity tests + 95 circuit soundness attacks + 155 curve vectors + 13 sequencer tests**
passing. (Soundness: 29 on `bet_encrypted`, 34 on `redeem_private`, 32 on `withdraw`.)
Everything numeric below is reproducible with the commands in §6.

**A security review of Phase 1 found and fixed one critical vulnerability**: the
sequencer could author spendable notes via `queuePadding` and drain the entire vault.
It was demonstrated with a real Groth16 proof before being fixed, and the proof is
kept as a regression test. See MEASUREMENTS.md §1d. Assume more exist — that was one
internal pass, not an audit.

The headline: **a real shielded bet costs 1,165,715 gas end to end, 58% of the
envelope.** Deposit is 1,378,641 and redeem 1,137,382. The cryptography was never the
risk; now the market on top of it is measured too.

Phase 1's milestone is *shielded positions, public pool total*. It is an internal
milestone, not a launch. Redemption is still public, and per the build plan that makes
the privacy claim **false rather than degraded** — so the honest description today is
*anonymous-participant parimutuel market*. Phase 2 is what earns the other one.

---

## 1b. Phase 2 — where it actually stands

Three components are built and verified in isolation. **Nothing is wired together**, and the
remaining work is mostly integration — which is where the one critical bug of Phase 1 came
from, so that distinction is load-bearing rather than pedantic.

**UPDATED 31 July 2026.** The table below has moved substantially: the encrypted bet
path is now wired, measured, and exercised on Monad testnet. See
[`PHASE2_TESTNET_REPORT.md`](PHASE2_TESTNET_REPORT.md) for the transaction record.

| Piece | Built | Verified | Wired |
|---|---|---|---|
| `ElGamalAccumulator` + `BabyJubJub` | yes | 19 tests, gate measured, **homomorphic sum proven on testnet** | **yes** |
| `bet_encrypted.circom` | yes | 29 soundness attacks, **real proof, 21,252 constraints, ptau 15** | **yes** |
| `ChaumPedersen` (DLEQ decryption proof) | yes | 13 tests, optimised 3.06x | **yes**, via `EncryptedParimutuelPool` |
| `EncryptedParimutuelPool` + plaintext binding | yes | 15 tests, **attack reverted on testnet** | **yes** |
| Single disclosed committee key | yes | generated circom include, cannot drift from the key file | n/a |
| `ShieldedPool` Phase 2 path (`betEncrypted`) | yes | 8 tests, **1,904,506 gas on testnet, 95.2% of envelope** | **yes** |
| `cancel` | **no** | — | design in §1e (deadline-first) |
| Publisher (cadence, BSGS, ratio) | **no** | BSGS + DLEQ now extracted to `circuits/scripts/lib/`, exercised, but no worker | — |

Test count is now **168 Solidity tests** (was 145), plus 13 sequencer tests.

### [VERIFIED] The encrypted path now settles end to end

Phase 2's two halves were each well tested, against **different inputs**, and nothing
joined them:

- `ShieldedPool.t.sol` ran a real `betEncrypted` proof, so the accumulator received a
  ciphertext the CIRCUIT built.
- `EncryptedParimutuelPool.t.sol` settled ciphertexts that `gen_settlement_fixtures.mjs`
  built directly in JavaScript.

No test had shown that a ciphertext the circuit produced could actually be decrypted and
settled on-chain — which is the entire claim Phase 2 rests on. That gap mattered
specifically because **all three real bugs found in this repo have lived in seams**, not
inside components: `queuePadding` (deposit and redeem each correct, neither proving a
leaf came from a deposit), and the guard migration (`units == 0`, which vanished at the
Solidity/circuit boundary rather than moving across it).

`contracts/test/EncryptedEndToEnd.t.sol` closes it. The full real sequence — deposit,
bet, encrypted deposit, `betEncrypted(100)`, encrypted deposit, `betEncrypted(37)`,
resolve, settle — with every proof real and nothing mocked:

```
staked (never visible to the contract) : 137
settled YES total                      : 137
published YES probability              : 10000 bps
```

[MEASURED] Two stakes the contract never saw, summed on-chain by point addition, and
recovered only at settlement under a DLEQ proof. Seven tests, including three that cover
the ways it fails rather than the way it works:

- the accumulator holds the homomorphic **sum** of both circuit-produced ciphertexts, and
  the untouched NO side is still the identity `(0,1)` — not all-zeros
- a lying total is rejected **against the real ciphertext**, not only a JS-built one
- claiming the empty side holds anything reverts, and settling before betting closes reverts

### [MEASURED] `betEncrypted`, closing the last UNMEASURED gap

An earlier revision of this file listed the 8-public-signal verify cost as unmeasured, with
~1,155,000 as an extrapolation. Measured:

| | Gas | % of 2,000,000 envelope |
|---|---|---|
| `betEncrypted`, full action, local | **1,352,807** | 68% |

[UNVERIFIED] The real testnet figure. Phase 1 measured local `deposit` at 1,378,641 against
a real **1,816,031** — local underestimates by ~30% because it charges neither calldata nor
the intrinsic cost. Applying that, `betEncrypted` lands near **1.8M, ~90% of envelope.**
Tight. Measure on testnet before assuming headroom.

### [FIXED] A clean `git pull` broke a third of the test suite

Not anyone's code — a build-artefact provenance bug, and the same class as the three CI
failures fixed earlier.

Verification keys were **committed**; proving keys are **gitignored** and, by design, not
reproducible. `snarkjs zkey contribute` mixes its own randomness in even when `-e` entropy
is fixed [MEASURED], so `vk_delta_2` differs per machine while `IC` matches. The committed
vkeys therefore only matched the machine that built them, and anyone pulling the repo got
29 failures reading `InvalidProof()` — which looks exactly like broken contracts. CI never
caught it because CI regenerates both halves in the same run.

[CORRECTION to our own first attempt] We tried pinning the contribution entropy to make
zkeys reproducible so the vkeys could stay committed. **It does not work, and it should
not:** `groth16 setup` is deterministic [MEASURED] but `contribute` is not, and if the whole
setup were derivable from public inputs the toxic waste would be public and every proof
forgeable. That non-determinism is the security property. The pin was reverted.

The actual fix: **stop committing the vkeys.** They are derived from a deliberately
irreproducible input, so committing them was the mistake. `make circuits` regenerates them.

What *is* pinned, because it works and was verified identical across runs: the **test
committee key**, derived by counter-hashing a public seed. That is what lets key-dependent
fixtures be valid on any machine. `ATRUM_RANDOM_KEY=1` opts out. Both pinned values are
loudly labelled public and worthless as secrets — which they already were, since Phase 2
ships "a single decryption key, disclosed plainly" by design.

`gen_settlement_fixtures.mjs` and `gen_e2e_fixtures.mjs` are now wired into `make fixtures`
and both CI jobs, so the new coverage cannot silently stop running.

### The correction this phase produced

**Chaum-Pedersen alone does not stop a lying publisher.** It proves the decryption
share came from the committee key; it says nothing about the integer claimed alongside
it. Binding the claim needs `C2 - D = [m]G` checked separately. Demonstrated on-chain:
a claim of 1275 against a true 425 reverted with `ClaimedPlaintextMismatch`, **not**
`InvalidDecryptionProof` — the proof was valid. §V6 of the reference and this document
both previously implied the proof was sufficient.

**A mid-market ratio cannot be verified on-chain at all.** Verifying it consumes the
plaintext totals, and publishing those defeats the phase; additive ElGamal has no
division. Mid-market odds are therefore an operator attestation
(`publishAttestedRatio`, rate-limited on-chain), and no payout reads it. Only
`publishFinalTotals` is verified, and only it feeds settlement.

### Gaps inside what looks finished

- **`bet_encrypted` has never produced a real proof.** It compiles at 21,250 constraints and
  its soundness was verified via *witness generation*, which decides constraint satisfaction
  and needs no trusted setup. But it requires **ptau power 15** (>16,384), and setup has not
  been run. There is no zkey, no verifier, and **the 8-public-signal verify cost is
  UNMEASURED** — ~1,155,000 is an extrapolation from the reference, not a measurement.
- Phase 2 raises public signals from 4 to 8 (the ciphertext is four field elements the
  contract must actually add, so it cannot be hashed away for free). At a measured 30,756
  gas per signal that is ~123,000 more per bet.

### The accumulator gate — PASSED

Measured against genuinely cold storage, the state a real bet finds:

| Layout | cold | warm |
|---|---|---|
| extended (X,Y,T,Z — 8 slots, no inversion) | 185,399 — **does not fit** | 15,799 |
| affine (x,y — 4 slots, 2 inversions) | **122,270 — fits, 61,699 spare** | 18,870 |

A real testnet deposit leaves 183,969 gas of headroom. `accumulateAffine` is the production
path; the extended variant is kept and still measured so the choice stays evidence-backed.

The homomorphic property is demonstrated on-chain, not assumed: accumulating `Enc(50)` then
`Enc(20)` lands on exactly the ciphertext circomlibjs computes for `Enc(70)`.

### Two guards that died when `units` went private

This is the Phase 2 failure mode worth internalising:

> **When a value goes private, every Solidity guard on it dies silently.** The contract still
> compiles. The tests still pass. The check is simply gone.

An audit of all ten guards in Phase 1's `bet` found exactly two whose input no longer exists
in Phase 2 — `units == 0` and `addStake(..., units)`. Both are handled (a circuit constraint
and the ciphertext accumulator respectively). The other eight operate on values that are
still public and survive unchanged.

A third gap was found the same way: `encRandomness = 0` was accepted, which makes
`C1 = identity` and `C2 = [units]G`, so anyone recovers the stake by discrete log. Alone that
is self-inflicted — but a compromised frontend could force it on every user, publishing every
bet while the contract sees nothing wrong. Now constrained in-circuit AND guarded at the
contract (`DegenerateCiphertext`), because the failure mode is completely silent.

### [CORRECTION to the plan] Decryption proofs are Phase 2, not Phase 3

`nisi-master-reference.md` §V6 lists Chaum-Pedersen decryption proofs as "REQUIRED once the
committee is t-of-n" — Phase 3. That is mis-phased.

The moment payouts derive from a decrypted ratio, whoever publishes that ratio can drain the
vault: publish a ratio favouring one side and its holders are overpaid, and nothing on-chain
can detect it, because checking a ratio against a ciphertext *is* this proof. Phase 1 had no
such exposure — the contract computed payouts from its own plaintext totals, so the publisher
could not lie about them. **Encrypting the pool is what creates the hole.**

So the proof is required as soon as the pool goes dark, even with a single key. Without it,
"single decryption key, disclosed plainly" is not a privacy caveat — it is unilateral
authority over everyone's collateral. Measured cost makes this easy: **$0.05/day** for hourly
publishing.

---

## 1c. Private redemption — BUILT, and the item both plans refuse to cut

`ShieldedPool.redeem` published a recipient address and an amount. Both plans forbid that:
`atrum-build-plan.md` — *"Never cut private redemption"*; `atrum-4day-plan.md` §7 —
*"Redemption stays inside the shielded pool. Non-negotiable."* A public payout retroactively
deanonymises every position it pays, which makes the privacy claim **false rather than weak**.

`redeemPrivate` publishes neither. The payout becomes a shielded note; leaving for USDC is a
separate, later, unlinkable action.

[MEASURED] end to end, real proofs throughout — deposit, bet, encrypted deposit,
`betEncrypted(100)`, encrypted deposit, `betEncrypted(37)`, graft, resolve, settle, redeem:

```
position units (private, never on-chain) : 100
payout units  (private, never on-chain) : 100
collateral moved                        : 0
gas                                     : 1,126,328   (56% of envelope)
```

### The four-outcome scheme, and the unbounded mint it prevents

The payout note needs an outcome value, and every pre-existing one is redeemable — so redeem a
winner, receive a payout note, redeem *that*, forever. Nullifiers do not help: each payout
note is genuinely new, and every individual step is legitimate. The 2-bit outcome field
already had room for a fourth value, so this costs nothing:

| outcome | bettable | redeemable | withdrawable |
|---|---|---|---|
| 0 — unbet collateral | yes | yes (1:1 refund) | **no** |
| 1 / 2 — YES / NO position | no | if it won | **no** |
| **3 — SETTLED payout** | no | **no** | **yes** |

`redeem_private` accepts `{0,1,2}` and always emits `3`. `withdraw` pins its input to `3` as a
circuit constant. The cycle is closed by construction rather than by a check someone could
forget.

### The payout division had to move in-circuit

Phase 1's contract computed `units × total / winning` because `units` was public. It is private
now, so the contract cannot. The settled totals ARE public, so the division is proved
in-circuit against public divisors:

```
units × totalPool == payout × winningPool + remainder,   remainder < winningPool
```

Exact integer division, truncating DOWN, so payouts can only sum to less than the pool.

**The contract's remaining job is pinning the divisors to reality**, and it is load-bearing:

```solidity
if (totalPool != yes + no) revert TotalsMismatch();
if (winningPool != (winning == OUTCOME_YES ? yes : no)) revert TotalsMismatch();
```

Without it the circuit proves the arithmetic faithfully — about invented inputs. A prover
claims a larger `totalPool` and walks away with a proportionally inflated payout carrying a
perfectly valid proof. Two tests cover it (inflated total, shrunk winning pool).

`ShieldedPool` reads settled totals through a one-time irreversible `bindEncryptedTotals`,
because `EncryptedParimutuelPool` already takes `ShieldedPool` in its constructor — the
dependency is circular. Same shape as `MappingNullifierSet.bindPool`: the privileged window is
exactly one call, and afterwards nobody can repoint where payouts are computed from.

### Verification

34 circuit soundness attacks, all rejected — 4 on the mint loop, 11 on payout inflation
(inflated payout, honest quotient with inflated note, quotient bumped with remainder forced to
zero, `remainder == winningPool`, lying about each of `totalPool`/`winningPool`/`units`, refund
inflated above units, division by zero, zero payout), plus packing and binding. Eight honest
baselines are asserted ACCEPTED first, including the two awkward ones: a division **with a
remainder**, and an unbet refund when `winningPool = 0`.

Plus 8 on-chain tests: no collateral moved, one-shot, pre-settlement rejection, both divisor
attacks, plaintext-market rejection, and bind irreversibility.

---

## 1d. `withdraw` — BUILT end to end

The exit: a SETTLED note becomes public USDC. **32 soundness attacks pass, `ShieldedPool.withdraw`
is built and measured at 1,166,565 gas**, and the whole private path is verified in one test:
`betEncrypted(100) + betEncrypted(37)` → settle 137 → `redeemPrivate` (payout stays a note) →
`withdraw` 60 public / 40 held back as change.

Stated plainly: the **amount and recipient are public and must be** — real collateral moves and
a transfer is visible. Privacy comes from unlinkability instead: which note funded it is
hidden, `redeemPrivate` already severed position→payout, and the timing is the holder's choice.

**Partial withdrawal exists for a privacy reason, not convenience.** A settled payout is
whatever the parimutuel arithmetic produced — 137, 1,041, an odd number — and a payout
uniquely identifies the position that earned it. Full-note-only withdrawal would leak exactly
what `redeemPrivate` protects. Withdrawing round, fixed denominations makes every withdrawal
look identical; the change returns as a new SETTLED note.

Conservation is the load-bearing constraint: `amount + change == units`, with both private, so
the contract can check neither. Seven attacks cover it, including the one that matters most —
**`amount = 2^200` with a complementary negative change**, which satisfies the sum modulo the
field while paying out vastly more than the note holds. The range checks on both halves stop
it.

---

## 1d-bis. Plaintext markets are DEPRECATED — what that did and did not remove

Acting on "deprecate plaintexts". The end state is one market type and one exit.

### Removed outright

**`ShieldedPool.redeem()` is gone**, with `_settleRedeem`, `_owedUnits` and
`_unpackPayoutData`. It published `payoutData = recipient * 2^64 + units` — a public address
and a public amount — which is the exact thing `atrum-build-plan.md` says never to ship,
because a public payout claim retroactively reveals every position. Its replacement is the
two-step `redeemPrivate` → `withdraw` in §1c and §1d.

Four tests went with it (`test_fullLifecycle_depositBetResolveRedeem`,
`test_gate_realDepositAndRedeemFitEnvelope`, and two revert cases). The lifecycle they covered
is covered better by `PrivateRedeem.t.sol`, which runs the same arc with the payout private.

### The consequence, stated plainly

**A plaintext market now has NO redemption path at all.** `redeemPrivate` cannot serve one: it
reads settled totals from `EncryptedParimutuelPool`, which a plaintext market does not have —
its total lives in `ParimutuelPool` in the clear. So collateral deposited into a legacy market
is stuck. That is acceptable only because no legacy market will ever hold real money, which is
what the freeze below enforces.

### Enforced, not just documented

`Deploy.s.sol` now registers the two fixture markets and then calls `freezeLegacyMarkets()` **in
the same transaction that opened them**. A deployed instance can never acquire a third legacy
market, so no future operator can strand funds in one. `registerEncryptedMarket` is
deliberately unaffected — freezing both would make the deployment inert.

`DeployConfig.t.sol` (new, 5 tests) asserts that end state instead of eyeballing console output,
which is what the script's correctness previously rested on. It checks the freeze holds against
the admin themselves, that encrypted registration still works, and that the removed `redeem`
selector is absent **from the deployed bytecode** — with the same scan first required to FIND
`withdraw`, so a miss means absence rather than a broken scan.

### NOT removed, and why

`registerMarket`, `bet()`, the `ParimutuelPool` wiring and the plaintext verifiers are still in
the tree. Deleting them requires regenerating `gen_action_fixtures.mjs` as an all-encrypted
lifecycle: sections 1–5 are the plaintext leg, and the encrypted sections graft onto the tree
it builds. Dropping them renumbers every batch, which changes every leaf index and therefore
every root and every proof — so every recorded fixture and every Solidity test asserting a root
has to be regenerated together. That is a mechanical but wide change, and it is the remaining
item; the deprecation above is what makes it safe to defer.

Legacy markets also leak precisely what Phase 2 exists to hide: bet SIZE is public in
`betData`, the running total is public, and odds move live — which reintroduces the late-money
problem encryption solves.

**Suite: 192 passing, 0 failing.**

---

## 1e. [CORRECTION x2] `cancel` is an adverse-selection problem, not a pricing one

Two earlier claims in this file were wrong. Both are corrected here rather than deleted,
because the wrong versions are the ones someone would naturally re-derive.

### The exploit

Alice bets 100 YES and 100 NO. Pools reach 1000/1000. News arrives, YES is near-certain, she
cancels NO:

| | payout | outlay | profit |
|---|---|---|---|
| no cancel button | 200 | 200 | **0** |
| free cancel | 190 | 100 | **+90** |

The +90 is not created. The YES multiplier drops 2.00x → 1.90x, so the other 900 YES units lose
0.10 each: **900 × 0.10 = 90**, exactly her gain. A transfer from the bettors who stayed in.

### [CORRECTION 1] Two quantities were conflated

An earlier table here reported "profit as % of cancelled stake" reaching ~100% for small
bettors, and concluded the exploit is *worst* for small players. That figure was the **gain from
cancelling versus not cancelling**, not profit:

| her stake | winning pool | share | no-cancel | cancel | gain | **total profit** |
|---|---|---|---|---|---|---|
| 100 | 1,000 | 10% | 0.0 | 90.0 | 90.0 | **90.0** |
| 100 | 100,000 | 0.1% | −99.0 | 0.9 | **99.9** | **0.9** |
| 900 | 1,000 | 90% | 800.0 | 810.0 | 10.0 | **810.0** |

The 99.9 is not a small bettor getting rich — it is that *not* cancelling is catastrophic for
them. Total profit is 0.9. `gain = c × (1 − a/Y)` is correct; calling it profit was not.

### [CORRECTION 2] Free cancellation is NOT mispriced

The bigger error. This was framed as a mispriced free option. It is not. [MEASURED] under
market-implied probability:

```
uninformed canceller, EV of not cancelling : +0.00
uninformed canceller, EV of cancelling     : +0.00
```

Refunding the stake **is** fair value — which follows directly from §5's result that a
parimutuel position is always worth exactly its stake under market-implied odds. So the +90
comes from nowhere in the pricing.

**It comes purely from information.** Alice cancels a leg the market values at 100 and she knows
is worth 0. The mechanism is **adverse selection**:

- uninformed bettors have no reason to cancel (EV 0)
- informed bettors always cancel (EV = +their edge)
- the pool therefore only ever faces the informed side, and cannot win on average

### What that changes about the fix

- **A fee still does not work**, but for a better reason than stated before: it must exceed the
  *informed edge*, which approaches 100% of the stake as certainty approaches 1. No fixed fee
  prices an unbounded edge.
- **A deadline is weaker than previously claimed here.** An earlier revision said "the deadline
  is the fix." It is a mitigation, not a fix: information arriving *before* the deadline is
  still exploitable. In a market where news can break at any moment, no deadline is fully safe.

The honest options, none of which are parameter tweaks:

1. **No cancellation.** Where the code is today. Structurally safe; costs early exit entirely.
2. **Cancellation with a short deadline.** Knowingly writes a free option to informed traders
   for that window. Size the window by how fast information moves in the specific market.
3. **Refund the position's value at cancellation time** rather than its stake — which collapses
   to (2), because those are the same number under market-implied odds, and pricing private
   information is not possible.

**Recommendation: option 1 for launch.** The plan already accepts capital lockup as parimutuel's
irreducible cost, and hedging (betting the other side) remains an exact, non-exploitable exit.
This is a product decision about how much adverse selection to accept, not an engineering one.

### The gap this leaves today

There is **no early exit at all**. `withdraw` accepts only SETTLED notes, and `redeemPrivate`
requires the market resolved *and* settled. So:

> **A depositor who deposits and never bets is locked until the market settles.**

Not a soundness bug, and pre-existing (the old public `redeem` had the same `NotResolved`
guard), but a real product problem. Mid-market exit currently means hedging, which is exact but
locks *more* capital rather than freeing it.

---

## 2. The claims ledger

Two source documents made claims: `atrum-build-plan.md` and
`nisi-master-reference.md`. Everything load-bearing was independently re-measured
against live Monad nodes rather than taken on trust.

### 2.1 Confirmed — measured ourselves, matches the claim

| Claim | Source said | We measured | |
|---|---|---|---|
| `ecAdd` 0x06 | 300 | **300** | exact |
| `ecMul` 0x07 | 30,000 | **30,000** | exact |
| `ecRecover` 0x01 | 6,000 | **6,000** | exact |
| `p256_verify` 0x0100 | 6,900 | **6,900** | exact |
| `bls12_g1_add` 0x0b | 375 | **375** | exact |
| `bls12_g2_add` 0x0d | 600 | **600** | exact |
| `ecPairing` 0x08 (BN254) | 225,000 + 170,000k | **225,000 + 170,000k** | exact, linear fit across k=0..5 |
| `bls12_pairing` 0x0f | 37,700 + 32,600k | **37,700 + 32,600k** | exact |
| Block gas limit | 150,000,000 | **150,000,000** | exact (docs' 200M is stale — confirmed stale) |
| Base fee | 100 gwei floor | **100 gwei** | exact |
| Chain IDs | 143 / 10143 | **143 / 10143** | exact |
| Cold SLOAD | 8,100 | **8,115** local, cold-access premium 10,252 on-chain | confirms both 8,100 and 10,100 |
| Groth16 verify, 4 public inputs | 1,031,828 | **1,029,454** | −0.2%, essentially exact |
| Per public input | ~30,000 | **30,756** | confirms |
| **Monad reprices BN254 ~5x, leaves BLS12-381 alone** | central thesis | **confirmed** | the fact the whole architecture rests on |
| `mulmod` / `addmod` | not listed as repriced | **10 gas, identical on both chains** | confirmed not repriced |
| **Homomorphic addition works** | `Enc(50)+Enc(20)=Enc(70)` | **decrypts to exactly 70** | mechanism proven, not assumed |
| **Sequencer must always batch** | asserted | **confirmed with a number** | unbatched bet = 106% of gas envelope |
| Curve choice BN254 + BabyJubJub | forced, not preferred | **confirmed by building it** | ElGamal proves correctly in-circuit |

### 2.2 Contradicted — our measurement disagrees

| Claim | Source said | We measured | Impact |
|---|---|---|---|
| **Production circuit padding** | "+15% to 25% over the verifier core" | **−0.2%** | Returns the whole safety margin. Real headroom vs the 1.5M gate is 32%, not ~10%. Verify cost is nearly all precompile cost, and snarkjs emits tight assembly, so there is nothing to pad. |
| **`modexp` 256-bit inverse** | 4,712 | **4,048** | Ours is exactly `16 × 253`, EIP-7883's formula; the zero-length probe returned exactly 500, EIP-7883's raised minimum. Not blocking — `modexp` is only for field inversion and the design forbids inversion in the hot path. |
| **Indexed nullifier tree** | recommended, to keep state root-only | **mapping is 24x cheaper — 28,945 vs 690,733** | **661,788 gas saved per bet.** An indexed tree only earns its cost if non-membership must be proved in-circuit; double-spend prevention needs plain membership. **Recommendation: mapping for nullifiers, Merkle tree only for commitments.** Tradeoff accepted: unbounded state growth. |
| **Threshold decryption proof "~180,000 gas"** | §V6, `[DERIVED]` as 6 × ecMul at t=3 | **895,842 measured** (2,741,396 before optimisation) | **5x off, and the derivation is invalid.** `ecMul` at 0x07 operates on alt_bn128 G1 — short Weierstrass over the BN254 *base* field. BabyJubJub is twisted Edwards over the *scalar* field, so the precompile cannot touch these points and every scalar multiplication is hand-written Solidity. Still affordable: $0.05/day hourly. |
| **Accumulator "BN254 via ecAdd precompile, 4 slots — 600 gas"** | §1.3 | **option does not exist** | Same reason: `ecAdd` is the wrong curve and the wrong field for BabyJubJub. The accumulator is hand-written field arithmetic. |
| **"A broken sequencer can't steal funds, only halt the market"** | build plan §8 trust model | **false as built — now true** | `queuePadding` let the sequencer author spendable notes and drain the whole vault. Proved with a real Groth16 proof (0 deposited → 5,000 USDC out). **Fixed:** padding is now derived on-chain from `keccak256(PAD_DOMAIN, treeStart, slot)`, so nobody chooses it. Regression test kept. See MEASUREMENTS.md §1d. |
| **"Fillers are unspendable by construction"** | `ShieldedPool.queuePadding` comment | **false** | `deposit.circom` binds commitment↔amount for deposits, but nothing forced every leaf to come from a deposit, and `redeem.circom` never checks provenance. |
| **"Prediction markets have thin liquidity and low adoption"** | §11 demand risk | **stale** | Polymarket did $8.9–10.5B/month in 2026, 1.29M wallets in Q1, ICE invested up to $2B at ~$9B valuation. Category demand is proven. The risk moved (see §5). |

### 2.3 Not verified — do not rely on these

| Item | Why it matters |
|---|---|
| **Hermez ptau transcript** | `snarkjs powersoftau verify` did not finish in our timeout. Setup succeeded against the published Hermez file, but the ceremony transcript is **unverified by us**. Verify before anything holds value. |
| **Accumulator ~68,000/bet single, ~2,375 batched** | Phase 2. The last unknown blocking the final gas-envelope decision. |
| **Threshold decryption ~180,000 gas (Chaum-Pedersen, t=3)** | Phase 3. |
| Block utilisation | Reference said ~4%; we saw **7.39%**. Same order, still nearly empty. Minor. |
| Local cold *account* access | Local forge reads ~18,000; live chain reads 10,252. **Live chain is authoritative.** Doesn't affect tree design, but don't trust local cross-contract call overhead. |
| FHE availability | Re-checked: Zama is on **Ethereum mainnet** (Dec 2025, ~1,040 TPS on 8×H100), Fhenix CoFHE on Base (Feb 2026). **Still nothing for Monad on any published roadmap.** |

---

## 3. What is actually built and proven

### Contracts (`contracts/`)

| File | What | Verified how |
|---|---|---|
| `Vault.sol` | Collateral layer. USDC ↔ {YES, NO} complete sets, fixed denominations, immutable resolver + resolution-spec hash, enforced gap between betting close and resolution | 30 tests incl. solvency invariant and fuzz |
| `IncrementalMerkleTree.sol` | Poseidon commitment tree, depth 20, root-only state, **subtree grafting** | Grafted roots proven **byte-identical** to sequential insertion for N=1,2,8,64 and across consecutive batches |
| `ShieldedPool.sol` | `deposit` / `bet` / `redeem`, commitment queue, sequencer batch entrypoint, market registry | 15 tests replaying real Groth16 proofs, incl. full lifecycle and a forged-root rejection |
| `ParimutuelPool.sol` | Public per-market stake totals, published odds, pro-rata payout | Covered by the lifecycle tests; truncation is down-only so payouts cannot exceed the pool |
| `MappingNullifierSet.sol` | Double-spend guard. The measured winner | 7 tests incl. a demonstrated double-spend on the losing design |
| `TreeNullifierSet.sol` | The build plan's alternative, kept as evidence | `ShieldedPool` refuses it via `enforcesOnChain()`, and that refusal is tested |
| `ActionGasPolicy.sol` | The single uniform declared gas limit every shielded action pads to | Anti-fingerprinting rule; guarded in CI (`.github/workflows/ci.yml`) |
| `PrecompileRepricing.t.sol` | **Fails** if `--network monad` is missing | Without the flag: `ecMul` 6,393 (Ethereum's price), 5x understated |
| `StorageRepricing.t.sol` | **Fails** if local storage pricing isn't Monad's | Without the flag: cold SLOAD 2,115 instead of 8,115 |

### Circuits (`circuits/`)

`elgamal.circom` — exponential ElGamal on BabyJubJub, `C1 = [r]G`, `C2 = [m]G + [r]H`.
Two probe variants: 4 public signals (key compiled in) and 6 (key rotatable).
~6,840 constraints, **~995 ms median proving time**.

`prove.mjs` does more than `snarkjs verify`, deliberately — a passing proof only says
a witness satisfied *some* constraint system. It also recomputes the ciphertext
independently with `circomlibjs` and confirms it matches, then runs real decryption:

- proof verifies, both variants
- `C1` and `C2` match independent computation
- decrypt round-trip recovers the plaintext
- tampered public signal is rejected
- **`Enc(50) + Enc(20)` decrypts to `70`**, published ratio "YES 70%"
- zero plaintext round-trips (the identity edge case)

### Tools (`tools/`)

`monad_gas.py` measures real Monad gas via `eth_call` + state overrides — no funded
key, no deploy, no spend. Uses **marginal cost** (`gas(N=2) − gas(N=1)`) so every
constant cancels, including the 10,100 cold-account charge that a single absolute
reading silently includes. Per-call probe overhead calibrated to exactly **119 gas**
against three targets spanning 300 → 905,000.

`measure_verifier.py` is the Phase 0 gate. `measure_poseidon.py` is Phase 1's.
`check_gas_uniformity.py` is the CI anti-fingerprinting guard — it already caught one
real bug (an envelope anchor set to the warm cost when a declared tx limit must cover
the cold first call).

### The gas budget as measured

| Component | Gas |
|---|---|
| Groth16 verify | 1,029,454 |
| Nullifier mapping write | 28,945 |
| **Per-user action subtotal** | **1,058,399** |
| Commitment insert (sequencer, batched, N=64) | 38,034/leaf |
| **Per bet, all-in** | **~1,096,433** |
| Uniform envelope (provisional) | 2,000,000 — **55% used** |

Derived from our own numbers: **145 proofs/block, ~485/sec, 0.103 MON per proof.**
Verification throughput is not a constraint.

Note: tx gas limit is 30,000,000, so at ~1.03M/verify a single transaction holds at
most **~28 proofs**. Batch size is bounded by the transaction limit, not the block.

---

## 4. Distance to a first private prediction market

### 4.1 Engineering remaining

**Immediate, in order:**

1. `ShieldedPool.withdraw` — the circuit and its 32 soundness tests exist; the contract path,
   the `RedeemPrivateVerifier`-style verifier export, and an e2e test spanning
   bet → settle → redeem → withdraw do not. This is the last piece of the private path.
2. `cancel` — **do not build without a product decision first.** §1e shows it is an
   adverse-selection problem with no parameter fix: a fee cannot price an unbounded informed
   edge, and a deadline only shrinks the window. Recommendation is to ship without it.
3. Publisher — cadence, BSGS ratio recovery, ratio-only publication. `publishAttestedRatio`
   exists on-chain; the off-chain worker does not.
4. Re-measure every action **on testnet** and set the uniform envelope once. Local
   underestimates by ~30% (Phase 1: 1,378,641 local vs 1,816,031 real), so `betEncrypted` at
   1,352,807 local likely lands near 1.8M — ~90% of a 2,000,000 envelope.
5. Frontend — nothing exists in `atrum-core`.



**Phase 1 (build plan: weeks 1–3) — complete**
- [x] `Vault.sol` + tests
- [x] Commitment tree + subtree grafting, measured
- [x] `ShieldedPool.sol` — tree + nullifier set + 3 verifiers, root history, action entrypoints
- [x] Circuits: `deposit` (3 public signals), `bet` (4), `redeem` (4) — Merkle path + nullifier derivation, all inside the ≤4 ceiling via packed public inputs
- [x] `ParimutuelPool.sol` — public sums, pro-rata payout, published odds in bps
- [x] Sequencer (TypeScript) — batch grafting, tree mirror, Merkle-path endpoint, 10 rotating relayer accounts
- [x] Uniformity guard extended to all action types, and wired into CI

Two deviations from the plan, both driven by measurement and both recorded in
`MEASUREMENTS.md` §1c:

1. **Nullifiers use a mapping, not an indexed tree.** 29,107 gas vs 632,196 — and more
   decisively, a Merkle accumulator cannot answer `isSpent` at all, because rejecting a
   double-spend needs *non*-membership.
2. **`bet` and `redeem` need ptau power 14**, not 13. A depth-20 Merkle path costs
   ~4,900 constraints on its own, putting them at 14,194 and 12,734 against power 13's
   ceiling of 8,192.

→ **Milestone reached: shielded positions, public pool total.** Internal only. Not a
launch: with the pool total public, late money is still unsolved, and redemption is
still a public payout.

**Phase 2 (weeks 4–5)**
- [ ] `ElGamalAccumulator.sol` — BabyJubJub, extended coordinates, no inversion in the hot path
- [ ] Extend `bet` circuit to emit `Enc(m)` and prove consistency with the spent note
- [ ] Publisher — decrypt on a cadence, BSGS to recover the ratio, publish ratio only
  *(BSGS is already implemented and tested in `prove.mjs` — reusable)*
- [ ] Measure accumulator gas, then **finalise the gas envelope**
- [ ] Single decryption key, disclosed plainly

→ **Milestone: the mechanism works end to end.** This is the first point at which
"private prediction market" is an honest description.

**Phase 3 (weeks 6–8)**
- [ ] Frontend on `monadNewHeads` / `monadLogs` websockets
- [ ] Resolver — price/on-chain oracle feeds only (Chainlink, Pyth). **No UMA, Reality.eth or Kleros exists on Monad — you are building the resolver, not integrating one**
- [ ] Multiple seeded markets
- [ ] Threshold committee, 3-of-5, Chaum-Pedersen decryption proofs

### 4.2 Before real money — not in the build plan's timeline

These are **blocking for mainnet** and none are budgeted in the 8-week plan:

| Gap | Current state | Needed |
|---|---|---|
| **Trusted setup** | Single phase-2 contribution from one dev machine — **that randomness can forge proofs** | Multi-party ceremony |
| **ptau provenance** | Hermez file used, transcript unverified by us | Verify the transcript |
| **Committee key** | Test key with a known secret in `circuits/build/` (gitignored) | Real key from a real ceremony |
| **Verifier field checks** | Safety depends on snarkjs's generated `checkField`, not on our code | Never replace a generated verifier without re-running `FieldBoundary.t.sol` — without that check, `nullifierHash + r` is an unlimited double-spend |
| **Private redemption** | `Vault.redeem` is **public** | Must move inside the ShieldedPool. A public payout path retroactively deanonymises every position — this makes the privacy claim *false*, not weak. **The one item the plan says never to cut.** |
| **Audit** | one internal review done — found 1 critical (fixed) | External review of circuits + contracts. An internal pass found a full-vault drain; assume more exist |
| **Regulatory position** | undecided | Private markets on real-world outcomes draw scrutiny everywhere; privacy sharpens it |

### 4.3 Honest summary of distance

- **Testnet demo, shielded positions + public pool:** end of Phase 1 — ~2–3 weeks
- **Testnet, genuinely private (encrypted pool):** end of Phase 2 — ~4–5 weeks
- **Public testnet product with real markets:** end of Phase 3 — ~6–8 weeks
- **Mainnet with real money:** Phase 3 **plus** ceremony, audit, and private
  redemption. The audit alone is typically weeks and is not in the estimate above.

The engineering risk is largely retired. What remains is mostly *volume* of work
plus the security process — not unknowns.

---

## 5. The risk that is not engineering

The reference's §11 said demand was unestablished, citing Augur/Gnosis/Omen
failures. **That framing is now stale** — Polymarket settled the category question.

But the composition matters. Of 2026 prediction-market volume, roughly **sports 39–40%,
politics 32%, crypto 20%** — ~91% retail speculation on public events, on a
**fully public order book**, where transparency is a growth feature (copy-trading,
whale-watching, media quoting odds).

Atrum is **parimutuel by necessity** — additive encryption does addition only, so no
matching engine is possible. Consequences, worked through and partly verified
numerically:

- **Exit needs no counterparty.** Betting the other side is an *exact* hedge
  (verified: hold 100 YES in a 500/500 pool, bet 125 NO, receive 225 either way).
- **There is no mark-to-market P&L to capture.** A parimutuel position is always
  worth exactly its stake under market-implied probability (verified across pool
  ratios). So "cash out at fair value" *is* "refund your stake."
- **Early cancellation is architecturally cheap** — additive encryption subtracts as
  well as adds, and ZK does the accounting, so no comparison on ciphertext is needed.
  **But it must carry a fee and a deadline**: free cancellation is a free option and
  is demonstrably exploitable (bet both sides, cancel the loser after news lands →
  +90 on a 100 stake).
- **Limit orders cannot exist on-chain**, but odds are public by design, so a
  client-side keeper covers conditional entry. And parimutuel has zero price impact,
  so the usual slippage rationale for limit orders mostly evaporates.
- **Irreducible cost: capital is committed until resolution.** Hedging removes risk
  but locks *more* capital, not less.

**So the target user is not the match-day sports flipper.** It is someone placing one
considered, hold-to-resolution bet who has a structural reason not to be seen doing
it: funds that cannot hold visible positions, DAOs where betting against your own
proposal is politically costly, large traders who get copied the moment they size up.

**The cheapest remaining de-risk is not code.** It is asking ten large traders or
three DAOs whether they would *commit*. Phase 1 is 2–3 weeks of building on an
unvalidated demand assumption; that conversation should run in parallel, not after.

---

## 6. Reproduce everything

```bash
# Monad Foundry required. Upstream foundryup IGNORES --network monad.
FOUNDRY_DIR=~/.foundry-monad bash -c \
  'curl -L https://foundry.category.xyz | bash && ~/.foundry-monad/bin/foundryup --network monad'
# forge --version must report 1.7.1-monad-v1.0.0, NOT plain 1.7.1

make circuits    # compile 5 circuits, Groth16 setup, export verifiers
make prove       # verify the ElGamal mechanism end to end
make fixtures    # real deposit/bet/redeem proofs for the Solidity suite
make verifiers   # copy generated verifiers into contracts/src
make test        # 81 contract tests, Monad gas schedule
make gate        # real verify gas, all 5 verifiers, vs the 1.5M stop-line
make uniformity  # anti-fingerprinting: every action under ONE declared limit
make measure     # chain params + precompile costs, live chain
make verify-all  # everything that can fail, in dependency order

cd sequencer && npm install && npx vitest run   # 13 tests
```

Order matters on a clean checkout: the contract suite replays real proofs, so
circuits and fixtures must be built before `make test`.

`make checkup-part PART=vault` runs one area at a time (`vault`, `tree`,
`shieldedPool`, `parimutuel`, `security`). It needs no RPC and spends nothing.

`make gate` / `make measure` hit live Monad nodes via `eth_call` with state overrides
— no key, no deploy, no spend. `NETWORK=mainnet` targets chain 143.

Full labelled measurement record: [`MEASUREMENTS.md`](MEASUREMENTS.md).

---

## 7. Open decisions

1. ~~**Uniform gas envelope.** Tightening to ~1.4M looks right.~~ **CLOSED — and the
   answer reversed.** That reasoning came from local `forge` numbers showing actions at
   ~55%. On real testnet transactions `deposit` costs **1,816,031 — 91% of 2,000,000**
   (MEASUREMENTS.md §1c). Tightening to 1.4M would have made every deposit revert.
   **Envelope stays at 2,000,000, with ~184,000 of headroom left for Phase 2's
   accumulator** — not the ~900,000 previously assumed. If the accumulator does not
   fit, optimise the action (most obviously: move `Vault.split` out of `deposit`)
   rather than raising the envelope, which is publicly observable.
2. ~~**Nullifiers: mapping or indexed tree.**~~ **CLOSED — mapping.** Both were built
   behind `INullifierSet` and measured: 29,107 vs 632,196. The decisive point was not
   gas: a Merkle accumulator cannot answer `isSpent` at all, because rejecting a
   double-spend needs *non*-membership. `ShieldedPool` now refuses any set whose
   `enforcesOnChain()` is false. See MEASUREMENTS.md §1c.
3. **Cancel circuit: in or out?** Recommend sizing the envelope for four circuits now
   even if `cancel` ships in Phase 2, because the envelope should be set once.
4. **Committee key: compiled in (4 public signals) or public input (6)?** Measured
   cost of the flexible option is **61,511 gas** — cheap. Compiled-in means key
   rotation requires a new trusted setup, which becomes a real liability at Phase 3
   when the single key becomes a 3-of-5 committee. Leaning toward the 6-signal
   variant for that reason.
5. **Tree depth 20** (1,048,576 leaves) — recommended and implemented. Depth is a
   direct multiplier on insertion cost.

---

## 8. Two coordination decisions, not engineering ones

Both surfaced while reconciling `atrum-4day-plan.md` against this codebase. Neither is a
bug; both will waste real work if left unresolved.

### 8.1 The 4-day plan and this repo disagree about Phase 2

`atrum-4day-plan.md` takes cut-line #3 deliberately and up front — encrypted pools are
**cut** — and §4 rules that the site must not claim *"positions stay encrypted until
settlement"* or *"private prediction market"*.

But encrypted pools are **built and verified end to end** here (see §1b). And the plan's
Day 1 and Day 2 deliverables — bet circuit, market registry, redeem circuit, resolution,
lifecycle — already exist in `atrum-core`. The plan is written against a separate
`atrum-zk-poc/` codebase (`ShieldedPoolPOC.sol`, `circuits/withdraw.circom`, `web/`) which
is not present in this repository.

Followed literally, Days 1–2 rebuild what exists, and the site under-claims what the code
actually does. **Which repo is the product** needs deciding: two codebases with overlapping
circuits is precisely how seam bugs arise, and every real bug here so far has been a seam.

### 8.2 The one item both plans refuse to cut is still open

`ShieldedPool.redeem` still pays a public address:

```solidity
vault.collateral().transfer(recipient, owed * vault.denomination())
```

`atrum-build-plan.md`: *"Never cut private redemption."*
`atrum-4day-plan.md` §7: *"Redemption stays inside the shielded pool. Non-negotiable."*

A public payout retroactively deanonymises every position it pays, which makes the privacy
claim **false rather than weak**. So the hardest part of Phase 2 is done and the part both
documents refuse to cut is not.

Design for it, including a trap found at design time: the payout note needs a fourth
outcome value, `3 = settled`. With `outcome = 0` (unbet) the payout note is itself
redeemable as a 1:1 refund, producing an unbounded mint — redeem a winner, get a payout
note, redeem *that* as unbet, repeat. Nullifiers do not stop it because each payout note is
genuinely new. The 2-bit outcome field already has room:

| outcome | bettable | redeemable | withdrawable |
|---|---|---|---|
| 0 — unbet collateral | yes | yes (1:1) | no |
| 1 / 2 — YES / NO position | no | if it won | no |
| **3 — settled payout** | **no** | **no** | **yes** |

`redeem` accepts `{0,1,2}` and always emits `3`; `withdraw` accepts only `3`.
