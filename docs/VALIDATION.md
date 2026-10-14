# Local validation record

Executed on 2026-10-14 with Foundry 1.8.3 (`cae51ad458f6abb64852b7709eb784352429825d`) and Solidity 0.8.26. Configuration: Cancun, optimizer 200, via-IR, bytecode hash none. These are contributor checks, not independent certification or a security audit.

## Final commands and results

| Check | Result |
|---|---|
| `forge build` | Passed with the pinned compiler. Compiler/linter warnings are discussed below. |
| `FOUNDRY_FUZZ_SEED=0x93045c93491d04879e85ced5397ffacfe0ff4bd7bd4fa9d4640c2f581586ad12 forge test` | **61 passed, 0 failed, 0 skipped**, seven suites. |
| Same seed, `forge test --isolate -vv` | **61 passed, 0 failed, 0 skipped**, including cold-call renderer size checks. |
| `forge fmt --check` | Passed. |
| `python3 -m unittest discover -s tools -p 'test_*.py' -v` | **10 passed**; no RPC or transactions. |
| `python3 tools/export_abis.py` and artifact comparison | All five delivered ABIs equal the compiled artifacts. |
| Constructor reference versus compiled ABI | All five names, argument names, types and order match; maximum ten constructor arguments. |
| Synthetic snapshot regeneration and comparison | Complete synthetic tree and every proof reproduce exactly. |
| Bytecode inspection | All five runtimes are below 24,576 bytes; no linked-library placeholders. |

Four fuzz tests (including the two currency-order variants) each ran 256 cases with the required seed. The invariant runner reports three assertions together as one aggregate test: 64 runs, depth 64, **4,096 handler calls, zero reverts**. Calls cover pulls, reveals, expiries, NFT transfers/returns, bonus funding and unsolicited token donations.

| Application contract | Runtime bytes |
|---|---:|
| InkPortraits | 6,050 |
| InkVault | 8,600 |
| InkLiquidity | 7,819 |
| InkHook | 5,359 |
| InkRenderer | 7,257 |

## Behavior exercised

- Portrait identity, fixed inputs/seeds, combined 2,000 mint limit, duplicate mint rejection, vault-only minting, transfers and agent-holder counts, royalty receiver, two-step ownership and irreversible renderer selection.
- Current seat ownership after a transfer, inactive-seat claims, exact double-hashed StandardMerkleTree encoding, duplicate/invalid claims, start/end boundaries, one-time funding, frozen configuration, wrong-decimal/taxed-token rejection.
- Release failure rollback, reentry attempt during release, permissionless release, zero vault-to-liquidity allowance, full 2,000 pending reservation capacity, next-block timing, last available hash and first expired block, refunds and duplicate consumption rejection.
- Swarm/agent returns, fee and bonus bounds, empty/limited bonus pot, backing conservation, inventory reuse/custody, unsolicited NFT rejection, NFT receiver rejection and reentry, transfer-dependent discounts.
- Actual pinned PoolManager, PositionManager and Universal Router, with actual CREATE2 hook permission bits, in **both INK currency orderings**. Exact input/output buys/sells, fee recipients and magnitudes, exemption transfers, callback/pool/router authentication, ignored forged hookData, settlement to zero transient deltas, min-output/max-input and payment failure rollback.
- Locked trading, seven-day fallback, first-swap clock, cumulative buy cap including exempt wallets, one-hour boundary, sells not reducing purchases, router subplan initiator preservation and recipient distinction.
- Actual single-sided release positions, guarded initialization and tick validity, stale-price release rollback and range repair, permanent position custody, rejected approval/permit/collection/decrease/burn attempts.
- Upload size/index/version/hash checks, partial resumption, corruption rejection, stale begin/lock transactions, independent script/preview locks and MIME-bound preview hashes, pending metadata, raw-input round trips and closing-script transport boundaries.
- Maximum 131,072-byte script plus 32,768-byte synthetic preview: metadata read **45,655,466 gas**; maximum script lock **9,304,917 gas**. Restarting a maximum upload stays below the test's 150,000-gas bound by selecting a new namespace. These bounds do not establish compatibility with any particular production RPC, transaction limit or marketplace.

