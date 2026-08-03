# Atrum — Handoff

**As of 3 August 2026.** What has been claimed, what has actually been verified, and
what stands between here and hosting a real private prediction market.

Written to be read by someone who has not seen the earlier conversation.

---

## NEXT UP — start here

**There is a front end now, and it is wired to a real deployment.** `atrum-markets/` (sibling
repo, Next.js) lists seven markets, connects a real wallet, and drives the full lifecycle on
Monad testnet. Read §0-quater below before touching it. Two things there outrank everything
else:

1. **The trust compromise** — proving runs server-side, so the server sees every note secret.
   That is what stands between this and something users should *trust*.
2. **There is no first run** — every screen explains itself and nothing explains the
   sequence, so a newcomer meets five unfamiliar steps one failure at a time and, on current
   evidence, gets stuck waiting for their first deposit to graft and never places a bet. That
   is what stands between this and something users can *use*. It is the cheapest of the two
   to fix and blocks nothing.

**Live deployment: pool `0xeC41Dd059d2CfDa55FAB3680E599D4af3aF4ad8f`**, `minAnonymitySet = 2`
(a DEMO value; production is 8), `minRootAge = 0`. Collateral (MockERC20)
`0xF7DE25a5D8be39fEE780f4AeDCb484E6533943E0`.

