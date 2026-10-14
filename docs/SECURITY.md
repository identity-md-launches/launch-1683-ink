# Security assumptions and unresolved findings

**Build-only; not audited or approved for production.** The pinned security/address references supplied with the assignment were read. The implementation and local checks are this contributor's work. A separate automated second-agent review was completed during this build; its bounded result is recorded in [VALIDATION.md](VALIDATION.md). No independent human security audit is claimed. Independent adversarial review is requested in [REVIEW_REQUEST.md](REVIEW_REQUEST.md) before any deployment, funding, original-art lock, or opening of claims.

## Accounting invariants

Let `P = 400000 * 10^18`, `C = circulating`, `R = pendingCount`, `B = bonusPot`, `A = claimedCount`, `I = inventoryCount` and `S = portraits.totalSupply()`.

- `S = C + I`, `S <= 2000`, `C + R <= 2000`.
- Before release, claim reserve is `(2000 - A) * P`; after release it is zero.
- Vault liabilities are `claimReserve + (C + R) * P + B`.
- For the supported plain-transfer token, vault INK balance is at least liabilities. With no unsolicited donations it is exactly liabilities. Donation surplus cannot enter bonuses or be withdrawn.
- Every inventory entry is unique, belongs to the vault and carries no active backing liability until drawn again. Direct unsolicited transfers to the vault are rejected by the portrait contract. The only inventory removal is a successful reveal.
- A pull increments `R` and transfers P atomically. Reveal decrements `R` and increments `C`; expiry decrements `R` and refunds exactly P. A request can be consumed once. A rejected receiver rolls back the reveal, and expiry remains available.
- A swarm return decreases `C`, increases `B` by its fee and pays `P - fee`. An agent return decreases `C`, decreases `B` by at most its current balance and pays `P + bonus`. Thus bonuses never spend backing.
- Release can only remove claim reserves. Vault state, the push transfer, and the liquidity addition share one atomic transaction. No ERC20 allowance or transferFrom authorization exists from vault to liquidity.

The stateful invariant suite checks solvency, donation isolation, custody, uniqueness, capacity and agent balances across requests, reveals, expiries, returns, transfers and bonus funding. It exercises the configured seed and finite run/depth, not every possible sequence.

## Open production blockers / limitations

| Finding | Concrete behavior / consequence | Required future action |
|---|---|---|
| **Blockhash draw is manipulable** | The brief explicitly requires next-block hash. Block producers can bias it; a buyer can wait for a result, arrange/return inventory before revelation, withhold an unfavorable reveal, and receive a full expiry refund. Inventory order/contents also depend on transaction ordering. Modulo has a small mathematical bias. This is unsuitable for a promise of fair or verifiable valuable randomness. | Production fairness is blocked pending an explicit review of this requested mechanism. A verifiable randomness redesign would change the stated mechanism and has not been silently substituted. Never advertise this as VRF or MEV-proof. |
| **Original algorithm absent** | The renderer transports supplied bytes and raw inputs, but there is no supplied generative algorithm, mapping of traits or original preview. Metadata explicitly says integration is pending. | Obtain the original work, verify originality/rights and deterministic trait fidelity, review the browser code, then authorize any uploads/locks separately. |
| **Private production snapshot absent** | Synthetic roots prove mechanics only. A malicious/incomplete production root can exclude a legitimate current seat owner or misstate fixed statistics. Onchain proof verification cannot certify the source data. | Independently audit all 2000 rows, including inactive seats, and the exact StandardMerkleTree encoding before funding. |
| **Production contracts and economics parameters unresolved** | No production owner, treasury, seat/token addresses, verified chain manager/router addresses, initial price, fee/spacing or ticks were supplied. Constructor reference contains symbolic parameters; no guessed operational address is present. | Resolve and verify them for the future launch. The hook is immutable; a wrong address or router cannot be fixed after deployment. |
| **Router scope is narrower than arbitrary routing** | Only one pinned, directly invoked Universal Router execution context is authenticated. Aggregator end-users, arbitrary recipients, alternate routers and `tx.origin` identities cannot safely be inferred by this hook. | Review [ROUTER.md](ROUTER.md). Block claims of arbitrary-router/end-beneficiary compatibility; commission additional reviewed authentication if needed. |
| **No independent audit / live integration** | Local success does not prove economic safety or match deployed dependencies. | Independent adversarial review and a separately authorized integration rehearsal are required before launch. |

