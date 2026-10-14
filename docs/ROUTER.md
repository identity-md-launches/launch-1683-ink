# Router authentication, fees and deltas

The hook supports the vendored **Uniswap Universal Router 2.0.0** implementation at commit `3663f6db6e2fe121753cd2d899699c2dc75dca86`, configured as one immutable address. This is source compatibility, not verification of any deployed Ethereum address. The production operator must match the selected deployed runtime and dependencies before construction. No address is copied from an unverified table.

The official [`Dispatcher.msgSender()`](https://github.com/Uniswap/universal-router/blob/3663f6db6e2fe121753cd2d899699c2dc75dca86/contracts/base/Dispatcher.sol) reads the active execution locker maintained by [`Lock`](https://github.com/Uniswap/universal-router/blob/3663f6db6e2fe121753cd2d899699c2dc75dca86/contracts/base/Lock.sol). The hook checks `msg.sender == immutable PoolManager` through BaseHook, checks the complete pool ID, checks the swap's `sender == immutable router`, then reads that router's `msgSender()`. Zero and self-router identities revert. Arbitrary hookData is ignored for identity. There is no use of `tx.origin`, user-asserted address, arbitrary router callback, or unscoped signature.

The authenticated wallet is the **initiator of Universal Router.execute**. This supports an EOA or smart account calling that router directly. Subplans preserve the locker in the pinned implementation. If a separate aggregator/relayer calls the router, that contract is the initiator; the hook cannot infer an ultimate human, an offchain payer, or a recipient chosen by a later TAKE command. That broader interpretation is **unsupported**, and aggregators must not advertise end-user-specific caps/waivers without a separately reviewed integration. Other router addresses and direct PoolManager swap callers revert. This immutable router restriction cannot be repaired by an admin after deployment.

The local suites use the actual pinned PoolManager, PositionManager and Universal Router code with real hook-address bits mined through CREATE2. They test actual unlock, swap, take and settle paths. Only ERC20 assets, seats and Permit2's allowance interface are mocked. The test allowance adapter does not simulate signed permits or their security. No mainnet fork, wallet integration or live routing service was used.

## Extra fee denomination

v4's afterSwap return delta is in the **unspecified** currency. This is the received token for exact input and the paid token for exact output. The 25 bps fee is `floor(abs(unspecifiedPoolDelta) * 25 / 10000)`. Exact input subtracts this fee from received output; exact output adds it to required input. The pool's configured LP fee is separate and is not waived.

| Trade | Fee denomination | Recipient |
|---|---|---|
| Buy INK, exact input | INK output | `0x000000000000000000000000000000000000dEaD` |
| Buy INK, exact output | IMD input | Immutable IMD treasury |
| Sell INK, exact input | IMD output | Immutable IMD treasury |
| Sell INK, exact output | INK input | INK dead sink |

The sink transfer does not call a token burn function or reduce total supply; it places INK at the requested dead address. IMD is never sent there by the hook. Agent portrait holders pay no **hook** fee in any of the four modes. There are no special caps or fee exemptions based on hookData. Fee rounding can make microscopic trades pay zero; the same formulas and buy accounting still apply.

The hook calls PoolManager.take to the final recipient, creating its transient debt. Its positive afterSwap delta credits precisely that fee to the hook and debits the router. The official router then settles its actual net input and takes actual net output. Uniswap requires all transient deltas to be zero on unlock completion; tests assert this for both router and hook and assert no hook token custody remains. Max-input/min-output checks include hook fees. Failed slippage checks or ERC20 settlement revert fees, pool state, buy accounting and first-swap timestamp together.

## Opening and buy cap

Swaps are locked until `vault.released()` or `initializedAt + 7 days`, whichever comes first. Pool initialization alone does not start the cap hour. The first permitted successful swap (buy or sell, including a zero-fill swap) starts the global hour. A failed transaction rolls its timestamp back. During `[firstSwapAt, firstSwapAt + 1 hour)`, positive pool INK output accumulates per authenticated initiator, with a limit of **1,200,000 INK**, including fee-exempt wallets. The cap uses gross pool INK output before any INK output hook fee. Sells never decrease cumulative purchases. Exactly at the end of the hour the cap ceases; historical counters remain readable.

This is a per-address, per-pool measure, not Sybil resistance. Alternate addresses, transfers, other pools and repeated borrowing of agent portraits cannot be excluded with the specified primitives. Receiving INK through a third-party recipient does not charge that recipient's counter; the initiating trader is charged. No claim of a global token trading restriction is made.
