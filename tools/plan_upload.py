#!/usr/bin/env python3
"""Read and verify renderer state, then emit calldata only. This program cannot send transactions."""
import argparse
import json
from pathlib import Path
import re
import subprocess

MAX_SIZE = 131072
MAX_CHUNK = 8192
MAX_CHUNKS = 64


def cast(*args):
    return subprocess.check_output(["cast", *map(str, args)], text=True).strip()


def digest(data):
    # Hex via stdin avoids Linux's per-argument size limit for the supported 128 KiB script.
    return subprocess.check_output(["cast", "keccak"], input="0x" + data.hex(), text=True).strip().lower()


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise ValueError("A nonzero, explicit address is required")
    return value.lower()


def calldata(signature, *args):
    return cast("calldata", signature, *args)


def verify_and_plan(data, state, chunks, chunk_size=MAX_CHUNK, restart=False):
    """Pure planning apart from local cast hashing/ABI encoding; no RPC or signing here."""
    if not data or len(data) > MAX_SIZE or not 1 <= chunk_size <= MAX_CHUNK:
        raise ValueError("Script must be 1..131072 bytes; chunk size must be 1..8192")
    wanted_hash = digest(data)
    version = state["uploadVersion"]
    operations = []
    same_upload = state["expectedBytes"] == len(data) and state["expectedHash"].lower() == wanted_hash
    if state["scriptLocked"] and not same_upload:
        raise ValueError("Locked renderer contains a different script")
    if restart and state["scriptLocked"]:
        raise ValueError("Cannot restart a locked renderer")
    if not same_upload or restart:
        if state["expectedBytes"] and not restart:
            raise ValueError("A different upload is in progress; explicit --restart required")
        operations.append({"operation": "beginUpload", "data": calldata(
            "beginUpload(uint256,uint256,bytes32)", version, len(data), wanted_hash)})
        version += 1
        chunks = []
        uploaded = 0
    else:
        if len(chunks) != state["chunkCount"]:
            raise ValueError("Chunk count changed or snapshot is inconsistent")
        uploaded = sum(len(c) for c in chunks)
        if uploaded != state["uploadedBytes"] or b"".join(chunks) != data[:uploaded] or uploaded > len(data):
            raise ValueError("Stored chunks do not exactly match the local script prefix")
        if any(not c or len(c) > MAX_CHUNK for c in chunks):
            raise ValueError("Invalid stored chunk size")
        if state["scriptLocked"] and uploaded != len(data):
            raise ValueError("Locked renderer is incomplete")
    index = len(chunks)
    if index + (len(data) - uploaded + chunk_size - 1) // chunk_size > MAX_CHUNKS:
        raise ValueError("Upload would exceed 64 chunks; choose larger chunks or explicitly restart")
    for offset in range(uploaded, len(data), chunk_size):
        part = data[offset:offset + chunk_size]
        operations.append({"operation": "appendChunk", "index": index,
                           "keccak256": digest(part), "bytes": len(part),
                           "data": calldata("appendChunk(uint256,uint256,bytes)", version, index, "0x" + part.hex())})
        index += 1
    lock = None if state["scriptLocked"] else {
        "operation": "lockScript", "irreversible": True,
        "data": calldata("lockScript(uint256,bytes32)", version, wanted_hash),
        "instruction": "Re-run this verifier after all append receipts; inspect the original art before signing this separately."
    }
    return {"scriptKeccak256": wanted_hash, "scriptBytes": len(data), "uploadVersion": version,
            "verifiedPrefixBytes": uploaded, "transactions": operations, "separateLockCandidate": lock}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, required=True, help="Owner-supplied ORIGINAL JS; never generated art")
    parser.add_argument("--renderer", type=address, required=True)
    parser.add_argument("--owner", type=address, required=True)
    parser.add_argument("--rpc-url", required=True, help="Read-only JSON-RPC endpoint")
    parser.add_argument("--chain-id", type=int, required=True)
    parser.add_argument("--artifact", type=Path, default=Path("out/InkRenderer.sol/InkRenderer.json"))
    parser.add_argument("--chunk-size", type=int, default=MAX_CHUNK)
    parser.add_argument("--restart", action="store_true", help="Explicitly plan replacing an unlocked upload")
    args = parser.parse_args()
    if int(cast("chain-id", "--rpc-url", args.rpc_url)) != args.chain_id:
        raise ValueError("RPC chain ID differs from the operator-supplied chain ID")
    block = int(cast("block-number", "--rpc-url", args.rpc_url))
    options = ["--rpc-url", args.rpc_url, "--block", str(block)]
    runtime = cast("code", args.renderer, *options)
    artifact = json.loads(args.artifact.read_text())
    expected_runtime = artifact["deployedBytecode"]["object"]
    if runtime.lower().removeprefix("0x") != expected_runtime.lower().removeprefix("0x"):
        raise ValueError("Renderer runtime differs from the locally compiled pinned artifact")

    def call(signature, *values):
        return cast("call", args.renderer, signature, *values, *options).split()[0]

    if address(call("owner()(address)")) != args.owner:
        raise ValueError("Renderer owner differs from the operator-supplied owner")
    state = {name: int(call(name + "()(uint256)")) for name in
             ("uploadVersion", "uploadedBytes", "expectedBytes", "chunkCount")}
    state["expectedHash"] = call("expectedHash()(bytes32)")
    state["scriptLocked"] = call("scriptLocked()(bool)") == "true"
    chunks = [bytes.fromhex(call("chunk(uint256)(bytes)", i)[2:]) for i in range(state["chunkCount"])]
    plan = verify_and_plan(args.script.read_bytes(), state, chunks, args.chunk_size, args.restart)
    plan.update({"buildOnly": True, "chainId": args.chain_id, "snapshotBlock": block,
                 "renderer": args.renderer, "owner": args.owner, "runtimeKeccak256": cast("keccak", runtime)})
    for tx in plan["transactions"]:
        tx.update({"to": args.renderer, "value": "0"})
    if plan["separateLockCandidate"]:
        plan["separateLockCandidate"].update({"to": args.renderer, "value": "0"})
    print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    main()
