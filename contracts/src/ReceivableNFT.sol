// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ReceivableNFT
/// @notice One token per invoice / receivable. While financed ("locked") it can only hop between the
///         vault and the default engine, so a borrower can never move collateral they have borrowed against.
contract ReceivableNFT is ERC721, Ownable {
    struct Receivable {
        uint128 faceValue; // in stablecoin units
        uint64 dueDate;
        address originator;
        bytes32 obligor; // hash / reference of the paying party, kept off-chain
    }

    uint256 public nextId;
    address public vault;
    address public engine;

    mapping(uint256 => Receivable) private _receivables;
    mapping(uint256 => string) private _uris;
    mapping(uint256 => bool) public locked;

    error ZeroAddress();
    error AlreadySet();
    error InvalidReceivable();
    error NotVault();
    error TransferWhileFinanced();

    event ReceivableMinted(
        uint256 indexed tokenId, address indexed originator, uint256 faceValue, uint64 dueDate, bytes32 obligor
    );
    event WiringSet(address vault, address engine);
    event Locked(uint256 indexed tokenId);
    event Unlocked(uint256 indexed tokenId);
    event DueDateUpdated(uint256 indexed tokenId, uint64 dueDate);

    constructor(address owner_) ERC721("Portal Receivable", "RCV") Ownable(owner_) {}

    /// @notice One-time wiring of the two contracts allowed to touch financed collateral.
    function setWiring(address vault_, address engine_) external onlyOwner {
        if (vault != address(0)) revert AlreadySet();
        if (vault_ == address(0) || engine_ == address(0)) revert ZeroAddress();
        vault = vault_;
        engine = engine_;
        emit WiringSet(vault_, engine_);
    }

    function mint(uint128 faceValue, uint64 dueDate, bytes32 obligor, string calldata metadataURI)
        external
        returns (uint256 tokenId)
    {
        if (faceValue == 0 || dueDate <= block.timestamp || obligor == bytes32(0)) revert InvalidReceivable();
        tokenId = ++nextId;
        _receivables[tokenId] =
            Receivable({faceValue: faceValue, dueDate: dueDate, originator: msg.sender, obligor: obligor});
        _uris[tokenId] = metadataURI;
        _mint(msg.sender, tokenId);
        emit ReceivableMinted(tokenId, msg.sender, faceValue, dueDate, obligor);
    }

    function receivable(uint256 tokenId) external view returns (Receivable memory) {
        _requireOwned(tokenId);
        return _receivables[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _uris[tokenId];
    }

    function lock(uint256 tokenId) external {
        if (msg.sender != vault) revert NotVault();
        locked[tokenId] = true;
        emit Locked(tokenId);
    }

    function unlock(uint256 tokenId) external {
        if (msg.sender != vault) revert NotVault();
        locked[tokenId] = false;
        emit Unlocked(tokenId);
    }

    function updateDueDate(uint256 tokenId, uint64 dueDate) external {
        if (msg.sender != vault) revert NotVault();
        _receivables[tokenId].dueDate = dueDate;
        emit DueDateUpdated(tokenId, dueDate);
    }

    /// @dev Enforces the lock on every transfer path (transferFrom, safeTransferFrom, burns).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (locked[tokenId]) {
            bool allowed = (from == vault && to == engine) || (from == engine && to == vault);
            if (!allowed) revert TransferWhileFinanced();
        }
        return super._update(to, tokenId, auth);
    }
}
