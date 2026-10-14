// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {AgentInputs, IInkLiquidity} from "../src/interfaces/IInk.sol";
import {MockINK, MockSeats, MockLiquidity, TaxToken} from "./mocks/Assets.sol";

contract ReenteringHolder is IERC721Receiver {
    InkVault public vault;
    bool public reentered;
    bool public reject;

    constructor(InkVault vault_) {
        vault = vault_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!reject, "reject NFT");
        (reentered,) = address(vault).call(abi.encodeCall(InkVault.pull, ()));
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract VaultTest is Test {
    InkVault internal vault;
    InkPortraits internal portraits;
    MockINK internal ink;
    MockSeats internal seats;
    MockLiquidity internal liquidity;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant PRICE = 400000 ether;
    AgentInputs internal active = AgentInputs(42, 9000, 50, 123, false);
    AgentInputs internal inactive = AgentInputs(0, 0, 0, 0, true);
    bytes32 internal activeLeaf;
    bytes32 internal inactiveLeaf;
    bytes32 internal root;

    function setUp() public {
        vm.warp(100000);
        portraits = new InkPortraits(address(this));
        vault = new InkVault(address(this), portraits);
        portraits.configureVault(address(vault));
        ink = new MockINK(address(this));
        seats = new MockSeats();
        seats.mint(alice, 0);
        seats.mint(bob, 1999);
        liquidity = new MockLiquidity(address(vault), address(ink));
        vault.configureAssets(IERC20(address(ink)), IERC721(address(seats)));
        activeLeaf = vault.leaf(0, active);
        inactiveLeaf = vault.leaf(1999, inactive);
        root = activeLeaf < inactiveLeaf
            ? keccak256(abi.encodePacked(activeLeaf, inactiveLeaf))
            : keccak256(abi.encodePacked(inactiveLeaf, activeLeaf));
        ink.approve(address(vault), 800000000 ether);
        vault.fund(root, block.timestamp + 10, liquidity);
        ink.transfer(alice, 90000000 ether);
        ink.transfer(bob, 90000000 ether);
        vm.prank(alice);
        ink.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        ink.approve(address(vault), type(uint256).max);
    }

    function _claimAlice() internal {
        vm.warp(vault.claimStart());
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = inactiveLeaf;
        vm.prank(alice);
        vault.claim(0, active, proof);
    }

    function _release() internal {
        vm.warp(vault.claimStart() + 1 days);
        vault.release();
    }

    function _reveal(uint256 request) internal returns (uint256) {
        (, uint256 entropyBlock) = vault.pulls(request);
        vm.roll(entropyBlock + 1);
        vm.setBlockhash(entropyBlock, keccak256(abi.encode(request)));
        return vault.reveal(request);
    }

    function _pull(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.pull();
    }

    function _assertSolvent() internal view {
        assertEq(ink.balanceOf(address(vault)), vault.liabilities());
        assertEq(portraits.totalSupply(), vault.circulating() + vault.inventoryCount());
        assertLe(vault.circulating() + vault.pendingCount(), 2000);
    }

    function testCurrentOwnerAndInactiveSeatClaim() public {
        vm.prank(alice);
        seats.transferFrom(alice, bob, 0);
        vm.warp(vault.claimStart());
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = inactiveLeaf;
        vm.expectRevert(InkVault.NotSeatOwner.selector);
        vm.prank(alice);
        vault.claim(0, active, proof);
        vm.prank(bob);
        vault.claim(0, active, proof);
        proof[0] = activeLeaf;
        vm.prank(bob);
        vault.claim(1999, inactive, proof);
        assertEq(portraits.ownerOf(0), bob);
        assertEq(portraits.ownerOf(1999), bob);
        assertEq(portraits.agentBalance(bob), 2);
        assertTrue(portraits.agentInputs(1999).outdated);
        assertEq(vault.claimedCount(), 2);
        _assertSolvent();
    }

    function testInvalidProofDuplicateAndWindowBoundaries() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = inactiveLeaf;
        vm.expectRevert(InkVault.WrongWindow.selector);
        vm.prank(alice);
        vault.claim(0, active, proof);
        vm.warp(vault.claimStart());
        AgentInputs memory modified = active;
        modified.outdated = true;
        vm.expectRevert(InkVault.InvalidProof.selector);
        vm.prank(alice);
        vault.claim(0, modified, proof);
        vm.prank(alice);
        vault.claim(0, active, proof);
        vm.expectRevert(InkVault.AlreadyClaimed.selector);
        vm.prank(alice);
        vault.claim(0, active, proof);
        vm.warp(vault.claimStart() + 1 days);
        proof[0] = activeLeaf;
        vm.expectRevert(InkVault.WrongWindow.selector);
        vm.prank(bob);
        vault.claim(1999, inactive, proof);
    }

    function testOneTimeFundingAndConfigurationFrozen() public {
        vm.expectRevert(InkVault.AlreadyFunded.selector);
        vault.fund(root, block.timestamp, liquidity);
        vm.expectRevert(InkVault.InvalidConfiguration.selector);
        vault.configureAssets(ink, seats);
        vm.expectRevert(InkVault.NotReleased.selector);
        _pull(alice);
    }

    function testReleaseRollbackAndPermissionlessSuccess() public {
        _claimAlice();
        vm.expectRevert(InkVault.WrongWindow.selector);
        vault.release();
        liquidity.setFail(true);
        vm.warp(vault.claimStart() + 1 days);
        uint256 beforeBalance = ink.balanceOf(address(vault));
        vm.expectRevert("liquidity failed");
        vault.release();
        assertFalse(vault.released());
        assertEq(ink.balanceOf(address(vault)), beforeBalance);
        assertEq(ink.balanceOf(address(liquidity)), 0);
        liquidity.setFail(false);
        liquidity.setReenter(true);
        vm.prank(bob);
        vault.release();
        assertFalse(liquidity.reentrySucceeded());
        assertTrue(vault.released());
        assertEq(liquidity.received(), 1999 * PRICE);
        assertEq(ink.allowance(address(vault), address(liquidity)), 0);
        vm.expectRevert(InkVault.AlreadyReleased.selector);
        vault.release();
        _assertSolvent();
    }

    function testPullRevealExpiryAndNoDoubleReservation() public {
        _release();
        uint256 beforeBalance = ink.balanceOf(alice);
        uint256 req = _pull(alice);
        assertEq(vault.pendingCount(), 1);
        assertEq(ink.balanceOf(alice), beforeBalance - PRICE);
        vm.expectRevert(InkVault.RevealNotReady.selector);
        vault.reveal(req);
        (, uint256 entropyBlock) = vault.pulls(req);
        vm.roll(entropyBlock);
        vm.expectRevert(InkVault.RevealNotReady.selector);
        vault.reveal(req);
        vm.roll(entropyBlock + 256);
        vm.setBlockhash(entropyBlock, keccak256("edge"));
        vm.expectRevert(InkVault.NotExpired.selector);
        vault.expire(req);
        uint256 id = vault.reveal(req);
        assertEq(id, 10000);
        assertEq(portraits.ownerOf(id), alice);
        assertNotEq(portraits.swarmSeed(id), bytes32(0));
        vm.expectRevert(InkVault.InvalidRequest.selector);
        vault.reveal(req);
        vm.expectRevert(InkVault.InvalidRequest.selector);
        vault.expire(req);
        req = _pull(alice);
        (, entropyBlock) = vault.pulls(req);
        vm.roll(entropyBlock + 257);
        vm.expectRevert(InkVault.RevealExpired.selector);
        vault.reveal(req);
        vm.prank(bob);
        vault.expire(req);
        assertEq(ink.balanceOf(alice), beforeBalance - PRICE);
        assertEq(vault.pendingCount(), 0);
        vm.expectRevert(InkVault.InvalidRequest.selector);
        vault.expire(req);
        _assertSolvent();
    }

    function testReturnsFeesBonusAndInventoryReuse() public {
        _claimAlice();
        _release();
        uint256 id = _reveal(_pull(bob));
        vm.prank(bob);
        portraits.approve(address(vault), id);
        vm.prank(bob);
        uint256 payout = vault.returnPortrait(id);
        assertEq(payout, PRICE * 9900 / 10000);
        assertEq(vault.bonusPot(), PRICE / 100);
        assertEq(portraits.ownerOf(id), address(vault));
        uint256 reused = _reveal(_pull(alice));
        assertEq(reused, id);
        assertEq(portraits.totalSupply(), 2);
        vm.prank(alice);
        portraits.approve(address(vault), id);
        vm.prank(alice);
        payout = vault.returnPortrait(id);
        assertEq(payout, PRICE * 9950 / 10000);
        assertEq(vault.bonusPot(), PRICE * 150 / 10000);
        vm.prank(alice);
        portraits.approve(address(vault), 0);
        vm.prank(alice);
        payout = vault.returnPortrait(0);
        assertEq(payout, PRICE + PRICE * 150 / 10000);
        assertEq(vault.bonusPot(), 0);
        assertEq(vault.inventoryCount(), 2);
        assertEq(vault.circulating(), 0);
        vm.expectRevert(InkVault.NotPortraitOwner.selector);
        vm.prank(alice);
        vault.returnPortrait(0);
        _assertSolvent();
    }

    function testAgentReturnNeverSpendsBackingAndMaximumBonus() public {
        _claimAlice();
        ink.approve(address(vault), PRICE);
        vault.fundBonus(PRICE);
        vm.prank(alice);
        portraits.approve(address(vault), 0);
        vm.prank(alice);
        uint256 payout = vault.returnPortrait(0);
        assertEq(payout, PRICE * 105 / 100);
        assertEq(vault.bonusPot(), PRICE * 95 / 100);
        _release();
        _assertSolvent();
    }

    function testAgentReturnWithEmptyPot() public {
        _claimAlice();
        vm.prank(alice);
        portraits.approve(address(vault), 0);
        vm.prank(alice);
        assertEq(vault.returnPortrait(0), PRICE);
        _assertSolvent();
    }

    function testUnsolicitedPortraitAndMissingApprovalRejected() public {
        _claimAlice();
        vm.expectRevert(InkPortraits.DirectVaultTransfer.selector);
        vm.prank(alice);
        portraits.transferFrom(alice, address(vault), 0);
        vm.expectRevert();
        vm.prank(alice);
        vault.returnPortrait(0);
        assertEq(vault.inventoryCount(), 0);
        assertEq(vault.circulating(), 1);
        _assertSolvent();
    }

    function testFeeBoundsAndOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setFees(500, 100, 1000);
        vm.expectRevert(InkVault.InvalidFees.selector);
        vault.setFees(501, 100, 1000);
        vm.expectRevert(InkVault.InvalidFees.selector);
        vault.setFees(100, 101, 500);
        vm.expectRevert(InkVault.InvalidFees.selector);
        vault.setFees(100, 50, 1001);
        vault.setFees(500, 500, 1000);
        assertEq(vault.baseFeeBps(), 500);
        vault.setFees(0, 0, 0);
        assertEq(vault.bonusBps(), 0);
    }

    function testRejectingReceiverRefundAndReentrancy() public {
        _release();
        ReenteringHolder holder = new ReenteringHolder(vault);
        ink.transfer(address(holder), 2 * PRICE);
        vm.prank(address(holder));
        ink.approve(address(vault), 2 * PRICE);
        uint256 req = _pull(address(holder));
        holder.setReject(true);
        (, uint256 target) = vault.pulls(req);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("hash"));
        vm.expectRevert("reject NFT");
        vault.reveal(req);
        assertEq(vault.pendingCount(), 1);
        assertEq(portraits.totalSupply(), 0);
        vm.roll(target + 257);
        vault.expire(req);
        assertEq(ink.balanceOf(address(holder)), 2 * PRICE);
        holder.setReject(false);
        _reveal(_pull(address(holder)));
        assertFalse(holder.reentered());
        _assertSolvent();
    }

    function testCapacityReservedAcrossAllPendingPulls() public {
        _release();
        // Recycle released mock funds for this capacity stress test only.
        vm.prank(address(liquidity));
        ink.transfer(alice, 800000000 ether);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 2000; ++i) {
            vault.pull();
        }
        vm.expectRevert(InkVault.NoCapacity.selector);
        vault.pull();
        vm.stopPrank();
        assertEq(vault.pendingCount(), 2000);
        _assertSolvent();
        (, uint256 target) = vault.pulls(1);
        vm.roll(target + 257);
        vault.expire(1);
        _pull(alice);
        assertEq(vault.pendingCount(), 2000);
        _assertSolvent();
    }

    function testNon18DecimalsAndTaxedFundingRejected() public {
        InkPortraits p = new InkPortraits(address(this));
        InkVault v = new InkVault(address(this), p);
        p.configureVault(address(v));
        TaxToken bad = new TaxToken(address(this), 6);
        vm.expectRevert(InkVault.NonPlainToken.selector);
        v.configureAssets(bad, seats);
        bad = new TaxToken(address(this), 18);
        v.configureAssets(bad, seats);
        MockLiquidity l = new MockLiquidity(address(v), address(bad));
        bad.approve(address(v), 800000000 ether);
        bad.enableTax();
        vm.expectRevert(InkVault.NonPlainToken.selector);
        v.fund(root, block.timestamp, l);
        assertFalse(v.funded());
        assertEq(bad.balanceOf(address(v)), 0);
    }

    function testFuzzFeeConservation(uint16 base, uint16 agent, uint16 bonus, bool holder) public {
        base = uint16(bound(base, 0, 500));
        agent = uint16(bound(agent, 0, base));
        bonus = uint16(bound(bonus, 0, 1000));
        vault.setFees(base, agent, bonus);
        _claimAlice();
        _release();
        address buyer = holder ? alice : bob;
        uint256 id = _reveal(_pull(buyer));
        vm.prank(buyer);
        portraits.approve(address(vault), id);
        vm.prank(buyer);
        uint256 payout = vault.returnPortrait(id);
        assertEq(payout, PRICE - PRICE * (holder ? agent : base) / 10000);
        _assertSolvent();
        vm.prank(alice);
        portraits.approve(address(vault), 0);
        vm.prank(alice);
        vault.returnPortrait(0);
        _assertSolvent();
    }
}
