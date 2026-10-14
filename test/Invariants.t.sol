// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {AgentInputs} from "../src/interfaces/IInk.sol";
import {MockINK, MockSeats, MockLiquidity} from "./mocks/Assets.sol";

contract VaultHandler is Test {
    InkVault public vault;
    InkPortraits public portraits;
    MockINK public ink;
    address[3] public actors;
    uint256[] public requests;
    uint256[] public tokens;
    uint256 public donations;

    constructor(InkVault v, InkPortraits p, MockINK i, address[3] memory a) {
        vault = v;
        portraits = p;
        ink = i;
        actors = a;
    }

    function request(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        if (ink.balanceOf(actor) < vault.PRICE() || vault.circulating() + vault.pendingCount() == 2000) {
            return;
        }
        vm.prank(actor);
        requests.push(vault.pull());
    }

    function reveal(uint256 index) external {
        if (requests.length == 0) return;
        uint256 id = requests[index % requests.length];
        (address buyer, uint256 target) = vault.pulls(id);
        if (buyer == address(0) || block.number > target + 256) return;
        if (block.number <= target) vm.roll(target + 1);
        vm.setBlockhash(target, keccak256(abi.encode(id, target)));
        tokens.push(vault.reveal(id));
    }

    function expire(uint256 index) external {
        if (requests.length == 0) return;
        uint256 id = requests[index % requests.length];
        (address buyer, uint256 target) = vault.pulls(id);
        if (buyer == address(0)) return;
        if (block.number <= target + 256) vm.roll(target + 257);
        vault.expire(id);
    }

    function returnToken(uint256 index) external {
        if (tokens.length == 0) return;
        uint256 id = tokens[index % tokens.length];
        address holder = portraits.ownerOf(id);
        if (holder == address(vault)) return;
        vm.startPrank(holder);
        portraits.approve(address(vault), id);
        vault.returnPortrait(id);
        vm.stopPrank();
    }

    function transfer(uint256 index, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        uint256 id = tokens[index % tokens.length];
        address holder = portraits.ownerOf(id);
        if (holder == address(vault)) return;
        vm.prank(holder);
        portraits.transferFrom(holder, actors[actorSeed % 3], id);
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 0, ink.balanceOf(actor));
        donations += amount;
        vm.prank(actor);
        ink.transfer(address(vault), amount);
    }

    function fundBonus(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 0, ink.balanceOf(actor));
        vm.prank(actor);
        vault.fundBonus(amount);
    }

    function seedAgent(uint256 id) external {
        require(msg.sender == address(vault.owner()));
        tokens.push(id);
    }
}

contract VaultInvariantTest is StdInvariant, Test {
    InkVault internal vault;
    InkPortraits internal portraits;
    MockINK internal ink;
    VaultHandler internal handler;
    address[3] internal actors;

    function setUp() public {
        vm.warp(1000);
        actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2")];
        portraits = new InkPortraits(address(this));
        vault = new InkVault(address(this), portraits);
        portraits.configureVault(address(vault));
        ink = new MockINK(address(this));
        MockSeats seats = new MockSeats();
        seats.mint(actors[0], 0);
        MockLiquidity liquidity = new MockLiquidity(address(vault), address(ink));
        vault.configureAssets(ink, seats);
        ink.approve(address(vault), 800000000 ether);
        AgentInputs memory data = AgentInputs(1, 10000, 1, 1, false);
        vault.fund(vault.leaf(0, data), block.timestamp, liquidity);
        vm.prank(actors[0]);
        vault.claim(0, data, new bytes32[](0));
        vm.warp(block.timestamp + 1 days);
        vault.release();
        for (uint256 i = 0; i < 3; ++i) {
            ink.transfer(actors[i], 50000000 ether);
            vm.prank(actors[i]);
            ink.approve(address(vault), type(uint256).max);
        }
        handler = new VaultHandler(vault, portraits, ink, actors);
        handler.seedAgent(0);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.reveal.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.returnToken.selector;
        selectors[4] = handler.transfer.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.fundBonus.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantSolvencyAndDonationIsolation() public view {
        assertEq(ink.balanceOf(address(vault)), vault.liabilities() + handler.donations());
        assertGe(ink.balanceOf(address(vault)), (vault.circulating() + vault.pendingCount()) * vault.PRICE());
    }

    function invariantCapacityAndInventoryCustody() public view {
        assertEq(portraits.totalSupply(), vault.circulating() + vault.inventoryCount());
        assertLe(portraits.totalSupply(), 2000);
        assertLe(vault.circulating() + vault.pendingCount(), 2000);
        uint256 count = vault.inventoryCount();
        for (uint256 i = 0; i < count; ++i) {
            assertEq(portraits.ownerOf(vault.inventoryAt(i)), address(vault));
            for (uint256 j = i + 1; j < count; ++j) {
                assertNotEq(vault.inventoryAt(i), vault.inventoryAt(j));
            }
        }
    }

    function invariantAgentBalancesFollowCustody() public view {
        address holder = portraits.ownerOf(0);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(portraits.agentBalance(actors[i]), holder == actors[i] ? 1 : 0);
        }
        assertEq(portraits.agentBalance(address(vault)), holder == address(vault) ? 1 : 0);
    }
}
