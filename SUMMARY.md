# Atrum — one page

**A prediction market where bets, identities and balances are hidden from everyone
including the operator, while the odds stay public and settlement is verifiable.**
On Monad. `atrum.fun`

## Mechanism: parimutuel (shared pot)

Two pots, YES and NO. Winners split both, pro rata. No order book, no AMM.

**Not a preference — forced.** The pool total is held under additively homomorphic
encryption, which can only **add**. No comparisons ⇒ no matching engine ⇒ no order
book, no AMM curve. Parimutuel is the only mechanism that needs nothing but addition.

Side effects: zero MEV (payout is order-independent), and no counterparty needed —
so it works at zero liquidity, unlike an order book.

## Privacy: two layers, not one

| Layer | Hides | How |
|---|---|---|
| **ZK shielded pool** | individual bets, identities, balances | Poseidon commitment tree + nullifiers, Groth16/BN254. Only a **root** on-chain. |
| **Homomorphic encryption** | the pool total / market depth | Exponential ElGamal on BabyJubJub. Contract adds `Enc(50)+Enc(20)=Enc(70)` **without decrypting**. Committee later reveals only the *ratio*. |

Curve choice is forced: the encryption must be proved correct *inside* the circuit,
which needs the curve's base field to equal the proof system's scalar field. That
holds only for BN254 → BabyJubJub.

## Measured on live Monad (chain 143 + 10143), not estimated

| | Measured | |
|---|---|---|
| Groth16 verify, 4 public signals | **1,029,454 gas** | 68.6% of the 1.5M stop-line |
| Poseidon(2), on-chain | **28,980 gas** | digests verified vs circomlibjs |
| Commitment insert, batched N=64 | **38,034/leaf** | 15.9x better than naive |
| Nullifier write | **28,945 gas** | mapping, 24x cheaper than an indexed tree |
| **Total per private bet** | **1,096,433 gas** | **55% of budget** |
| Proving time (client-side) | **~995 ms** | ~6,840 constraints |
| Throughput | **~485 proofs/sec** | 145/block |
| `ecPairing` (BN254) | **225,000 + 170,000k** | 5x Ethereum — the repricing the design is built around |
| `bls12_pairing` | **37,700 + 32,600k** | unchanged — hence BN254 stays |

Measured via `eth_call` + state overrides: **no funded key, no deploy, no spend.**
Marginal-cost method cancels Monad's 10,100 cold-account charge.

## Mechanism correctness — proven, not asserted

`prove.mjs` doesn't just trust `snarkjs verify` (which only proves a witness
satisfied *some* constraint system). It recomputes ciphertexts independently with
`circomlibjs` and confirms they match, then decrypts for real:

- `C1`/`C2` match independent computation ✓
- decrypt round-trip recovers plaintext ✓
- tampered public signal rejected ✓
- **`Enc(50) + Enc(20)` decrypts to exactly `70` → publishes "YES 70%"** ✓

## Validate it yourself

```bash
make measure   # precompile + chain params, live Monad
make gate      # real Groth16 verify gas vs the 1.5M stop-line
make prove     # proofs + the homomorphic property end to end
make test      # 53 contract tests under Monad's gas schedule
```

Two CI guards **fail** if `--network monad` is omitted — without it the local EVM
reports Ethereum's prices (`ecMul` 6,393 vs 30,000), understating the operations that
dominate proof cost by ~5x.

Full labelled record: [`MEASUREMENTS.md`](MEASUREMENTS.md) · claims ledger and gaps:
[`HANDOFF.md`](HANDOFF.md)

## Stated plainly: what this is not (yet)

- **Not FHE.** Additively homomorphic only. Never say "fully".
- **Trusted setup is a single contribution from one machine** — that randomness could
  forge proofs. Measurement-only; needs a multi-party ceremony before real value.
- **`Vault.redeem` is still public.** Must move inside the shielded pool before
  launch — a public payout path retroactively deanonymises every position.
- **Not decentralised at launch.** One sequencer, one decryption key. Liveness
  depends on the operator; safety does not.
- **Odds are public by design.** Depth and participants are what's hidden.

**Status:** Phase 0 complete (risk gate passed), Phase 1 ~25% (commitment tree built
and measured). Engineering risk largely retired; what remains is volume plus the
security process.
