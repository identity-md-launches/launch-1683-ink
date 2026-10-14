// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {InkPortraits} from "./InkPortraits.sol";
import {IInkRelease, IRouterIdentity} from "./interfaces/IInk.sol";

/// @notice Immutable hook for one pool and one verified Universal Router deployment.
contract InkHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    uint256 public constant FEE_BPS = 25;
    uint256 public constant BUY_CAP = 1200000 ether;
    // Required sink from the brief, not a placeholder for an operational address.
    address public constant INK_SINK = 0x000000000000000000000000000000000000dEaD;
    InkPortraits public immutable portraits;
    IInkRelease public immutable vault;
    address public immutable liquidity;
    address public immutable ink;
    address public immutable imd;
    address public immutable treasury;
    address public immutable router;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    PoolId public immutable poolId;
    uint256 public initializedAt;
    bool public initialized;
    uint256 public firstSwapAt;
    bool public tradingStarted;
    mapping(address => uint256) public bought;

    error InvalidConfiguration();
    error WrongPool();
    error OnlyInitializer();
    error UnsupportedRouter();
    error SwapsLocked();
    error BuyCapExceeded();
    event PoolInitialized(uint256 timestamp, int24 tick);
    event TradingStarted(uint256 timestamp);
    event HookFee(
        address indexed trader, address indexed currency, address indexed recipient, uint256 amount
    );
    event BuyRecorded(address indexed trader, uint256 grossInk, uint256 cumulative);

    constructor(
        IPoolManager manager_,
        InkPortraits portraits_,
        IInkRelease vault_,
        address liquidity_,
        address ink_,
        address imd_,
        address treasury_,
        address router_,
        uint24 fee_,
        int24 spacing_
    ) BaseHook(manager_) {
        if (
            address(manager_) == address(0) || address(portraits_) == address(0)
                || address(vault_) == address(0) || liquidity_ == address(0) || ink_ == address(0)
                || imd_ == address(0) || ink_ == imd_ || treasury_ == address(0) || treasury_ == INK_SINK
                || router_ == address(0) || fee_ > 1000000 || spacing_ <= 0 || spacing_ > 32767
        ) revert InvalidConfiguration();
        portraits = portraits_;
        vault = vault_;
        liquidity = liquidity_;
        ink = ink_;
        imd = imd_;
        treasury = treasury_;
        router = router_;
        poolFee = fee_;
        tickSpacing = spacing_;
        poolId = PoolKey(
                Currency.wrap(ink_ < imd_ ? ink_ : imd_),
                Currency.wrap(ink_ < imd_ ? imd_ : ink_),
                fee_,
                spacing_,
                IHooks(address(this))
            )
            .toId();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function key() external view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(ink < imd ? ink : imd),
            Currency.wrap(ink < imd ? imd : ink),
            poolFee,
            tickSpacing,
            IHooks(address(this))
        );
    }

    function _checkPool(PoolKey calldata key_) private view {
        if (PoolId.unwrap(key_.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _beforeInitialize(address sender, PoolKey calldata key_, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        _checkPool(key_);
        if (sender != liquidity || initialized) revert OnlyInitializer();
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address sender, PoolKey calldata key_, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        _checkPool(key_);
        if (sender != liquidity || initialized) revert OnlyInitializer();
        initialized = true;
        initializedAt = block.timestamp;
        emit PoolInitialized(block.timestamp, tick);
        return IHooks.afterInitialize.selector;
    }

    function _trader(address sender) private view returns (address trader) {
        if (sender != router) revert UnsupportedRouter();
        trader = IRouterIdentity(router).msgSender();
        if (trader == address(0) || trader == router) revert UnsupportedRouter();
    }

    function _beforeSwap(address sender, PoolKey calldata key_, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key_);
        _trader(sender);
        if (!initialized || (!vault.released() && block.timestamp < initializedAt + 7 days)) {
            revert SwapsLocked();
        }
        if (!tradingStarted) {
            tradingStarted = true;
            firstSwapAt = block.timestamp;
            emit TradingStarted(block.timestamp);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key_,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _checkPool(key_);
        address trader = _trader(sender);
        int128 inkDelta = ink < imd ? delta.amount0() : delta.amount1();
        if (inkDelta > 0 && block.timestamp < firstSwapAt + 1 hours) {
            uint256 gross = uint256(uint128(inkDelta));
            uint256 cumulative = bought[trader] + gross;
            if (cumulative > BUY_CAP) revert BuyCapExceeded();
            bought[trader] = cumulative;
            emit BuyRecorded(trader, gross, cumulative);
        }
        if (portraits.agentBalance(trader) != 0) return (IHooks.afterSwap.selector, 0);
        // v4 afterSwap deltas charge the unspecified currency: output on exact-in, input on exact-out.
        bool unspecifiedIs1 = (params.amountSpecified < 0) == params.zeroForOne;
        int256 unspecified = unspecifiedIs1 ? int256(delta.amount1()) : int256(delta.amount0());
        uint256 magnitude = uint256(unspecified < 0 ? -unspecified : unspecified);
        uint256 fee = magnitude * FEE_BPS / 10000;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        Currency currency = unspecifiedIs1 ? key_.currency1 : key_.currency0;
        address recipient = Currency.unwrap(currency) == ink ? INK_SINK : treasury;
        emit HookFee(trader, Currency.unwrap(currency), recipient, fee);
        poolManager.take(currency, recipient, fee);
        // Magnitude originates from an int128; a 25 bps fraction always fits positive int128.
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }
}