These blockers are recorded without replacing the prescribed economics or inventing production inputs. They do not prevent compiling/testing this build-only deliverable.

## Economic and operational trust

- Next-block randomness chooses inventory/visual seed only; it does not change the 400,000 INK backing. Nevertheless agent inventory grants a fee waiver and potential bonus, so the selection can have monetary value. Permissionless reveal reduces buyer exclusivity but does not remove producer/censorship/withholding risk. Full refunds preserve funds at the cost of a free timing option.
- Repeated acquisition and return of the same agent NFT can repeatedly collect the available bonus, until the pot is exhausted. There is no one-time-bonus rule in the brief and none was invented. Owner-configured bonus bounds do not make the pot resistant to this behavior. Agent NFTs can be transferred or borrowed to obtain fee waivers. A cap is per address, not per human.
- Claim reserve covers exactly 2000 seats. Expired unclaimed-seat reserve goes to permanent liquidity, but unused portrait capacity remains available for newly funded swarm pulls. This does not mint a free swarm allocation or double count backing.
- The owner chooses external assets, fixed root/start, renderer, initial price and release range before their respective freeze points. The owner can change fee rates immediately within the specified bounds and can withhold configuration/funding or decline to repair a stale range. There is no admin backing withdrawal, emergency escape, post-funding asset/root replacement or hook owner.
- INK must remain a plain-transfer, non-rebasing 18-decimal token. Incoming balance differences reject taxed funding/pulls; this does not make arbitrary upgradeable, blocklisting, malicious or future-taxed tokens supported. A frozen/blocklisted external token can prevent payouts. The actual identity.md contract must honestly expose current ERC721 ownership.
- PoolManager, PositionManager and the immutable router must be the verified official compatible implementations. A contract merely reporting the correct interface/getters is not sufficient. Configuration is an owner responsibility. No production chain address was verified in this build-only assignment.
- The release range is compared to spot price solely to establish one-sided deposit validity, not as a valuation oracle. After the seven-day trading fallback, swaps can move price across the range and delay release; the owner can repair ticks before release. Before that fallback, swaps are locked until release. Rounding dust stays permanently in liquidity custody, as do LP fees. No fee-collection permission exists for the owner.
- The configured royalty receiver is the original explicit owner. Royalties are ERC2981 signals, not enforced marketplace payments. Ownership handover does not move royalty proceeds. Transfers correctly update live agent balances, including vault custody.
- Timestamps define 24-hour, seven-day and one-hour boundaries. Normal block timestamp variation can move actions at these boundaries. Reveal eligibility uses block numbers and the EVM's 256-block hash availability window, not elapsed seconds.
- Original JavaScript is intentionally executable, owner-supplied content. Base64 transport prevents an embedded closing-script sequence from corrupting the HTML wrapper; CSP is a restriction, not a guarantee that arbitrary original code is safe. Viewers should use isolated/sandboxed rendering. The content/preview locks and renderer-selection lock are separate and irreversible. Locking unreviewed bytes can make a mistake permanent.

## Previous-attempt findings addressed or retained explicitly

- **arbitrary-send-erc20 in liquidity:** eliminated structurally. `InkLiquidity` contains no `transferFrom` and receives no vault allowance. Only the configured vault may invoke the one-shot addition after pushing its own funds. The PositionManager is prefunded and settles from its own balance.
- **weak-prng:** the requested blockhash mechanism remains deliberately visible and is a documented production fairness blocker, not suppressed or disguised.
- **release/addition reentrancy:** vault and liquidity entrypoints use OpenZeppelin ReentrancyGuard; reserves/reservations and one-shot flags are set before transfers. Tests attempt reentry through liquidity and NFT receivers. Uniswap callbacks are authenticated by the manager and complete all transient settlement or revert. Post-call liquidity result/dust accounting is under the guard.
- **uninitialized fee/bonus:** both locals explicitly initialize to zero.
- **unused initialize return:** returned initialization tick is recorded in the event. Liquidity reads the packed sqrt price using the pinned official StateLibrary pool-slot constant; no ignored Slot0 tuple is used.
- **events/timestamps:** events surrounding interactions may be reported by broad static heuristics. The guarded vault/liquidity paths and explicit timing boundaries are covered locally; such reports are not evidence of an independent audit.

The project does not suppress analyzer detectors. Review any new report against the actual bounded paths and trust assumptions. Slither and Mythril were not present on this worker and were not run; Foundry compiler/lint output and the listed tests are the checks actually performed.
