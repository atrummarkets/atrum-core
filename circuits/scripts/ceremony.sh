#!/usr/bin/env bash
#
# Groth16 phase-2 trusted setup ceremony.
#
# WHAT THIS FIXES
#
# `build.sh` runs exactly ONE `zkey contribute`, with entropy from the machine that ran it.
# Whoever holds that randomness -- the "toxic waste" -- can forge proofs for any of these
# circuits, and forging a proof here mints collateral from nothing. build.sh says so at the
# contribution step; this script is the fix it points at.
#
# A phase-2 ceremony has several people each inject randomness and destroy it. It is sound if
# EVEN ONE contributor was honest, which is why it matters that contributors are not all the
# same team: the claim being made is "not all of them colluded."
#
# ORDERING -- READ THIS BEFORE PLANNING A DEPLOYMENT
#
# New zkeys mean new verification keys, which mean regenerated Solidity verifiers, which mean
# every contract is redeployed. Run the ceremony BEFORE the final deployment or you will do
# the deployment twice.
#
# WHAT THIS SCRIPT IS NOT
#
# It is not part of `make circuits`, and CI must never call it. CI regenerates zkeys fresh in
# every job on purpose: it is testing that the two halves of a build agree with each other,
# not that the keys are trustworthy. Throwaway single-contribution keys are exactly right
# there, and making CI wait on human coordination would be wrong.
#
# It also does not try to be reproducible. `snarkjs zkey contribute` mixes in its own
# randomness even with a fixed `-e`, and build.sh:62-71 records a reverted attempt to pin it.
# That non-determinism IS the security property: if the setup were derivable from public
# inputs, the toxic waste would be public and every proof forgeable. Only the closing beacon
# is meant to be publicly reproducible.
#
# USAGE
#
#   ./scripts/ceremony.sh init       <circuit>
#   ./scripts/ceremony.sh contribute <circuit> <in.zkey> <out.zkey> <contributor-name>
#   ./scripts/ceremony.sh finalize   <circuit> <in.zkey> <beacon-hash>
#   ./scripts/ceremony.sh verify     <circuit> <zkey>
#
# The four live circuits: deposit, bet_encrypted, redeem_private, withdraw.
set -euo pipefail

# Resolve before the cd -- `$0` is relative and stops resolving once we move.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

cd "$(dirname "$0")/.."

BUILD=build
CEREMONY=ceremony
LIB=node_modules/circomlib/circuits

# Must match build.sh's CIRCUITS table. A circuit set up against the wrong power produces a
# zkey that cannot prove its own witnesses.
declare -A POWER=(
    [deposit]=13
    [bet_encrypted]=15
    [redeem_private]=14
    [withdraw]=14
)

die() { echo "error: $*" >&2; exit 1; }

ptau_for() {
    local c="$1"
    local power="${POWER[$c]:-}"
    [[ -n "$power" ]] || die "unknown circuit '$c' (expected one of: ${!POWER[*]})"
    local ptau="$BUILD/powersOfTau28_hez_final_${power}.ptau"
    if [[ ! -f "$ptau" ]]; then
        echo "==> fetching powers-of-tau (power $power)" >&2
        curl -sL -o "$ptau" \
            "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_${power}.ptau"
    fi
    echo "$ptau"
}

# Both hashes go in the transcript. snarkjs prints its own contribution hash, but the file
# sha256 is checkable by anyone who merely downloads the zkey, without trusting snarkjs's
# output or rerunning anything.
report_hash() {
    local f="$1"
    echo
    echo "  file   : $f"
    echo "  size   : $(du -h "$f" | cut -f1)"
    echo "  sha256 : $(sha256sum "$f" | cut -d' ' -f1)"
}

cmd_init() {
    local c="${1:-}"
    [[ -n "$c" ]] || die "usage: ceremony.sh init <circuit>"
    local ptau; ptau="$(ptau_for "$c")"

    mkdir -p "$CEREMONY"

    # build.sh deletes its own `_0000.zkey` once it has contributed, so there is nothing to
    # chain onto. Minting a fresh one is safe: `groth16 setup` is deterministic, so the same
    # .r1cs and .ptau produce identical bytes to any other build's starting point.
    if [[ ! -f "$BUILD/$c.r1cs" ]]; then
        echo "==> compiling $c (no r1cs yet)"
        circom "src/$c.circom" --r1cs --wasm --sym -o "$BUILD" -l "$LIB" -l src
    fi

    local out="$CEREMONY/${c}_0000.zkey"
    echo "==> groth16 setup ($c, ptau power ${POWER[$c]})"
    npx snarkjs groth16 setup "$BUILD/$c.r1cs" "$ptau" "$out"

    echo
    echo "STARTING POINT for $c -- record in TRANSCRIPT.md, then send to contributor #1."
    report_hash "$out"
}

