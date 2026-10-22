// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockStable
/// @notice 6-decimal test stablecoin with a one-time public faucet, for demos on testnet only.
contract MockStable is ERC20, Ownable {
    uint256 public constant FAUCET_AMOUNT = 10_000e6;

    mapping(address => bool) public claimed;

    error AlreadyClaimed();

    constructor(address owner_) ERC20("PortalCredit USD", "pcUSD") Ownable(owner_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function faucet() external {
        if (claimed[msg.sender]) revert AlreadyClaimed();
        claimed[msg.sender] = true;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
