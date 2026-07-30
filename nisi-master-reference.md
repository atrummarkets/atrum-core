# Nisi: Master Reference

**Private conditional and prediction markets on Monad. Every approach considered, evaluated, and labelled.**

Compiled 28 July 2026. This supersedes all previous drafts. Where an earlier draft was wrong, the correction is marked and the original claim is stated so you can see what changed.

---

## 0. How to read this

Every factual claim carries one of these labels. Nothing is unlabelled.

| Label | Meaning |
|---|---|
| **[MEASURED]** | I ran it. Against Monad mainnet via `eth_call` with state overrides, or compiled locally. Reproduction script in Appendix A. |
| **[DOCUMENTED]** | Verbatim from a primary source: vendor docs, MIP, EIP, protocol registry. Source named. |
| **[PUBLISHED]** | From a peer-reviewed or preprint paper, with the authors and venue named. |
| **[DERIVED]** | Arithmetic on measured or documented values. The arithmetic is shown. |
| **[ESTIMATE]** | My judgement. Not verified. Treat as a hypothesis to test. |
| **[UNVERIFIED]** | I could not confirm this and you should before relying on it. |
| **[CORRECTION]** | I said something wrong in an earlier draft. Stated plainly. |

---

## 1. Measured ground truth

### 1.1 Chain parameters

| Parameter | Value | Label |
|---|---|---|
| Mainnet chain ID | 143 | [DOCUMENTED] |
| Testnet chain ID | 10143 | [DOCUMENTED] |
| Block gas limit | **150,000,000** | [MEASURED] at block 91,117,507 |
| Docs claim for block gas limit | 200,000,000 | [DOCUMENTED] and **stale**, do not use |
| Base fee | 100 gwei, exactly the floor | [MEASURED] |
| Block utilisation at sample | ~4% (6.3M of 150M) | [MEASURED] |
| Block time | 300 ms | [DOCUMENTED] MIP-12, shipped v0.15.0 |
| Speculative finality | 1 slot, 300 ms | [DOCUMENTED] |
| Full finality | 2 slots, 600 ms | [DOCUMENTED] |
| Tx gas limit | 30,000,000 | [DOCUMENTED] |
| Block byte limit | ~1.5 MB | [DOCUMENTED] MIP-12 |
| Tx per block | ~3,750 | [DOCUMENTED] MIP-12 |
| Contract code limit | 128 KB | [DOCUMENTED] MIP-2 |
| Cold SLOAD surcharge | 8,100 (Ethereum 2,100) | [DOCUMENTED] |
| Cold account access | 10,100 (Ethereum 2,600) | [DOCUMENTED] |
| Warm access | 100, unchanged | [DOCUMENTED] |
| Memory expansion | linear `w/2`, 8 MB cap | [DOCUMENTED] |
| Gas charged | `gas_limit`, **not** `gas_used` | [DOCUMENTED] |
| Blob transactions (type 3) | Not supported | [DOCUMENTED] |
| Global mempool | None. Forwarded to next 3 leaders. | [DOCUMENTED] |
| Third-party block builders | Refused delegation by VDP policy | [DOCUMENTED] |
| Execution delay `D` | 3 blocks | [DOCUMENTED] |
| Reserve balance | 10 MON inflight gas budget per EOA | [DOCUMENTED] |
| Native USDC (CCTP) | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | [DOCUMENTED] |

### 1.2 Precompiles, all [MEASURED]

Overhead of ~250 gas (warm STATICCALL 100, memory expansion 128, opcodes ~22) stripped.

| Precompile | Monad | Ethereum | Ratio |
|---|---|---|---|
| `ecRecover` 0x01 | 6,000 | 3,000 | 2x |
| `modexp` 0x05, 256-bit inverse | 4,712 | same | **1x** |
| `ecAdd` 0x06 | 300 | 150 | 2x |
| `ecMul` 0x07 | 30,000 | 6,000 | **5x** |
| `ecPairing` 0x08 | **225,000 + 170,000k** | 45,000 + 34,000k | **5x** |
| `bls12_g1_add` 0x0b | 375 | 375 | **1x** |
| `bls12_g1_msm` 0x0c, k=1/2/4 | 12,000 / 22,776 / 38,256 | same | **1x** |
| `bls12_g2_add` 0x0d | 600 | 600 | **1x** |
| `bls12_pairing` 0x0f | **37,700 + 32,600k** | same | **1x** |
| `p256_verify` 0x0100 | 6,900 | not on L1 | Monad only |

**The central asymmetry: Monad repriced BN254 by 5x and left EIP-2537 BLS12-381 untouched.** Every design decision below traces back to this.

Linear fit was exact across k = 0 to 5, five identical deltas of 170,000 and 32,600 respectively.

### 1.3 Composite operations, all [MEASURED] on Monad mainnet

Groth16 verifier core (l scalar mults and adds to build `vk_x`, then a 4-pair check):

| Public inputs | BN254 | BLS12-381 | Ratio |
|---|---|---|---|
| 1 | 937,441 | 181,427 | 5.17x |
| 2 | 968,903 | 192,236 | 5.04x |
| **4** | **1,031,828** | **207,781** | **4.97x** |
| 8 | 1,157,678 | 239,543 | 4.83x |

