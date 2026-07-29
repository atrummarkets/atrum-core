# Atrum: Build Plan — Private Prediction Market on Monad

**atrum.fun**

**A tutorial-plan for building a plain (single-event) private prediction market.** Companion to `nisi-master-reference.md`, which has the full measurement backing and also covers conditional/two-level markets. This file scopes down to what you actually decided to build: **plain prediction market, not conditional/futarchy.**

Everything here that references a gas number, a precompile cost, or a trust-model claim traces back to `nisi-master-reference.md`. Read that file for the "why" behind every number; read this file for "what to build, in what order."

---

## 0. What we're building, one paragraph

A prediction market where anyone can bet YES or NO on a single event ("Will X happen?"), where **individual bets, identities, and balances are hidden from everyone — including the operator** — but the final odds are public and anyone can verify settlement was done correctly. No order book, no AMM: a parimutuel pool, same style as a horse-racing bet. Privacy comes from two layered techniques, not one: sealed-envelope proofs for individual bets, and lockbox-style encrypted math for the pool total.

---

## 1. Glossary — read this before anything else

| Term | Plain meaning |
|---|---|
| **ZK proof** | Proof you did something correctly, without revealing the data. Like proving you're over 21 without showing your birthdate. |
| **Groth16** | The specific ZK proof system used. Fast to verify on-chain, needs a one-time setup ceremony. |
| **Commitment** | A sealed envelope. Contains a hidden value (e.g. bet amount); you can later prove what's inside without revealing it early. |
| **Commitment tree** | Efficient storage for millions of sealed envelopes. One small fingerprint ("root") on-chain represents the whole pile. |
| **Nullifier** | A "used" stamp. Published when you spend an envelope, so the system can block double-spends without revealing which envelope it was. |
| **Homomorphic encryption** | Encryption you can do math on without decrypting. Post more into a locked box, its total grows — nobody can read the total until it's unlocked. |
| **ElGamal (additive)** | The specific homomorphic scheme used. Can only do **addition** on encrypted numbers — not comparison, not multiplication. This limitation is why the mechanism must be parimutuel. |
| **Threshold decryption / t-of-n** | The lockbox's decryption key is split across N parties; any T of them together can unlock it, no single party can alone. |
| **FHE** | Fully Homomorphic Encryption — arbitrary math on encrypted data (add, multiply, compare). More powerful than additive ElGamal, but **not available on Monad today, and centralized where it does run.** Not used here. |
| **TEE** | Secure hardware enclave (Intel SGX etc.) that promises isolated, tamper-proof execution. Real 2025 attacks broke this promise on real hardware. **Not used as a trust root here.** |
| **Gas** | The fee to run computation on-chain. Privacy tech (proofs, encryption) costs more gas than plain transfers — this is why every technique below has a measured gas cost attached. |
| **Precompile** | A shortcut built into the chain for one expensive math operation, much cheaper than writing it in a contract. Monad reprices some of these vs. Ethereum — matters for curve choice below. |
| **Curve (BN254 / BabyJubJub)** | The elliptic-curve math underneath both the ZK proofs and the ElGamal encryption. Proof system and encryption scheme must use *matching* curves or costs explode 10-100x. |
| **Parimutuel** | Betting style where everyone's stake goes into one pool per outcome, winners split it proportionally. No price sett in advance, no order matching — only ever needs addition. |
| **MEV** | The edge someone gets by reordering or front-running transactions. Parimutuel has ~zero MEV: payout doesn't depend on bet order. |

---

## 2. System components

| # | Component | Type | Job |
|---|---|---|---|
| 1 | **Vault** | on-chain contract, public | Takes USDC, issues YES/NO position (as private envelopes, not visible balances) |
| 2 | **ShieldedPool** | on-chain contract, private | Holds only a commitment tree root + nullifier tree root. Verifies ZK proofs. Never sees plaintext. |
| 3 | **Circuits** (deposit / bet / redeem) | off-chain, runs client-side | Generate the ZK proofs before each transaction. Three circuits, one per action. |
| 4 | **ElGamalAccumulator** | on-chain contract, public but ciphertext-only | Holds `Enc(YES_total)` and `Enc(NO_total)`. Adds encrypted bet amounts via elliptic-curve point addition. |
| 5 | **Threshold committee** | off-chain, t-of-n parties | Hold shares of the decryption key. Jointly decrypt only the ratio, on request, never individually. |
| 6 | **Publisher** | off-chain worker + small on-chain writer | Asks committee to decrypt ratio on a cadence (e.g. hourly), writes odds on-chain. Never touches raw totals. |
| 7 | **Sequencer** | off-chain infrastructure | Batches transactions, maintains the trees, runs rotating relayer wallets so your own address never touches the chain directly. |
| 8 | **Resolver** | off-chain oracle + small on-chain writer | Determines the real-world outcome (v1: price/on-chain data feeds only, e.g. Chainlink/Pyth), posts result. Fully separate from the committee. |

**Nobody in this system, including you as operator, can see an individual bet.** Nobody can see the pool total without 3-of-5 (or whatever t-of-n you pick) committee cooperation, and even then only the ratio comes out, never raw numbers.

