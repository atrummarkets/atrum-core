#!/usr/bin/env python3
"""
PHASE 1 GATE (part 1): what does Poseidon actually cost on Monad?

Poseidon is the commitment and nullifier hash for the shielded pool. It is chosen
because it is cheap *inside* a ZK circuit -- but on-chain it is a long chain of
field multiplications rather than a native opcode, so it is comparatively
expensive there.

This is the number that drives Phase 1's design, because a Merkle insertion pays
for one Poseidon per tree level. At depth 20 the hash cost is multiplied by 20, and
on top of that Monad charges 8,100 per cold SLOAD (4x Ethereum) for the sibling
path. If those two together push a single insertion over the action gas envelope,
the tree has to be redesigned -- shallower, or batched harder, or both.

Runtime bytecode is extracted by deploying circomlib's generated contract to a
local Monad-mode anvil, then injected into a live-chain `eth_call` so the figure
comes from Monad's real gas schedule.

Usage:
    anvil -n monad --port 8555 --silent &
    python3 tools/measure_poseidon.py [--network testnet|mainnet]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from monad_gas import TARGET_ADDR, measure_marginal, rpc  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
POSEIDON_JSON = ROOT / "circuits" / "build" / "poseidon-contracts.json"
ANVIL = "http://127.0.0.1:8555"

# anvil's first prefunded dev account.
DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

CAST = Path.home() / ".foundry-monad" / "bin" / "cast"


def local_rpc(method: str, params: list):
    req = urllib.request.Request(
        ANVIL,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                         "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise SystemExit(f"anvil {method}: {body['error']}")
    return body["result"]


def deploy_and_get_runtime(creation_code: str) -> str:
    """Deploy to local anvil, return the deployed runtime bytecode."""
    out = subprocess.run(
        [str(CAST), "send", "--rpc-url", ANVIL, "--private-key", DEV_KEY,
         "--create", creation_code, "--json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise SystemExit(
            f"deploy failed -- is `anvil -n monad --port 8555` running?\n{out.stderr}"
        )
    receipt = json.loads(out.stdout)
    address = receipt["contractAddress"]
    return local_rpc("eth_getCode", [address, "latest"])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--network", choices=["testnet", "mainnet"], default="testnet")
    ap.add_argument("--json", metavar="PATH")
    args = ap.parse_args()

    contracts = json.loads(POSEIDON_JSON.read_text())

    print(f"Poseidon gas on Monad {args.network}\n")
    results = {}

    for name, meta in contracts.items():
        n = meta["inputs"]
        runtime = deploy_and_get_runtime(meta["creationCode"])

        # poseidon(uint256[n]) -- a fixed-size array, so calldata is just the
        # selector plus n words. Non-zero inputs, so we are not measuring a
        # short-circuit on zeros.
        sig = f"poseidon(uint256[{n}])"
        sel = subprocess.run([str(CAST), "sig", sig],
                             capture_output=True, text=True, check=True).stdout.strip()
        calldata = sel + "".join(f"{i + 1:064x}" for i in range(n))

        overrides = {TARGET_ADDR: {"code": runtime}}

        # Confirm it returns a sane field element before trusting the gas figure.
        ret = rpc(args.network, "eth_call", [
            {"to": TARGET_ADDR, "data": calldata, "gas": hex(0x2000000)},
            "latest", overrides,
        ])
        digest = int(ret, 16)
        if digest == 0:
            print(f"{name}: returned zero -- call likely failed, skipping")
            continue

        m = measure_marginal(args.network, TARGET_ADDR, calldata, overrides)

        print(f"--- {name} ({n} inputs) ---")
        print(f"  runtime bytecode   {len(runtime) // 2 - 1:,} bytes")
        print(f"  digest             0x{digest:064x}")
        print(f"  gas (warm)         {m['cost']:,}")
        print(f"  linear             {m['linear']}\n")

        results[name] = {"inputs": n, "gas": m["cost"],
                         "bytecode_bytes": len(runtime) // 2 - 1}

    # What this implies for a Merkle tree, using our own measured numbers.
    if "poseidon2" in results:
        h = results["poseidon2"]["gas"]
        COLD_SLOAD = 8_100      # documented, and we measured 8,115 locally
        SSTORE_RESET = 2_900

        print("=" * 62)
        print("IMPLICATIONS for an incremental Merkle tree [DERIVED]")
        print("=" * 62)
        print(f"  Poseidon(2) measured: {h:,} gas\n")
        print(f"  {'depth':>6} {'hashes':>10} {'cold SLOADs':>13} "
              f"{'total/insert':>14} {'vs 2M envelope':>16}")

        for depth in (16, 20, 24, 32):
            hashes = depth * h
            sloads = depth * COLD_SLOAD
            writes = 3 * SSTORE_RESET  # root, nextIndex, one filledSubtree
            total = hashes + sloads + writes
            print(f"  {depth:>6} {hashes:>10,} {sloads:>13,} {total:>14,} "
                  f"{100 * total / 2_000_000:>15.1f}%")

        print("\n  Add ~1,030,000 for the Groth16 verify in the same transaction.")
        depth20 = 20 * h + 20 * COLD_SLOAD + 3 * SSTORE_RESET
        combined = depth20 + 1_029_454
        print(f"  depth-20 insert + verify = {combined:,} "
              f"({100 * combined / 2_000_000:.1f}% of the 2M envelope)")
        if combined > 2_000_000:
            print("\n  *** EXCEEDS the envelope. Batching is not an optimisation "
                  "here, it is mandatory. ***")

        results["_derived"] = {
            "poseidon2_gas": h,
            "depth20_insert_gas": depth20,
            "depth20_insert_plus_verify": combined,
            "fits_2m_envelope": combined <= 2_000_000,
        }

    if args.json:
        Path(args.json).write_text(json.dumps(
            {"network": args.network, "results": results}, indent=2))
        print(f"\nwrote {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