Homomorphic ElGamal accumulate (two point additions plus storage):

| Implementation | Compute | With storage |
|---|---|---|
| BN254 via `ecAdd` precompile, affine, 4 slots | 600 | 35,172 measured with zero slots |
| Twisted Edwards / Grumpkin, Jacobian, no inversion, 6 slots | **1,715** | 51,600 measured with zero slots |

Realistic with live non-zero slots: [DERIVED] 6 slots x (8,100 cold + 2,900 SSTORE_RESET) = 66,000, plus 1,715 compute, so **~68,000 per bet if one bet per transaction**.

**Batched, N bets per transaction:** [DERIVED] 66,000 fixed + 1,715 per bet. At N=100 that is **2,375 gas per bet.** The sequencer must batch anyway for nullifier subtree insertion, so this is free.

### 1.4 Derived throughput and cost

| | Gas | Per block | Per second | Cost at floor |
|---|---|---|---|---|
| Groth16 verify, BN254 | 1,031,828 | 145 | 484 | 0.103 MON |
| Groth16 verify, BLS12-381 | 207,781 | 722 | 2,406 | 0.021 MON |
| Homomorphic accumulate, batched | 1,715 | ~87,000 | ~290,000 | negligible |
| Relayer tx per EOA (10 MON / 0.103 MON) | | ~97 inflight per 900 ms | ~108 | |

All [DERIVED] from section 1.1 to 1.3.

---

## 2. What is actually being hidden, from whom

Every approach below is judged against this table. Get this right first; the technology is downstream.

| Fact | Hidden from public? | Hidden from operator? | Must be public? |
|---|---|---|---|
| Who bet | Yes | Yes, ideally | No |
| How much they bet | Yes | Yes, ideally | No |
| Individual positions and balances | Yes | Yes, ideally | No |
| Aggregate pool size / market depth | Yes | Depends on approach | No |
| **The price / implied probability** | **No** | **No** | **YES** |
| That settlement was executed correctly | No | No | **YES** |
| Resolution outcome | No | No | **YES** |

**The price must be public.** A prediction market that does not publish a probability has produced nothing. This single line eliminates half the technology stack, because it means you never need to hide the aggregate from the public, only the individuals from each other.

Your original pitch said "not even the current odds." **[CORRECTION to your framing]** If the odds are hidden from everyone, you have built a sealed pool, not a market, and the information aggregation that justifies prediction markets does not happen. What you probably want is: odds public, depth hidden, participants hidden. Those are different and the difference is the whole architecture.

---

## 3. Confidentiality approaches

### C1. ZK shielded pool

**What it is.** Encrypted UTXO notes. Poseidon commitment tree, indexed nullifier tree, Groth16 circuits for deposit, transfer, redeem. One Merkle root on chain, nothing else.

**Hides.** Individual positions, balances, identity, transaction graph.
**Does not hide.** Aggregate pool state. Anything the contract must compute on.

**Trust root.** Mathematical, plus a per-circuit trusted setup for Groth16.
**On Monad.** Yes, today. Nothing to wait for.
**Cost.** 1,031,828 gas per verify on BN254, 4 public inputs. [MEASURED]
**Throughput.** 484 proofs/sec chain-wide. [DERIVED]

**Verdict: BASELINE. Non-optional.** This is the layer that actually delivers the product promise. Everything else is an addition to it.

---

### C2. Threshold additively homomorphic encryption (exponential ElGamal)

**What it is.** Ciphertext `C = (g^r, H^r · g^m)` under a committee public key `H`. Adding two ciphertexts is two elliptic curve point additions. A t-of-n committee threshold-decrypts. Recover `m` from `g^m` by baby-step giant-step for bounded `m`.

**Hides.** Aggregate pool state, from everyone including the contract, until the committee decrypts.
**Does not hide.** Nothing else, and it only supports **addition**. No comparisons, no ciphertext multiplication, no branching on hidden values.

**Trust root.** Mathematical (DDH), plus t-of-n committee non-collusion.
**On Monad.** Yes, today. Native on existing precompiles.
**Cost.** 1,715 gas compute, ~2,375 gas per bet amortised in batches. [MEASURED] / [DERIVED]
**Prior art.** MACI (Minimal Anti-Collusion Infrastructure) uses ElGamal on BabyJubJub with circom for encrypted voting and homomorphic tallying. Production, not research.

**[CORRECTION]** In an earlier draft I wrote that ZK "provably cannot" give you encrypted shared state and that hiding the aggregate requires FHE or MPC. **That is false.** I conflated *arbitrary computation* on shared encrypted state (which does need FHE) with *addition* on shared encrypted state (which needs only AHE, a 1985 primitive). This was the single largest error in the earlier work.

**Verdict: RECOMMENDED for the pool state.** 500x the encrypted throughput of any FHE coprocessor, no external dependency, no chain-support wait. Constrained to addition, which is exactly what a parimutuel needs and nothing more.

---

