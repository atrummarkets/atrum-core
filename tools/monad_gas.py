#!/usr/bin/env python3
"""
Monad gas prober.

Measures real gas consumption on a live Monad node without spending anything and
without a funded key, by using `eth_call` with state overrides:

  1. Inject a small probe contract at a throwaway address.
  2. The probe brackets a STATICCALL to the target with GAS ... GAS, SUB.
  3. The probe returns the delta, so the *node's* gas schedule does the measuring.

This is the method behind `nisi-master-reference.md` Appendix A, generalised so it
can measure arbitrary injected bytecode (e.g. a generated Groth16 verifier), not
just precompiles.

Why this and not `forge test --gas-report`: Monad reprices BN254 by ~5x. Only the
real node knows the real schedule. Local numbers are a cross-check, never the
source of truth.

Usage:
    python3 tools/monad_gas.py precompiles [--network testnet|mainnet]
    python3 tools/monad_gas.py chain      [--network testnet|mainnet]
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request

RPC = {
    "mainnet": "https://rpc.monad.xyz",
    "testnet": "https://testnet-rpc.monad.xyz",
}
CHAIN_ID = {"mainnet": 143, "testnet": 10143}

# Throwaway addresses for injected code. Never deployed; exist only inside the
# eth_call state override.
PROBE_ADDR = "0x000000000000000000000000000000000000dEaD"
TARGET_ADDR = "0x000000000000000000000000000000000000c0de"

# A STATICCALL that runs out of gas consumes everything forwarded. We forward
# 0xffffff, so a result at/near that value means the call reverted -- invalid
# input, not a valid measurement.
FORWARDED_GAS = 0xFFFFFF
REVERT_SENTINEL = FORWARDED_GAS - 1

# Constant cost of the probe's own opcodes (the pushes, GAS, SWAP1, SUB, MSTORE,
# RETURN) plus memory expansion to the return offset. Cancels out in deltas
# between two measurements, and is subtracted for absolute figures.
PROBE_OVERHEAD = 250

# Cost of the probe's own per-call opcodes (six PUSHes, STATICCALL base, POP).
# Empirically calibrated and cross-validated against three targets of known cost
# spanning three orders of magnitude -- ecAdd (300), ecMul (30,000) and
# ecPairing k=4 (905,000) -- each of which measured exactly 119 gas high.
PER_CALL_OVERHEAD = 119


class RpcError(RuntimeError):
    pass


def _push(value: int) -> str:
    """Minimal PUSHn for a non-negative int. PUSH1..PUSH32."""
    if value == 0:
        return "6000"  # PUSH1 0x00
    body = f"{value:x}"
    if len(body) % 2:
        body = "0" + body
    nbytes = len(body) // 2
    if nbytes > 32:
        raise ValueError(f"cannot push {value}: exceeds 32 bytes")
    return f"{0x5F + nbytes:02x}{body}"


def probe_precompile(address: int, args_size: int) -> str:
    """
    Bytecode measuring a STATICCALL to `address` with `args_size` bytes of
    zero-filled calldata (memory is untouched, so it reads as zeros).

    Zero-filled input is deliberate: for the EC precompiles an all-zero point
    decodes as the point at infinity, which is valid, so the call succeeds and
    the cost is the real arithmetic cost. This is what makes the pairing linear
    fit work across k.
    """
    return (
        "5a"                     # GAS                      -> gasBefore
        + _push(32)              # retSize
        + _push(0x2000)          # retOffset (well clear of args)
        + _push(args_size)       # argsSize
        + _push(0)               # argsOffset
        + _push(address)         # target
        + _push(FORWARDED_GAS)   # gas
        + "fa"                   # STATICCALL
        + "50"                   # POP (discard success flag)
        + "5a"                   # GAS                      -> gasAfter
        + "90"                   # SWAP1
        + "03"                   # SUB  -> gasBefore - gasAfter
        + _push(0) + "52"        # MSTORE at 0
        + _push(32) + _push(0) + "f3"   # RETURN 32 bytes
    )


def probe_contract(target: str, repeats: int = 1) -> str:
    """
    Bytecode that forwards the probe's own calldata verbatim to `target`,
    `repeats` times, bracketed by GAS ... GAS, SUB.

    Used to measure injected contract bytecode such as a generated Groth16
    verifier. Repeat it and take the marginal cost (see `measure_marginal`):
    a single absolute reading is contaminated by constants that do NOT apply to
    the real per-transaction cost -- notably the *cold account access*, which is
    10,100 gas on Monad (vs 2,600 on Ethereum) and is paid only on first touch.
    """
    target_int = int(target, 16)
    one_call = (
        _push(32)                # retSize
        + _push(0x4000)          # retOffset (clear of copied calldata)
        + "36"                   # argsSize = CALLDATASIZE
        + _push(0)               # argsOffset
        + _push(target_int)      # target
        + _push(FORWARDED_GAS)   # gas
        + "fa"                   # STATICCALL
        + "50"                   # POP (discard success flag)
    )
    return (
        # copy all calldata to memory[0:]
        "36"                     # CALLDATASIZE   (size)
        + _push(0)               # offset
        + _push(0)               # destOffset
        + "37"                   # CALLDATACOPY
        + "5a"                   # GAS            -> gasBefore
        + one_call * repeats
        + "5a"                   # GAS            -> gasAfter
        + "90"                   # SWAP1
        + "03"                   # SUB
        + _push(0) + "52"        # MSTORE at 0
        + _push(32) + _push(0) + "f3"   # RETURN 32 bytes
    )


def measure_marginal(
    network: str,
    target: str,
    calldata: str = "0x",
    overrides: dict | None = None,
) -> dict:
    """
    Marginal cost of one call to `target`, with every constant cancelled.

    cost = gas(2 calls) - gas(1 call)

    Everything constant -- probe opcodes, CALLDATACOPY, memory expansion, and
    the one-time cold account access -- appears identically in both readings and
    subtracts out exactly. The result is the true warm, per-call cost.

    Also returns `cold_premium`: what the first touch costs on top of that, which
    is the figure that actually applies to the first call in a transaction.
    """
    one = measure(network, probe_contract(target, 1), calldata, overrides,
                  subtract_overhead=False)
    two = measure(network, probe_contract(target, 2), calldata, overrides,
                  subtract_overhead=False)
    three = measure(network, probe_contract(target, 3), calldata, overrides,
                    subtract_overhead=False)

    # Linearity check: the 2->3 delta must equal the 1->2 delta, or something
    # non-constant is in play (memory growth, warm/cold transitions) and the
    # marginal figure cannot be trusted.
    marginal = two - one
    marginal_2 = three - two

    return {
        # true warm per-call cost of the target itself
        "cost": marginal - PER_CALL_OVERHEAD,
        "linear": marginal == marginal_2,
        "first_call_total": one,
        # what the first touch adds: cold account access etc.
        "cold_premium": one - marginal,
    }


def rpc(network: str, method: str, params: list) -> object:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    req = urllib.request.Request(
        RPC[network],
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RpcError(f"{method}: {body['error']}")
    return body["result"]


def measure(
    network: str,
    probe_code: str,
    calldata: str = "0x",
    overrides: dict | None = None,
    subtract_overhead: bool = True,
) -> int:
    """
    Run a probe and return gas consumed by the bracketed call.
    Raises RpcError if the inner call reverted (consumed all forwarded gas).
    """
    state = {PROBE_ADDR: {"code": "0x" + probe_code.removeprefix("0x")}}
    for addr, ov in (overrides or {}).items():
        state[addr] = ov

    result = rpc(
        network,
        "eth_call",
        [
            {"to": PROBE_ADDR, "data": calldata, "gas": hex(0x2000000)},
            "latest",
            state,
        ],
    )
    used = int(result, 16)
    if used >= REVERT_SENTINEL:
        raise RpcError(
            f"inner call consumed all forwarded gas ({used}) -- it reverted; "
            "input is invalid for this target"
        )
    return used - PROBE_OVERHEAD if subtract_overhead else used


# ---------------------------------------------------------------------------
# Precompile suite
# ---------------------------------------------------------------------------

# BN254 base field prime -- used to build a real 256-bit modular inversion for
# the modexp probe.
BN254_P = 21888242871839275222246405745257275088696311157297823662689037894645226208583

# (label, address, args_size, reference_value_from_nisi_master_reference)
PRECOMPILES = [
    ("ecRecover      0x01", 0x01, 128, 6_000),
    ("ecAdd          0x06", 0x06, 128, 300),
    ("ecMul          0x07", 0x07, 96, 30_000),
    ("bls12_g1_add   0x0b", 0x0B, 256, 375),
    ("bls12_g2_add   0x0d", 0x0D, 512, 600),
    ("p256_verify  0x0100", 0x0100, 160, 6_900),
]


def measure_modexp_inverse(network: str) -> int:
    """
    Measure a real 256-bit modular inversion: base^(p-2) mod p over the BN254
    base field (Fermat's little theorem, the standard way to invert in-EVM).

    modexp cannot be probed with zero-filled memory: all-zero length headers make
    it the trivial path (~500 gas), not the 4,712 the reference reports. The input
    has to be structured, so it is passed as calldata and copied in.
    """
    payload = (
        f"{32:064x}"            # length of base
        + f"{32:064x}"          # length of exponent
        + f"{32:064x}"          # length of modulus
        + f"{3:064x}"           # base = 3 (any non-trivial residue)
        + f"{BN254_P - 2:064x}"  # exponent = p - 2
        + f"{BN254_P:064x}"     # modulus = p
    )
    return measure_marginal(network, "0x05", calldata="0x" + payload)["cost"]


def run_precompiles(network: str) -> dict:
    print(f"\n=== precompiles on Monad {network} (chain {CHAIN_ID[network]}) ===")
    print(f"{'precompile':<22} {'measured':>10} {'reference':>10}  {'':>6}")
    results = {}

    for label, addr, size, reference in PRECOMPILES:
        try:
            gas = measure(network, probe_precompile(addr, size))
            flag = "ok" if gas == reference else f"DIFF {gas - reference:+,}"
            print(f"{label:<22} {gas:>10,} {reference:>10,}  {flag}")
            results[label] = gas
        except RpcError as exc:
            print(f"{label:<22} {'--':>10} {reference:>10,}  {exc}")
            results[label] = None

    # modexp needs structured (non-zero) input, so it is probed separately.
    try:
        gas = measure_modexp_inverse(network)
        ref = 4_712
        flag = "ok" if gas == ref else f"DIFF {gas - ref:+,}"
        print(f"{'modexp 0x05 (256-inv)':<22} {gas:>10,} {ref:>10,}  {flag}")
        results["modexp 0x05 (256-bit inverse)"] = gas
    except RpcError as exc:
        print(f"{'modexp 0x05 (256-inv)':<22} {'--':>10} {4712:>10,}  {exc}")
        results["modexp 0x05 (256-bit inverse)"] = None

    # Pairings are linear in the number of pairs: cost = base + slope*k.
    # Measuring across k and checking the deltas are identical is what proves
    # the fit (and proves the measurement is sound).
    for label, addr, pair_bytes, ref_base, ref_slope in [
        ("ecPairing 0x08 (BN254)", 0x08, 192, 225_000, 170_000),
        ("bls12_pairing 0x0f", 0x0F, 384, 37_700, 32_600),
    ]:
        print(f"\n--- {label}: cost = base + slope*k ---")
        points = {}
        for k in range(0, 6):
            try:
                points[k] = measure(network, probe_precompile(addr, k * pair_bytes))
                print(f"  k={k}  {points[k]:>12,}")
            except RpcError as exc:
                print(f"  k={k}  failed: {exc}")

        deltas = [
            points[k] - points[k - 1]
            for k in range(1, 6)
            if k in points and k - 1 in points
        ]
        if deltas:
            uniform = len(set(deltas)) == 1
            slope = deltas[0]
            base = points.get(0)
            print(f"  deltas: {[f'{d:,}' for d in deltas]}")
            print(f"  slope = {slope:,} (reference {ref_slope:,})"
                  f"{'  ok' if slope == ref_slope else '  DIFF'}")
            if base is not None:
                print(f"  base  = {base:,} (reference {ref_base:,})"
                      f"{'  ok' if base == ref_base else '  DIFF'}")
            print(f"  linear fit exact across k: {uniform}")
            results[label] = {"base": base, "slope": slope, "exact": uniform}

    return results


# ---------------------------------------------------------------------------
# Chain parameters
# ---------------------------------------------------------------------------

def run_chain(network: str) -> dict:
    print(f"\n=== chain parameters, Monad {network} ===")
    chain_id = int(rpc(network, "eth_chainId", []), 16)
    block = rpc(network, "eth_getBlockByNumber", ["latest", False])

    gas_limit = int(block["gasLimit"], 16)
    gas_used = int(block["gasUsed"], 16)
    base_fee = int(block.get("baseFeePerGas", "0x0"), 16)
    number = int(block["number"], 16)
    tx_count = len(block.get("transactions", []))

    print(f"  chain id            {chain_id}  "
          f"{'ok' if chain_id == CHAIN_ID[network] else 'MISMATCH'}")
    print(f"  block number        {number:,}")
    print(f"  block gas limit     {gas_limit:,}")
    print(f"  block gas used      {gas_used:,}")
    print(f"  utilisation         {100 * gas_used / gas_limit:.2f}%")
    print(f"  base fee            {base_fee / 1e9:.1f} gwei")
    print(f"  txs in block        {tx_count}")

    return {
        "chain_id": chain_id,
        "block_number": number,
        "block_gas_limit": gas_limit,
        "block_gas_used": gas_used,
        "base_fee_wei": base_fee,
        "tx_count": tx_count,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["precompiles", "chain", "all"])
    ap.add_argument("--network", choices=list(RPC), default="testnet")
    ap.add_argument("--json", metavar="PATH", help="write results as JSON")
    args = ap.parse_args()

    out = {"network": args.network}
    try:
        if args.command in ("chain", "all"):
            out["chain"] = run_chain(args.network)
        if args.command in ("precompiles", "all"):
            out["precompiles"] = run_precompiles(args.network)
    except (RpcError, OSError) as exc:
        print(f"\nfailed: {exc}", file=sys.stderr)
        return 1

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(out, fh, indent=2, default=str)
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