The Python tests cover sorted tree/proof construction, invalid/incomplete snapshots, upload prefixes, exact completion, locked state, explicit restarts, chunk bounds and the maximum-size hashing regression. The planner's production RPC/runtime/owner checks have not been exercised against a deployed renderer; no upload was executed.

## Separate automated review

A separate agent reviewed the five application contracts, integration tests, router authentication and fee settlement, PositionManager custody, upload tooling and documentation. This is a second automated review, **not an independent human audit**.

The reviewer reproduced a process-argument limit failure when hashing large scripts. Hashing now passes bytes through stdin; the reviewer independently retested 65,535- and 131,072-byte inputs successfully. It also identified unbounded tiny-chunk counts/restart cost by inspection; the final implementation caps chunks at 64 and restarts with a fresh storage namespace. Maximum-size tests exposed excessive layered-encoding cost; HTML transport was revised and the final maximum script plus preview read passes the recorded bound.

Three additional adversarial review tests passed and were promoted from disposable scratch space into the permanent v4 suite, in both currency orderings: nested router plans with a different recipient, attempted position approvals/permits, and attempted LP collection/decrease/burn. The reviewer reported no remaining concrete accounting, settlement, authentication or custody defect in its reviewed paths; this is a bounded review result, not proof of absence.

For the revised HTML transport, the reviewer independently checked six synthetic constructions using Node's WHATWG URL parser and `fetch`, including Base64 `+`, `/`, padding, closing-script text, Unicode, every byte value and maximum-size content. Original script bytes survived decoding. This tested transport construction, not browser execution, original art, or marketplace compatibility.

## Warnings and limitations

The build is not warning-free, and no analyzer detector was suppressed. Foundry lint reports timestamp use, guarded external-call/event ordering, numeric casts, exact incoming-balance equality, JSON concatenation with `abi.encodePacked`, modifier order and test timestamp reads around `vm.warp`.

- Time windows intentionally use timestamps. Their boundary behavior is tested; validator timing influence remains documented.
- Vault/liquidity mutations use ReentrancyGuard, with entry state set before interactions and one-shot/reservation effects before transfers. The guard resets after the body. `onlyOwner` preceding the guard performs a local ownership check without an external call. Post-call checks/events are inside the guarded operation. Renderer encoding helpers are internal and make no external callbacks.
- Liquidity amounts are bounded to 800m INK before uint128 conversion; action constants fit uint8. The hook converts positive int128 INK output and charges only 25 bps of an int128 magnitude. Packed Slot0 extraction intentionally keeps its low 160 price bits.
- Exact incoming-balance equality rejects unsupported transfer-tax behavior; unsolicited donations before the operation do not invalidate it. JSON concatenation is not used as a hash preimage or authorization encoding.
- Timing tests passed in both normal and isolated execution with the pinned compiler. The lint's test-helper timestamp warning is not represented as production timestamp immutability.

The previous arbitrary-from ERC20 path is absent: liquidity never calls transferFrom, and the vault pushes funds before an atomic addition. The required next-block hash remains a weak randomness mechanism; its bias, selective expiry and inventory-order manipulation are an explicit **production fairness blocker**, not concealed by tests.

Slither, Mythril, formal verification, a mainnet fork, deployed address verification, Permit2 signature flows, wallet/marketplace rendering and a human security audit were **not run**. No production transaction, artwork upload, deployment, pool creation, claim opening or lock was performed. Original art, private production snapshot, real deployment inputs and the independent adversarial review requested in [REVIEW_REQUEST.md](REVIEW_REQUEST.md) remain future work. See [SECURITY.md](SECURITY.md) for the full unresolved findings and trust assumptions.
