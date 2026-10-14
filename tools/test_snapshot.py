import unittest
from snapshot import build, leaf, node

class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.rows = [{"seat": seat, "accepted": seat * 2, "rateBps": 7500,
                      "turns": 500, "hoursTenths": 123, "outdated": bool(seat % 2)} for seat in (0, 1, 777, 1999, 33)]

    def test_sorted_standard_tree_every_proof(self):
        tree, proofs = build(self.rows, synthetic=True)
        for row, proof in zip(self.rows, proofs):
            h = leaf(row)
            for sibling in proof: h = node(h, sibling)
            self.assertEqual(h, tree["tree"][0])
        reverse, _ = build(list(reversed(self.rows)), synthetic=True)
        self.assertEqual(tree["tree"], reverse["tree"])

    def test_invalid_and_incomplete_snapshots(self):
        with self.assertRaises(ValueError): build(self.rows)
        with self.assertRaises(ValueError): build(self.rows + [self.rows[0]], True)
        for key, value in (("seat", 2000), ("rateBps", 10001), ("accepted", -1), ("turns", 2**32), ("outdated", "false")):
            invalid = dict(self.rows[0]); invalid[key] = value
            with self.assertRaises(ValueError): leaf(invalid)
