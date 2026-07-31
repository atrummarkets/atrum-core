# Atrum — Phase 2 on Monad testnet

**31 July 2026.** What was executed on a live chain, what each transaction proves, and
what is still not proven.

Chain 10143 (Monad testnet). Explorer: `https://testnet.monadexplorer.com`.
Deployer / sequencer / resolver: [`0x7975E591…C080c`](https://testnet.monadexplorer.com/address/0x7975e591c26e6c6d9b0cfd9a81f6d61a921c080c).

Labelling follows the repo's convention: **[MEASURED]** on-chain, **[LOCAL ONLY]**
reproduced in `forge` but not broadcast, **[NOT VERIFIED]** neither.

---

## 1. The headline

**A bet entered a live prediction market without the chain ever learning its size, and
the pool total it joined is a ciphertext that only the committee key can read.**

Two encrypted bets of **100** and **37** units were placed. The chain holds
`Enc(137)`. The public parimutuel total for that market reads **0** — not because
nothing was staked, but because the contract was never told what was staked.

The same deployment runs a Phase 1 plaintext market side by side, where the identical
stake of 100 is plainly visible in calldata. The difference is one function call.

---

## 2. Deployed contracts

| Contract | Address |
|---|---|
| `ShieldedPool` | [`0xD7EF64B2…eD0d`](https://testnet.monadexplorer.com/address/0xD7EF64B254e37c60e3Fa6897A4233dF3b6DceD0d) |
| `ElGamalAccumulator` | [`0x55023372…F286`](https://testnet.monadexplorer.com/address/0x550233726824E7cE668638B9d325Daf00Bc3F286) |
| `EncryptedParimutuelPool` | [`0x179413D8…bF0f`](https://testnet.monadexplorer.com/address/0x179413D8A2912e3C97Ba6d17Cfc6251D66bebF0f) |
| `BetEncryptedVerifier` | [`0x151AF77c…9bF4`](https://testnet.monadexplorer.com/address/0x151AF77cEd9B5752C06736ace021f8d8E8fb9bF4) |
| `IncrementalMerkleTree` | [`0x8608Eb12…F62E`](https://testnet.monadexplorer.com/address/0x8608Eb120cD488eC207cCe026558E134A6F6F62E) |
| `ParimutuelPool` | [`0x44bC3D03…bbDA`](https://testnet.monadexplorer.com/address/0x44bC3D03228cBd4cF90F80e5b2a1F4c34707bbDA) |
| `MappingNullifierSet` | [`0xE6C1042D…5E2f`](https://testnet.monadexplorer.com/address/0xE6C1042D19f833701cee50B95aC26551FFA25E2f) |
| `PoseidonT3` | [`0x452Ddb7D…1310`](https://testnet.monadexplorer.com/address/0x452Ddb7De7e668073304fA3C613d3A3E67011310) |
| `Vault` (market 7, plaintext) | [`0x0D341717…AC6d`](https://testnet.monadexplorer.com/address/0x0D3417171C62905F1FeB59e8c8151C2E635FAC6d) |
| `Vault` (market 8, encrypted) | [`0xf787e3A8…51aE`](https://testnet.monadexplorer.com/address/0xf787e3A8319df794f7defD16FE000146A29151aE) |
| Collateral (MockERC20, 6dp) | [`0x7dD7DDd7…bEE6`](https://testnet.monadexplorer.com/address/0x7dD7DDd7871069645D3E77f21B059159DB33bEE6) |

Notable deploy costs: `BetEncryptedVerifier` 638,316 (the 8-signal verifier),
`ElGamalAccumulator` 1,082,446, `EncryptedParimutuelPool` 1,785,412,
`registerEncryptedMarket` 773,073 — it initialises both accumulator sides to `Enc(0)`
in the same transaction, so a market can never be bet into before initialisation.

### Source verification [MEASURED]

**All 16 Solidity contracts are verified `exact_match` on Sourcify** (chain 10143),
including the three settlement-rig contracts from §5. Confirmed by querying the
registry independently of the submission responses:

```bash
curl https://sourcify-api-monad.blockvision.org/v2/contract/10143/<address>
# -> {"match":"exact_match", ...}
```

`exact_match` means the deployed runtime bytecode matches a compilation of this
source including the metadata hash — not merely functionally equivalent bytecode. It
is what makes every claim in this document auditable by a third party rather than
taken on trust.

Monad testnet exposes no Etherscan-style API (`etherscanAPI: false` in Sourcify's own
chain list), so verification goes through Sourcify directly; the exact command is
recorded in `contracts/foundry.toml`.

**One contract is deliberately unverifiable: `PoseidonT3`.** It is raw EVM assembly
emitted by circomlibjs, deployed from a bytecode blob, with no Solidity source to
match — the Sourcify lookup returns `match: null`. Its correctness is established
differently and more directly: `Deploy.s.sol` requires the deployed contract's
`Poseidon(1,2)` to equal circomlibjs's own digest before the deployment continues, so a
truncated or mis-wrapped runtime aborts the deploy rather than surviving to be
discovered later.

---

## 3. The lifecycle, transaction by transaction [MEASURED]

All succeeded. Gas is real, paid, on-chain.

| # | Action | Gas | Transaction |
|---|---|---|---|
| 1 | `approve` | 66,310 | [`0xba545261…`](https://testnet.monadexplorer.com/tx/0xba545261b324ab0dc7e2248d2fd6982782cc0d8a0425bb34649bb0a6d10cecd7) |
| 2 | `deposit` (market 7) | 1,816,159 | [`0x5d4a0340…`](https://testnet.monadexplorer.com/tx/0x5d4a0340e465ac16dffb4af87ba6c21546bbbe417318ef79c214a4b1f529dc88) |
| 3 | `flushBatch` | 3,734,454 | [`0xd3a2280b…`](https://testnet.monadexplorer.com/tx/0xd3a2280b72519180870c724f889f9ef47600a56d2e719d516c081ade6fb2fbfa) |
| 4 | **`bet` (plaintext)** | 1,644,303 | [`0xaaefeccc…`](https://testnet.monadexplorer.com/tx/0xaaefeccc6f5572535766866c6e3186486b0ecee42a98f6c7abf02bd7b5100059) |
| 5 | `flushBatch` | 3,652,118 | [`0x777c8aaa…`](https://testnet.monadexplorer.com/tx/0x777c8aaa6be96bfbf2728a74b75cb4ff9b675df3fca0e6683d0bccc9bad5943e) |
| 6 | `deposit` (market 8) | 1,793,723 | [`0xa011db8f…`](https://testnet.monadexplorer.com/tx/0xa011db8f1a0b58a66a3ebec1b4f4c5d92747397d617ac811df00d732f6ad975c) |
| 7 | `flushBatch` | 3,652,118 | [`0x15f01183…`](https://testnet.monadexplorer.com/tx/0x15f01183c2cf77a4033959782a8dbeb0b065fa419fd98b1c62357ce3e8859a03) |
| 8 | **`betEncrypted` #1 (stake 100)** | **1,904,506** | [`0xa0e5ca8b…`](https://testnet.monadexplorer.com/tx/0xa0e5ca8b8282c95fcfbcb96e9201dc80d5a7c88cb9fe3f380d7b69050f0b2c86) |
| 9 | `deposit` (market 8, 2nd) | 1,659,268 | [`0xceb5ea36…`](https://testnet.monadexplorer.com/tx/0xceb5ea36c7100ffa4a396a4c424fec8671721f525493c267e8cefc276b0b616a) |
| 10 | `flushBatch` (2 real leaves) | 3,649,016 | [`0xd2597a0b…`](https://testnet.monadexplorer.com/tx/0xd2597a0b600d22302a1122308eddfd6091bd36a67dd0d6be36e6c7f93f25b867) |
| 11 | **`betEncrypted` #2 (stake 37)** | **1,859,677** | [`0x71c71033…`](https://testnet.monadexplorer.com/tx/0x71c710336b3f248a693855bdb27f7e8bf7ff6256f26710a9095ba72a60113bb6) |

---

## 4. The privacy claims, checked rather than asserted

### 4.1 The stake is not in the calldata [MEASURED]

`betEncrypted` #1 carries 516 bytes of calldata, 16 words. Scanning every word for the
staked value:

```
first stake (100) appears at word indices: NOWHERE
second stake (37) appears at word indices: NOWHERE
```

The only human-readable word is `33` — that is `betMeta = marketId * 4 + outcome`
= `8 * 4 + 1`, i.e. market 8, YES. Market and side are public **by design**; the build
plan is explicit that odds are public and only depth and identity are hidden.

The contrast is the whole point. Decoding the plaintext `bet` from the same run:

```
betData word: 534955578137576996964
  unpacked -> marketId: 7  outcome: 1  units: 100
```

Same lifecycle, same stake size, one function apart: in Phase 1 the amount sits in
public calldata; in Phase 2 it is not present at any offset.

### 4.2 The public pool total never moved [MEASURED]

Read directly from `ParimutuelPool`:

```
market 8 (encrypted) totalUnits : 0
market 7 (plaintext) totalUnits : 100
```

137 units of real, collateral-backed stake entered market 8. The public total reads
zero because the contract was never given a number to add.

### 4.3 The ciphertext on-chain is real, and decrypts to the true total [MEASURED]

`scripts/verify_onchain.mjs` reads `ElGamalAccumulator.totalAffine(8, 1)` over plain
`eth_call` — no local state — and decrypts it with the committee key using the same
BSGS the publisher will use:

```
C1 = (12388296992209888201692020963338678384143741604174097441948999898994687376860,
      17484953415046052341270068297030937461322912948961194039819018367979651184858)
C2 = (15589965530789276059735995958983429517350868678444350413475774232062209963276,
      12191103447833392420550592268336032663017757365835311906153737088748408142691)
  ok    C1 is on the curve
  ok    C2 is on the curve
  decrypts to: 137
  ok    decrypted total equals the expected 137
```

`137 = 100 + 37`. Reproduce:

```bash
cd circuits && ACCUMULATOR=0x550233726824E7cE668638B9d325Daf00Bc3F286 \
  MARKET_ID=8 EXPECTED=137 node scripts/verify_onchain.mjs
```

The NO side reads `(0,1)` — the curve identity, `Enc(0)` — confirming an untouched
side is distinguishable from an uninitialised one, which is the failure the
`initialised` flag exists to prevent.

### 4.4 Homomorphic addition happened on-chain [MEASURED]

The accumulator was handed two independent ciphertexts and never a plaintext. Its
resulting state was asserted equal, **field element for field element**, to the
ciphertext sum computed off-chain by `circomlibjs` — all four coordinates checked in
`ExerciseEncrypted._report`, any mismatch reverting the transaction.

This is the property the whole architecture rests on, and it is now demonstrated on a
live chain rather than in a unit test.

### 4.5 The tree agrees with the prover [MEASURED]

```
on-chain root : 640786437924043091714481218523665609986894724673683186750896085826436440119
expected root : 640786437924043091714481218523665609986894724673683186750896085826436440119
```

Three independent implementations of the same Poseidon hashing rules — circom,
Solidity, and the sequencer's TypeScript mirror — agree on a live chain across four
grafted batches.

---

## 5. The attack: a valid proof carrying a false total [MEASURED]

The most important transaction in this document is one that **failed**.

`ChaumPedersen.verify` proves a decryption share `D` was computed with the committee's
real key. It proves **nothing** about what integer the publisher claims alongside it.
A publisher supplying an honest share, a valid proof, and a fabricated total would
settle the market at that fabricated number — overpaying one side out of the other's
collateral, with nothing on-chain to notice.

`EncryptedParimutuelPool._checkClaimedPlaintext` closes this by binding the claim to
the ciphertext algebraically: with `C2 = [m]G + [r]H` and `D = [r]H`, it must hold that
`C2 − D = [m]G`.

Exercised against deployed bytecode on a rig market (id 9) whose true totals are
YES 425 / NO 350:

| Attempt | Claimed YES | Result | Transaction |
|---|---|---|---|
| **The lie** | **1275** (3×) | **REVERTED**, `status 0x0` | [`0x8c73156f…`](https://testnet.monadexplorer.com/tx/0x8c73156fc95c598e8d6e964eaa8d1c60c2522de42a396b8fa1ea4a34bca0a3a8) |
| The truth | 425 | success, 2,410,578 gas | [`0xe62d5e86…`](https://testnet.monadexplorer.com/tx/0xe62d5e86a64a5b294205cbfe00854afd94d6e7611ede312eb26dda8cd1b9113e) |

The revert data is `0x3923e9b5`:

```
ClaimedPlaintextMismatch() = 0x3923e9b5   <-- what was returned
InvalidDecryptionProof()   = 0xf8833d50
```

**This distinction is the finding.** The transaction did not fail because the proof was
bad — the Chaum-Pedersen proof verified perfectly. It failed only at the plaintext
binding. Had that binding been absent, this transaction would have succeeded and the
market would have settled at 1275.

That is not hypothetical: a mutation test with the binding removed produced exactly
that outcome locally (`next call did not revert as expected`).

Settled state, read back on-chain:

```
settled(9)             : true
finalYesTotal(9)       : 425      <- the truth, not the lie
finalNoTotal(9)        : 350
finalYesProbabilityBps : 5483
payoutUnits(9,YES,425) : 775      <- the whole pool, never more
```

**Neither `nisi-master-reference.md` nor `HANDOFF.md` documents this check.** Both
treat Chaum-Pedersen as sufficient for binding a published value to a ciphertext. It
is not.

### What the rig does and does not prove

The rig's ciphertexts come from `settlement-fixtures.json` (sums of five per-bet
ciphertexts) written into a standalone accumulator, not from `betEncrypted` calls, and
its vault is back-dated so it is resolvable immediately. This was necessary because
`Vault.MIN_RESOLUTION_GAP` enforces at least an hour between betting close and
resolution — deliberately, so a last-second bet cannot front-run a known outcome — and
that cannot be skipped on a live chain.

So: the **contract logic** under attack is real deployed bytecode. The **path from a
real bet to that state** is proven separately by §3 and §4. Settlement of a market that
was naturally bet into is **[LOCAL ONLY]**, covered by `EncryptedParimutuelPoolTest`
(15 tests).

Rig addresses: `EncryptedParimutuelPool`
[`0xd84E9139…599b`](https://testnet.monadexplorer.com/address/0xd84E9139a13cE39760baB688a124f75003CC599b),
accumulator [`0xB622A39C…1839`](https://testnet.monadexplorer.com/address/0xB622A39C349997d764Cf3d4385dCA95467C41839),
back-dated vault [`0x96102Dff…6A70`](https://testnet.monadexplorer.com/address/0x96102Dff65DBCb05f0D65b88FA8ffB3B1Ad86A70).

---

## 6. Gas: the envelope question, now closed [MEASURED]

`betEncrypted` was the last unmeasured action. Local `forge` said 1,352,807 — 67% of
the envelope — and every prior action came in 30–40% higher on a real transaction.

| Action | local `forge` | **live testnet** | Δ | % of 2,000,000 envelope |
|---|---|---|---|---|
| `deposit` | 1,378,641 | 1,816,159 | +32% | 91% |
| `bet` | 1,173,880 | 1,644,303 | +40% | 82% |
| **`betEncrypted` (cold accumulator)** | 1,352,807 | **1,904,506** | **+41%** | **95.2%** |
| `betEncrypted` (warm accumulator) | — | 1,859,677 | — | 93.0% |

**It fits — with 95,494 gas to spare.**

This is tighter than the 91–94% estimated before broadcasting, and the estimate erred
optimistically, exactly as §1c of `MEASUREMENTS.md` warned. The envelope stays at
2,000,000; **it must not be raised**, because the declared gas limit is a public field
and changing it retroactively shrinks the anonymity set of everything submitted before.

Worth recording plainly: `HANDOFF.md` §7.1 nominated "move `Vault.split` out of
`deposit`" as the lever if Phase 2 did not fit. That lever does not act on this action —
`betEncrypted` never calls `Vault.split`. Had the number landed over budget, the stated
fallback would not have helped.

The 8-signal verifier, measured against live nodes by `make gate`:

| | warm | cold first call | vs 1.5M gate |
|---|---|---|---|
| `BetEncryptedVerifier` (8 signals) | 1,152,559 | 1,162,809 | PASS, 76.8% |
| `BetVerifier` (4 signals) | 1,029,454 | 1,039,706 | PASS, 68.6% |

The four extra ciphertext signals cost **123,105 gas — 30,776 each**, a third
independent confirmation of the ~30,756 per-signal figure.

---

## 7. What is still NOT proven

| Item | Status |
|---|---|
| **Private redemption** | **[NOT VERIFIED] — not built.** `redeem` still publishes recipient and amount as plaintext public signals. Until `redeemShielded` + `withdraw` land, a payout deanonymises the position that funded it, and the build plan is explicit that this makes the privacy claim *false*, not weak. |
| Settlement of a naturally-bet market | [LOCAL ONLY] — time-gated by `MIN_RESOLUTION_GAP`; §5 used a rig. |
| Publisher (cadence, BSGS, on-chain writes) | [NOT VERIFIED] — not built. BSGS and DLEQ proving exist as libraries and are exercised, but no worker runs them. |
| Attested mid-market ratio | Deliberately **unverifiable on-chain**. Verifying a ratio consumes the plaintext totals, and publishing those defeats the phase; additive ElGamal has no division. `publishAttestedRatio` is operator-asserted, rate-limited by `minPublishInterval`, and **no payout reads it**. |
| Trusted setup | [NOT VERIFIED] — single phase-2 contribution from one dev machine. That randomness can forge proofs. Needs a multi-party ceremony. |
| ptau provenance | [NOT VERIFIED] — powers 13, 14 and now 15 are used; `snarkjs powersoftau verify` has never completed on any of them. |
| Committee key | **Test key**, secret in a gitignored file on a developer machine. Protects nothing. |
| External audit | Not done. One internal review found a full-vault drain in Phase 1; assume more exist. |

**This is a testnet demonstration, not a launch.** The honest description today is
*shielded positions with an encrypted pool total and a public payout path*.

---

## 8. Reproduce

```bash
make circuits && make fixtures && make verifiers   # ptau 15 fetched automatically
make test                                          # 168 tests
make gate && make uniformity                       # live-chain verify gas

cd contracts
PRIVATE_KEY=0x… forge script script/Deploy.s.sol \
  --rpc-url https://testnet-rpc.monad.xyz --broadcast --network monad --slow

PRIVATE_KEY=0x… POOL=0x… COLLATERAL=0x… \
  forge script script/ExerciseEncrypted.s.sol \
  --rpc-url https://testnet-rpc.monad.xyz --broadcast --network monad --slow

cd ../circuits
ACCUMULATOR=0x… MARKET_ID=8 EXPECTED=137 node scripts/verify_onchain.mjs
```

Monad Foundry is required (`forge --version` must report `1.7.1-monad-v1.0.0`).
Stock Foundry misprices BN254 by ~5x and cold SLOAD by 4x.
