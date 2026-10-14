// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AgentInputs, IInkRenderer} from "./interfaces/IInk.sol";

contract InkPortraits is ERC721, ERC2981, Ownable2Step {
    uint256 public constant MAX_PORTRAITS = 2000;
    uint256 public totalSupply;
    uint256 public nextSwarmId = 10000;
    address public vault;
    IInkRenderer public renderer;
    bool public rendererLocked;
    mapping(uint256 => AgentInputs) private _inputs;
    mapping(uint256 => bytes32) public swarmSeed;
    mapping(address => uint256) public agentBalance;

    error InvalidConfiguration();
    error OnlyVault();
    error Capacity();
    error InvalidSeat();
    error DirectVaultTransfer();
    error RendererNotConfigured();
    event VaultConfigured(address indexed vault);
    event RendererSelected(address indexed renderer);
    event RendererLocked(address indexed renderer);

    constructor(address initialOwner) ERC721("Ink & Inference", "INKINF") Ownable(initialOwner) {
        _setDefaultRoyalty(initialOwner, 500);
    }

    function configureVault(address vault_) external onlyOwner {
        if (vault != address(0) || vault_ == address(0) || totalSupply != 0) revert InvalidConfiguration();
        vault = vault_;
        emit VaultConfigured(vault_);
    }

    function setRenderer(IInkRenderer renderer_) external onlyOwner {
        if (rendererLocked || address(renderer_) == address(0)) revert InvalidConfiguration();
        renderer = renderer_;
        emit RendererSelected(address(renderer_));
    }

    function lockRenderer() external onlyOwner {
        if (rendererLocked || address(renderer) == address(0)) revert InvalidConfiguration();
        rendererLocked = true;
        emit RendererLocked(address(renderer));
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function mintAgent(address recipient, uint256 seat, AgentInputs calldata inputs) external onlyVault {
        if (seat >= MAX_PORTRAITS || inputs.rateBps > 10000) revert InvalidSeat();
        if (totalSupply >= MAX_PORTRAITS) revert Capacity();
        ++totalSupply;
        _inputs[seat] = inputs;
        _safeMint(recipient, seat);
    }

    function mintSwarm(address recipient, bytes32 seed) external onlyVault returns (uint256 id) {
        if (totalSupply >= MAX_PORTRAITS) revert Capacity();
        ++totalSupply;
        id = nextSwarmId++;
        swarmSeed[id] = seed;
        _safeMint(recipient, id);
    }

    function agentInputs(uint256 id) external view returns (AgentInputs memory) {
        _requireOwned(id);
        return _inputs[id];
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        if (address(renderer) == address(0)) revert RendererNotConfigured();
        return renderer.tokenURI(id, _inputs[id], swarmSeed[id]);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        // An unsolicited deposit would bypass the payout/inventory accounting.
        if (to == vault && msg.sender != vault) revert DirectVaultTransfer();
        from = super._update(to, tokenId, auth);
        if (tokenId < MAX_PORTRAITS) {
            if (from != address(0)) --agentBalance[from];
            if (to != address(0)) ++agentBalance[to];
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
