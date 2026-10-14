#!/usr/bin/env python3
"""StandardMerkleTree-compatible snapshot builder; no seat owners or private snapshot are included."""
import argparse
import json
from pathlib import Path
from plan_upload import digest

ENCODING = ["uint256", "uint32", "uint16", "uint32", "uint32", "bool"]
FIELDS = ["seat", "accepted", "rateBps", "turns", "hoursTenths", "outdated"]


def leaf(row):
    numbers = [row[x] for x in FIELDS]
    if type(numbers[5]) is not bool:
        raise ValueError("outdated must be a boolean")
    for value, maximum in zip(numbers[:5], (1999, 2**32 - 1, 10000, 2**32 - 1, 2**32 - 1)):
        if type(value) is not int or not 0 <= value <= maximum:
            raise ValueError("Invalid seat/stat bound")
    encoded = b"".join(int(n).to_bytes(32, "big") for n in numbers)
    return digest(bytes.fromhex(digest(encoded)[2:]))


def node(a, b):
    return digest(bytes.fromhex("".join(sorted((a[2:], b[2:])))))


def build(rows, synthetic=False):
    if not rows or len({r["seat"] for r in rows}) != len(rows):
        raise ValueError("Snapshot must contain unique seat IDs")
    if not synthetic and {r["seat"] for r in rows} != set(range(2000)):
        raise ValueError("Production snapshot must cover all 2000 seats, including inactive seats")
    hashed = sorted((leaf(row), i) for i, row in enumerate(rows))
    tree = [None] * (2 * len(rows) - 1)
    indices = [None] * len(rows)
    for i, (value, original) in enumerate(hashed):
        index = len(tree) - 1 - i
        tree[index] = value
        indices[original] = index
    for i in range(len(rows) - 2, -1, -1):
        tree[i] = node(tree[2 * i + 1], tree[2 * i + 2])
    values = [{"value": [str(row[x]) if x != "outdated" else row[x] for x in FIELDS],
               "treeIndex": indices[i]} for i, row in enumerate(rows)]
    proofs = []
    for index in indices:
        proof = []
        while index:
            proof.append(tree[index - 1 if index % 2 == 0 else index + 1])
            index = (index - 1) // 2
        proofs.append(proof)
    return {"format": "standard-v1", "leafEncoding": ENCODING, "tree": tree, "values": values}, proofs


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--synthetic", action="store_true", help="Allow incomplete test fixtures, never production funding")
    args = p.parse_args()
    tree, proofs = build(json.loads(args.input.read_text()), args.synthetic)
    args.output.write_text(json.dumps(tree, indent=2) + "\n")
    args.output.with_suffix(".proofs.json").write_text(json.dumps({"synthetic": args.synthetic,
        "root": tree["tree"][0], "proofs": proofs}, indent=2) + "\n")


if __name__ == "__main__":
    main()
