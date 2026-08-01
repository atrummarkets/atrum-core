# Atrum — trusted setup ceremony transcript

**Status: NOT STARTED. The keys in use today are single-contribution development keys.**

This file is the public record of Atrum's Groth16 phase-2 ceremony. It exists so that anyone
can check the chain of contributions themselves rather than taking our word for it.

---

## 0. What this is for, stated plainly

Every Groth16 circuit needs a proving key produced by a setup procedure that generates a
secret as a by-product — the *toxic waste*. **Whoever holds that secret can forge proofs.** In
Atrum, forging a proof mints collateral from nothing: a fake `deposit` proof creates a
spendable note, and a fake `withdraw` proof drains real USDC.

Today's keys were produced by `circuits/scripts/build.sh`, which makes **exactly one
contribution, on a developer's machine.** The script says so at the contribution step. That
is fine for testing and measurement — it is not fine for anything holding value.

A phase-2 ceremony fixes this by having several people each inject fresh randomness and
destroy it. The security claim is:

> **The setup is sound if even ONE contributor was honest.**

That claim is weaker the more the contributors resemble each other. Contributors drawn
entirely from the team reduce it to "we did not collude with ourselves." Outside
contributors are what make it worth stating.

## 1. Ordering — this must happen before the final deployment

New zkeys produce new verification keys, which produce new Solidity verifiers, which change
every contract's bytecode and therefore its address. `contracts/script/Deploy.s.sol`
constructs all five verifiers and wires them into `ShieldedPool`'s constructor, so a ceremony
run after deployment means deploying everything a second time.

**Ceremony first, then deploy once.**

## 2. How to verify this ceremony yourself

Every row below carries two hashes:

- the hash **snarkjs prints** when a contribution is applied, and
- the **sha256 of the resulting file**, which anyone can check with `sha256sum` without
  trusting snarkjs's output or re-running anything.

Each contributor publishes their hashes **before** passing the file to the next person.
Publishing after the handoff would prove nothing, because the chain could have been rewritten
in between.

To check the final key for a circuit yourself:

```bash
sha256sum <circuit>_final.zkey                        # must match the table below
snarkjs zkey verify circuits/build/<circuit>.r1cs \
    circuits/build/powersOfTau28_hez_final_<power>.ptau \
    <circuit>_final.zkey
```

## 3. Scope — four circuits

Only the four live user actions. The deprecated plaintext circuits (`bet`, `redeem`) and the
Phase 0 probes are excluded: no plaintext market will ever hold real money, and a plaintext
market has no redemption path at all now.

| circuit | constraints | ptau power | zkey |
|---|---|---|---|
| `deposit` | 1,621 | 13 | 712K |
| `bet_encrypted` | 21,252 | 15 | 10M |
| `redeem_private` | 14,405 | 14 | 6.1M |
| `withdraw` | 14,438 | 14 | 6.1M |

## 4. Open decisions — these are the actual work

The commands are one line each and take minutes. What takes time is deciding:

- [ ] **Who contributes.** Ideally people outside the team; the security claim is "not all of
      them colluded."
- [ ] **How many.** 5–10 is defensible for a testnet MVP.
- [ ] **Which beacon closes it.** A future Monad block, announced here *before* it is mined,
      so nobody — including the last contributor — can grind it.
- [ ] **Where contributors post their hashes** as they go (this file is the permanent record,
      but contributors should also post publicly under their own name at the time).

## 5. The procedure

The coordinator runs `init` once per circuit and publishes the starting hash. Contributors
then run their step **on their own machine** — never centrally, since a central run would
recreate exactly the single-point-of-trust the ceremony removes.

```bash
# coordinator, once per circuit
./circuits/scripts/ceremony.sh init <circuit>

# each contributor, on their own machine, in sequence
./circuits/scripts/ceremony.sh contribute <circuit> <in.zkey> <out.zkey> "<their name>"
#   -> posts both printed hashes publicly, THEN sends <out.zkey> to the next contributor

# coordinator, after the last contribution
./circuits/scripts/ceremony.sh finalize <circuit> <last.zkey> <beacon-block-hash>
#   -> applies the beacon, verifies the whole chain against the r1cs (hard failure if broken),
#      and installs the result into circuits/build/

# then, once all four circuits are final
make verifiers && make fixtures && make test
```

Intermediate zkeys are passed hand to hand and are **never committed** — `bet_encrypted`
alone is 10MB, and only the final key matters. They are gitignored, as is the `ceremony/`
working directory.

---

## 6. Transcript

### `deposit`

_Not started._

| # | contributor | snarkjs contribution hash | sha256 of resulting zkey | date |
|---|---|---|---|---|
| 0 | _(setup — no contribution)_ | — | | |
| 1 | | | | |

**Beacon:** _not chosen_
**Final zkey sha256:** _n/a_

### `bet_encrypted`

_Not started._

| # | contributor | snarkjs contribution hash | sha256 of resulting zkey | date |
|---|---|---|---|---|
| 0 | _(setup — no contribution)_ | — | | |
| 1 | | | | |

**Beacon:** _not chosen_
**Final zkey sha256:** _n/a_

### `redeem_private`

_Not started._

| # | contributor | snarkjs contribution hash | sha256 of resulting zkey | date |
|---|---|---|---|---|
| 0 | _(setup — no contribution)_ | — | | |
| 1 | | | | |

**Beacon:** _not chosen_
**Final zkey sha256:** _n/a_

### `withdraw`

_Not started._

| # | contributor | snarkjs contribution hash | sha256 of resulting zkey | date |
|---|---|---|---|---|
| 0 | _(setup — no contribution)_ | — | | |
| 1 | | | | |

**Beacon:** _not chosen_
**Final zkey sha256:** _n/a_

---

## 7. Rehearsal record

The full flow was rehearsed end to end on `deposit` before any real contributor was involved,
to prove the script and the downstream pipeline work. **These are throwaway keys with known
entropy and carry no security value whatsoever** — they exist only to show the mechanism runs.

| step | sha256 (first 24) |
|---|---|
| `init` starting point | `699d5b804d1119b3fce30e3f24b3664b` |
| contribution 1, `rehearsal-alice` | `62790ba3297fff68bdf207e50afd2f3f` |
| contribution 2, `rehearsal-bob` | `4f32618e88d0e824bf4ae8e755053193` |
| beacon + finalize | `a5d8e0d78e7ddd505da7f324b44e8370` |

Beacon used: Monad testnet block 50,039,157,
`0xe71a0a6e98c39e2d0058be26ea891f4f4b2443c5b56f0d657e6637d16633faa3`.

`snarkjs zkey verify` passed against `deposit.r1cs`, and the resulting key went through
`make verifiers && make fixtures && make test` unchanged — confirming the downstream pipeline
cannot tell a ceremony key from a build key, which is the property that makes the ceremony a
drop-in step rather than a fork of the build.

**The real ceremony starts from a fresh `init`.** Nothing in this section is reused.

---

## 8. A separate, still-open gap: ptau provenance

This ceremony is *phase 2* — the circuit-specific half. The universal half (powers of tau)
comes from the published Hermez ceremony, downloaded by `build.sh`.

**We have not verified that transcript ourselves.** `snarkjs powersoftau verify` did not
finish inside our timeout (`MEASUREMENTS.md` §6, and `build.sh` says so in a comment at the
fetch step). Setup succeeds against the published files, but succeeding is not the same as
having checked the ceremony that produced them.

Verify it before anything holds value. It is independent of the work above and can run in
parallel.