---

## 3. Full transaction lifecycle, with a concrete example

Market: "Will Team A win?" Three bettors: Alice, Bob, Carol.

1. **Deposit.** Alice locks 100 USDC into the Vault. Gets back a sealed envelope worth 100. Chain sees: one more envelope added to the pile, root updates. Doesn't see "Alice has 100."
2. **Bet.** Alice bets 50 on YES. She runs the *bet circuit* locally, producing a proof that: she owns a real envelope, she isn't reusing it (nullifier), and she's creating a new 50-remaining envelope plus a 50-on-YES bet envelope. She also emits `Enc(50)`, an encrypted version of the amount, with a proof it matches the real bet. Chain sees: one nullifier, two new sealed envelopes, one `Enc(50)` — no name, no amount, no link between them.
3. **Accumulate.** The ElGamalAccumulator adds `Enc(50)` (Alice) + `Enc(20)` (Carol, also betting YES) directly as ciphertext: `Enc(50) + Enc(20) = Enc(70)`. Nobody decrypts anything here. The YES lockbox now holds an encrypted 70, invisible to everyone.
4. **Publish odds.** Every hour, the committee (say 3-of-5) jointly decrypts just the ratio: `Enc(YES_total=70)` vs `Enc(NO_total=30)` → publishes "YES: 70%." Raw totals never surface, individual bets never surface.
5. **Resolve.** Team A actually wins. The Resolver (a price/data oracle in v1) posts "YES." Fully separate system from the committee — only flips a public flag.
6. **Redeem.** Alice proves via the *redeem circuit*: "I hold a winning envelope, pay me my share." Never reveals which envelope was hers. Payout arrives as a new sealed envelope (or she can choose to exit to public USDC — her choice, not forced).

---

## 4. Trust & visibility matrix

| Component | Sees individual bets? | Sees pool totals? | Can move funds alone? |
|---|---|---|---|
| Vault / ShieldedPool contract | No | No | No |
| ElGamalAccumulator contract | No | No (ciphertext only) | No |
| Sequencer | No (sees tx timing/metadata only) | No | No |
| Single committee member | No | No (needs t-of-n) | No |
| Full committee (t-of-n together) | No | Yes, ratio only, on request | No |
| Resolver | No | No | No — only flips outcome flag |
| You, the bettor | Your own bet only | No, same as public | Only your own funds |

---

## 5. Tech stack decisions

| Decision | Choice | Why |
|---|---|---|
| Proof system | Groth16 | Fast on-chain verification, standard, MACI (production ElGamal-on-BabyJubJub voting system) uses the same stack — proven combination. |
| Proving curve | **BN254**, not BLS12-381 | BLS12-381 is 4.97x cheaper per Groth16 verify [MEASURED], but the ElGamal encryption must be proved *inside* the circuit, which requires matching the curve's base field to the proof system's scalar field. That match only exists for BN254 → BabyJubJub. Switching breaks it, forcing non-native EC arithmetic — 10-100x constraint blowup. Savings from BLS12-381: ~two cents per proof. Not worth it. |
| Encryption curve | BabyJubJub, twisted Edwards | Matches BN254, what circomlib and MACI already ship. |
| Commitment hash | Poseidon | Cheap inside ZK circuits, unlike SHA256. |
| Chain | Monad | Cold SLOAD is 8,100 gas (4x Ethereum) — root-only on-chain state design matters more here than on Ethereum. P256 precompile at 6,900 gas makes on-chain attestation cheap if you ever add TEE hardening later. |

### Measured gas costs (all from `nisi-master-reference.md` §1, reproducible via Appendix A there)

| Operation | Gas | Notes |
|---|---|---|
| Groth16 verify, BN254, 4 public inputs | 1,031,828 | The bet/deposit/redeem proof check |
| Homomorphic ElGamal add, BabyJubJub, compute only | 1,715 | The pool-total accumulation |
| Same, with live non-zero storage slots, single bet | ~68,000 | Cold SLOAD + SSTORE dominate, not the math |
| Same, batched, N=100 bets/transaction | ~2,375/bet | Sequencer must batch anyway for nullifier insertion — this is free |
| Threshold decryption proof (Chaum-Pedersen), t=3 | ~180,000 | Once per publish interval, not per bet |

---

## 6. Non-negotiable engineering constraints

| Rule | Because |
|---|---|
| Root-only on-chain state, indexed nullifier tree | Cold SLOAD costs 4x Ethereum on Monad — don't store more than you must |
| **All three circuits (deposit/bet/redeem) padded to one uniform gas limit** | Monad charges the declared `gas_limit`, which is a public field — if your three actions cost different gas, that difference alone fingerprints which action a user took |
| Redemption happens inside the ShieldedPool, never as a plain public claim | A public payout claim retroactively reveals every position. Skipping this makes the privacy claim false, not weak |
| Fixed denomination splits | Arbitrary split sizes leak participation and bet size even when the amounts are otherwise hidden |
| Sequencer always batches | Turns ~68,000 gas/bet into ~2,375 gas/bet |
| Never call `eth_estimateGas` | You pay the declared limit regardless; MetaMask sets it absurdly high when estimation reverts |
| Publish odds on a cadence, never continuously | Continuous revelation reintroduces the late-money problem the encryption exists to solve |
| Anonymity set = batch window, not block | Monad blocks are ~300ms and can be as small as a handful of transactions — batch across a wider window for real cover |

