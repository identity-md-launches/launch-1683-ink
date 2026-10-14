// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {AgentInputs} from "../src/interfaces/IInk.sol";
import {SyntheticSnapshot} from "./fixtures/SyntheticSnapshot.sol";
import {MockINK, MockSeats, MockLiquidity} from "./mocks/Assets.sol";

contract SnapshotTest is Test {
    function testStandardMerkleTreeSyntheticFixtureClaimsAllRows() public {
        InkPortraits p = new InkPortraits(address(this));
        InkVault v = new InkVault(address(this), p);
        p.configureVault(address(v));
        MockINK ink = new MockINK(address(this));
        MockSeats seats = new MockSeats();
        v.configureAssets(ink, seats);
        MockLiquidity liquidity = new MockLiquidity(address(v), address(ink));
        ink.approve(address(v), 800000000 ether);
        v.fund(SyntheticSnapshot.ROOT, block.timestamp, liquidity);
        address holder = makeAddr("synthetic holder");
        for (uint256 i = 0; i < 5; ++i) {
            (uint256 seat, AgentInputs memory data, bytes32[] memory proof) = SyntheticSnapshot.row(i);
            seats.mint(holder, seat);
            vm.prank(holder);
            v.claim(seat, data, proof);
            assertEq(p.ownerOf(seat), holder);
            assertEq(p.agentInputs(seat).accepted, data.accepted);
        }
        assertEq(v.claimedCount(), 5);
        assertEq(p.agentBalance(holder), 5);
        assertEq(ink.balanceOf(address(v)), v.liabilities());
    }
}
