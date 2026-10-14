# Vendored dependencies

All dependencies are ordinary source files; there are no submodules, package downloads at build time, or compiler binaries in this repository. Exact upstream commits are in `dependencies.json`. Only Solidity source and license files from upstream archives were copied. No dependency implementation was patched. Files not in the import graph (such as legacy v2/v3 implementations and Permit2 0.8.17 implementation) are not compiled by this pinned 0.8.26 project; their compatible interfaces are used where required.

| Directory | Pin / purpose | License location |
|---|---|---|
| `lib/openzeppelin-contracts` | OpenZeppelin 5.1.0; ERC721/ERC2981, ownership, reentrancy, Merkle proofs, ERC20 operations, encoding | `lib/openzeppelin-contracts/LICENSE` |
| `lib/v4-core` | Exact core subdependency pinned by the selected v4 periphery commit; official managers/types/math | `lib/v4-core/licenses/` and per-file SPDX |
| `lib/v4-periphery` | Exact periphery subdependency of Universal Router 2.0.0; official PositionManager and BaseHook | `lib/v4-periphery/LICENSE` and per-file SPDX |
| `lib/universal-router` | Universal Router 2.0.0 tag resolved to commit; actual router integration tests | `lib/universal-router/LICENSE` |
| `lib/permit2` | Exact Universal Router subdependency; interfaces and signature helpers. Test allowance adapter is clearly labeled in `test/mocks/` | `lib/permit2/LICENSE` |
| `lib/solmate` | Exact Universal Router subdependency; Uniswap dependencies | `lib/solmate/LICENSE` |
| `lib/v3-periphery` | Exact Universal Router subdependency; compatibility interfaces | `lib/v3-periphery/LICENSE` |
| `lib/v3-core` | v1.0.0 tag; compatible interfaces/math required by router | `lib/v3-core/LICENSE` |
| `lib/v2-core` | 816075049f811f1b061bca81d5d040b96f4c07eb; compatible pair interface required by router | `lib/v2-core/LICENSE` |
| `lib/forge-std` | 1.9.4; test framework | `lib/forge-std/LICENSE-MIT`, `LICENSE-APACHE` |

Application-owned files carry their own SPDX identifiers. Third-party files retain upstream copyright and licensing, including Uniswap's per-file licenses; no relicensing of third-party code is implied.
