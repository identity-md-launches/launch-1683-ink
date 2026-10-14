// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentInputs} from "../../src/interfaces/IInk.sol";

// Synthetic StandardMerkleTree fixture. Never use this root for production.
library SyntheticSnapshot {
    bytes32 internal constant ROOT = 0xdfca10f37bddc47df903cf454ae90e8799de3df4dbb146ca91b56e354731430b;

    function row(uint256 index)
        internal
        pure
        returns (uint256 seat, AgentInputs memory data, bytes32[] memory proof)
    {
        if (index == 0) {
            seat = 0;
            data = AgentInputs(42, 9000, 50, 123, false);
            proof = new bytes32[](2);
            proof[0] = 0xf623821c03e82fe8f167776543fef5fe12e915d8de39ed5b0363f5c11cefc6ec;
            proof[1] = 0x1e383d77bbdef2cce3e3f53fe922afaf6d88573125063a20b10c6fdce3865034;
            return (seat, data, proof);
        }
        if (index == 1) {
            seat = 1;
            data = AgentInputs(0, 0, 0, 0, true);
            proof = new bytes32[](3);
            proof[0] = 0x1a402794cce0d8b2261dfb7a9c206eb6cc1e095e5787e5c8692139902e452468;
            proof[1] = 0xe5553e2f0dcfc323b6f6eb7d2ee8bbbf4d828797b1e05e6073f26e4760b6d8d0;
            proof[2] = 0x1e383d77bbdef2cce3e3f53fe922afaf6d88573125063a20b10c6fdce3865034;
            return (seat, data, proof);
        }
        if (index == 2) {
            seat = 777;
            data = AgentInputs(1000, 7500, 2000, 360, false);
            proof = new bytes32[](2);
            proof[0] = 0x32ac2aa1e4bd9ebdab2308eaf9a4a82d66c8da4a3eb08c1391c81bcd80bcd033;
            proof[1] = 0x1bff10d47dedb582b2463327d73edcd822a2cfc4eb2d0414eb34c66813d76989;
            return (seat, data, proof);
        }
        if (index == 3) {
            seat = 1999;
            data = AgentInputs(0, 0, 0, 0, true);
            proof = new bytes32[](2);
            proof[0] = 0x813843a15d202f7a4bb039acf7d7e532cb4d23a4f4bc96ab50379cfe6bcad3f8;
            proof[1] = 0x1bff10d47dedb582b2463327d73edcd822a2cfc4eb2d0414eb34c66813d76989;
            return (seat, data, proof);
        }
        if (index == 4) {
            seat = 33;
            data = AgentInputs(4294967295, 10000, 4294967295, 4294967295, true);
            proof = new bytes32[](3);
            proof[0] = 0x0566ed80c5c298cfed67d2f7e888a5e5e242b23808a7a43e34fc2a73ce9e9c3b;
            proof[1] = 0xe5553e2f0dcfc323b6f6eb7d2ee8bbbf4d828797b1e05e6073f26e4760b6d8d0;
            proof[2] = 0x1e383d77bbdef2cce3e3f53fe922afaf6d88573125063a20b10c6fdce3865034;
            return (seat, data, proof);
        }
        revert("fixture index");
    }
}