---

## 7. Build plan

### Phase 0 (days 1-3): kill the risk
- Vault skeleton on testnet: plain `USDC → {YES, NO}` split, no nesting.
- Prove one trivial BabyJubJub ElGamal circuit in circom, verify on testnet, **record real gas.** The 1,031,828 figure is the verifier core only — a production circuit with field arithmetic and input validation typically adds 15-25%. **If it exceeds ~1.5M gas, stop and reassess.**
- Use **Monad Foundry**, not stock Foundry — gas numbers from stock Foundry will be wrong for this chain.

### Phase 1 (weeks 1-3): the market, public pools
- Full Vault contract with test suite.
- Parimutuel pool, public sums for now, odds published directly (no encryption yet).
- ShieldedPool: Poseidon commitments, indexed nullifier tree, subtree batch insertion, single root.
- Circuits: deposit, bet, redeem. Keep public inputs to 4 or fewer — each costs ~30,000 gas on BN254.
- Sequencer: batching, ~10 relayer EOAs.
- CI test asserting all three action types carry identical gas limits (the fingerprinting rule above).

**Milestone: private positions, public pool total.** Internal milestone, not a launch — late-money problem still unsolved at this point.

### Phase 2 (weeks 4-5): encrypted pools
- ElGamalAccumulator: BabyJubJub, extended coordinates, no inversion in the hot path.
- Extend the bet circuit to emit `Enc(m)` and prove consistency with the spent envelope. **MACI is the reference implementation to read for this exact pattern.**
- Publisher: decrypt on cadence, baby-step-giant-step to recover the plaintext ratio, publish ratio only.
- Start with a **single decryption key, disclosed plainly** — not yet a full committee.

**Milestone: the actual mechanism works end to end.**

### Phase 3 (weeks 6-8): product
- Frontend on `monadNewHeads` / `monadLogs` websockets.
- Resolver integration — v1 ships with price/on-chain oracle feeds only (Chainlink, Pyth, etc.), zero human judgment, zero dispute surface.
- **Multiple seeded markets — breadth is the thesis, one market proves nothing.**
- Upgrade to threshold committee, 3-of-5, with Chaum-Pedersen decryption proofs.
- Optional: TEE hardening for committee members (defense in depth only, never the trust root — see `nisi-master-reference.md` §C5/C6 for why).

### Cut lines, in order (what to drop first if time runs short)
1. Threshold committee → ship single-key, disclosed plainly.
2. Number of seeded markets → ship fewer, not zero.
3. Encrypted pools (Phase 2) → only if Phase 1 slips badly. If cut, say the smaller thing plainly: "shielded positions, public pool," not "private prediction market."
4. **Never cut private redemption.** A public redemption path makes the entire privacy claim false, not degraded.

---

## 8. What this explicitly is not

- **Not FHE.** Additively homomorphic only — addition, nothing else. Say "homomorphic encryption." Never say "fully."
- **Not decentralized at launch.** One sequencer, one decryption key initially. Liveness depends on you; safety does not (a broken sequencer can't steal funds, only halt the market).
- **Not a TEE product.** If TEEs get added later, it's hardening for the committee, never the trust root.
- **Not hiding the odds.** Odds are public by design — a market that hides its own price has produced nothing. Depth and participant identity are what's hidden.
- **Not a conditional/futarchy market.** Single event only. (If you change your mind on this later, see `nisi-master-reference.md` §5 M5 and §6 R-X1/R-X2 for what changes — it's a real architectural jump, not a toggle.)
- **Not regulator-proof.** Private markets on real-world outcomes draw scrutiny everywhere; privacy sharpens that, doesn't dodge it.

---

## 9. The open risk this plan doesn't solve

Everything above is engineering, and the engineering is sound. **Demand is not established.** Prediction markets have had thin-liquidity and low-adoption problems historically for reasons that have nothing to do with privacy. Before Phase 1, the cheapest way to derisk this: find a small number of DAOs, companies, or private groups who will *commit* — not "sounds cool" — to running one market. If none commit, the cryptography is moot. If some do, they'll tell you whether privacy is actually what they want, versus capital efficiency, trusted resolution, or just a better interface.

---

## Appendix: where each number comes from

Every gas figure and trust-model claim above is sourced and labeled in `nisi-master-reference.md`:
- §1 — measured chain parameters and precompile costs, with a reproduction script in Appendix A there
- §2 — the "what's hidden from whom" table this whole design satisfies
- §3 — full evaluation of every confidentiality approach considered (C1-C10), why FHE and TEE-as-root were rejected
- §5 — mechanism evaluation (M1-M5), why parimutuel over order book/AMM
- §6 — resolution approaches (R1-R5), why v1 ships oracle-only
- §7 — decision matrix, one-line verdict per approach
- §11 — the demand-validation risk in full
