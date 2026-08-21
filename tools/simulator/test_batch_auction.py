#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from batch_auction import allocate, choose_price, simulate


class BatchAuctionTests(unittest.TestCase):
    def test_reference_book_and_strict_priority(self):
        result = simulate({"orders": [
            {"id": "b1", "side": "buy", "limit": 105, "size": 4},
            {"id": "b2", "side": "buy", "limit": 100, "size": 6},
            {"id": "b3", "side": "buy", "limit": 95, "size": 5},
            {"id": "s1", "side": "sell", "limit": 95, "size": 3},
            {"id": "s2", "side": "sell", "limit": 100, "size": 5},
            {"id": "s3", "side": "sell", "limit": 105, "size": 4},
        ]})
        self.assertEqual(result["clearing_price"], 100)
        self.assertEqual(result["executable_volume"], 8)
        self.assertEqual({x["id"]: x["filled"] for x in result["fills"]},
                         {"b1": 4, "b2": 4, "b3": 0, "s1": 3, "s2": 5, "s3": 0})

    def test_round_down_retains_marginal_remainder(self):
        orders = [
            {"id": "b1", "side": "buy", "limit": 100, "size": 1},
            {"id": "b2", "side": "buy", "limit": 100, "size": 1},
        ]
        self.assertEqual(allocate(orders, 100, 1, "buy"), {"b1": 0, "b2": 0})

    def test_previous_price_and_first_batch_tie_break(self):
        orders = [
            {"id": "b1", "side": "buy", "limit": 100, "size": 1},
            {"id": "s1", "side": "sell", "limit": 100, "size": 1},
            {"id": "b2", "side": "buy", "limit": 110, "size": 1},
            {"id": "s2", "side": "sell", "limit": 110, "size": 1},
        ]
        self.assertEqual(choose_price(orders)[0], 100)
        self.assertEqual(choose_price(orders, 110)[0], 110)

    def test_input_order_and_equal_price_do_not_create_time_priority(self):
        orders = [
            {"id": "late", "side": "buy", "limit": 110, "size": 3},
            {"id": "early", "side": "buy", "limit": 110, "size": 3},
        ]
        fills = allocate(orders, 100, 3, "buy")
        self.assertEqual(fills, {"early": 1, "late": 1})
        payload = {"orders": orders + [{"id": "s", "side": "sell", "limit": 100, "size": 3}]}
        self.assertEqual(simulate(payload), simulate({"orders": list(reversed(payload["orders"]))}))

    def test_non_integer_quantities_fail_closed(self):
        with self.assertRaises(ValueError):
            simulate({"orders": [{"id": "b", "side": "buy", "limit": "1.5", "size": 1}]})


if __name__ == "__main__":
    unittest.main()
