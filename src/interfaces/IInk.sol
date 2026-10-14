// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct AgentInputs {
    uint32 accepted;
    uint16 rateBps;
    uint32 turns;
    uint32 hoursTenths;
    bool outdated;
}

interface IInkRenderer {
    function tokenURI(uint256 id, AgentInputs calldata inputs, bytes32 seed)
        external
        view
        returns (string memory);
}

interface IInkLiquidity {
    function vault() external view returns (address);
    function ink() external view returns (address);
    function ready() external view returns (bool);
    /// @dev The vault pushes tokens immediately before this call, in the same transaction.
    function addReleased(uint256 amount) external;
}

interface IInkRelease {
    function released() external view returns (bool);
}

interface IRouterIdentity {
    function msgSender() external view returns (address);
}
