// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDefaultResolver} from "./interfaces/IDefaultResolver.sol";
import {DefaultEngine} from "./DefaultEngine.sol";

/// @title ArbiterResolver
/// @notice Reference resolver: an owner-controlled arbiter (a multisig in production) rules on disputes and can veto
///         the seizure of a specific receivable. It is the stand-in for an external default protocol such as
///         Portaldot's DaaS; swapping it only requires implementing IDefaultResolver and calling setResolver.
contract ArbiterResolver is IDefaultResolver, Ownable {
    DefaultEngine public immutable engine;

    mapping(uint256 => bool) public vetoed;

    error NotEngine();

    event Vetoed(uint256 indexed tokenId, bool vetoed);
    event SeizureNotified(uint256 indexed tokenId);
    event LiquidationNotified(uint256 indexed tokenId, uint256 recovered);

    constructor(DefaultEngine engine_, address owner_) Ownable(owner_) {
        engine = engine_;
    }

    function resolve(uint256 tokenId, bool upheld, uint64 newDueDate) external onlyOwner {
        engine.resolveDispute(tokenId, upheld, newDueDate);
    }

    function setVeto(uint256 tokenId, bool value) external onlyOwner {
        vetoed[tokenId] = value;
        emit Vetoed(tokenId, value);
    }

    function validateDefault(uint256 tokenId, bytes calldata) external view returns (bool) {
        return !vetoed[tokenId];
    }

    function onSeized(uint256 tokenId) external {
        if (msg.sender != address(engine)) revert NotEngine();
        emit SeizureNotified(tokenId);
    }

    function onLiquidated(uint256 tokenId, uint256 recovered) external {
        if (msg.sender != address(engine)) revert NotEngine();
        emit LiquidationNotified(tokenId, recovered);
    }
}
