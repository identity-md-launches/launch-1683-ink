// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {InkVault} from "../../src/InkVault.sol";
import {IInkLiquidity} from "../../src/interfaces/IInk.sol";

contract MockINK is ERC20 {
    constructor(address holder) ERC20("INK", "INK") {
        require(block.chainid != 1, "TEST ONLY");
        _mint(holder, 1000000000 ether);
    }
}

contract MockIMD is ERC20 {
    constructor(address holder) ERC20("Test IMD", "IMD") {
        require(block.chainid != 1, "TEST ONLY");
        _mint(holder, 1000000000 ether);
    }
}

contract MockSeats is ERC721 {
    constructor() ERC721("Synthetic identity.md seats", "TESTSEAT") {
        require(block.chainid != 1, "TEST ONLY");
    }

    function mint(address holder, uint256 id) external {
        _mint(holder, id);
    }
}

contract MockLiquidity is IInkLiquidity {
    address public immutable vault;
    address public immutable ink;
    bool public ready = true;
    bool public fail;
    bool public reenter;
    bool public reentrySucceeded;
    uint256 public received;

    constructor(address vault_, address ink_) {
        vault = vault_;
        ink = ink_;
    }

    function setFail(bool value) external {
        fail = value;
    }

    function setReenter(bool value) external {
        reenter = value;
    }

    function addReleased(uint256 amount) external {
        require(msg.sender == vault, "vault");
        require(!fail, "liquidity failed");
        require(MockINK(ink).balanceOf(address(this)) >= amount, "not pushed");
        received += amount;
        if (reenter) {
            MockINK(ink).approve(vault, 400000 ether);
            (reentrySucceeded,) = vault.call(abi.encodeCall(InkVault.pull, ()));
        }
    }
}

contract TaxToken is ERC20 {
    bool public tax;
    uint8 private immutable _decimals;

    constructor(address holder, uint8 decimals_) ERC20("Test tax", "TAX") {
        require(block.chainid != 1, "TEST ONLY");
        _decimals = decimals_;
        _mint(holder, 1000000000 ether);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function enableTax() external {
        tax = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (tax && from != address(0) && to != address(0) && amount > 0) {
            super._update(from, address(0), amount / 100);
            super._update(from, to, amount - amount / 100);
        } else {
            super._update(from, to, amount);
        }
    }
}
