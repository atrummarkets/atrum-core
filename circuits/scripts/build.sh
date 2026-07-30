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
PTAU="$BUILD/powersOfTau28_hez_final_13.ptau"

# Real Hermez ceremony file (power 13 -> 8,192 constraints; our circuits use
# ~6,840). Using the actual ceremony output rather than a locally generated tau
# keeps the production path identical to the measurement path -- a self-generated
# tau would mean whoever ran it knows the toxic waste and could forge proofs.
if [[ ! -f "$PTAU" ]]; then
    echo "==> fetching powers-of-tau (power 13)"
    curl -sL -o "$PTAU" \
        https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_13.ptau
fi

CIRCUITS=(probe_pubkey_input probe_fixed_key)

for c in "${CIRCUITS[@]}"; do
    echo
    echo "=============================================================="
    echo "  $c"
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
        --name="atrum-phase0-measurement" -v -e="$(head -c 64 /dev/urandom | base64)"

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