cmd_contribute() {
    local c="${1:-}" in="${2:-}" out="${3:-}" who="${4:-}"
    [[ -n "$c" && -n "$in" && -n "$out" && -n "$who" ]] \
        || die "usage: ceremony.sh contribute <circuit> <in.zkey> <out.zkey> <contributor-name>"
    [[ -f "$in" ]] || die "no such file: $in"
    [[ ! -f "$out" ]] || die "$out already exists -- refusing to overwrite a contribution"

    echo "==> contributing to $c as '$who'"
    echo "    entropy comes from this machine and is never written down."

    # Run this on YOUR OWN machine. The point of the ceremony is that no single party sees
    # every contribution; running everyone's step centrally would reproduce exactly the
    # single-point-of-trust this replaces.
    npx snarkjs zkey contribute "$in" "$out" \
        --name="$who" -v -e="$(head -c 64 /dev/urandom | base64)"

    echo
    echo "CONTRIBUTION COMPLETE for $c by '$who'."
    echo "Post the hash below PUBLICLY (TRANSCRIPT.md) BEFORE passing the file on --"
    echo "publishing after the handoff proves nothing, because the chain could have been"
    echo "rewritten in between."
    report_hash "$out"
    echo
    echo "  next: send $out to the next contributor. Do NOT commit it -- it is a large"
    echo "        intermediate blob and only the final zkey matters."
}

cmd_finalize() {
    local c="${1:-}" in="${2:-}" beacon="${3:-}"
    [[ -n "$c" && -n "$in" && -n "$beacon" ]] \
        || die "usage: ceremony.sh finalize <circuit> <in.zkey> <beacon-hash>"
    [[ -f "$in" ]] || die "no such file: $in"

    # A beacon closes the chain with a value nobody could have ground out in advance -- so
    # the last contributor cannot pick their contribution to steer the result. Announce which
    # block you will use BEFORE it is mined.
    [[ "$beacon" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
        || die "beacon must be a 32-byte hex hash (a Monad block hash); got '$beacon'"
    local beacon_hex="${beacon#0x}"

    local ptau; ptau="$(ptau_for "$c")"
    local final="$CEREMONY/${c}_final.zkey"

    echo "==> applying beacon to $c"
    npx snarkjs zkey beacon "$in" "$final" "$beacon_hex" 10 -n="atrum production beacon"

    # Hard gate, not a warning. This is the check that the whole chain -- every contribution
    # plus the beacon -- is consistent with the circuit it claims to be for.
    echo "==> verifying the full chain against $c.r1cs"
    if ! npx snarkjs zkey verify "$BUILD/$c.r1cs" "$ptau" "$final"; then
        rm -f "$final"
        die "zkey verify FAILED for $c. The chain is broken -- do NOT deploy this. Deleted $final."
    fi

    # Install as the build's zkey so `make verifiers` picks it up with no special casing.
    # These three commands are build.sh:115-121 verbatim, so the downstream pipeline cannot
    # tell which path produced the key.
    cp "$final" "$BUILD/$c.zkey"
    npx snarkjs zkey export verificationkey "$BUILD/$c.zkey" "$BUILD/${c}_vkey.json"
    npx snarkjs zkey export solidityverifier "$BUILD/$c.zkey" "$BUILD/${c}_verifier.sol"

    echo
    echo "FINALISED $c. Verified against the r1cs and installed into $BUILD/."
    report_hash "$final"
    echo
    echo "  beacon : 0x$beacon_hex (iterations 10)"
    echo "  next   : record the above in TRANSCRIPT.md."
    echo "           When all four circuits are final: make verifiers && make fixtures && make test"
}

cmd_verify() {
    local c="${1:-}" zkey="${2:-}"
    [[ -n "$c" && -n "$zkey" ]] || die "usage: ceremony.sh verify <circuit> <zkey>"
    [[ -f "$zkey" ]] || die "no such file: $zkey"
    local ptau; ptau="$(ptau_for "$c")"
    npx snarkjs zkey verify "$BUILD/$c.r1cs" "$ptau" "$zkey"
    report_hash "$zkey"
}

case "${1:-}" in
    init)       shift; cmd_init "$@" ;;
    contribute) shift; cmd_contribute "$@" ;;
    finalize)   shift; cmd_finalize "$@" ;;
    verify)     shift; cmd_verify "$@" ;;
    *)
        sed -n '/^# USAGE/,/^set -euo/p' "$SELF" | sed 's/^# \{0,1\}//;$d'
        exit 1
        ;;
esac
