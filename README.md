# atrum-core

Private prediction market on Monad. **atrum.fun**

Bet YES or NO on a single real-world event. Individual bets, identities and
balances are hidden from everyone — including the operator — while the odds stay
public and settlement is publicly verifiable.

- [`atrum-build-plan.md`](atrum-build-plan.md) — what to build, in what order
- [`nisi-master-reference.md`](nisi-master-reference.md) — why; every approach
  considered, with the measurement backing
- [`MEASUREMENTS.md`](MEASUREMENTS.md) — **what this repo measured itself**, against
  live Monad nodes, including where it contradicts the reference

## Status: Phase 0 complete, Phase 1 complete

Phase 0 killed the one risk that could have ended the project: *does a production-shaped
Groth16 circuit verify affordably on Monad?* Phase 1 built the market on top of it.

| | |
|---|---|
| Groth16 verify, 4 public signals | **1,029,454 gas** — 68.6% of the 1.5M stop-line |
| Homomorphic accumulation | `Enc(50) + Enc(20)` → decrypts to `70`, verified |
| Proving time | ~995 ms median, client-side |
| **Real `deposit`, end to end** | **1,378,641 gas** — 69% of the action envelope |
| **Real `bet`, end to end** | **1,165,715 gas** — 58% |
| **Real `redeem`, end to end** | **1,137,382 gas** — 57% |
| Test suite | **94 passing** — 81 Solidity under the Monad gas schedule, 13 sequencer |

Every action figure above is a real Groth16 proof through the real snarkjs-generated
verifier. Nothing is mocked: a mocked verifier would hide exactly the failures that
matter — public-signal ordering, a packing layout that disagrees between circom and
Solidity, an in-circuit hash that differs from the on-chain one. Each of those verifies
fine in isolation and reverts on-chain.

Notable: the reference predicted a real verifier would cost 15–25% more than its
1,031,828 core figure. It actually costs **0.2% less**, which returns the whole
safety margin. See [`MEASUREMENTS.md`](MEASUREMENTS.md) §1.

## Tech stack

| Layer | Choice | Why this one |
|---|---|---|
| Contracts | **Solidity 0.8.28**, optimizer on at `runs=200` | Pinned, not left to the profile default — contract size is sensitive to it |
| Toolchain | **Monad Foundry `1.7.1-monad-v1.0.0`** | Mandatory. Stock Foundry reports Ethereum's prices: `ecMul` 6,393 vs 30,383, cold SLOAD 2,115 vs 8,115. Two tests fail if the fork is missing |
| Proof system | **Groth16 over BN254**, via `snarkjs 0.7` | Constant-size proof and a constant-cost verify. Monad reprices BN254 ~5x and leaves BLS12-381 alone, and this repricing is the fact the whole architecture rests on |
| Circuits | **circom 2.1.9**, `circomlib` | 5 circuits: 2 Phase 0 ElGamal probes, plus `deposit` / `bet` / `redeem` |
| Trusted setup | **Hermez `powersOfTau28_hez_final_{13,14}`** | Power 14 for `bet` (14,194 constraints) and `redeem` (12,734); a depth-20 Merkle path alone costs ~4,900 and overflows power 13's 8,192 |
| Encryption | **Exponential ElGamal on BabyJubJub** | Forced, not preferred: proving encryption inside a BN254 circuit requires the curve's base field to equal the proof system's scalar field. Additively homomorphic only — which is *why* the market must be parimutuel |
| Hashing | **Poseidon(2)**, circomlib's generated contract | One arity everywhere — in-circuit, on-chain, and in the sequencer mirror — so there is a single place for them to diverge, and it is asserted |
| Commitments | Depth-20 Merkle tree, **subtree grafting** | 38,034 gas/leaf at N=64 against 604,315 for the naive loop. Batching is a correctness requirement of the gas budget, not an optimisation |
| Nullifiers | **`mapping(uint256 => bool)`** | Measured 29,107 vs 632,196 for a tree. Decided by measurement — see `contracts/test/NullifierSet.t.sol` |
| Sequencer | **TypeScript + `viem` + `circomlibjs`**, tested with `vitest` | Serves Merkle paths the contract deliberately cannot produce |
| Measurement | **Python 3**, `eth_call` with state overrides | Real Monad gas with no key, no deploy, no spend |
| CI | GitHub Actions | Asserts the Monad fork is present before trusting any gas number |

## Layout