### C3. FHE via hosted coprocessor (Fhenix CoFHE or Zama fhEVM)

**What it is.** Symbolic execution. `euint32` is `type euint32 is uint128`, a handle. The contract emits an event, derives the result handle deterministically, and continues. The FHE math runs offchain. [DOCUMENTED]

**Hides.** Arbitrary encrypted state, with arbitrary computation including comparisons.

**Availability.** [DOCUMENTED] from Fhenix's compatibility page:

| Network | Supported |
|---|---|
| Ethereum Sepolia | Yes |
| Arbitrum Sepolia | Yes |
| Base Sepolia | Yes |
| **Everything else, including all mainnets and Monad** | **No** |

"Support additional host chains" appears on the roadmap with timeline `N/A` and status ❌. [DOCUMENTED]

**Trust root, per Fhenix's own decentralization table, every row status ❌:** [DOCUMENTED]
- All Threshold Network parties run by Fhenix
- Keys and randomness from a Trusted Dealer
- **MPC requires all participants, not t-of-n.** T-out-of-N is an unscheduled roadmap item.
- SealOutput re-encryption performed centrally
- CoFHE trusted to compute correctly (AVS verification planned, not built)
- ZK-Verifier is an offchain ECDSA signer, only "intended to" run in a TEE
- Unaudited, not fully open source

**Throughput.** ~20 TPS on CPU, 500 to 1000 targeted with GPUs. [DOCUMENTED, Zama litepaper]
**Latency.** No figures published anywhere. Fhenix's gas and benchmarks page is a "Coming Soon" stub. [DOCUMENTED]
**Onchain cost.** Negligible. Monad's BN254 repricing is irrelevant to this path.

**[CORRECTION]** I earlier claimed the CoFHE mock stack exceeds EIP-170 and therefore only Monad's 128 KB limit can host it. **Wrong.** I compiled `@cofhe/mock-contracts@0.5.2`: [MEASURED]

| Compiler settings | MockTaskManager |
|---|---|
| optimizer off | 36,975 bytes, exceeds 24,576 |
| **optimizer on, runs=200** | **21,429 bytes, fits** |
| optimizer on, runs=1,000,000 | 27,971 bytes, exceeds |

The `code_size_limit = 100000` in Fhenix's `foundry.toml` exists because Foundry's default profile has the optimizer **off**. The mocks deploy on Ethereum. Do not put this claim in a pitch.

**Verdict: NOT AVAILABLE.** Architecturally a good fit, zero availability on Monad, no timeline, and every trust assumption currently sits with one company.

---

### C4. FHE self-hosted (Zama stack)

**What it is.** Deploy Zama's host contracts on Monad, run your own coprocessor, Gateway, and KMS MPC network. `fhevm`, `tfhe-rs`, `kms`, `mpc-operator` are all open source. [DOCUMENTED]

**Blockers.**
1. **Licensing.** BSD-3-Clause-Clear, free "only for development, research, prototyping, and experimentation purposes. However, for any commercial use of Zama's open source code, companies must purchase Zama's commercial patent license." [DOCUMENTED, verbatim] You said product. That is a cost line, not a footnote.
2. **Operational scope.** You become the coprocessor, the Gateway, and the KMS. That is a distributed systems company, not a feature.
3. **Trust.** You become the single trust anchor, which is strictly worse than a threshold committee you also run but which is 300 lines instead of a network.

**Verdict: NOT VIABLE for a product.** Viable as a research project if that is what you want.

---

### C5. TEE as the confidentiality root

**What it is.** Enclave holds the plaintext state and the decryption key. Intel SGX/TDX, AMD SEV-SNP, or Nvidia GPU CC.

**Current security state.** [PUBLISHED] Three attacks in a two-week window, October 2025:

| Attack | Target | Result |
|---|---|---|
| Battering RAM (KU Leuven, Birmingham) | SGX, SEV-SNP, DDR4 | Memory aliasing, replay |
| WireTap (US) | Server SGX, DDR4 | Attestation signing key extraction |
| **TEE.fail** (Georgia Tech, Purdue) | **SGX, TDX, SEV-SNP with Ciphertext Hiding, DDR5, plus Nvidia GPU CC** | **Attestation key extraction, forged quotes** |

Root cause is architectural, not a bug: server TEEs use deterministic AES-XTS memory encryption without integrity or replay protection, traded away for performance.

**The demonstration the TEE.fail authors chose:** forging TDX attestations on Ethereum's BuilderNet to read confidential transaction data and keys, enabling undetectable frontrunning. [PUBLISHED] That is your threat model with the names changed.

Phala, Secret Network, Crust, and IntegriTEE all issued emergency updates. Oasis did not need to, because their architecture never made a TEE a single point of failure.

**The nuance that decides it.** The attacks require physical access plus root. So the trust model reduces to *who runs the hardware*:

| Deployment | Physical attacker is | Assessment |
|---|---|---|
| One enclave you run in AWS/Azure confidential computing | The cloud provider | Bounded. Roughly the assumption you already make. |
| Permissionless network of TEE operators | Every operator, by construction | Fatal. Forged attestations are undetectable. |

