// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkHook} from "../src/InkHook.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {AgentInputs, IInkRelease, IInkLiquidity} from "../src/interfaces/IInk.sol";
import {MockINK, MockIMD, MockSeats} from "./mocks/Assets.sol";
import {PermitAllowance} from "./mocks/PermitAllowance.sol";

contract UnsupportedRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function attack(PoolKey memory key, address impersonate) external {
        manager.unlock(abi.encode(key, impersonate));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, address impersonate) = abi.decode(data, (PoolKey, address));
        manager.swap(
            key, SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1), abi.encode(impersonate)
        );
        return "";
    }

    function msgSender() external pure returns (address) {
        return address(1);
    }
}

abstract contract V4IntegrationBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    MockINK internal ink;
    MockIMD internal imd;
    MockSeats internal seats;
    InkPortraits internal portraits;
    InkVault internal vault;
    InkLiquidity internal liquidity;
    InkHook internal hook;
    PoolManager internal manager;
    PositionManager internal positions;
    UniversalRouter internal router;
    PermitAllowance internal permit;
    PoolKey internal poolKey;
    address internal alice = makeAddr("trader alice");
    address internal bob = makeAddr("trader bob");
    address internal treasury = makeAddr("immutable treasury");
    AgentInputs internal inputs = AgentInputs(0, 0, 0, 0, true);
    bool internal ink0;

    function _setup(bool inkIs0) internal {
        vm.warp(100000);
        ink0 = inkIs0;
        ink = new MockINK(address(this));
        for (uint256 i = 0;; ++i) {
            MockIMD candidate = new MockIMD{salt: bytes32(i)}(address(this));
            if ((address(ink) < address(candidate)) == inkIs0) {
                imd = candidate;
                break;
            }
        }
        seats = new MockSeats();
        seats.mint(alice, 0);
        portraits = new InkPortraits(address(this));
        vault = new InkVault(address(this), portraits);
        portraits.configureVault(address(vault));
        liquidity = new InkLiquidity(address(this));
        manager = new PoolManager(address(this));
        permit = new PermitAllowance();
        positions = new PositionManager(
            manager,
            IAllowanceTransfer(address(permit)),
            100000,
            IPositionDescriptor(makeAddr("unused descriptor")),
            IWETH9(makeAddr("unused WETH"))
        );
        RouterParameters memory config;
        config.permit2 = address(permit);
        config.weth9 = makeAddr("unused WETH");
        config.v2Factory = makeAddr("unused v2 factory");
        config.v3Factory = makeAddr("unused v3 factory");
        config.v3NFTPositionManager = makeAddr("unused v3 positions");
        config.v4PoolManager = address(manager);
        config.v4PositionManager = address(positions);
        router = new UniversalRouter(config);
        liquidity.configure(address(ink), address(imd), address(vault), manager, positions);
        bytes memory args = abi.encode(
            manager,
            portraits,
            vault,
            address(liquidity),
            address(ink),
            address(imd),
            treasury,
            address(router),
            uint24(3000),
            int24(60)
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(InkHook).creationCode, args));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 salt;
        for (uint256 i = 0;; ++i) {
            address expected = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash)))
                )
            );
            if (uint160(expected) & Hooks.ALL_HOOK_MASK == flags) {
                salt = bytes32(i);
                break;
            }
        }
        hook = new InkHook{salt: salt}(
            manager,
            portraits,
            IInkRelease(address(vault)),
            address(liquidity),
            address(ink),
            address(imd),
            treasury,
            address(router),
            3000,
            60
        );
        liquidity.initializePool(
            hook, uint160(1 << 96), ink0 ? int24(600) : int24(-1200), ink0 ? int24(1200) : int24(-600)
        );
        poolKey = hook.key();
        _seedPool();
        vault.configureAssets(ink, seats);
        ink.approve(address(vault), 800000000 ether);
        vault.fund(vault.leaf(0, inputs), block.timestamp, IInkLiquidity(address(liquidity)));
        ink.transfer(alice, 20000000 ether);
        ink.transfer(bob, 20000000 ether);
        imd.transfer(alice, 20000000 ether);
        imd.transfer(bob, 20000000 ether);
        _approve(alice);
        _approve(bob);
    }

    function _seedPool() internal {
        uint256 maximum = 96000000 ether;
        ink.transfer(address(positions), maximum);
        imd.transfer(address(positions), maximum);
        bytes[] memory p = new bytes[](5);
        p[0] = abi.encode(
            poolKey,
            int24(-60000),
            int24(60000),
            uint256(100000000 ether),
            uint128(maximum),
            uint128(maximum),
            address(this),
            bytes("")
        );
        p[1] = abi.encode(poolKey.currency0, uint256(0), false);
        p[2] = abi.encode(poolKey.currency1, uint256(0), false);
        p[3] = abi.encode(poolKey.currency0, address(this));
        p[4] = abi.encode(poolKey.currency1, address(this));
        positions.modifyLiquidities(
            abi.encode(
                abi.encodePacked(
                    uint8(Actions.MINT_POSITION),
                    uint8(Actions.SETTLE),
                    uint8(Actions.SETTLE),
                    uint8(Actions.SWEEP),
                    uint8(Actions.SWEEP)
                ),
                p
            ),
            block.timestamp
        );
    }

    function _approve(address who) internal {
        vm.startPrank(who);
        ink.approve(address(permit), 20000000 ether);
        imd.approve(address(permit), 20000000 ether);
        permit.approve(address(ink), address(router), uint160(20000000 ether), type(uint48).max);
        permit.approve(address(imd), address(router), uint160(20000000 ether), type(uint48).max);
        vm.stopPrank();
    }

    function _release() internal {
        vm.warp(vault.claimStart() + 1 days);
        vault.release();
    }

    function _claim() internal {
        vm.prank(alice);
        vault.claim(0, inputs, new bytes32[](0));
    }

    function _swap(
        address trader,
        bool buy,
        bool exactIn,
        uint128 amount,
        uint128 limit,
        bytes memory hookData
    ) internal returns (uint256 paid, uint256 received) {
        IERC20 tokenIn = buy ? IERC20(address(imd)) : IERC20(address(ink));
        IERC20 tokenOut = buy ? IERC20(address(ink)) : IERC20(address(imd));
        bool zeroForOne = buy != ink0;
        bytes[] memory p = new bytes[](3);
        p[0] = exactIn
            ? abi.encode(IV4Router.ExactInputSingleParams(poolKey, zeroForOne, amount, limit, hookData))
            : abi.encode(IV4Router.ExactOutputSingleParams(poolKey, zeroForOne, amount, limit, hookData));
        p[1] = abi.encode(Currency.wrap(address(tokenIn)), uint256(exactIn ? amount : limit));
        p[2] = abi.encode(Currency.wrap(address(tokenOut)), uint256(exactIn ? limit : amount));
        bytes memory actions = abi.encodePacked(
            uint8(exactIn ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory commands = new bytes[](1);
        commands[0] = abi.encode(actions, p);
        uint256 beforeIn = tokenIn.balanceOf(trader);
        uint256 beforeOut = tokenOut.balanceOf(trader);
        vm.prank(trader);
        router.execute(hex"10", commands, block.timestamp);
        paid = beforeIn - tokenIn.balanceOf(trader);
        received = tokenOut.balanceOf(trader) - beforeOut;
    }

    function swapExternal(
        address trader,
        bool buy,
        bool exactIn,
        uint128 amount,
        uint128 limit,
        bytes memory data
    ) external returns (uint256, uint256) {
        return _swap(trader, buy, exactIn, amount, limit, data);
    }

    function _assertSettled() internal view {
        IPoolManager m = IPoolManager(address(manager));
        assertEq(m.currencyDelta(address(router), poolKey.currency0), 0);
        assertEq(m.currencyDelta(address(router), poolKey.currency1), 0);
        assertEq(m.currencyDelta(address(hook), poolKey.currency0), 0);
        assertEq(m.currencyDelta(address(hook), poolKey.currency1), 0);
        assertEq(m.getNonzeroDeltaCount(), 0);
        assertFalse(m.isUnlocked());
        assertEq(ink.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(router.msgSender(), address(0));
    }

    function testOfficialManagersReleaseAndPermanentPosition() public {
        uint256 beforeBalance = ink.balanceOf(address(manager));
        _release();
        assertTrue(vault.released());
        assertTrue(liquidity.releaseAdded());
        assertEq(liquidity.totalReleased(), 800000000 ether);
        assertEq(positions.ownerOf(liquidity.positionId()), address(liquidity));
        assertGt(positions.getPositionLiquidity(liquidity.positionId()), 0);
        assertEq(
            ink.balanceOf(address(manager)) - beforeBalance + ink.balanceOf(address(liquidity)),
            800000000 ether
        );
        assertLe(liquidity.lockedDust(), 1);
        assertEq(ink.allowance(address(vault), address(liquidity)), 0);
        assertEq(ink.allowance(address(liquidity), address(positions)), 0);
        assertEq(positions.getApproved(liquidity.positionId()), address(0));
        uint256 lockedId = liquidity.positionId();
        vm.expectRevert();
        positions.transferFrom(address(liquidity), bob, lockedId);
        vm.expectRevert(InkLiquidity.OnlyVault.selector);
        liquidity.addReleased(1 ether);
        vm.expectRevert(InkLiquidity.AlreadyAdded.selector);
        vm.prank(address(vault));
        liquidity.addReleased(1 ether);
        _assertSettled();
    }

    function testExactInputBothDirectionsFeesAndSettlement() public {
        _release();
        (uint256 paid, uint256 received) = _swap(alice, true, true, 10000 ether, 1, "");
        uint256 burned = ink.balanceOf(hook.INK_SINK());
        assertEq(paid, 10000 ether);
        assertEq(burned, (received + burned) * 25 / 10000);
        assertEq(hook.bought(alice), received + burned);
        assertEq(imd.balanceOf(treasury), 0);
        (paid, received) = _swap(alice, false, true, 10000 ether, 1, "");
        uint256 treasuryFee = imd.balanceOf(treasury);
        assertEq(paid, 10000 ether);
        assertEq(treasuryFee, (received + treasuryFee) * 25 / 10000);
        assertEq(ink.balanceOf(hook.INK_SINK()), burned);
        _assertSettled();
    }

    function testExactOutputBothDirectionsFeesAndSettlement() public {
        _release();
        (uint256 paid, uint256 received) = _swap(alice, true, false, 10000 ether, 20000 ether, "");
        uint256 treasuryFee = imd.balanceOf(treasury);
        assertEq(received, 10000 ether);
        assertEq(treasuryFee, (paid - treasuryFee) * 25 / 10000);
        assertEq(hook.bought(alice), received);
        assertEq(ink.balanceOf(hook.INK_SINK()), 0);
        (paid, received) = _swap(alice, false, false, 10000 ether, 20000 ether, "");
        uint256 burned = ink.balanceOf(hook.INK_SINK());
        assertEq(received, 10000 ether);
        assertEq(burned, (paid - burned) * 25 / 10000);
        assertEq(imd.balanceOf(treasury), treasuryFee);
        _assertSettled();
    }

    function testWaiverTracksPortraitTransfersAndIgnoresHookData() public {
        _claim();
        _release();
        _swap(alice, true, true, 10000 ether, 1, "");
        assertEq(ink.balanceOf(hook.INK_SINK()), 0);
        assertGt(hook.bought(alice), 0);
        // An ordinary trader cannot impersonate a holder through arbitrary hookData.
        _swap(bob, true, true, 10000 ether, 1, abi.encode(alice));
        uint256 sinkBefore = ink.balanceOf(hook.INK_SINK());
        assertGt(sinkBefore, 0);
        vm.prank(alice);
        portraits.transferFrom(alice, bob, 0);
        _swap(bob, true, false, 10000 ether, 20000 ether, "");
        assertEq(imd.balanceOf(treasury), 0);
        _swap(alice, true, true, 10000 ether, 1, abi.encode(bob));
        assertGt(ink.balanceOf(hook.INK_SINK()), sinkBefore);
        _assertSettled();
    }

    function testCapCumulativeIncludingExemptAndOneHourBoundary() public {
        _claim();
        _release();
        _swap(alice, true, false, 600000 ether, 1000000 ether, "");
        _swap(alice, true, false, 600000 ether, 1000000 ether, "");
        assertEq(hook.bought(alice), 1200000 ether);
        assertEq(imd.balanceOf(treasury), 0);
        uint256 beforeBalance = ink.balanceOf(alice);
        vm.expectRevert();
        this.swapExternal(alice, true, false, 1, 1000000 ether, "");
        assertEq(ink.balanceOf(alice), beforeBalance);
        _swap(bob, true, false, 10000 ether, 20000 ether, "");
        assertEq(hook.bought(bob), 10000 ether);
        vm.warp(hook.firstSwapAt() + 1 hours - 1);
        vm.expectRevert();
        this.swapExternal(alice, true, false, 1, 1000000 ether, "");
        vm.warp(hook.firstSwapAt() + 1 hours);
        _swap(alice, true, false, 1, 1000000 ether, "");
        _assertSettled();
    }

    function testLockedThenSevenDayFallbackStartsAtFirstSwap() public {
        uint256 initialized = hook.initializedAt();
        vm.expectRevert();
        this.swapExternal(alice, true, true, 1000 ether, 1, "");
        assertFalse(hook.tradingStarted());
        vm.warp(initialized + 7 days - 1);
        vm.expectRevert();
        this.swapExternal(alice, true, true, 1000 ether, 1, "");
        vm.warp(initialized + 7 days + 100);
        _swap(alice, true, true, 1000 ether, 1, "");
        assertEq(hook.firstSwapAt(), initialized + 7 days + 100);
        assertFalse(vault.released());
        _assertSettled();
    }

    function testSlippageFailureRollsBackFeeAndTradingStart() public {
        _release();
        uint256 balance = ink.balanceOf(alice);
        vm.expectRevert();
        this.swapExternal(alice, true, true, 1000 ether, 1000000 ether, "");
        assertEq(ink.balanceOf(alice), balance);
        assertEq(ink.balanceOf(hook.INK_SINK()), 0);
        assertFalse(hook.tradingStarted());
        assertEq(hook.bought(alice), 0);
        vm.expectRevert();
        this.swapExternal(alice, true, false, 1000 ether, 1, "");
        assertEq(imd.balanceOf(treasury), 0);
        _assertSettled();
    }

    function testAuthenticationAndWrongPool() public {
        _release();
        SwapParams memory params = SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert();
        hook.beforeSwap(address(router), poolKey, params, "");
        vm.expectRevert();
        hook.afterSwap(address(router), poolKey, params, toBalanceDelta(-1, 1), "");
        vm.expectRevert();
        router.unlockCallback("");
        UnsupportedRouter attacker = new UnsupportedRouter(manager);
        vm.expectRevert();
        attacker.attack(poolKey, alice);
        PoolKey memory wrong = poolKey;
        wrong.fee = 500;
        vm.expectRevert();
        manager.initialize(wrong, uint160(1 << 96));
        // Even the real router outside an active execute context does not identify a trader.
        vm.expectRevert(InkHook.UnsupportedRouter.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), poolKey, params, abi.encode(alice));
        _assertSettled();
    }

    function testGuardedInitializationAndInvalidRanges() public {
        vm.expectRevert();
        manager.initialize(poolKey, uint160(1 << 96));
        vm.expectRevert(InkLiquidity.InvalidConfiguration.selector);
        liquidity.initializePool(hook, uint160(1 << 96), 600, 1200);
        vm.expectRevert(InkLiquidity.InvalidRange.selector);
        liquidity.setReleaseRange(-60, 60);
        vm.expectRevert(InkLiquidity.InvalidRange.selector);
        liquidity.setReleaseRange(601, 1200);
        vm.expectRevert();
        vm.prank(alice);
        liquidity.setReleaseRange(600, 1200);
        vm.expectRevert(InkLiquidity.InvalidConfiguration.selector);
        liquidity.configure(address(ink), address(imd), address(vault), manager, positions);
    }

    function testPriceMovedReleaseRollbackAndRangeRepair() public {
        vm.warp(hook.initializedAt() + 7 days);
        _swap(alice, true, true, 1000 ether, 1, "");
        vm.warp(hook.firstSwapAt() + 1 hours);
        _swap(alice, true, true, 6000000 ether, 1, "");
        uint256 balance = ink.balanceOf(address(vault));
        vm.expectRevert(InkLiquidity.InvalidRange.selector);
        vault.release();
        assertFalse(vault.released());
        assertFalse(liquidity.releaseAdded());
        assertEq(ink.balanceOf(address(vault)), balance);
        assertEq(ink.balanceOf(address(liquidity)), 0);
        liquidity.setReleaseRange(ink0 ? int24(1800) : int24(-2400), ink0 ? int24(2400) : int24(-1800));
        vault.release();
        assertTrue(vault.released());
        _assertSettled();
    }

    function testSettlementFailureRollsBackPoolAndHook() public {
        _release();
        vm.prank(alice);
        permit.approve(address(imd), address(router), 0, 0);
        vm.expectRevert();
        this.swapExternal(alice, true, true, 1000 ether, 1, "");
        assertFalse(hook.tradingStarted());
        assertEq(hook.bought(alice), 0);
        assertEq(ink.balanceOf(hook.INK_SINK()), 0);
        _assertSettled();
    }

    function testSellStartsGlobalCapClockAndDoesNotOffsetBuys() public {
        _release();
        _swap(alice, false, true, 1000 ether, 1, "");
        uint256 first = hook.firstSwapAt();
        assertGt(first, 0);
        _swap(alice, true, false, 1000 ether, 2000 ether, "");
        _swap(alice, false, true, 1000 ether, 1, "");
        assertEq(hook.bought(alice), 1000 ether);
        assertEq(hook.firstSwapAt(), first);
    }

    function testReviewNestedRouterPlanPreservesInitiatorAndRecipientBoundary() public {
        _claim();
        _release();
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(
            IV4Router.ExactOutputSingleParams(poolKey, !ink0, 1000 ether, 2000 ether, abi.encode(bob))
        );
        p[1] = abi.encode(Currency.wrap(address(imd)), uint256(2000 ether));
        p[2] = abi.encode(Currency.wrap(address(ink)), bob, uint256(1000 ether));
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE)
        );
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encode(actions, p);
        bytes[] memory outer = new bytes[](1);
        outer[0] = abi.encode(hex"10", inner);
        uint256 beforeBalance = ink.balanceOf(bob);
        vm.prank(alice);
        router.execute(hex"21", outer, block.timestamp);
        assertEq(ink.balanceOf(bob) - beforeBalance, 1000 ether);
        assertEq(hook.bought(alice), 1000 ether);
        assertEq(hook.bought(bob), 0);
        assertEq(imd.balanceOf(treasury), 0);
        _assertSettled();
    }

    function testReviewOwnerCannotApproveOrPermitRetainedPosition() public {
        _release();
        uint256 id = liquidity.positionId();
        vm.expectRevert();
        positions.approve(bob, id);
        vm.expectRevert();
        positions.permit(bob, id, block.timestamp, 0, hex"");
        vm.expectRevert();
        positions.permitForAll(address(liquidity), bob, true, block.timestamp, 0, hex"");
        assertEq(positions.getApproved(id), address(0));
        assertFalse(positions.isApprovedForAll(address(liquidity), bob));
        assertEq(positions.ownerOf(id), address(liquidity));
    }

    function testReviewOwnerCannotCollectDecreaseOrBurnRetainedPosition() public {
        _release();
        uint256 id = liquidity.positionId();
        bytes[] memory p = new bytes[](1);
        p[0] = abi.encode(id, uint256(0), uint128(0), uint128(0), bytes(""));
        vm.expectRevert();
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY)), p), block.timestamp
        );
        vm.expectRevert();
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY)), p), block.timestamp
        );
        p[0] = abi.encode(id, uint128(0), uint128(0), bytes(""));
        vm.expectRevert();
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.BURN_POSITION)), p), block.timestamp
        );
        assertEq(positions.ownerOf(id), address(liquidity));
        assertGt(positions.getPositionLiquidity(id), 0);
        _assertSettled();
    }

    function testFuzzSwapFeeAndSettlement(uint128 amount, bool buy, bool exactIn) public {
        amount = uint128(bound(amount, 1000, 100000 ether));
        _release();
        (uint256 paid, uint256 received) = _swap(alice, buy, exactIn, amount, exactIn ? 1 : 300000 ether, "");
        bool feeInInk = buy == exactIn;
        uint256 fee = feeInInk ? ink.balanceOf(hook.INK_SINK()) : imd.balanceOf(treasury);
        uint256 gross = exactIn ? received + fee : paid - fee;
        assertEq(fee, gross * 25 / 10000);
        assertEq(exactIn ? paid : received, amount);
        _assertSettled();
    }
}

contract V4InkIsCurrency0Test is V4IntegrationBase {
    function setUp() public {
        _setup(true);
    }
}

contract V4InkIsCurrency1Test is V4IntegrationBase {
    function setUp() public {
        _setup(false);
    }
}
