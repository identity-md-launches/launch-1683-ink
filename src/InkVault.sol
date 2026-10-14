// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {InkPortraits} from "./InkPortraits.sol";
import {AgentInputs, IInkLiquidity} from "./interfaces/IInk.sol";

contract InkVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant PRICE = 400000 ether;
    uint256 public constant SEATS = 2000;
    uint256 public constant CLAIM_WINDOW = 24 hours;
    IERC20 public ink;
    IERC721 public seats;
    InkPortraits public immutable portraits;
    IInkLiquidity public liquidity;
    bytes32 public statsRoot;
    uint256 public claimStart;
    bool public funded;
    bool public released;
    uint256 public claimedCount;
    uint256 public circulating;
    uint256 public pendingCount;
    uint256 public bonusPot;
    uint256 public nextRequestId = 1;
    uint16 public baseFeeBps = 100;
    uint16 public agentFeeBps = 50;
    uint16 public bonusBps = 500;
    mapping(uint256 => bool) public claimed;

    struct Pull {
        address buyer;
        uint256 entropyBlock;
    }
    mapping(uint256 => Pull) public pulls;
    uint256[] private _inventory;

    error NotConfigured();
    error InvalidConfiguration();
    error AlreadyFunded();
    error WrongWindow();
    error NotSeatOwner();
    error InvalidProof();
    error AlreadyClaimed();
    error NotReleased();
    error AlreadyReleased();
    error NoCapacity();
    error InvalidRequest();
    error RevealNotReady();
    error RevealExpired();
    error NotExpired();
    error NonPlainToken();
    error NotPortraitOwner();
    error InvalidFees();
    event AssetsConfigured(address indexed ink, address indexed seats);
    event Funded(bytes32 indexed root, uint256 start, address indexed liquidity);
    event Claimed(uint256 indexed seat, address indexed holder);
    event Released(uint256 amount);
    event PullRequested(uint256 indexed requestId, address indexed buyer, uint256 entropyBlock);
    event Revealed(uint256 indexed requestId, uint256 indexed portraitId, bytes32 seed);
    event PullExpired(uint256 indexed requestId, address indexed buyer);
    event PortraitReturned(
        uint256 indexed id, address indexed holder, uint256 payout, uint256 fee, uint256 bonus
    );
    event FeesSet(uint16 base, uint16 agent, uint16 bonus);
    event BonusFunded(address indexed donor, uint256 amount);

    constructor(address initialOwner, InkPortraits portraits_) Ownable(initialOwner) {
        if (address(portraits_) == address(0)) revert InvalidConfiguration();
        portraits = portraits_;
    }

    /// @notice Production INK and identity.md seats are supplied later. Frozen by funding.
    function configureAssets(IERC20 ink_, IERC721 seats_) external onlyOwner {
        if (funded || address(ink_) == address(0) || address(seats_) == address(0)) {
            revert InvalidConfiguration();
        }
        if (IERC20Metadata(address(ink_)).decimals() != 18) revert NonPlainToken();
        ink = ink_;
        seats = seats_;
        emit AssetsConfigured(address(ink_), address(seats_));
    }

    function fund(bytes32 root, uint256 start, IInkLiquidity liquidity_) external onlyOwner nonReentrant {
        if (funded) revert AlreadyFunded();
        if (address(ink) == address(0) || portraits.vault() != address(this)) revert NotConfigured();
        if (
            root == bytes32(0) || start < block.timestamp || start > type(uint256).max - CLAIM_WINDOW
                || address(liquidity_) == address(0)
        ) revert InvalidConfiguration();
        if (liquidity_.vault() != address(this) || liquidity_.ink() != address(ink) || !liquidity_.ready()) {
            revert InvalidConfiguration();
        }
        funded = true;
        statsRoot = root;
        claimStart = start;
        liquidity = liquidity_;
        emit Funded(root, start, address(liquidity_));
        _receiveExact(SEATS * PRICE);
    }

    function leaf(uint256 seat, AgentInputs calldata inputs) public pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        seat,
                        inputs.accepted,
                        inputs.rateBps,
                        inputs.turns,
                        inputs.hoursTenths,
                        inputs.outdated
                    )
                )
            )
        );
    }

    function claim(uint256 seat, AgentInputs calldata inputs, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (!funded) revert NotConfigured();
        if (block.timestamp < claimStart || block.timestamp >= claimStart + CLAIM_WINDOW) {
            revert WrongWindow();
        }
        if (
            seat >= SEATS || inputs.rateBps > 10000
                || !MerkleProof.verifyCalldata(proof, statsRoot, leaf(seat, inputs))
        ) {
            revert InvalidProof();
        }
        if (claimed[seat]) revert AlreadyClaimed();
        if (seats.ownerOf(seat) != msg.sender) revert NotSeatOwner();
        claimed[seat] = true;
        ++claimedCount;
        ++circulating;
        emit Claimed(seat, msg.sender);
        portraits.mintAgent(msg.sender, seat, inputs);
    }

    function release() external nonReentrant {
        if (!funded) revert NotConfigured();
        if (released) revert AlreadyReleased();
        if (block.timestamp < claimStart + CLAIM_WINDOW) revert WrongWindow();
        uint256 amount = (SEATS - claimedCount) * PRICE;
        released = true;
        emit Released(amount);
        if (amount != 0) {
            // Push, never approve an arbitrary `from` withdrawal. Failure reverts the entire release.
            ink.safeTransfer(address(liquidity), amount);
            liquidity.addReleased(amount);
        }
    }

    function pull() external nonReentrant returns (uint256 requestId) {
        if (!released) revert NotReleased();
        if (circulating + pendingCount >= SEATS) revert NoCapacity();
        requestId = nextRequestId++;
        uint256 target = block.number + 1;
        pulls[requestId] = Pull(msg.sender, target);
        ++pendingCount;
        emit PullRequested(requestId, msg.sender, target);
        _receiveExact(PRICE);
    }

    /// @notice Permissionless delivery to the committed buyer. Blockhash entropy is manipulable; see SECURITY.md.
    function reveal(uint256 requestId) external nonReentrant returns (uint256 id) {
        Pull memory request = pulls[requestId];
        if (request.buyer == address(0)) revert InvalidRequest();
        if (block.number <= request.entropyBlock) revert RevealNotReady();
        if (block.number > request.entropyBlock + 256) revert RevealExpired();
        bytes32 entropy = blockhash(request.entropyBlock);
        if (entropy == bytes32(0)) revert RevealNotReady();
        bytes32 seed = keccak256(abi.encode(entropy, requestId, request.buyer, address(this), block.chainid));
        delete pulls[requestId];
        --pendingCount;
        ++circulating;
        uint256 count = _inventory.length;
        if (count != 0) {
            uint256 index = uint256(seed) % count;
            id = _inventory[index];
            _inventory[index] = _inventory[count - 1];
            _inventory.pop();
            emit Revealed(requestId, id, seed);
            portraits.safeTransferFrom(address(this), request.buyer, id);
        } else {
            id = portraits.mintSwarm(request.buyer, seed);
            emit Revealed(requestId, id, seed);
        }
    }

    function expire(uint256 requestId) external nonReentrant {
        Pull memory request = pulls[requestId];
        if (request.buyer == address(0)) revert InvalidRequest();
        if (block.number <= request.entropyBlock + 256) revert NotExpired();
        delete pulls[requestId];
        --pendingCount;
        emit PullExpired(requestId, request.buyer);
        ink.safeTransfer(request.buyer, PRICE);
    }

    function returnPortrait(uint256 id) external nonReentrant returns (uint256 payout) {
        if (portraits.ownerOf(id) != msg.sender) revert NotPortraitOwner();
        uint256 fee = 0;
        uint256 bonus = 0;
        if (id < SEATS) {
            bonus = PRICE * bonusBps / 10000;
            if (bonus > bonusPot) bonus = bonusPot;
            bonusPot -= bonus;
        } else {
            fee = PRICE * (portraits.agentBalance(msg.sender) == 0 ? baseFeeBps : agentFeeBps) / 10000;
            bonusPot += fee;
        }
        payout = PRICE - fee + bonus;
        --circulating;
        _inventory.push(id);
        emit PortraitReturned(id, msg.sender, payout, fee, bonus);
        portraits.transferFrom(msg.sender, address(this), id);
        ink.safeTransfer(msg.sender, payout);
    }

    function setFees(uint16 base, uint16 agent, uint16 bonus) external onlyOwner {
        if (base > 500 || agent > base || bonus > 1000) revert InvalidFees();
        baseFeeBps = base;
        agentFeeBps = agent;
        bonusBps = bonus;
        emit FeesSet(base, agent, bonus);
    }

    function fundBonus(uint256 amount) external nonReentrant {
        if (!funded) revert NotConfigured();
        bonusPot += amount;
        emit BonusFunded(msg.sender, amount);
        _receiveExact(amount);
    }

    function inventoryCount() external view returns (uint256) {
        return _inventory.length;
    }

    function inventoryAt(uint256 index) external view returns (uint256) {
        return _inventory[index];
    }

    /// @notice Donations can make balance larger, but never reduce these segregated liabilities.
    function liabilities() external view returns (uint256) {
        uint256 claimReserve = funded && !released ? (SEATS - claimedCount) * PRICE : 0;
        return claimReserve + (circulating + pendingCount) * PRICE + bonusPot;
    }

    function _receiveExact(uint256 amount) private {
        uint256 beforeBalance = ink.balanceOf(address(this));
        ink.safeTransferFrom(msg.sender, address(this), amount);
        if (ink.balanceOf(address(this)) != beforeBalance + amount) revert NonPlainToken();
    }
}