**Why your product is close to the worst case.** Secret half-life: value of the secret times how long it must stay secret.
- TEE protecting a 3-second sealed bid: fine. Broken later, the secret was public anyway.
- TEE protecting a position held for months, in a market where knowing positions is directly monetisable: bad.
- A confidentiality break is **retroactive and silent.** Extract the key once, decrypt everything the enclave ever sealed, and nobody finds out.

**Verdict: DO NOT USE AS THE ROOT.**

---

### C6. TEE as committee hardening

**What it is.** Run the C2 threshold committee as t-of-n, with some members' key shares held inside enclaves.

**Why this works where C5 doesn't.** Compromising the pool now requires breaking t independent parties, and the TEE raises the cost of each one. The TEE stops being a single point of failure and becomes one layer of several. This is Oasis's stated architectural philosophy and it is why they stayed online through Battering RAM while Secret Network scrambled.

**Monad-specific advantage.** [MEASURED] Intel DCAP attestation verification is a chain of ECDSA signatures over secp256r1. Most EVM chains need a Solidity P256 implementation at 200k to 1M gas. **Monad has the P256 precompile at `0x0100`, measured at 6,900 gas.** A three-signature quote chain is roughly 21,000 gas plus certificate parsing. [DERIVED]

**Onchain remote attestation is cheap on Monad in a way it is not almost anywhere else.** If you use TEEs at all, verify attestation on chain per operation and make the enclave measurement part of protocol state. Affordable here, not elsewhere. Nobody has published this.

**Verdict: RECOMMENDED as defence in depth, phase 3.** Never let a TEE be the thing that can move money.

---

### C7. MPC committee with secret-shared state

**What it is.** N parties hold additive or Shamir shares of the pool state and compute on shares.

**Versus C2.** For addition only, threshold ElGamal is strictly simpler: no per-operation interaction, no online protocol, the contract does the addition itself. MPC only wins when you need comparisons, and then it needs a live interactive protocol per operation, which fights a 300 ms chain.

**Verdict: DOMINATED by C2 for this use case.** Revisit only if you add comparisons.

---

### C8. Third-party privacy stack (Unlink)

**What it is.** Private accounts on existing chains. Groth16, encrypted UTXO notes, relayers, ERC-4337 sponsorship, and an `execute()` primitive that atomically withdraws from the pool, runs arbitrary calls, and returns tokens privately.

**Availability.** [DOCUMENTED] `monad-testnet` (10143) **available now**. `monad` mainnet (143) requires an access grant. SDK `@unlink-xyz/sdk` latest canary `0.3.0-canary.772`, published 28 July 2026. [MEASURED, npm registry]

**The catch.** [DOCUMENTED, their trust model page] The spending key never leaves the client, but **the viewing and nullifying keys are sent to Unlink's Engine at registration and retained**, and the Engine generates all Groth16 proofs. You get privacy from the chain and from other users. You do not get privacy from Unlink.

**Verdict: FALLBACK ONLY.** Acceptable if circuit work slips. Not acceptable as the foundation of a product whose entire claim is privacy.

---

### C9. Commit and reveal

**What it is.** Submit `H(bet || salt)`, reveal later.

**Fails on.** The last-mover withholding problem: whoever dislikes the emerging outcome simply does not reveal. Patchable with bond slashing. Also provides no persistent confidentiality, only temporary.

**Verdict: NOT NEEDED.** See M1: a parimutuel is order independent, so there is nothing to seal against.

---

### C10. Trusted operator with an offchain database

**What it is.** You hold the positions in Postgres and settle on chain.

**I am listing this because it is the honest baseline and nobody names it.** It delivers every confidentiality property in section 2 except "hidden from operator." It ships in a week. Most "private" products in this category are functionally this.

**Verdict: NOT WHAT YOU ARE BUILDING**, but if you cannot articulate what your architecture buys over this, in one sentence, you have a positioning problem rather than a technology problem.

---

## 4. Correctness and verification approaches

### V1. Native onchain execution

Contract performs the computation itself. Nothing to prove because nothing happened offchain.
**Cost.** 1,715 gas for a homomorphic addition. [MEASURED]
**Verdict: USE THIS.** Available precisely because the mechanism is addition-only.

### V2. Optimistic recomputation and fraud proof

FHE evaluation is deterministic and public. Ciphertexts are public, operations are public, only plaintexts are hidden. Anyone can re-run and check.

Zama's own position: "everything the coprocessor does is publicly verifiable, and anyone can just recompute the ciphertexts to verify the result." [DOCUMENTED]

**Cost.** Near zero, plus a challenge window.
**Verdict: THE CORRECT ANSWER if you ever do use a coprocessor.** Not a SNARK.

### V3. SNARK on input validity (ZKPoK)

Prove each encrypted input is well-formed and you know the plaintext. Blocks malleability and chosen-ciphertext attacks, to which FHE schemes are inherently vulnerable.

Both CoFHE and Zama ship this. [DOCUMENTED]
**Cost.** Standard Groth16, 1,031,828 gas on BN254. [MEASURED]
**Verdict: MANDATORY.** This is where the SNARK belongs in any encrypted design.

