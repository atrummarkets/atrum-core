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
| **2** — encrypted pools | Accumulator, `Enc(m)` in-circuit, publisher | not started |
| **3** — product | Frontend, resolver, seeded markets, threshold committee | not started |

**115 tests passing** — 102 Solidity under the Monad gas schedule, 13 sequencer.
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
| **Homomorphic addition works** | `Enc(50)+Enc(20)=Enc(70)` | **decrypts to exactly 70** | mechanism proven, not assumed |
| **Sequencer must always batch** | asserted | **confirmed with a number** | unbatched bet = 106% of gas envelope |
| Curve choice BN254 + BabyJubJub | forced, not preferred | **confirmed by building it** | ElGamal proves correctly in-circuit |

### 2.2 Contradicted — our measurement disagrees

| Claim | Source said | We measured | Impact |
|---|---|---|---|
| **Production circuit padding** | "+15% to 25% over the verifier core" | **−0.2%** | Returns the whole safety margin. Real headroom vs the 1.5M gate is 32%, not ~10%. Verify cost is nearly all precompile cost, and snarkjs emits tight assembly, so there is nothing to pad. |
| **`modexp` 256-bit inverse** | 4,712 | **4,048** | Ours is exactly `16 × 253`, EIP-7883's formula; the zero-length probe returned exactly 500, EIP-7883's raised minimum. Not blocking — `modexp` is only for field inversion and the design forbids inversion in the hot path. |
| **Indexed nullifier tree** | recommended, to keep state root-only | **mapping is 24x cheaper — 28,945 vs 690,733** | **661,788 gas saved per bet.** An indexed tree only earns its cost if non-membership must be proved in-circuit; double-spend prevention needs plain membership. **Recommendation: mapping for nullifiers, Merkle tree only for commitments.** Tradeoff accepted: unbounded state growth. |
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
