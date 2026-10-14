#!/usr/bin/env python3
"""Export committed ABI files from the artifacts created by forge build. No transactions."""
import json
from pathlib import Path

NAMES = ("InkPortraits", "InkVault", "InkLiquidity", "InkHook", "InkRenderer")


def main():
    Path("abi").mkdir(exist_ok=True)
    for name in NAMES:
        artifact = json.loads(Path(f"out/{name}.sol/{name}.json").read_text())
        Path(f"abi/{name}.json").write_text(json.dumps(artifact["abi"], indent=2) + "\n")


if __name__ == "__main__":
    main()
