# Ink & Inference

A new, build-only Foundry project with five application contracts. No production token, deployment, pool creation, funding, claims, uploads, or irreversible locks were executed. Source is prepared for publication by the swarm; this checkout does not publish a GitHub repository.

**Art and trait integration is pending.** The original JavaScript and private production seat snapshot have not been supplied. Fixtures contain synthetic statistics and transport-test JavaScript only. No generated artwork or substitute trait algorithm is included.

## Build and check offline

Prerequisites: Foundry with Solidity **0.8.26** installed, and Python 3 for optional tooling checks. All Solidity dependencies are ordinary vendored source files in `lib/`; no submodules, package installation, FFI, RPC, filesystem cheatcodes, environment variables, or external services are needed by the Solidity tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x93045c93491d04879e85ced5397ffacfe0ff4bd7bd4fa9d4640c2f581586ad12 forge test
forge fmt --check
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

The same fuzz seed is pinned in `foundry.toml`. Cancun, optimizer 200, via-IR, and `bytecode_hash = "none"` are pinned. Mocks are under `test/`, reject construction on chain ID 1, and are never launch assets. The suite uses local copies of the official Uniswap v4 PoolManager, PositionManager and Universal Router. Permit2's allowance interface is mocked; signature-based Permit2 behavior is outside these tests.

[Validation](docs/VALIDATION.md) records executed checks. [Security assumptions and unresolved findings](docs/SECURITY.md) must be reviewed before any separate launch.

## Contracts

| Contract | Behavior |
|---|---|
| `InkPortraits` | ERC721 `Ink & Inference` / `INKINF`; at most 2,000 combined portraits. Agent IDs 0–1999 equal seat IDs, swarm IDs start at 10000. Only its one-time configured vault mints. Fixed inputs and swarm seeds never change. Agent balances track every transfer. ERC2981 pays 5% to the explicit constructor owner; this original royalty receiver does not follow later ownership transfers. |
| `InkVault` | One funded snapshot and 24-hour current-seat-owner claim period; 400,000 external INK per portrait. Atomic unclaimed reserve release, reserved asynchronous swarm pulls, expiry refunds, NFT returns, inventory reuse, and segregated bonus accounting. No backing or surplus withdrawal. |
| `InkLiquidity` | Owner guards initialization and release ticks using official v4 managers. Vault pushes released INK, then this contract mints a strictly out-of-range, INK-only PositionManager NFT to itself. The NFT, fees and rounding dust have no withdrawal, collection, approval, permit-signing, or transfer path. |
| `InkHook` | Ownerless, immutable configuration for exactly one INK/IMD pool and one verified router. Adds 25 bps on v4's unspecified currency, waived for current agent-portrait holders. INK fees go to the specified dead sink; IMD fees go to the immutable treasury. Enforces opening time and cumulative buys. |
| `InkRenderer` | Owner-supplied script chunks, expected-hash verification, versioned resumption, onchain JSON and HTML, raw fixed inputs, and independent permanent script/preview locks. Portrait renderer-selection lock is separate. |

All owned contracts use explicit constructor owners and two-step ownership transfer. They are not proxies. Ownership includes `renounceOwnership`; renouncing before setup/locks are complete can permanently prevent those operations.

## Vault lifecycle and economics

1. Configure external INK (18 decimals, plain transfers only), the real seat ERC721 and vault mint authority. Complete the liquidity configuration and guarded pool initialization in the **separate future launch**.
2. Owner approves **800,000,000 INK** and calls `fund(root, claimStart, liquidity)`. This pulls from **the caller**, checks the exact received amount, and freezes assets, snapshot, claim start and liquidity recipient. Start must be at or after the funding transaction's timestamp. The other 200 million INK is outside this vault.
3. For `claimStart <= timestamp < claimStart + 24 hours`, a seat's **current ERC721 owner** claims once. Snapshot statistics need not represent activity: inactive and outdated seats remain eligible. No snapshot owner or allowlist of active seats is used. The 2000-seat root must include inactive seats as well.
4. At/after the end, anyone calls `release()`. `(2000 - claimedCount) * 400000 INK` is pushed into `InkLiquidity`, which must successfully add its permanent position in the same transaction. A failed transfer, invalid range, or manager failure rolls back the entire release, including the `released` flag. Zero unclaimed seats require no liquidity transaction. Other vault operations cannot reenter while release is executing.
5. Swarm pulls begin after release. `pull()` transfers exactly 400,000 INK, reserves one available slot, and commits the caller as buyer. If committed in block `n`, entropy is `blockhash(n+1)`. Anyone may reveal to the fixed buyer in blocks `n+2` through `n+257`, inclusive. From `n+258`, anyone may expire it, fully refunding the buyer and releasing the reservation. A rejected safe NFT delivery can be retried or refunded after expiry. No early cancellation or refund to a caller-selected recipient exists.
6. Reveal chooses an index by applying modulo to the blockhash-derived seed against current returned inventory when nonempty; otherwise it mints within unused capacity. This is manipulable and has modulo bias; it is not verifiable randomness. Inventory may contain agent or swarm NFTs. Reused NFTs retain their original inputs/seed. The total historical mint count never exceeds 2000; returned NFTs are never burned.
7. The current portrait owner, with vault approval, calls `returnPortrait(id)`. Returning a swarm portrait pays backing minus 1%, or minus 0.5% if the owner currently holds an agent portrait. These **NFT deposit fees** fund the bonus pot; the initial INK pull has no additional fee. Returning an agent pays backing plus `min(bonusPot, backing * 5%)`. Owner limits are base fee ≤5%, agent fee ≤base, bonus ≤10%. Rate changes are immediate. `fundBonus` adds an exact voluntary donation to the pot. Unsolicited token donations are segregated surplus with no withdrawal path.

