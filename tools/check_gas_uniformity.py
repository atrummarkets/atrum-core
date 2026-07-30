#!/usr/bin/env python3
"""
CI GUARD: every shielded action must fit under ONE uniform declared gas limit.

Why this is a privacy check and not a cost check:

Monad charges the declared `gas_limit`, not `gas_used`, and `gas_limit` is a public
field. If deposit, bet and redeem each carry a snug, different limit, that field
alone reveals which private action a user took -- the proofs stay sealed and the
deanonymisation happens anyway through transaction metadata.

So this asserts:
  1. every measured action fits under UNIFORM_ACTION_GAS_LIMIT, and
  2. the envelope is not so loose that it wastes an unreasonable share of a block.

It reads the *on-chain measured* figures produced by `measure_verifier.py`, not
local forge numbers, so the check is against Monad's real repriced schedule.

Wired now, before Phase 1 adds the deposit/bet/redeem circuits, so a new action
that breaks uniformity fails CI instead of quietly shrinking the anonymity set.

Usage:
    python3 tools/measure_verifier.py --network testnet --json /tmp/gate.json
    python3 tools/check_gas_uniformity.py /tmp/gate.json
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POLICY_SOL = ROOT / "contracts" / "src" / "ActionGasPolicy.sol"

# If padding every action to the envelope leaves fewer than this many actions per
# block, the envelope is too loose to be practical.
MIN_ACTIONS_PER_BLOCK = 50


def solidity_constant(name: str) -> int:
    """Read a uint constant out of ActionGasPolicy.sol -- single source of truth."""
    text = POLICY_SOL.read_text()
    match = re.search(rf"{name}\s*=\s*([0-9_]+)\s*;", text)
    if not match:
        raise SystemExit(f"could not find constant {name} in {POLICY_SOL}")
    return int(match.group(1).replace("_", ""))


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    gate = json.loads(Path(sys.argv[1]).read_text())
    envelope = solidity_constant("UNIFORM_ACTION_GAS_LIMIT")
    block_limit = solidity_constant("BLOCK_GAS_LIMIT")
    declared_max = solidity_constant("MAX_MEASURED_VERIFY_GAS")

    print("gas-limit uniformity check")
    print(f"  network              {gate['network']}")
    print(f"  uniform envelope     {envelope:,}")
    print()

    failures: list[str] = []
    costs: dict[str, int] = {}

    for name, r in gate["results"].items():
        if "error" in r:
            failures.append(f"{name}: {r['error']}")
            continue
        # The first action in a transaction pays the cold-access premium, so that is
        # the figure the declared limit has to cover -- not the warm cost.
        costs[name] = r["verify_gas_cold_first_call"]

    if not costs:
        failures.append("no measured actions found in gate results")

    for name, cost in sorted(costs.items(), key=lambda kv: -kv[1]):
        headroom = envelope - cost
        ok = cost <= envelope
        print(f"  {'ok  ' if ok else 'FAIL'} {name:<24} {cost:>10,}"
              f"   headroom {headroom:>10,}")
        if not ok:
            failures.append(
                f"{name} needs {cost:,} > envelope {envelope:,} -- optimise it or "
                f"consciously raise UNIFORM_ACTION_GAS_LIMIT"
            )

    if costs:
        worst = max(costs.values())
        print()

        # The declared MAX_MEASURED_VERIFY_GAS must not drift below reality, or the
        # envelope's justification silently stops matching the measurements.
        if worst > declared_max:
            failures.append(
                f"MAX_MEASURED_VERIFY_GAS is {declared_max:,} but we measured "
                f"{worst:,}. Update ActionGasPolicy.sol."
            )

        per_block = block_limit // envelope
        print(f"  worst measured action  {worst:,}")
        print(f"  envelope utilisation   {100 * worst / envelope:.1f}%")
        print(f"  actions per block      {per_block}")

        if per_block < MIN_ACTIONS_PER_BLOCK:
            failures.append(
                f"envelope allows only {per_block} actions/block, below the "
                f"{MIN_ACTIONS_PER_BLOCK} floor -- envelope is too loose"
            )

        # Not fatal, but worth surfacing: a very slack envelope wastes real money on
        # every action, since Monad charges the declared limit.
        if worst < envelope // 2:
            print(f"\n  note: worst action uses under half the envelope. Padding is "
                  f"the price of the anonymity set, but {envelope - worst:,} gas of "
                  f"slack is paid on EVERY action.")

    print()
    if failures:
        print("FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASSED -- all actions fit one uniform declared gas limit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