### V4. SNARK on FHE evaluation (verifiable FHE)

**[PUBLISHED]** Tremblay Thibault and Walter (Zama), *Towards Verifiable FHE in Practice: Proving Correct Execution of TFHE's Bootstrapping using plonky2*, eprint 2024/451. State of the art, by the parties with the strongest incentive to make it look good.

| Machine | Prove ONE programmable bootstrap |
|---|---|
| AWS Hpc7a.96xlarge (192 cores, 768 GB) | 18 min |
| AWS C6i.metal (128 cores, 256 GB) | 21 min |
| M2 MacBook Pro | 48 min |

Proof ~200 kB, plonky2 verification <10 ms (not EVM verification).

zkVM route, per single *step* of blind rotation: RISC Zero 23 min, SP1 2.5 min. Neither could prove a full PBS. A full PBS needs n=728 steps, so SP1 extrapolates to roughly **30 hours per bootstrap**. [DERIVED from published per-step figures]

Cost: [ESTIMATE] ~$2 of compute per FHE operation at c6i.metal on-demand pricing.

Authors' own conclusion: "still likely to be too costly for many applications." Their suggested deployment is "akin to hybrid rollups, where a proof is only required in case of a dispute," which is V2, not V4.

Additional onchain cost: a 200 kB FRI proof is expensive to verify in the EVM. You would wrap in Groth16, adding 1,031,828 gas [MEASURED] plus wrapping proof time.

**Verdict: RESEARCH, NOT PRODUCT.** Approximately 21 minutes of a 128-core machine per FHE gate-equivalent.

### V5. Onchain TEE attestation

DCAP quote verification via the P256 precompile. **6,900 gas per signature** [MEASURED], ~21,000 for a three-signature chain [DERIVED].
**Verdict: CHEAP ON MONAD.** Use it if you use TEEs at all.

### V6. Threshold decryption proof

Chaum-Pedersen proof of discrete-log equality per decryption share. Verifying t shares costs roughly 2t scalar multiplications.
**Cost.** [DERIVED] At t=3 on BN254: 6 x 30,000 = 180,000 gas per decryption event. Once per publication interval, not per bet. Acceptable.
**Verdict: REQUIRED once the committee is t-of-n.**

---

## 5. Market mechanism approaches

### M1. Parimutuel pools

Stakes pool per outcome. Payout pro rata from the combined pool.

**The property that decides the architecture: parimutuel is order independent.** Payout depends only on final pool composition, never on arrival order. First and last bet on the same side pay identically.

Consequences:
- **Zero MEV surface.** No price impact to sandwich, no ordering advantage to buy. A leader reordering your transaction gains nothing.
- **No batch auction, no commit-reveal, no sealed bids needed for ordering reasons.** [CORRECTION] I specified a frequent batch auction in two earlier drafts. It was necessary for an order book and is dead weight here. Cut it.
- **Addition only**, so it works under C2 additive homomorphic encryption.
- **No counterparty required**, which is the entire problem in a thin conditional market.

**Costs.** No limit orders. No exit before resolution. Worse price discovery than a book. Cannot be arbitraged, hence the documented favourite-longshot bias. **In a conditional market this compounds: capital is locked in a branch until A resolves, potentially for months.**

**The one real weakness: late money.** Bettors arriving after the ratio moves get a free read on everyone else's information. **This is exactly what C2 encryption fixes.** Encrypted pool state is therefore not a privacy garnish; it is what makes the mechanism sound.

**Verdict: RECOMMENDED, with the lockup caveat stated openly.**

### M2. Central limit order book

**Requires comparisons** for matching, which rules out C2 and forces C3/C4 (unavailable) or C5 (unsafe) or a trusted matching engine.
Has a real MEV surface, on a chain with no encrypted mempool and, by VDP policy, no purchasable private orderflow.
**Verdict: REJECTED** unless you accept a trusted matcher.

### M3. LMSR or AMM

Needs `exp` and `log`, impossible under C2. Public `q` vector leaks the aggregate positioning you were hiding. Requires a subsidy.
**Verdict: REJECTED.**

### M4. Frequent batch auction

Solves ordering for M2. Redundant for M1.
**Verdict: CUT.** [CORRECTION] Present in earlier drafts.

### M5. Conditional Token Framework nesting

Nested split: `USDC → {A_YES, A_NO}`, then `A_YES → {A∧B, A∧¬B}`. Trade the second pair. If A resolves NO, both conditional legs are worthless but every trader still holds `A_NO` which pays 1, so collateral returns in full and the conditional trade had zero P&L. That is the refund.

`P(B|A) = price(A∧B) / (price(A∧B) + price(A∧¬B))`.

**Verdict: REQUIRED** for conditional markets. Two levels only; three fragments liquidity past usefulness.

---

## 6. Resolution approaches

**[DOCUMENTED]** I pulled the full `monad-crypto/protocols` mainnet registry, 190 entries. **There is no UMA, no Reality.eth, and no Kleros on Monad.** Polymarket runs on UMA. Omen runs on Reality.eth plus Kleros. **You are building the resolver, not integrating one.**

