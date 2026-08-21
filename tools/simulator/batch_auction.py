#!/usr/bin/env python3
"""Deterministic integer batch-auction reference simulator.

This is an off-chain policy fixture for Atrum's confirmed V2 clearing rules.
It deliberately models order sizes and price levels as integers: quantities are
collateral denominations and prices are grid levels, not decimal floats.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def normalize(order: dict[str, Any]) -> dict[str, Any]:
    side = order.get("side", "").lower()
    if side not in {"buy", "sell"}:
        raise ValueError(f"{order.get('id', '<missing>')}: invalid side")
    try:
        limit = int(order["limit"])
        size = int(order["size"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"{order.get('id', '<missing>')}: limit and size must be integers") from exc
    if str(limit) != str(order["limit"]) or str(size) != str(order["size"]):
        raise ValueError(f"{order.get('id', '<missing>')}: limit and size must be integer values")
    if limit < 0 or size <= 0:
        raise ValueError(f"{order.get('id', '<missing>')}: limit must be >= 0 and size > 0")
    return {"id": str(order["id"]), "side": side, "limit": limit, "size": size}


def curve(orders: list[dict[str, Any]], price: int) -> tuple[int, int]:
    demand = sum(o["size"] for o in orders if o["side"] == "buy" and o["limit"] >= price)
    supply = sum(o["size"] for o in orders if o["side"] == "sell" and o["limit"] <= price)
    return demand, supply


def choose_price(
    orders: list[dict[str, Any]],
    previous_price: int | None = None,
    grid_levels: int | None = None,
) -> tuple[int, int, int]:
    if grid_levels is None or grid_levels <= 0:
        raise ValueError("grid_levels must be a positive integer")
    candidates = []
    for price in range(grid_levels):
        demand, supply = curve(orders, price)
        candidates.append((-min(demand, supply), abs(demand - supply), price, demand, supply))
    if not candidates:
        raise ValueError("orders must not be empty")
    best_volume = min(row[0] for row in candidates)
    best_imbalance = min(row[1] for row in candidates if row[0] == best_volume)
    tied = [row for row in candidates if row[0] == best_volume and row[1] == best_imbalance]
    if previous_price is None:
        selected = min(tied, key=lambda row: row[2])
    else:
        selected = min(tied, key=lambda row: (abs(row[2] - previous_price), row[2]))
    _, _, price, demand, supply = selected
    return price, demand, supply


def _pro_rata(group: list[dict[str, Any]], amount: int) -> dict[str, int]:
    total = sum(o["size"] for o in group)
    if not total or amount <= 0:
        return {o["id"]: 0 for o in group}
    # Integer division intentionally retains any remainder at the marginal level.
    return {o["id"]: o["size"] * amount // total for o in sorted(group, key=lambda x: x["id"])}


def allocate(eligible: list[dict[str, Any]], price: int, target: int, side: str) -> dict[str, int]:
    strict = [o for o in eligible if (o["limit"] > price if side == "buy" else o["limit"] < price)]
    marginal = [o for o in eligible if o["limit"] == price]
    fills: dict[str, int] = {}
    remaining = target
    levels: dict[int, list[dict[str, Any]]] = {}
    for order in strict:
        levels.setdefault(order["limit"], []).append(order)
    for level in sorted(levels, reverse=side == "buy"):
        group = levels[level]
        total = sum(o["size"] for o in group)
        if total <= remaining:
            fills.update({o["id"]: o["size"] for o in group})
            remaining -= total
        else:
            fills.update(_pro_rata(group, remaining))
            return fills
    fills.update(_pro_rata(marginal, remaining))
    return fills


def simulate(payload: dict[str, Any]) -> dict[str, Any]:
    orders = [normalize(order) for order in payload.get("orders", [])]
    if not orders:
        raise ValueError("orders must not be empty")
    if len({o["id"] for o in orders}) != len(orders):
        raise ValueError("order IDs must be unique")
    previous = payload.get("previous_clearing_price")
    previous_price = int(previous) if previous is not None else None
    if previous is not None and str(previous_price) != str(previous):
        raise ValueError("previous_clearing_price must be an integer")
    grid_levels = payload.get("grid_levels")
    try:
        grid_levels = int(grid_levels)
    except (TypeError, ValueError) as exc:
        raise ValueError("grid_levels must be a positive integer") from exc
    if str(grid_levels) != str(payload.get("grid_levels")) or grid_levels <= 0:
        raise ValueError("grid_levels must be a positive integer")
    if any(order["limit"] >= grid_levels for order in orders):
        raise ValueError("order limits must be within the configured grid")
    price, demand, supply = choose_price(orders, previous_price, grid_levels)
    volume = min(demand, supply)
    buys = [o for o in orders if o["side"] == "buy" and o["limit"] >= price]
    sells = [o for o in orders if o["side"] == "sell" and o["limit"] <= price]
    buy_fills = allocate(buys, price, volume, "buy")
    sell_fills = allocate(sells, price, volume, "sell")
    executed = min(sum(buy_fills.values()), sum(sell_fills.values()))
    while sum(buy_fills.values()) != executed or sum(sell_fills.values()) != executed:
        buy_fills = allocate(buys, price, executed, "buy")
        sell_fills = allocate(sells, price, executed, "sell")
        executed = min(sum(buy_fills.values()), sum(sell_fills.values()))
    assert sum(buy_fills.values()) == sum(sell_fills.values()) == executed
    fills = {**buy_fills, **sell_fills}
    return {
        "clearing_price": price,
        "executable_volume": executed,
        "demand_at_price": demand,
        "supply_at_price": supply,
        "imbalance": abs(demand - supply),
        "fills": [{**o, "filled": fills.get(o["id"], 0)} for o in sorted(orders, key=lambda x: x["id"])],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", help="JSON fixture; stdin if omitted")
    args = parser.parse_args()
    payload = json.loads(open(args.input).read() if args.input else sys.stdin.read())
    json.dump(simulate(payload), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
