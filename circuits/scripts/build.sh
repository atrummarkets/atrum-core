#!/usr/bin/env bash
#
# Compile -> Groth16 setup -> Solidity verifier -> proof, for each probe circuit.
#
# Phase 0 exists to answer one question with a real number: does a
# production-shaped BabyJubJub-ElGamal Groth16 verify fit inside the gas budget on
# Monad? The reference's 1,031,828 figure is the verifier *core* only; a real
# circuit adds field arithmetic and input validation on top. The stated stop-line
# is ~1.5M gas.
#
# Usage: ./scripts/build.sh
set -euo pipefail

cd "$(dirname "$0")/.."

LIB=node_modules/circomlib/circuits
BUILD=build

# Real Hermez ceremony files. Using the actual ceremony output rather than a locally
# generated tau keeps the production path identical to the measurement path -- a
# self-generated tau would mean whoever ran it knows the toxic waste and could forge
# proofs.
#
# Power is per circuit because it is not free: a bigger tau means a bigger zkey and a
# slower setup, and the Phase 0 probes were measured against power 13. The Phase 1
# action circuits do not fit there -- a depth-20 Merkle path costs ~4,900 constraints
# on its own, putting `bet` at 14,194 and `redeem` at 12,734 against power 13's ceiling
# of 8,192. Those two need power 14 (16,384).
#
# Phase 2's `bet_encrypted` proves an ElGamal encryption in-circuit on top of the same
# Merkle path, at 21,250 constraints. That clears power 14's 16,384 ceiling, so it takes
# power 15 (32,768) -- the first circuit here that needs it.
#
# PROVENANCE IS UNVERIFIED FOR EVERY POWER USED HERE. `snarkjs powersoftau verify` has
# not been run to completion on any of these files (MEASUREMENTS.md §6). Setup succeeds
# against the published Hermez files, but nothing here has checked the ceremony
# transcript. Verify before anything holds value.
fetch_ptau() {
    local power="$1"
    local ptau="$BUILD/powersOfTau28_hez_final_${power}.ptau"
    if [[ ! -f "$ptau" ]]; then
        echo "==> fetching powers-of-tau (power $power)"
        curl -sL -o "$ptau" \
            "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_${power}.ptau"
    fi
    echo "$ptau"
}

# The committee key is gitignored (it holds a secret), but probe_fixed_key bakes the
# PUBLIC half in at compile time. Generate the key if absent, then derive the circom
# constants from it -- otherwise a clean clone compiles against a stale key and every
# ciphertext check fails looking like a circuit bug.
if [[ ! -f "$BUILD/committee-key.json" ]]; then
    echo "==> no committee key found, generating one (TEST KEY)"
    node scripts/keygen.mjs
fi
echo "==> deriving circom committee-key constants"
node scripts/gen_committee_key_circom.mjs

# circuit:ptau-power. Phase 0 probes stay on 13 so their measured gas is not perturbed
# by an unrelated change; the Phase 1 action circuits take the smallest power they fit.
CIRCUITS=(
    probe_pubkey_input:13
    probe_fixed_key:13
    deposit:13
    bet:14
    redeem:14
    bet_encrypted:15
)

for entry in "${CIRCUITS[@]}"; do
    c="${entry%%:*}"
    power="${entry##*:}"
    PTAU="$(fetch_ptau "$power" | tail -1)"

    echo
    echo "=============================================================="
    echo "  $c   (ptau power $power)"
    echo "=============================================================="

    echo "==> compiling"
    circom "src/$c.circom" --r1cs --wasm --sym -o "$BUILD" -l "$LIB" -l src

    echo "==> groth16 setup"
    npx snarkjs groth16 setup \
        "$BUILD/$c.r1cs" "$PTAU" "$BUILD/${c}_0000.zkey"

    # Phase-2 contribution. One contribution is enough to make the zkey usable;
    # a real deployment needs a multi-party ceremony, since anyone who knows every
    # contribution can forge proofs.
    echo "==> phase-2 contribution (single -- NOT a production ceremony)"
    npx snarkjs zkey contribute \
        "$BUILD/${c}_0000.zkey" "$BUILD/$c.zkey" \
        --name="atrum-measurement-$c" -v -e="$(head -c 64 /dev/urandom | base64)"

    echo "==> exporting verification key"
    npx snarkjs zkey export verificationkey \
        "$BUILD/$c.zkey" "$BUILD/${c}_vkey.json"

    echo "==> exporting Solidity verifier"
    npx snarkjs zkey export solidityverifier \
        "$BUILD/$c.zkey" "$BUILD/${c}_verifier.sol"

    rm -f "$BUILD/${c}_0000.zkey"
done

echo
echo "==> done. Verifiers:"
ls -la "$BUILD"/*_verifier.sol
