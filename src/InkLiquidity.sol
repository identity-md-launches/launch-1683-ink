// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {InkHook} from "./InkHook.sol";

/// @notice Holds PositionManager NFTs forever. No approvals, transfers, collection, or arbitrary calls.
contract InkLiquidity is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address public ink;
    address public imd;
    address public vault;
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    PoolKey private _key;
    bool public ready;
    bool public releaseAdded;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public positionId;
    uint256 public totalReleased;
    uint256 public lockedDust;

    error InvalidConfiguration();
    error NotConfigured();
    error OnlyVault();
    error InvalidRange();
    error AlreadyAdded();
    error WrongFunding();
    error PositionMismatch();
    event Configured(
        address indexed ink, address indexed imd, address indexed vault, address manager, address positions
    );
    event Initialized(address indexed hook, uint160 sqrtPriceX96, int24 tick);
    event RangeSet(int24 lower, int24 upper);
    event LiquidityLocked(uint256 indexed positionId, uint256 amount, uint128 liquidity, uint256 dust);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function configure(
        address ink_,
        address imd_,
        address vault_,
        IPoolManager manager_,
        IPositionManager positions_
    ) external onlyOwner {
        if (
            ready || ink_ == address(0) || imd_ == address(0) || ink_ == imd_ || vault_ == address(0)
                || address(manager_) == address(0) || address(positions_) == address(0)
        ) revert InvalidConfiguration();
        if (IERC20Metadata(ink_).decimals() != 18 || address(positions_.poolManager()) != address(manager_)) {
            revert InvalidConfiguration();
        }
        ink = ink_;
        imd = imd_;
        vault = vault_;
        poolManager = manager_;
        positionManager = positions_;
        emit Configured(ink_, imd_, vault_, address(manager_), address(positions_));
    }

    function initializePool(InkHook hook, uint160 sqrtPriceX96, int24 lower, int24 upper)
        external
        onlyOwner
        nonReentrant
    {
        if (ink == address(0)) revert NotConfigured();
        if (
            ready || address(hook.poolManager()) != address(poolManager) || hook.ink() != ink
                || hook.imd() != imd || hook.liquidity() != address(this) || address(hook.vault()) != vault
        ) revert InvalidConfiguration();
        _key = hook.key();
        _validateRange(sqrtPriceX96, lower, upper);
        ready = true;
        tickLower = lower;
        tickUpper = upper;
        emit RangeSet(lower, upper);
        int24 tick = poolManager.initialize(_key, sqrtPriceX96);
        emit Initialized(address(hook), sqrtPriceX96, tick);
    }

    /// @notice Allows correcting a stale range if the seven-day swap fallback moved the price before release.
    function setReleaseRange(int24 lower, int24 upper) external onlyOwner {
        if (!ready) revert NotConfigured();
        if (releaseAdded) revert AlreadyAdded();
        uint160 price = _price();
        _validateRange(price, lower, upper);
        tickLower = lower;
        tickUpper = upper;
        emit RangeSet(lower, upper);
    }

    function key() external view returns (PoolKey memory) {
        return _key;
    }

    function addReleased(uint256 amount) external nonReentrant {
        if (msg.sender != vault) revert OnlyVault();
        if (!ready) revert NotConfigured();
        if (releaseAdded) revert AlreadyAdded();
        if (amount == 0 || amount > 800000000 ether || IERC20(ink).balanceOf(address(this)) < amount) {
            revert WrongFunding();
        }
        uint160 price = _price();
        _validateRange(price, tickLower, tickUpper);
        bool inkIs0 = ink < imd;
        uint128 units = LiquidityAmounts.getLiquidityForAmounts(
            price,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            inkIs0 ? amount : 0,
            inkIs0 ? 0 : amount
        );
        if (units == 0) revert InvalidRange();
        uint256 id = positionManager.nextTokenId();
        releaseAdded = true;
        totalReleased = amount;
        positionId = id;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            _key,
            tickLower,
            tickUpper,
            uint256(units),
            uint128(inkIs0 ? amount : 0),
            uint128(inkIs0 ? 0 : amount),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(Currency.wrap(ink), uint256(0), false);
        params[2] = abi.encode(Currency.wrap(ink), address(this));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SWEEP));
        // The official PositionManager settles its own prefunded balance. No transferFrom or standing allowance.
        IERC20(ink).safeTransfer(address(positionManager), amount);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        if (
            IERC721(address(positionManager)).ownerOf(id) != address(this)
                || positionManager.getPositionLiquidity(id) != units
        ) revert PositionMismatch();
        uint256 dust = IERC20(ink).balanceOf(address(this));
        // Rounding residue and unsolicited donations have no withdrawal path.
        lockedDust = dust;
        emit LiquidityLocked(id, amount, units, dust);
    }

    function _price() private view returns (uint160 price) {
        // Read only sqrtPriceX96 from the packed Slot0; no unused return tuple.
        bytes32 slot = keccak256(abi.encodePacked(_key.toId(), StateLibrary.POOLS_SLOT));
        price = uint160(uint256(poolManager.extsload(slot)));
    }

    function _validateRange(uint160 price, int24 lower, int24 upper) private view {
        if (
            lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower >= upper
                || lower % _key.tickSpacing != 0 || upper % _key.tickSpacing != 0
        ) revert InvalidRange();
        if (ink < imd) {
            if (price >= TickMath.getSqrtPriceAtTick(lower)) revert InvalidRange();
        } else {
            if (price <= TickMath.getSqrtPriceAtTick(upper)) revert InvalidRange();
        }
    }
}