Live oracles: Chainlink, Pyth, Redstone, Stork, Supra, Switchboard, Band, Chronicle. eOracle is deployed but dead, zero feed updates since 15 Jan 2026. [DOCUMENTED]

### Two structural problems unique to conditional resolution

**R-X1. The void attack.** In a normal market, manipulating resolution means making your side win. Here there is a cheaper third option: if you are losing the B|A book, make **A** resolve NO. Everything voids and you are refunded. You do not need a specific outcome in B, only *ambiguity in A*.

**Hard rule: A must be strictly harder to ambiguate than B. Never the reverse.** A should be a discrete, publicly recorded event with one canonical source. B can be the fuzzy numeric one. Encode this at market creation.

Mitigation bonus: C2 encrypted pools partially defuse this. If you cannot see whether you are losing, you do not know when to trigger the void.

**R-X2. The dynamic window.** "If Musk resigns, TSLA drops 50%" by when, from what baseline? B's measurement window starts when A resolves, which is unknown at market creation. Most prediction market contracts assume fixed windows. Yours cannot.

### R1. Push and pull price oracles
Chainlink, Pyth, Redstone, Stork, Supra. Live on mainnet.
Covers: price, on-chain metrics, protocol revenue, TVL. Zero human judgment, zero dispute surface.
**Verdict: SHIP ONLY THIS IN v1.** Removes the single largest source of product risk.

### R2. Custom API feed
Switchboard Feed Builder, permissionless feed creation against arbitrary APIs with variable overrides for API-gated sources. Contract `0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67`, live. [DOCUMENTED]
Covers more than it sounds: "did Tesla file an 8-K with Item 5.02" is a deterministic query against EDGAR.
**Verdict: PHASE 3.**

### R3. zkTLS
Prove an HTTPS response without trusting an oracle operator. Primus is on Monad but only as a token-distribution app, not a general verifier contract. [DOCUMENTED] Reclaim is not in the registry.
**Verdict: [UNVERIFIED] whether a usable general verifier exists on Monad.** Check before planning around it.

### R4. Optimistic oracle, built by you
Propose with bond, challenge window, escalate to a resolution council, loser's bond pays the winner. ~300 lines, standard design.
**Verdict: DEFER.** It is the weakest link in the whole product. Do not ship it until R1 and R2 are running and demand exists.

### R5. Committee or multisig resolver
Honest, centralised, fine for a v1 with disclosure.
**Verdict: ACCEPTABLE INTERIM.**

### Requirements regardless of tier
1. Resolver address and a hash of the full resolution spec committed at market creation, immutable. Spec text offchain, hash onchain.
2. A gap between betting close and resolution start. Otherwise last-second bets front-run known information, and unlike ordinary parimutuel bets that one *is* profitable.
3. Resolution stays fully separate from decryption. The resolver emits a branch selector only; the committee decrypts the numbers. Independent trust surfaces.
4. UX: the chain finalises in 600 ms, markets resolve in days. "Closed, resolving, funds locked until X" must be a first-class state.

---

## 7. Decision matrix

| ID | Approach | Hides aggregate | On Monad today | Trust root | Cost | Verdict |
|---|---|---|---|---|---|---|
| C1 | ZK shielded pool | No | Yes | Math + trusted setup | 1,031,828 gas | **BASELINE** |
| C2 | Threshold ElGamal (AHE) | Yes, addition only | Yes | Math + t-of-n | 1,715 gas | **RECOMMENDED** |
| C3 | Hosted FHE coprocessor | Yes, arbitrary | **No** | One company | negligible onchain | NOT AVAILABLE |
| C4 | Self-hosted FHE | Yes, arbitrary | Possible | You alone | commercial license | NOT VIABLE |
| C5 | TEE as root | Yes, arbitrary | Yes | Hardware vendor + physical | cheap | **DO NOT** |
| C6 | TEE hardening committee | via C2 | Yes | Adds a layer to C2 | 6,900 gas attestation | PHASE 3 |
| C7 | MPC secret sharing | Yes | Yes | t-of-n + liveness | interactive | DOMINATED by C2 |
| C8 | Unlink | No | Testnet yes | Unlink holds viewing keys | sponsored | FALLBACK |
| C9 | Commit-reveal | Temporarily | Yes | Bonds | trivial | NOT NEEDED |
| C10 | Trusted operator | Yes | Yes | You | ~zero | THE BASELINE TO BEAT |

| ID | Verification | Cost | Verdict |
|---|---|---|---|
| V1 | Native onchain | 1,715 gas | **USE** |
| V2 | Optimistic recomputation | ~free + window | correct answer for coprocessors |
| V3 | SNARK on inputs | 1,031,828 gas | **MANDATORY** |
| V4 | SNARK on FHE evaluation | 21 min/bootstrap | RESEARCH ONLY |
| V5 | Onchain attestation | 6,900 gas/sig | cheap on Monad |
| V6 | Threshold decryption proof | ~180,000 gas/event | required at t-of-n |

---

## 8. Recommended composition