**`0xcF2b2113…` above (and everything before it) is now ALSO orphaned — same bug, a third
time.** `atrum-core/circuits/build/` had drifted from what `0xcF2b2113…`'s verifiers were
actually deployed against (no rebuild command run since is recorded anywhere, but the
non-determinism this project keeps re-learning about doesn't need one to be found — see
`deployments/monad-testnet-10143/README.md`'s bug #3). Found via `atrum-markets`' own deposit
failing `execution reverted` in the browser, confirmed by calling the dead pool's
`DepositVerifier` directly with a fresh proof and getting `false`. Fixed the only way this bug
class is ever fixed: `make verifiers` (no intervening `make circuits`, so the new verifiers are
guaranteed to match what's currently on disk) then a fresh `Deploy.s.sol`, same operator, same
`sequencer` address, same committee key. Re-verified the fix directly: the same proof against
the new `DepositVerifier` returns `true`. Full address table and cost:
`deployments/monad-testnet-10143/README.md`.

`atrum-markets/circuits-build/` (this session also removed its `ATRUM_CORE_DIR` dependency —
see below) was resynced from this same `circuits/build/`, so it matches the new pool too.
Markets 40/41/42 (BTC/ETH/SOL, oracle-resolved, replacing `atrum-markets/markets.json`'s old
seeded demo markets 31-37) were re-registered on the new pool with `create-market.mjs`, fixed
this session to target the right registry file and schema — it previously wrote to
`atrum-client/markets.json`, a stale sibling.

**Outstanding**: the sequencer's Render deployment (`atrum-core.onrender.com`) needs its
`POOL_ADDRESS` updated to the new pool and restarting — an external service, not reachable from
this session. The local `sequencer/.env` was found already stale/disconnected from whatever
Render actually runs (its `RELAYER_MNEMONIC` derives to an unrelated test wallet, not this
pool's `sequencer`) — a separate, pre-existing gap, not something this redeploy caused.

The rest of this section describes an EARLIER deployment (`0x26969270…`) and remains true
about the protocol; only the addresses moved.

**The four privacy phases from `DESIGN-PRIVACY.md` are done and verified on chain.** Read
that document's §4 for what changed and, more importantly, for the two places its own plan
turned out not to be implementable.

**Live deployment: pool `0x26969270fFB9c0b8307abB4b8a14057DA9C50Fec`** (Monad testnet), with
`minAnonymitySet = 8` and `minRootAge = 0`. `Vault.MIN_RESOLUTION_GAP` on this deployment is
**3 minutes, not the 1-hour production value** — shortened for demo iteration
(`contracts/src/Vault.sol`), immutable and readable on chain like every other test-vs-production
constant here. Both prior pools this session (`0x5EaB8063…`, then `0xE9ea2115…`) are orphaned.
Evidence collected live via `atrum-client/scripts/live-loop.mjs` and a scoped variant of it
(`live-loop-scoped.mjs`, added to target one note among the many the persistent test profile
accumulates across pools):

**This pool** (fast resolution gap, manual-resolver market 11, no Pyth dependency — deployed
directly with `forge create` + `registerEncryptedMarket` rather than `create-market.mjs`, whose
oracle path always adds its own ~61-minute margin regardless of `MIN_RESOLUTION_GAP`):

| what | evidence |
|---|---|
| 8 real deposits, `minAnonymitySet = 8` cleared | `totalDeposits` 8, e.g. tx `0x018039bd6ac423c2b3778ddb78d9419eda319a046684a5c09828395d037237cd` |
| bet relayed, YES | tx `0x6f3351cd6a73644b30f235d3eb9be02510123659c75ad4c1986eb103696d4f71` |
| manual resolve (`vault.resolve(Yes)`, resolver = deployer EOA, no oracle) | tx `0x9b737f7e32d240d7ff0ae145da12d51cc883d770f923737b2cba821e0a8179c6` |
| settle (`publishFinalTotals`, YES=100 NO=0) | tx `0xc46f931f640619bf01a08abe819ff6b1f43c43e3871af5cfcd5fe792064b8b08` |
| `redeemPrivate`, relayed | tx `0x017dab4b85b45c5ad289dee63b4f64102b6026c0a09f0f34e29e151eaa08fe9e` |
| **settled-payout withdrawal to a fresh address**, `unbetExit = 0`, 100 units | tx `0xa89b1ec904734054d2b49b4f253a537714634e1d5306359fc7a7665ca89bb04f` — recipient `0x31442C829404F8219b259c314479bBeB9C8f56e9` balance confirmed `100000000` (exactly 100 × `DENOM`) via `cast call balanceOf` |
| **wall-clock time, market creation to settled withdrawal in hand** | **12.6 minutes**, not 61+ |

**Part 4 — relayer gas top-up, live** (`sequencer/src/relay.ts`). Not exercised by any deployment
until now; every earlier evidence row above ran with `RELAY_TOPUP_AMOUNT_WEI` unset. Restarted
the sequencer with it set to `0.02` MON, withdrew to a fresh address confirmed at **zero balance
in both assets before the call**: `unbetExit = 1` withdraw of 100 units, sender
`0x6384693344164A0dF1ec2b7fEff0E89Dc10c5e96` (a relay-pool account, not the depositor).
Recipient `0x09ab1BA3E9606a1aA3a2AA4dd6fda850Bb819aea` afterward held USDC `100000000` (the
withdrawal, block 50465803) **and** MON `20000000000000000` (the top-up, block 50465808, same
sender, 5 blocks later — the "same account, rides the same batch" property the design calls
for, confirmed from raw block data, not trusted from client logs). One relay account needed a
manual top-up (from the deployer, 3 MON) mid-test — `ACTION_GAS_LIMIT` is billed at the full
declared 2,500,000 gas regardless of usage, and a relay account depletes fast at ~0.5 MON per
action; whatever runs this in production needs to watch relayer balances, this session did not.

**Same pool, market 12** — pushed further: a ~2-3 minute betting window against the same
3-minute `MIN_RESOLUTION_GAP`, reusing one of the 8 deposits already on the pool (no re-bootstrap
needed once `minAnonymitySet` is cleared once). Bet landed with seconds to spare before
`bettingCloseTime`.

| what | evidence |
|---|---|
| bet relayed, YES, market 12 | tx `0x780d78d328ff4950c6ae1c6ff57fdf0e77cb2fad86de70481f82ca2fa703c676` |
| manual resolve + settle | resolve tx `<not captured — RPC was flaking at the time, see below>`, settle tx `0x3db68a8904501b4226f0114540a4f3a21617d0f61687404931c5d7a4229821ac` |
| settled-payout withdrawal to a fresh address, 100 units | recipient `0x3e14F3074E4b603ad8e883Ec453F6225A3dF3f06` balance confirmed `100000000` via `cast call balanceOf` |

**What actually happened getting there, worth recording.** The Monad testnet RPC (both
`testnet-rpc.monad.xyz` and Ankr's endpoint) had a genuinely flaky stretch mid-session —
`fetch failed` on the sequencer's chain calls, one `forge script` deploy that hung 16 minutes
sending nothing and had to be killed. Under that flakiness, a `redeemPrivate` relay attempt
returned an HTTP 500 but the client had already PERSISTED its payout note locally (by design —
see the ordering note at the top of `app.js`), so `atrum-client` status showed a "withdrawable"
note that had never actually reached the chain. Retrying blind against that produced a second,
genuinely-different payout note; only one nullifier-spend can ever land, so exactly one of the
two was real. Diagnosed by reading `queuedCount`/`pendingCommitments` directly off the pool
contract rather than trusting client-local state, which is the general lesson: **under relay
flakiness, treat the client's local note DB as an intent log, not a settled record — verify
against the chain before trusting a "withdrawable" row.** Nothing here is a contract or circuit
bug; the nullifier uniqueness check did exactly its job.

**Prior pool** (`0xE9ea2115…`, same code, orphaned when this one replaced it) — the unbet-exit
half of the fix, and the deposit/bet hedge pattern this pool's test reused:

| what | evidence |
|---|---|
| 8 real deposits, clearing `minAnonymitySet = 8` for real (not the K=2 test value) | `totalDeposits` 8, e.g. tx `0x5d43e0ae27a7a47f21dc5772b6bd67e833d571e7d0bbdf3d85261b6ea6fb7f6a` |
| bet relayed (both sides, market 12, hedged since ETH was trading well under the $2,000 threshold) | YES `0x33efee50ba28e2df3548acc0f9314d30c68c88fe8a008b9dd226a3c0da2f55af`, NO `0xd3943d30150caf4191507a6cd73313ea5433c66f5b93705be47be4a8a705caee` |
| **the actual fix**: unbet-exit withdrawal to a fresh address the depositing wallet never controlled, 100 units, `unbetExit = 1` | tx `0x1c045728f6a1d3c0312653704c1479b7788422c8d6c4418843d741addc310509` — recipient `0x473BD751B9be69CB75cfF946730A6bDB4c312181` balance confirmed `100000000` (exactly 100 × `DENOM`), an address that never signed or received anything else |
| settled-payout path (`unbetExit = 0`) on market 12 | queued in a background script against this pool's sequencer, which was stopped when the pool above replaced it — that script's later steps will fail with a sequencer-unreachable error; superseded by this pool's own settled-payout row above, not worth re-running |

The 8-deposit runs also incidentally re-verified the Part 3 default-amount nudge: an unscoped
withdraw against a 100-unit note defaulted to 10 (the largest rung strictly below it) and was
correctly refused by `DenominationTooRare` — nobody had withdrawn exactly 10 on that pool yet.

**The exit-correlation leak, and the fix.** Every winner who withdrew was deanonymising
themselves regardless of how private the bet was: `_checkRedeemMeta` means only winners ever
reach `withdraw`, and `withdrawData` used to pack the full `marketId` as a public signal — so
a winner's withdrawal publicly named the market they won in. Fixed by narrowing that field to
a 1-bit `unbetExit` flag (`ShieldedPool._unpackWithdrawData`, `withdraw.circom`). Cost: the
settled-payout branch of `_checkWithdrawable` no longer has a `marketId` to check
`marketVault`/`encryptedMarket`/`settled` against, so it checks nothing — every settled
withdrawal now trusts a two-circuit reachability argument with no independent on-chain check
at the moment collateral leaves. The client also gained a fresh-recipient-address withdraw
field and a partial-withdrawal default nudge (`atrum-client/app.js`), both client-only.

### What is verified live, with transaction hashes

| what | evidence |
|---|---|
| deposit names no market | `0x649fef2290a2cb8c1784633122b31f6d50f84e9ea60565946a295159a1bad10e` |
| unbet exit (deposit → never bet → withdraw) | `0x9fc76f18…` then `0xe1605caa…` on the prior pool |
| bet relayed, user address absent | `0xa476ec819cd2e68fcb29da33fe16bd7a0a88287b434a60760f1539716aeb4fca`, `from` = `0x63846933` |
| root-age gate refuses a fresh root | same bet, first attempt: `RootTooRecent(56, 120)` |
| anonymity-set counters | `totalDeposits` 2, `depositsAtDenomination(100)` 1, `(10)` 1 |

`deposit` gas fell **1,816,031 → ~1,160,000** now that it no longer splits into a vault. The
headroom figure quoted in `ShieldedPool`'s own notice is therefore an over-estimate for
`deposit` and should be re-measured rather than assumed.

### The two plan corrections worth knowing before you touch this

Both are cases where the design document described something that cannot be built, and both
were only visible once the code was written. Expect more of these.

1. **`Vault.split` could not move to bet time.** `betEncrypted` never receives `units` — the
   stake is encrypted, which is the entire point — so the contract cannot split a quantity it
   cannot see. Per-market vaults were dropped from custody entirely; they are now a market
   clock and an oracle result. This deleted the complete-set invariant, which was the system's
   strongest safety property, and replaced it with arithmetic in `_recordPayout`.
   `ShieldedPoolSolvency.t.sol` is the net for that trade.

2. **The anonymity gate could not be per-denomination at bet time**, for the same reason. It
   is gated on the TOTAL deposit count instead — which is also the correct set, since a bet
   publishes no amount. Per-rung gating applies to `withdraw`, where the amount is public.

### What is still open

- **Relaying is configuration, not code.** It needs `RELAY_MNEMONIC` and funded accounts, and
  it is OFF unless both are present. When it is off, every user action puts their address on
  chain — the thing Phase 1 exists to prevent. The startup banner says which mode it is in.
- **`minRootAge` and the batch cadence are coupled.** The admissible window is
  `[minRootAge, ROOT_HISTORY_SIZE batches]`. Raise the age above the wall time 64 batches take
  and the window is EMPTY — every action reverts with `UnknownRoot`, naming the wrong cause.
  `RootAge.t.sol::test_windowIsNotEmpty` asserts the relationship; keep it honest if the
  sequencer's `MAX_BATCH_DELAY_MS` changes.
- **Hidden bet side and multi-note bets** (`DESIGN-PRIVACY.md` §5, §7) are still deferred.
  `betMeta` publishes which outcome a bet backs.
- **The ceremony has not been run.** `TRANSCRIPT.md` is empty. The proving keys still come
  from one machine's entropy, so whoever holds it can forge proofs. Nothing built on this
  should be described as trustless.
- **None of this manufactures a crowd.** With three users there are three notes. This work
  makes the crowd undivided, refuses to let anyone bet into one too small, and says so out
  loud. Launch strategy remains a security parameter.

---


## 0-quater. A real front end, on 2026-08-03 — and the trust it currently costs

`atrum-markets/` is a Next.js app that lists markets, connects a wallet, and drives deposit →
bet → resolve → settle → redeem → withdraw against a live pool. It replaces the shared-key
demo harness described in §0-ter, which had no wallet and one hardcoded market.

**What a user does, and who signs what:**

| action | signed by | gas paid by | why |
|---|---|---|---|
| `deposit` | **the user's own wallet** | the user | `transferFrom(msg.sender)` — relaying it would move the payment link one hop, not remove it. The boundary is public BY DESIGN. |
| `betEncrypted` / `redeemPrivate` / `withdraw` | **a relayer** | the operator | proof-gated, never sender-gated. This is the whole point of `sequencer/src/relay.ts`, and it is now actually switched on. |

**[MEASURED] The relaying claim, checked on chain rather than in the UI.** A fresh wallet
(`0x1E5537C98820015f86aadb3A86B62c510C8A97D6`) ran the flow through the browser. Its nonce
afterwards was **3** — mint, approve, deposit, the three transactions it signed. The bet
(`0xc3b1ec63e2c246c105a0e6870680f57434d20c5efd6d5098f23528e0d6a56e02`) has
`from = 0xDcE2557410A6C374219830Dc86A60cec52B47cBd`, a relay account. The user's address is
genuinely not on their own bet. Deposit landed at **1,135,409 gas**, consistent with the
~1,135,4xx figure recorded for this pool's earlier deposits.

### THE TRUST COMPROMISE, stated plainly

**Proving runs on the server, so the server sees every note secret.** A witness needs the
`nullifier` and `secret` that spend a note; the browser sends them to an API route, which
builds the Groth16 proof and relays it. Two consequences, and neither is hypothetical:

1. A server compromise reveals every user's positions and can spend every note.
2. Because the server already holds the secrets, note STORAGE was also put server-side
   (`.data/notes.json`, keyed by owner address, guarded by a signature-derived session).
   That is defensible only as a consequence of (1) — it adds no assumption that server-side
   proving had not already forced — and it buys multi-device access and no lost notes.

The production design is the opposite: the browser holds its own secrets and proves locally.
HANDOFF §0-bis already measured that this is viable — 29.7MB of artefacts, cached in
IndexedDB, `bet_encrypted` at 1.83s in a browser — and §0-bis's own conclusion was that
proving MUST run in a Web Worker. None of that is built. **Until it is, this deployment is
custodial in the way that matters, and the UI says so on both the market and boundary pages
rather than burying it.**

### Two redeploys, and the reason for the first one

`0xcF2b2113…` is the third pool of the session. The first (`0x6BAE039F…`) was orphaned within
the hour by a stale-artefact bug worth recording, because it is the THIRD time this class has
bitten (see the deployments README's bugs #2 and #3):

> **`circuits/build/` had drifted from `circuits/src/`.** `deposit.circom` no longer declares
> a `marketId` signal — the deposit-names-no-market change — but the compiled `deposit.wasm`
> in the tree still did. Every proof attempt failed with `Not all inputs have been set. Only 4
> out of 5`. Nothing detects this: the source is right, the tests pass (CI rebuilds both
> halves in one run), and only a client building a witness against the on-disk artefact ever
> notices. Fixed by `make circuits && make verifiers` and redeploying, which is also what
> forced the second pool.

The lesson is the same one the README already states and this repo keeps re-learning: **a
build artefact and its source can disagree silently, and the failure surfaces somewhere else
entirely.** A checked-in hash of `src/` compared at build time would catch it; that is not
built either.

### [FIXED] Two front-end bugs that only a real browser found

Both were invisible to a type-check and to the API-level tests, and both were caught by
driving the app with a real injected wallet:

- **A page refresh forgot the wallet.** The session cookie survived, React state did not, so
  the app rendered a signed-in user with no address and no chain: balance read `—` and the
  header demanded a chain switch that had already happened. Fixed by restoring on mount with
  `eth_accounts` (the silent form — `eth_requestAccounts` would prompt on every page load).
- **A failed poll blanked the entire note list.** `fetchNotes().catch(() => setNotes([]))`
  meant one timeout emptied the table. Notes are the user's money; an empty table reads as
  "everything is gone". It now keeps the last known-good list and retries.

### Every fabricated number was removed

The UI was ported from a design mock and carried its invented figures. They were not
harmless: a confident wrong number is worse than no number, and two of them contradicted the
protocol.

| was | now |
|---|---|
| a "constraints satisfied" counter animating to **1,048,576** | the real count, read from the `.r1cs` header at request time (`server/atrum/circuits.ts`) — `deposit` 1,621, `bet_encrypted` 21,252, `redeem_private` 14,405, `withdraw` 14,408, verified identical to `snarkjs r1cs info` |
| stakes and payouts labelled **"MON"** | the collateral is a 6-decimal **USDC** mock; symbol and decimals are read from the token |
| `ANONYMITY_FLOOR = 12` hardcoded | `minAnonymitySet` read from the pool (this deployment: **2**) |
| "last republish 00:14:22 ago", "41 notes ahead", "31 withdrawals this hour" | deleted, or replaced with live `queuedCount` / `batchCount` |
| a progress bar during proving | **removed.** The prover reports no progress, so a bar was decorative. The overlay shows the real step and a real elapsed clock, and says why there is no bar. |

Constraint counts are PARSED rather than transcribed for the same reason the committee key is
read rather than hardcoded: a constant copied out of this document goes stale the next time
`make circuits` runs, and nothing would announce it.

### Markets are a registry file, not a log scan

`ShieldedPool` cannot enumerate its own markets — there is no array, only `marketVault[id]` —
and this repo's standing rule is never to build on `eth_getLogs` (100-block cap on the public
RPC). `circuits/scripts/seed-markets.mjs` creates a batch of markets and writes
`atrum-markets/markets.json`.

That file is a **cache of ids, not a source of truth**: betting window, outcome and settled
totals are re-read from the vault on every request. A stale or tampered registry can only
list or omit a market, never misstate one.

### What is new and still unsatisfying

- **The mid-market ratio is decrypted server-side for display.** No publisher service exists
  (§1b), so the app holds the disclosed committee secret and decrypts the accumulator to show
  live odds. This is precisely the leak §"The privacy leak found in the publisher's design"
  describes — a precise, continuously-updated ratio is a sequence of equations in the running
  sums. Real deployments must publish coarsely and on a cadence. The UI states this on the
  odds board; it does not excuse it.
- **Resolution is an EOA on every seeded market.** `PythResolver` exists and works
  (`0x7de5Cd77…` on this pool, market 10), but the seeded demo markets name the operator as
  `Vault.resolver` so outcomes can be driven on demand. The operator panel is shown in the UI
  rather than hidden, because hiding it would not make the market trustless.
- **Sessions replay.** The sign-in nonce is echoed by the client rather than tracked
  server-side, so a signature the user already produced can be replayed. Acceptable only
  because a session grants access to notes the signer already owns; a production build needs
  server-issued single-use nonces.
- **Operator funding is now a live dependency.** Relaying spends the operator's gas on users'
  behalf, and `ACTION_GAS_LIMIT` bills the full declared 2,500,000 regardless of use — about
  0.5 MON per action. Three relay accounts and the sequencer's batching account all need
  watching; the batching account already ran dry once mid-session and every `flushBatch`
  reverted until it was topped up.

### THE BIGGEST PRODUCT GAP: there is no first run

**Every screen explains itself. Nothing explains the sequence — and the sequence is the
unfamiliar part.** A user arriving from Polymarket expects "deposit, click YES, done". What
this protocol actually requires is five steps, three of which have no analogue in any
prediction market they have used, and the app currently reveals them one failure at a time.

The mechanism is not the problem. The mechanism is good and the copy is honest about it. The
problem is that a newcomer meets it in the wrong order, and every one of the steps below is a
place where a reasonable person concludes the site is broken rather than that it is working
as designed:

| what happens | what a first-timer thinks |
|---|---|
| deposit needs testnet MON for gas AND mock USDC | discovers the MON requirement only when their wallet errors. Two faucets, one of them external, neither mentioned until you fail. |
| after depositing you cannot bet yet | "it didn't work." The note is queued until a batch grafts. No countdown, no "come back in ~30s" — the bet ticket just says there is nothing to stake. |
| a bet spends the WHOLE note | "where is the amount field?" You cannot bet 30 of a 100-unit note. |
| the pool refuses a bet below `minAnonymitySet` | reads as an error, not as the product's central promise being kept. |
| redeem does not pay you | "I redeemed and got nothing." It mints a shielded note; `withdraw` is a separate action, deliberately, and the two-step split is the whole of what protects the winner. |
| withdraw only accepts powers of ten, and only rungs others have used | "why is my amount rejected?" |

**A guided first run is the fix, and the shape of it matters.** Atrum's voice is to explain
the mechanism and refuse rather than hide — a wizard must SEQUENCE that, not skin over it.
The waiting step is the sharpest test: the graft delay is not latency to apologise for, it is
the anonymity set being assembled, and the boundary page already says so in prose. A first run
should make that legible while it happens rather than leaving the user staring at a disabled
button.

Concretely, what it needs to be:

1. **State the prerequisites up front**, before the first click, with both faucets reachable
   from one place: testnet MON for gas (external, `faucet.monad.xyz`) and the mock collateral
   (in-app, `mint` is permissionless).
2. **Make the queue a step, not a dead end.** After a deposit, show the note's position and
   the live `queuedCount`/`batchCount` already exposed by `/api/atrum/config`, and say plainly
   that the wait IS the privacy. Then move the user on automatically when it grafts.
3. **Teach notes-not-balances once**, at the moment it first bites — most naturally when the
   bet ticket asks which note to spend, rather than as an up-front wall of text.
4. **Pre-announce the two-step exit** before the user redeems, so "no money moved" is the
   expected outcome and not a scare.
5. **Be skippable and resumable**, keyed to real state rather than a local flag: someone who
   already holds a grafted note should never be walked through depositing again. Every input
   it needs is already served by the existing endpoints.

None of this is protocol work and none of it is blocked. It is the difference between a thing
that demos well to someone who already knows how it works and a thing a stranger on a waitlist
can use — and on current evidence, that stranger gets stuck at step 2 and never places a bet.

### Addresses for this deployment

| contract | address |
|---|---|
| ShieldedPool | `0xcF2b211397dC7499331F227DdDec9436FE9Da379` |
| Collateral (MockERC20, 6dp, permissionless `mint`) | `0x306cBE8c76dC0c2F5A7C90559003096b0AcDC554` |
| EncryptedParimutuelPool | `0xE301c4cf09d9ED1DF4591CCFc757fA2547e0495a` |
| ElGamalAccumulator | `0x27Cb0E6813807c60F16bFE3E1C3ed317504a2dEB` |
| IncrementalMerkleTree | `0x01947CDf891BCA485e62fA7876fbf6c0D34019eF` |
| MappingNullifierSet | `0x838e37C930C0773E773b425970161F58bD27FA99` |
| PythResolver | `0x7de5Cd779B77356348aDf870d74fD9c6A0261eC1` |
| DepositVerifier | `0xDf30126AE1545D38e59AAf54489CFdd7Af6e6907` |
| BetEncryptedVerifier | `0xc3df60a600C478b4Abca43e2ec82920a785c28f2` |
| RedeemPrivateVerifier | `0xBdaf19c0508783F0440b4464a1e55366d6B83ce3` |
| WithdrawVerifier | `0xAC11ac605Ff3547D6f6B38a56C4C35e5C8692cA4` |

Sequencer batching account `0x0f85c6875a2c29BbabeF070Fa00CE9f72B874538` (this is what
`SEQUENCER` was set to at deploy — see §0-ter's GOTCHA, which is why it must match). Relay
accounts derive from a SEPARATE mnemonic, index 0–2, first is
`0xDcE2557410A6C374219830Dc86A60cec52B47cBd`.

Markets 31–37 are seeded demo markets; 7/8/10 come from `Deploy.s.sol` as always.

### Running it

```bash
# 1. sequencer, with batching AND relaying (sequencer/.env.local, gitignored)
cd sequencer && node --experimental-strip-types src/main.ts
#    needs POOL_ADDRESS, RELAYER_MNEMONIC (batching), RELAY_MNEMONIC (relaying, separate),
#    RELAY_TOPUP_AMOUNT_WEI. Use a private RPC: the public one falsely reports
#    "Signer had insufficient balance" under load -- see sequencer/src/chains.ts, hit again
#    this session on Alchemy and worked around by switching to Ankr.

# 2. the app (atrum-markets/.env.local, gitignored)
cd ../../atrum-markets && npm run dev
#    needs ATRUM_CORE_DIR (it proves against circuits/build/ in this repo), POOL_ADDRESS,
#    COLLATERAL_ADDRESS, RPC_URL, SEQUENCER_URL, PRIVATE_KEY (operator, resolve/settle only),
#    SESSION_SECRET.
```

`seed-markets.mjs` and `create-manual-market.mjs` create markets on an existing pool without
redeploying — `registerEncryptedMarket` is admin-gated but has no deploy-time restriction.

---

## 0-ter. The client's other three actions, and two more bugs use found

`atrum-client` now wires `betEncrypted`, `redeemPrivate`, and `withdraw`, not just deposit —
same note lifecycle discipline throughout (persist the note an action produces before
broadcasting, mark the note it spent as spent only after confirmation), same
verify-before-trust standard as `deposit` had. Full account of what changed, and why the pool
address moves again below, belongs in `atrum-client`'s own commits; this is what surfaced in
atrum-core while getting there.

### [FIXED] The sequencer never checked whether its own transaction succeeded

`Sequencer.submit()` awaited `waitForTransactionReceipt` and returned — no read of
`receipt.status`. viem resolves that call once a transaction is **included**, not once it
**succeeds**; a caller has to check status itself, and this one didn't. Every `flushBatch`
revert was therefore treated as a successful graft: `tick()` went on to update the in-memory
mirror as if the leaves it just tried to insert were really on chain.

Found by hitting it: deploying without pointing `SEQUENCER` at an address the running
sequencer's relayers actually control (see below) made every `flushBatch` revert with
`NotSequencer()` — silently, per the bug above — and the failure surfaced one tick later as
`MIRROR DIVERGED`, correctly fatal but for a reason one step removed from the real one.
Fixed: `submit()` now throws immediately on a reverted receipt, naming the transaction and
which relayer sent it.

### [GOTCHA] `SEQUENCER` at deploy time must match a relayer the sequencer will actually use

`ShieldedPool.onlySequencer` checks `msg.sender == sequencer` — **one fixed address**, set at
construction (`Deploy.s.sol`'s `vm.envOr("SEQUENCER", deployer)`, defaulting to the deployer
if unset). `RelayerPool`'s own docstring describes rotating across ~10 accounts specifically
*so no single address is a fixed point* — but the contract only ever authorizes one. Deploying
with the default (`SEQUENCER` unset, so it's the deployer) and then running the sequencer
service with a *different* `RELAYER_MNEMONIC` means every single flush reverts.

**Not resolved as a design question here** — whether the contract should accept a set of
sequencer addresses, or whether "rotating relayers" should describe something else (e.g.
rotating who *signs*, with a single registered forwarding address), is an open architecture
question, not a bug fix. The immediate fix for testing was mechanical: set `SEQUENCER` at
deploy time to the first address `RELAYER_MNEMONIC` derives
(`mnemonicToAccount(mnemonic, { addressIndex: 0 })`), so at least that account's turns
succeed. A real deployment needs an actual decision here before rotation past index 0 matters.

### [MEASURED] The full lifecycle, live, every step through the real client

Not a subset — deposit through withdraw, six real transactions on Monad testnet, each built
by the actual `atrum-client` code (headless-driven, real funded wallet, real Web Worker,
nothing canned), separated by the real one-hour `resolutionStartTime` gap `Vault.sol`
enforces even under `EXERCISE_MODE=1` — not worked around, since it is a stated safety
invariant, not a knob:

| step | block | notes |
|---|---|---|
| deposit | 50197417 | 100 units, market 8 |
| `betEncrypted` YES | 50197594 | 1,493,512 gas; ElGamal-encrypted client-side against the on-chain committee key |
| `vault.resolve(YES)` | 50210340 | via `resolve-and-settle.mjs` |
| `publishFinalTotals` | 50210396 | decrypted YES=100, NO=0 — matches the single bet exactly |
| `redeemPrivate` | 50210468 | 1,285,617 gas |
| `withdraw` | 50210822 | 1,372,435 gas; `Withdrawn(0x7975e591…, marketId=8, amount=100)` confirmed from the raw event log, not just receipt status |

**The relayer-rotation gap above is not hypothetical — it happened mid-run.** The third
sequencer batch (grafting the redeem's payout note) landed on relayer index 1 by round-robin
and reverted with `NotSequencer()`, exactly as §"GOTCHA" above predicts once rotation moves
past index 0. The new receipt-status check caught it immediately and named the relayer;
restarting the sequencer reset the cursor to 0 and the next batch succeeded. Left as-is
rather than patched further — it is evidence for the open question above, not a new one.

---

## 0-bis. What changed on 2026-08-02

Two tracks opened in parallel, per §0's "next up": the browser proving harness and the
trusted setup ceremony. Neither is finished; both are now startable by someone else.

### `atrum-client` — a new sibling repo, harness first

The frontend starts as a measuring instrument, not a UI. `atrum-client/` holds a static
harness (`harness.html` + `harness.js`, no bundler, following `atrum-zk-poc/web`'s pattern)
that fetches each circuit's wasm and zkey, proves the canned input from
`witness-inputs.json`, **verifies the result**, and reports download size, prove time and a
rough heap delta. `scripts/sync-assets.sh` copies artefacts out of this repo — scripted,
because atrum-zk-poc's hand-`cp`'d `web/vendor/` has no record of what built it.

### [MEASURED, headless] The browser multiplier — the question §0 left open

Measured by driving the harness in headless Chromium 151 (`npm run browser-baseline`), every
proof verified **in the browser**:

| circuit | download | Node (this machine) | browser | multiplier | **frame stall** |
|---|---|---|---|---|---|
| `deposit` | 2.4MB | 369ms | **276ms** | **0.75x** | 96ms |
| `bet_encrypted` | 11.8MB | 881ms | **1.83s** | 2.08x | **388ms** |
| `redeem_private` | 7.8MB | 517ms | **1.04s** | 2.01x | 117ms |
| `withdraw` | 7.8MB | 517ms | **1.27s** | 2.46x | 134ms |

Full client 29.7MB, confirming the 29.8MB estimate.

**The multiplier is ~2-2.5x for the three real circuits, and below 1 for `deposit`.** The
sub-1x is not an error: `deposit` is 1,621 constraints, small enough that Node's process and
module-load overhead outweighs the proving itself, while the browser arrives warm. It is a
reminder that the multiplier is not a constant to extrapolate with — it depends on circuit
size, and the number that matters is `bet_encrypted`'s, because that is the one every user
hits on a first bet.

Headless is a fair measurement — same V8, same wasm engine, and proving is pure compute. What
it does not reproduce is contention with a real page's paint work, so the stalls above are if
anything **optimistic**.

### [DECIDED] Proving must run in a Web Worker

Not on the multiplier — on the stall. `requestAnimationFrame` simply stops firing while the
main thread is blocked, so the gap after it resumes is the freeze the user sees:

> **`bet_encrypted` holds the main thread for 388ms. Every circuit exceeds 100ms.**

A 2x multiplier would have been survivable; a third of a second of dead UI on the primary
action is not, and it is measured in a headless browser with nothing else competing. So the
worker is mandatory, and this is recorded as a decision with the number behind it rather than
an assumption.

**IndexedDB caching was never gated on this.** 29.7MB is too much to re-download per session
at any prove speed.

### [MEASURED] Node proving is ~2x faster on this machine than §0 records

`npm run baseline` re-measures Node proving locally, because a multiplier is meaningless if
its two halves come from different machines:

| circuit | §0 (HANDOFF) | this machine | drift |
|---|---|---|---|
| `deposit` | 322ms | **365ms** | +13% |
| `bet_encrypted` | 2,255ms | **897ms** | **−60%** |
| `redeem_private` | 1,437ms | **545ms** | −62% |
| `withdraw` | 1,411ms | **620ms** | −56% |

Dividing a browser time measured here by §0's Node numbers would have **understated the
browser multiplier by about 2x** — in the unsafe direction, again. The harness now reads a
locally-measured baseline and says which one it used.

Full-client download re-measured at **30MB** across the four circuits, confirming §0's 29.8MB.

### The ceremony is scripted and rehearsed, not started

`circuits/scripts/ceremony.sh` (`init` / `contribute` / `finalize` / `verify`), deliberately
separate from `build.sh` — CI must keep minting throwaway single-contribution keys, because
it tests that a build's halves agree, not that the keys are trustworthy. `finalize` applies
the beacon, then **hard-fails and deletes its output** if `snarkjs zkey verify` does not pass.

[MEASURED] The whole flow was rehearsed on `deposit`: `init` → two contributions → beacon
(real Monad testnet block 50,039,157) → verify → install, and the result went through
`make verifiers && make fixtures && make test` with **246 tests passing, unchanged**. That
closes the question of whether ceremony output needs special handling downstream: it does
not. The rehearsal keys have known entropy and are worthless; the real ceremony starts from a
fresh `init`.

`TRANSCRIPT.md` is the public record. **What remains is not code** — who contributes, how
many, which beacon block, where they post their hashes. See §4's "before real money."

### [FIXED] A stale committee key, silently reused, and the same shape as bug #2

`build.sh` regenerated the committee key only when the file was **absent**. This machine held
a random key from 30 July, predating the pinned seed — so every build silently used it. Nothing
failed: the circuits compiled, the fixtures regenerated against the same stale key, and all
246 tests passed. The only visible symptom was that committed key-dependent fixtures diffed
for no apparent reason.

That is bug #2's shape exactly — a key that goes stale without anything announcing it, which
on testnet produced a market that could never settle. `keygen.mjs --check` now asserts the
on-disk key matches the pinned derivation, and `build.sh` runs it on every build.
`ATRUM_RANDOM_KEY=1` still opts out.

### [CONFIRMED] The fixture coupling, demonstrated rather than described

§0's gotcha — *"always make fixtures, never a generator directly"* — was tested by trying to
revert the committed `e2e-` and `settlement-fixtures.json` independently. It fails
immediately with `InvalidDecryptionProof()`: those files carry DLEQ proofs bound to
ciphertexts living in the **gitignored** `action-fixtures.json`, which is regenerated with
fresh randomness every run.

The practical consequence, which is worth knowing before it confuses someone: **`make
fixtures` always dirties the working tree**, and those two committed files cannot be reverted
on their own. They are only ever valid as a set with the untracked artefacts beside them.

---

## 0. What changed on 2026-08-01, and what it cost to find out

Fourteen commits. The protocol did not change much; almost everything below was found by
DEPLOYING and then trying to use the thing. That is the headline finding of the day:

> **Four live, fund-affecting bugs. All four were invisible to a passing 200+ test suite.
> Three came from deployment or operations, not from the protocol.**

| # | bug | consequence | how it surfaced |
|---|---|---|---|
| 1 | `bindEncryptedTotals` never called | **one-way vault** — deposits work, nothing can ever be withdrawn | querying the live pool by hand |
| 2 | committee key hardcoded, went stale | **market could never settle** | `InvalidDecryptionProof()` on a real settlement, 65 min after the bets |
| 3 | `resync` sliced the queue into 64s | **sequencer could not restart** after any partial batch | reasoning about Render restarts |
| 4 | both services scanned `eth_getLogs` | **impossible on Monad** — public RPC caps at 100 blocks, Alchemy free at 9 | booting the publisher against the live chain |

None of these are exotic. Each is the kind of thing that works on a laptop and fails the first
time a real user touches it.

### Deployed, measured, and proven on chain

**`ShieldedPool 0x6af21cA16B40ae5Ab154eE1867f30FC3E64BfBED`** — full record and receipts in
[`deployments/monad-testnet-10143/`](deployments/monad-testnet-10143/).

The full private path ran end to end on testnet: deposit → `betEncrypted` ×2 → settle →
`redeemPrivate` → `withdraw`, with the on-chain root matching the prover's `rootAfterBatch6`
exactly. Every user action now has a real number:

| action | local `forge` | **real testnet** | ratio | % of 2,500,000 |
|---|---|---|---|---|
| `betEncrypted` | 1,381,102 | **~1,947,000** (proj.) | 1.41x | 78% |
| `deposit` | 1,378,691 | **1,815,993** | 1.32x | 73% |
| `withdraw` | 1,166,565 | **1,804,341** | **1.55x** | 72% |
| `redeemPrivate` | 1,126,337 | **1,671,108** | 1.48x | 67% |

Local `forge` understates by **32–55%**. My own projections were wrong in the unsafe
direction — `withdraw` was projected at ~1,642,000 and came in at 1,804,341.

**Monad bills the DECLARED gas limit — measured, not assumed.** A 21,000-gas transfer declared
at 2,000,000 was charged for **2,114,412 gas**. That is the premise the uniform-envelope design
rests on, and it means the envelope is a direct tax on every action.

**The envelope moved once, to 2,500,000, and should not move again.** At 2,000,000 the binding
action had 95,555 gas of headroom while two `betEncrypted` calls in the same run differed by
**44,734 from cold/warm variation alone** — half the headroom consumed by ordinary variance.
Overrunning is worse than expensive: the transaction reverts out of gas AND the user still pays
the full declared limit.

### Built today

- **Publisher** — BSGS decryption, coarse-ratio policy, entrypoint, Render config. 51 tests.
  Verified against the live chain: decrypts the real ciphertext, correctly declines a settled
  market.
- **Fixed denominations**, enforced on-chain. Privacy was resting on a wallet convention.
- **`Vault.Outcome.Void`** — deadline-gated, permissionless refund. The only emergency control,
  and deliberately one nobody can reach for.
- **`IOracleResolver` + `PythResolver`** — market 10's outcome is decidable by **no address**.
- **`DeploymentInvariants`** — a broken deployment now REVERTS instead of broadcasting.

### The privacy leak found in the publisher's design

A single ratio leaks nothing — `yes/(yes+no)` is scale-free. A SEQUENCE does, because three
things are already public: every bet is a visible transaction, `betMeta` carries the OUTCOME so
each bet's SIDE is known, and settlement reveals exact totals. Each published ratio is then one
equation in the running sums, and settlement supplies the scale. Publish once per bet at full
precision and an observer gets about as many equations as unknown stakes.

Bounded by capping the number of equations (3 bets between publications) and degrading each from
an equality to an interval (1% buckets). **That is a bound on a known attack, not a proof of
privacy**, and the code says so.

### The exploit in my own resolver, found by a question

`parsePriceFeedUpdates` accepts ANY update in the window, and the CALLER supplies it. Pyth
publishes ~every 400ms, so a 60-second window offers ~150 candidates — and since resolution is
permissionless, a bettor could submit whichever price wins them the market. Switched to
`parsePriceFeedUpdatesUnique`, which pins the result to the first update at or after the target.

### Proving spike — before building a frontend

| circuit | constraints | prove (node) | download |
|---|---|---|---|
| `deposit` | 1,621 | 322ms | 2.4MB |
| **`bet_encrypted`** | **21,252** | **2,255ms** | **11.8MB** |
| `redeem_private` | 14,405 | 1,437ms | 7.8MB |
| `withdraw` | 14,438 | 1,411ms | 7.8MB |

**29.8MB** for a full client. Download is the harder constraint, not proving time: a user cannot
place a first bet without fetching 11.8MB. Node timings are a LOWER BOUND and **the browser
multiplier is unmeasured** — that needs a real browser, not an estimate.

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

## 1a. DEPLOYED TO MONAD TESTNET — and the envelope is nearly full

Chain 10143, `ShieldedPool` at `0x8Ea29D5C3eed4Bc6D8E68c25065f6E30BDE74464`. Full record,
addresses and raw receipts: [`deployments/monad-testnet-10143/`](deployments/monad-testnet-10143/).

State queried back off the chain, not read from the script's output: `legacyMarketsFrozen()`
is **true**, `encryptedMarket(8)` true, `encryptedMarket(7)` false, and the tree root matches
the local genesis root exactly. A selector scan of the deployed bytecode confirms `redeem` is
**absent** while `redeemPrivate` and `withdraw` are present — the deprecation is live.

### The measurement that closes a long-open question

Real transactions, from the broadcast receipts:

| action | local `forge` | **real testnet** | ratio | % of 2,000,000 envelope |
|---|---|---|---|---|
| `betEncrypted` | 1,352,833 | **1,904,445** | 1.41× | **95.2%** |
| `deposit` | 1,378,691 | **1,815,993** | 1.32× | **90.8%** |
| `bet` (deprecated) | 1,173,922 | 1,644,342 | 1.40× | 82.2% |
| `flushBatch` (64 leaves) | — | 3,734,346 | — | 186.7% (sequencer, not user-facing) |

**Local measurements understate real cost by 32–41%** — no calldata, no intrinsic cost, no true
cross-contract cold access. Every local figure in this repo is a lower bound. `test_report_betEncryptedGas`
said in its own docstring that "the envelope question is not closed until this action is
broadcast for real"; it now has been, and the answer is uncomfortable.

**`betEncrypted` has 95,555 gas of headroom — 4.8%.** One cold SLOAD (8,100) or cold account
access (10,100) added to that path eats a fifth of what is left. The envelope is closed to new
work on `betEncrypted` without an optimisation first. This is the single most important
constraint on the project now.

`flushBatch` at 187% is fine — it is a sequencer operation, nothing about it is private, so it
is not subject to the uniform-limit rule.

### Still UNMEASURED on testnet

`redeemPrivate` and `withdraw` were not exercised — `ExerciseEncrypted.s.sol` stops after the
encrypted bets. Projected at the worst observed ratio they land at ~79% and ~82%, so they
*should* fit. **That is a projection, not a measurement**, and the same reasoning would have
made `betEncrypted` look comfortable before it was broadcast. Extending the exercise script
through settlement → `redeemPrivate` → `withdraw` is now the top task.

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

### Gaps found by auditing the deprecation, and closed

The first pass left three, all found by asking what had been *asserted* rather than run:

**`deposit` lost its only gas-envelope gate.** The deleted `test_gate_realDepositAndRedeemFitEnvelope`
measured deposit and `redeem` in one test; removing `redeem` took deposit's gate with it.
Deposit is still a live action. Restored as `test_gate_realDepositFitsActionEnvelope`.

**`redeemPrivate` and `withdraw` were never gated at all** — both measured their gas and only
`console.log`ed it. The envelope is the anti-fingerprinting control: Monad charges the DECLARED
`gas_limit`, which is public, so every action must declare the same limit, which only works if
every action fits under it. A number in a log nobody reads gates nothing. Both now assert.

Measured against the 2,000,000 envelope:

| action | gas | utilisation |
|---|---|---|
| `deposit` | 1,378,691 | 69% |
| `withdraw` | 1,166,565 | 58% |
| `redeemPrivate` | 1,126,337 | 56% |

`deposit` is the binding constraint, not `withdraw` — and locally-measured deposit understates
the real figure badly (§1: testnet 1,816,031, 91%).

**A dead `redeemVerifier` was still deployed.** With `redeem()` gone nothing read the immutable,
yet it remained a constructor argument and `Deploy.s.sol` still deployed a full 1,635-byte
Groth16 verifier for it. Removed from the constructor and all 7 construction sites.

Still outstanding and deliberately not fixed: the Makefile continues to build the `redeem`
circuit and export `RedeemVerifier.sol`. Removing that means removing section 5 of the fixture
generator, which is part of the same lifecycle rewrite described above.

**Suite: 193 passing, 0 failing.** `forge fmt --check` clean, `make verifiers` clean, deploy
script simulates successfully.

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

**The protocol is done.** Everything that could have failed for cryptographic or gas reasons
now works on a real chain. What remains is four different KINDS of work:

1. ~~**Frontend** — nothing exists.~~ **PARTLY DONE, see §0-quater.** `atrum-markets/` lists
   markets, connects a wallet, and drives the full lifecycle on testnet. What is NOT done is
   the part this item was really about: **proving still runs on the server, so the server
   sees every note secret.** Moving it into the browser — IndexedDB-cached artefacts,
   lazy-loaded per action, a Web Worker, all as §0-bis measured — is the remaining work, and
   it is what separates a demo from something a user should trust with money.
2. **Onboarding — a guided first run.** Separate from the above and much cheaper: the app
   explains every screen and never the sequence, so a stranger hits five unfamiliar steps one
   failure at a time. §0-quater lists them and what the wizard has to do. Nothing blocks it,
   it needs no new endpoints, and until it exists the waitlist converts badly no matter how
   good the protocol is.
3. **Fixture lifecycle rewrite** — mechanical. Deletes `registerMarket`, `bet()`,
   `ParimutuelPool` and the plaintext verifiers, leaving one market type and one exit. Blocks
   nothing, but every line of dead code is audit surface you pay for.
4. **Ceremony + threshold committee** — coordination, not code. Neither moves without other
   people and calendar time, so **start them early**; they are the only items with an
   irreducible wait.

**Not building:** `cancel`. §1e shows it is adverse selection with no parameter fix.

**Before real money, and none of it is engineering:**
- The trusted setup is ONE contribution. `build.sh` says so plainly. Whoever holds that toxic
  waste can forge proofs and mint collateral from nothing.
- The committee is ONE key, held by the operator, who can therefore decrypt every bet.
- No audit.

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