Blockhash entropy and repeated agent bonuses have material economic limitations; see [SECURITY.md](docs/SECURITY.md). No verifiable-randomness claim is made.

## Snapshot format

The exact leaf is:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(
    seat, accepted, rateBps, turns, hoursTenths, outdated
))))
```

StandardMerkleTree types are `uint256,uint32,uint16,uint32,uint32,bool`. Hash pairs are sorted; leaves are sorted by hash. `tools/snapshot.py` outputs a `standard-v1` tree and proofs. Production mode requires each of the 2000 seat IDs exactly once. Values are fixed raw inputs, not inferred traits; rate is 0–10000 basis points. Ownership is checked onchain at claim time, not encoded in the leaf.

```sh
# Reproduce only the included synthetic fixture; this is NOT a production snapshot.
python3 tools/snapshot.py test/fixtures/synthetic-stats.json test/fixtures/synthetic-tree.json --synthetic
```

The production snapshot remains a future private input. Audit the complete source data, ABI types, tree and root before funding. Funding does not prove completeness or truth of the owner-supplied root.

## After launch — configuration responsibilities

This describes a future, separately authorized launch, not actions performed here. [Constructor reference](docs/constructors.json) uses symbolic parameters instead of invented addresses. [Setup order](docs/SETUP.md) covers CREATE2 dependencies and read checks. [ABIs](abi/) are exported from the pinned compiler.

| Setting | Owner operation | Value and source |
|---|---|---|
| Portrait vault | `InkPortraits.configureVault` (once) | Deployed `InkVault` for these portraits; verify immutable `portraits()` first. |
| Portrait renderer | `setRenderer`, later `lockRenderer` | Deployed and reviewed `InkRenderer`; selection remains mutable until explicitly locked. |
| External assets | `InkVault.configureAssets` (until funded) | Future external INK and actual identity.md seat ERC721 from the requester; verify bytecode, 18 decimals and token semantics. No production addresses are supplied here. |
| Liquidity dependencies | `InkLiquidity.configure` (until initialized) | INK, Ethereum IMD, this vault, official Ethereum PoolManager and PositionManager. Verify official chain records and code; verify PositionManager's manager. |
| Pool price/range | `initializePool`, `setReleaseRange` | Approved original price and tick range from the future economics setup; range stays adjustable until a release position is added. |
| Funded setup | `InkVault.fund` (once) | Reviewed complete private snapshot root, future claim timestamp and ready liquidity contract. Owner supplies the entire 800m vault reserve. |
| Vault rates | `setFees` | Defaults 100/50/500 bps; any policy change remains within the specified bounds. |
| Script/preview | `beginUpload`, `appendChunk`, `setPreview`; later `lockScript`, `lockPreview` | Requester's ORIGINAL JavaScript and preview; inspect and verify hashes before locking. |

There is **no address registry in this input** and no chain address is asserted as verified. The hook's immutable manager, INK, IMD, vault, portraits, liquidity, treasury, router, LP fee and tick spacing must all be resolved and independently checked **before its future deployment**. The dead address is exclusively the explicitly required INK fee sink, never a substitute for an unknown owner or treasury.

The 1 billion INK supply and 10% swarm / 10% initial pool / 80% vault allocation describe the future external token economics. This code does not mint that production token, distribute the 10% swarm allocation, fund initial trading liquidity or implement a token launch.