```
 PUBLIC                                  PRIVATE
 ──────────────────────────────          ────────────────────────────────
 ConditionalVault            [M5]        ShieldedPool               [C1]
   USDC → {A_YES, A_NO}                    Poseidon commitment tree
   A_YES → {A∧B, A∧¬B}                     indexed nullifier tree
   A_NO redeems 1:1 if A = NO               ONE root onchain

 ElGamalAccumulator          [C2]        Circuits, circom/Groth16/BN254
   encAB, encAnotB                         deposit
   BabyJubJub twisted Edwards              bet     → also emits Enc(m) and
   1,715 gas per add          [V1]                   proves it encrypts the
                                                     same m               [V3]
 Publisher                                 redeem  → MUST be private
   threshold decrypt the RATIO
   publish P(B|A) on a cadence [V6]      Sequencer
   pool magnitudes never revealed          batches, maintains trees,
                                           10 sharded relayer EOAs
 Resolver                    [R1]
   price/onchain metrics only in v1
```

**Curve choice: BN254 throughout, not BLS12-381, despite the measured 4.97x.**

The ElGamal must be proved correct in-circuit. That requires the encryption curve's base field to equal the proof system's scalar field. For circom over BN254 that curve is BabyJubJub, which circomlib ships and MACI runs in production. Switching the verifier to BLS12-381 breaks that alignment and forces non-native EC arithmetic in the circuit, a 10x to 100x constraint blowup. [ESTIMATE on the blowup magnitude]

You would save 820,000 gas per proof, worth roughly two cents, and buy a circuit nobody can prove. **1,031,828 gas is a quarter of a cent and supports 484 proofs/sec. That is not a constraint.**

The BLS12-381 measurement remains worth publishing standalone. It is the first quantification of Monad's repricing asymmetry. **Write the post. Do not build the product around it.**

### Non-negotiable constraints, each traceable to a measurement

| Rule | Because |
|---|---|
| Root-only onchain state, indexed nullifier tree | Cold SLOAD measured at 8,100, 4x Ethereum |
| **All circuits padded to one uniform gas limit** | Monad charges `gas_limit` and it is a public field, so it fingerprints which private action you took |
| Redemption inside the shielded pool | Public `A_NO` claims reveal every position retroactively. Skipping this makes the privacy claim false, not weak. |
| Fixed denomination splits | The split reveals participation and size even when trades are hidden |
| Accumulator slots contiguous | MIP-8: 128 contiguous slots share one 4 KB page, warm after one cold touch |
| Sequencer always batches | Turns 68,000 gas per bet into 1,715 |
| Never call `eth_estimateGas` | You pay the limit; MetaMask sets it absurdly high when estimation reverts |
| Publish on a cadence, not continuously | Continuous revelation reintroduces the late-money problem the encryption exists to solve |
| Anonymity set = batch window, not block | 300 ms blocks; sampled block had 7 transactions |

---

## 9. Build plan

### Phase 0, days 1 to 3: kill the risk
- `ConditionalVault` skeleton on testnet. Nested split, `A_NO` refund path. Plain Solidity.
- Prove one trivial BabyJubJub ElGamal circuit in circom, verify on testnet, **record real gas.** My 1,031,828 is the verifier core; a production circuit adds field arithmetic and input validation. [ESTIMATE] +15% to 25%. **If it exceeds 1.5M, stop and reassess.**
- Use **Monad Foundry**, not stock Foundry, or every gas number you produce will be wrong.

### Phase 1, weeks 1 to 3: the market, public pools
- Full `ConditionalVault` with test suite.
- Parimutuel pools, public sums, P(B|A) published.
- `ShieldedPool`: Poseidon commitments, indexed nullifier tree, subtree batch insertion, one root.
- Circuits: deposit, bet, redeem. Four or fewer public inputs; each costs 30,000 gas on BN254.
- Sequencer, batching, 10 relayer EOAs.
- CI test asserting all three action transactions carry identical gas limits.

**Milestone: private positions, public pool.** Internal milestone, not a launch. Late money still unsolved.

### Phase 2, weeks 4 to 5: encrypted pools
- `ElGamalAccumulator`. BabyJubJub, extended coordinates, no inversion in the hot path.
- Extend `bet` circuit to emit `Enc(m)` and prove consistency with the spent note. Native BabyJubJub in a BN254 circuit. **MACI is the reference implementation to read.**
- Publisher: decrypt on cadence, BSGS to recover `m` from `g^m`, publish the ratio only.
- **Single decryption key, disclosed plainly.**

**Milestone: the mechanism actually works.**

### Phase 3, weeks 6 to 8: product
- Frontend on `monadNewHeads` and `monadLogs` websockets.
- Resolution integration, dispute window, R2 custom feeds.
- **Twenty seeded markets. Breadth is the thesis; one market proves nothing.**
- Threshold decryption 3-of-5 with Chaum-Pedersen [V6], optionally TEE-hardened [C6] with onchain attestation [V5].
- Publish the gas measurement post.

