// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Only the Permit2 allowance surface used by these tests; no signature/permit behavior is simulated.
contract PermitAllowance {
    using SafeERC20 for IERC20;

    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }
    mapping(address => mapping(address => mapping(address => Allowance))) public allowances;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowances[msg.sender][token][spender] = Allowance(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowances[from][token][msg.sender];
        require(block.timestamp <= a.expiration && amount <= a.amount, "allowance");
        a.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}
