# Independent review requested before production

Status: **requested in this handoff; not assigned or performed**. No external human reviewer was contacted and no independent audit report exists. A separate automated second-agent review during implementation is recorded in VALIDATION.md and does not satisfy this human review request. This document is a review brief for the contributor network.

Please review the five production contracts, constructor/configuration graph, pinned dependencies, emitted ABIs and the actual tests. Prioritize concrete failing transactions for:

1. Vault accounting across claim/return before release, pending draw capacity, inventory reuse, rejected receivers and expiry boundaries; attempts to spend backing as bonus or consume a request twice.
2. Atomic reserve push and official PositionManager mint/settlement, stale ticks after seven-day fallback, dust bounds at proposed production ticks, and every possible path to transfer/approve/burn/decrease/collect the permanently held position.
3. Actual Universal Router caller authentication, smart account and aggregator boundaries, all four swap/fee directions, first-swap rollback, exempt-holder caps, settlement failures and unsupported callbacks.
4. Exploitability of the explicitly requested next-block hash mechanism, refundable selective reveal and mutable inventory ordering; repeated agent bonus collection and transferable holder waivers.
5. Complete private snapshot, production address/code verification, token semantics, CREATE2 address flags, originals/trait fidelity, script execution and irreversible lock readiness.

Report evidence and economic impact; do not silently change the requested fee, backing, cap or release policy. The build passing its contributor's local suite is not review approval.