```
contracts/      Solidity, Monad Foundry
  src/Vault.sol                collateral layer: USDC <-> {YES, NO} complete sets
  src/ShieldedPool.sol         deposit / bet / redeem, the Phase 1 milestone
  src/ParimutuelPool.sol       public per-market stake totals, pro-rata payout
  src/IncrementalMerkleTree.sol  depth-20 commitments, subtree grafting
  src/MappingNullifierSet.sol  double-spend guard (the measured winner)
  src/TreeNullifierSet.sol     the alternative, kept as the evidence it lost
  src/ActionGasPolicy.sol      one declared gas limit for every action
  src/verifiers/               generated Groth16 verifiers (derived, gitignored)
  script/Deploy.s.sol          full stack, incl. Poseidon from raw bytecode
circuits/       circom + snarkjs
  src/note.circom              note commitment + public-input packing rules
  src/merkle.circom            depth-20 inclusion, mirrors the contract exactly
  src/deposit.circom           3 public signals
  src/bet.circom               4 public signals
  src/redeem.circom            4 public signals
  src/elgamal.circom           exponential ElGamal on BabyJubJub (Phase 0/2)
  scripts/prove.mjs            mechanism proofs + independent verification
  scripts/gen_action_fixtures.mjs  real proofs the Solidity suite replays
sequencer/      TypeScript, viem
  src/tree.ts                  mirror of the on-chain tree; serves Merkle paths
  src/sequencer.ts             batching, padding, divergence detection
  src/relayers.ts              ~10 rotating relayer accounts
tools/          measurement against live Monad nodes
  monad_gas.py                 precompile and chain-parameter prober
  measure_verifier.py          the gate, across all five verifiers
  check_gas_uniformity.py      anti-fingerprinting guard
```

## Setup

**Monad Foundry is required.** Stock Foundry reports wrong gas — Monad reprices
BN254 ~5x and cold SLOAD 4x.

```bash
# Upstream foundryup IGNORES --network monad. Use Category Labs' installer,
# and still pass --network monad explicitly.
FOUNDRY_DIR=~/.foundry-monad bash -c \
  'curl -L https://foundry.category.xyz | bash && ~/.foundry-monad/bin/foundryup --network monad'

# forge --version should report 1.7.1-monad-v1.0.0, not plain 1.7.1

curl -sSL -o ~/.local/bin/circom \
  https://github.com/iden3/circom/releases/download/v2.2.3/circom-linux-amd64
chmod +x ~/.local/bin/circom

cd circuits && npm install
git clone --depth 1 -b v1.9.6 \
  https://github.com/foundry-rs/forge-std.git contracts/lib/forge-std
```

## Use

```bash
make circuits    # compile 5 circuits, Groth16 setup, export verifiers
make prove       # proofs + verify the ElGamal mechanism end to end
make fixtures    # real deposit/bet/redeem proofs for the Solidity suite
make verifiers   # copy generated verifiers into contracts/src/verifiers
make test        # 81 contract tests, Monad gas schedule
make gate        # real verify gas for all 5 verifiers vs the 1.5M stop-line
make uniformity  # anti-fingerprinting: every action under ONE declared limit
make measure     # chain params + precompile costs
make verify-all  # everything that can fail
```

Order matters on a clean checkout: the contract suite replays real proofs, so
`make circuits && make fixtures && make verifiers` must run before `make test`.

Sequencer:

```bash
cd sequencer && npm install && npx vitest run   # 13 tests
```

`make gate`, `make uniformity` and `make measure` hit live Monad nodes via `eth_call`
with state overrides — no funded key, no deploy, no spend. Add `NETWORK=mainnet` to
target chain 143 instead of testnet.

## What this is not

- **Not FHE.** Additively homomorphic only — addition, nothing else. This is why
  the mechanism must be parimutuel: no comparisons means no order book and no AMM.
  Say "homomorphic encryption", never "fully".
- **Not decentralised at launch.** One sequencer, one decryption key. Liveness
  depends on the operator; safety does not.
- **Not a TEE product.** If TEEs appear later they harden the committee; they are
  never the trust root.
- **Not hiding the odds.** Odds are public by design. Depth and participants are
  what's hidden.
- **Not a conditional/futarchy market.** Single event only.
- **Not demand-validated.** The engineering is measured and sound; demand is not
  established. Monad blocks measured 7% full, which is a demand signal as much as
  cheap blockspace. See `nisi-master-reference.md` §11.

## What Phase 1 does and does not hide

**Hidden:** which note a bet spent, and therefore which deposit funded it. The
anonymity set is every other note in the tree, and batches are a fixed 64 so the set
size does not leak how busy the market is.

**Public:** deposit amounts and depositor addresses, pool totals, and redemption
payouts.

That last one is the important caveat. `atrum-build-plan.md` is blunt that a public
redemption path makes the privacy claim **false rather than degraded** — an observer
correlates payout amounts and timing back to positions and retroactively deanonymises
the bets that funded them. It is public here because Phase 1's milestone is explicitly
*"shielded positions, public pool total"*, an internal milestone rather than a launch.
Phase 2 moves redemption inside the pool, paying into a fresh note instead of an
address.

**Until then this is an anonymous-participant parimutuel market, not a private
prediction market.** Use the smaller description.

## Caveats before anything holds value

- Zkeys have a **single phase-2 contribution from one machine**. That randomness can
  forge proofs. A real deployment needs a multi-party ceremony.
- `circuits/build/committee-key.json` is a **test key with a known secret**.
- The Hermez ptau transcript was **not** independently verified — `powersoftau
  verify` did not finish in our timeout.
- Redemption is **public** — see above. The one item the plan says never to cut.
- The sequencer is trusted for **liveness and ordering**. It cannot forge a
  commitment (`flushBatch` checks the leaves against the on-chain queue) and cannot
  learn which note a bet spent, but it can stall.
- **No audit.** External review of the circuits and contracts has not happened.