### Cut lines, in order
1. Threshold committee → ship single-key, say so
2. Twenty markets → ship five
3. BLS12-381 → already cut
4. Encrypted pools → only if Phase 1 slips badly, and then you have a shielded prediction market, not a solution to late money. Say the smaller thing.
5. **Never cut private redemption.**

---

## 10. What this is not

- **Not FHE.** Additively homomorphic only. No comparisons, no encrypted matching, no branching on hidden data. **Say "homomorphic encryption." Never say "fully." Someone will check.**
- **Not decentralised at launch.** One sequencer, one decryption key. Liveness depends on you; safety does not.
- **Not a TEE product.** And do not present TEE as a "fallback for FHE." They are different trust roots, mathematical hardness versus a hardware vendor plus physical security of a specific machine. Presenting them as substitutes at different availability tiers signals you have not costed the difference.
- **Not hiding the odds.** Odds public, depth hidden, participants hidden.
- **Not a general prediction market.** Two conditioning levels.
- **Not regulator-proof.** Private markets on real-world outcomes are contested nearly everywhere and privacy sharpens that. Polymarket is fully public and still drew CFTC action and a French ban. Scoping to DAO governance, protocol KPIs, and internal forecasting is a deliberate choice.
- **Not demand-validated.** See section 11.

---

## 11. The open risk I have not resolved

Everything above is engineering. The engineering is sound and the measurements are real. The demand is not established.

Conditional markets have failed repeatedly since Hanson proposed them: Augur, Gnosis, Omen, MetaDAO. The documented failure modes in Butter's governance research corpus are thin liquidity, metric gaming, and oracle reliability. **Privacy is not on that list.** No post-mortem says "we would have made it if positions were hidden."

Monad blocks are 4% full. [MEASURED] I cited that repeatedly as cheap blockspace. It is also a demand signal. Castora already runs price prediction markets on Monad; check their real volume before assuming an audience.

**Cheapest way to resolve this, before Phase 1:** find three DAOs or protocols who will *commit* to running one market. Not "sounds cool." Committed. If you cannot find three, the cryptography is irrelevant. If you can, they will tell you whether they want privacy, or capital efficiency, or resolution they trust, or just an interface that does not require understanding conditional tokens.

The measurement work in section 1 is publishable **now**, independent of the product, and is worth real reputational value regardless of how that conversation goes. That is one week and it derisks nothing but costs nothing.

---

## Appendix A: reproduce every measurement

```python
import json, urllib.request
T = "0x000000000000000000000000000000000000dEaD"

def build(addr, args_size):
    return ("0x5a"                        # GAS
            "6020" "612000"               # retSize=32, retOffset=0x2000
            + "61%04x" % args_size +      # argsSize
            "6000" + "60%02x" % addr +    # argsOffset=0, address
            "62ffffff" "fa" "50"          # gas, STATICCALL, POP
            "5a" "90" "03"                # GAS, SWAP1, SUB
            "600052" "60206000f3")        # MSTORE, RETURN

def measure(addr, size):
    p = {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
         {"to":T,"data":"0x","gas":"0x2000000"},"latest",
         {T:{"code":build(addr,size)}}]}
    r = urllib.request.Request("https://rpc.monad.xyz", data=json.dumps(p).encode(),
                               headers={"Content-Type":"application/json"})
    return int(json.loads(urllib.request.urlopen(r,timeout=30).read())["result"],16) - 250

print("ecAdd  ", measure(0x06,128))                    # 300
print("ecMul  ", measure(0x07,96))                     # 30,000
for k in range(6):  print("bn254  k=%d"%k, measure(0x08,k*192))   # 225,000 + 170,000k
for k in range(1,6):print("bls    k=%d"%k, measure(0x0f,k*384))   # 37,700 +  32,600k
```

Constant overhead ~250 gas, cancels in the deltas. A result near 16,777,215 means the precompile reverted and consumed all forwarded gas, which distinguishes a valid measurement from invalid input.

Composite figures (Groth16 cores, ElGamal accumulators, MODEXP) came from compiled Solidity run the same way. CoFHE mock sizes came from `npm install @cofhe/mock-contracts@0.5.2` and compiling with solc 0.8.25 at varying optimizer settings.

---

## Appendix B: sources

**Monad.** Full crawl of `docs.monad.xyz` (187 pages, 28 July 2026). `mips.monad.xyz` MIP-2, 4, 7, 8, 11, 12. `monad-crypto/protocols` mainnet registry (190 entries). Live `eth_getBlockByNumber` and `eth_call` against `rpc.monad.xyz`.

**FHE.** Full crawl of `cofhe-docs.fhenix.zone` (96 pages). Zama Protocol litepaper and `docs.zama.org`. `github.com/zama-ai` licensing. Tremblay Thibault and Walter, eprint 2024/451.

**TEE.** TEE.fail (Georgia Tech, Purdue, Oct 2025), WireTap, Battering RAM.

**Privacy stack.** `docs.unlink.xyz`, npm registry for `@unlink-xyz/sdk`.

**Mechanism.** Butter / ggresearch futarchy corpus. Alea Research and Umbra Research on MetaDAO. EIP-1108, EIP-2537, EIP-2565, EIP-7951.
