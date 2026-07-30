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

## Status: Phase 0 complete, gate passed

Phase 0 exists to kill one risk before any product work: *does a production-shaped
Groth16 circuit verify affordably on Monad?*

| | |
|---|---|
| Groth16 verify, 4 public signals | **1,029,454 gas** — 68.6% of the 1.5M stop-line |
| Homomorphic accumulation | `Enc(50) + Enc(20)` → decrypts to `70`, verified |
| Proving time | ~995 ms median, client-side |
| Vault suite | 30/30 passing under the Monad gas schedule |

Notable: the reference predicted a real verifier would cost 15–25% more than its
1,031,828 core figure. It actually costs **0.2% less**, which returns the whole
safety margin. See [`MEASUREMENTS.md`](MEASUREMENTS.md) §1.

## Layout

```
contracts/      Solidity, Monad Foundry
  src/Vault.sol      collateral layer: USDC <-> {YES, NO} complete sets
  src/verifiers/     generated Groth16 verifiers (derived, gitignored)
circuits/       circom + snarkjs
  src/elgamal.circom          exponential ElGamal on BabyJubJub
  src/probe_fixed_key.circom      4 public signals, key compiled in
  src/probe_pubkey_input.circom   6 public signals, key rotatable
  scripts/prove.mjs           proofs + independent mechanism verification
tools/          measurement against live Monad nodes
  monad_gas.py           precompile and chain-parameter prober
  measure_verifier.py    the Phase 0 gate
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
make test        # contract suite, Monad gas schedule
make circuits    # compile, Groth16 setup, export verifiers
make prove       # proofs + verify the ElGamal mechanism end to end
make gate        # PHASE 0 GATE: real verify gas vs the 1.5M stop-line
make measure     # chain params + precompile costs
make verify-all  # everything that can fail
```

`make gate` and `make measure` hit live Monad nodes via `eth_call` with state
overrides — no funded key, no deploy, no spend. Add `NETWORK=mainnet` to target
chain 143 instead of testnet.

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

## Phase 0 caveats before anything holds value

- Zkeys have a **single phase-2 contribution from one machine**. That randomness can
  forge proofs. A real deployment needs a multi-party ceremony.
- `circuits/build/committee-key.json` is a **test key with a known secret**.
- The Hermez ptau transcript was **not** independently verified — `powersoftau
  verify` did not finish in our timeout.
- `Vault.sol` holds **public balances** and has a **public `redeem`**. Both are
  Phase 0 scaffolding. Private redemption is the one thing that must never be cut:
  a public payout path retroactively deanonymises every position.
