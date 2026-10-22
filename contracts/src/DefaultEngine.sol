// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDefaultEngine} from "./interfaces/IDefaultEngine.sol";
import {IDefaultResolver} from "./interfaces/IDefaultResolver.sol";
import {ICreditVault} from "./interfaces/ICreditVault.sol";
import {ReceivableNFT} from "./ReceivableNFT.sol";

/// @title DefaultEngine
/// @notice Permissionless, fully on-chain default lifecycle for financed receivables.
///
///   Performing --flagOverdue--> Overdue --dispute--> Disputed --resolve--> Performing (upheld)
///                                  |                    |                     or Overdue (rejected/expired)
///                                  +--seize (window over)--> Seized --liquidate--> Liquidated | Recovered
///                                                                                   Liquidated --recover--> Recovered
///                                                                                   Liquidated --writeOff--> WrittenOff
///
/// Design notes
///   - Every transition is permissionless except dispute resolution (the resolver) and early write-off (owner).
///   - Liquidation is a Dutch auction: the buyout price decays linearly from the full debt to `floorBps` of it.
///     Anyone can buy the collateral at the current price, so recovery does not depend on a trusted liquidator.
///   - A resolver that reverts can never block seizure or liquidation: hooks are best-effort. Only an explicit
///     `false` from `validateDefault` vetoes a seizure.
///   - If the resolver never rules on a dispute, anyone can expire it after `resolutionTimeout` (bond refunded).
contract DefaultEngine is Ownable, Pausable, ReentrancyGuard, IDefaultEngine {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint64 public constant MAX_WINDOW = 90 days;
    uint16 public constant MIN_FLOOR_BPS = 1_000;

    struct Case {
        Status status;
        bool disputeUsed;
        uint64 disputeDeadline; // end of the window in which the borrower may dispute / seizure becomes possible
        uint64 disputedAt;
        uint64 seizedAt;
        uint64 liquidatedAt;
        bytes32 evidence;
        uint256 bond;
        uint256 shortfall; // principal not yet recovered after liquidation
    }

    struct Checkpoint {
        Status status;
        uint64 timestamp;
        bytes32 ref;
    }

    ICreditVault public immutable vault;
    ReceivableNFT public immutable nft;
    IERC20 public immutable stable;

    address public resolver;
    uint64 public gracePeriod = 3 days;
    uint64 public disputeWindow = 3 days;
    uint64 public auctionDuration = 2 days;
    uint64 public resolutionTimeout = 7 days;
    uint64 public recoveryPeriod = 30 days;
    uint16 public floorBps = 4_000;
    uint256 public disputeBond;

    mapping(uint256 => Case) public cases;
    mapping(uint256 => Checkpoint[]) private _timeline;

    error ZeroAddress();
    error NotAContract();
    error ZeroAmount();
    error BadStatus();
    error NotYet();
    error NotVault();
    error NotBorrower();
    error NotResolver();
    error AlreadyDisputed();
    error WindowClosed();
    error DisputeWindowOpen();
    error DefaultNotValidated();
    error BadDueDate();
    error PriceTooHigh(uint256 price, uint256 maxPrice);
    error ExceedsShortfall();
    error ParamOutOfBounds();

    event FlaggedOverdue(uint256 indexed tokenId, uint64 disputeDeadline);
    event Disputed(uint256 indexed tokenId, address indexed borrower, bytes32 evidence, uint256 bond);
    event DisputeResolved(uint256 indexed tokenId, bool upheld, uint64 newDueDate);
    event DisputeExpired(uint256 indexed tokenId);
    event Seized(uint256 indexed tokenId);
    event Liquidated(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 shortfall);
    event Recovered(uint256 indexed tokenId, address indexed payer, uint256 amount, uint256 shortfallLeft);
    event WrittenOff(uint256 indexed tokenId, uint256 loss);
    event ResolverSet(address resolver);
    event ParameterSet(bytes32 indexed key, uint256 value);

    modifier onlyVault() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    constructor(ICreditVault vault_, ReceivableNFT nft_, IERC20 stable_, address owner_) Ownable(owner_) {
        if (address(vault_) == address(0) || address(nft_) == address(0) || address(stable_) == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        nft = nft_;
        stable = stable_;
    }

    // ------------------------------------------------------------------ admin

    /// @dev address(0) disables the resolver. A non-contract address is rejected because a failed ABI decode of
    ///      empty return data is not caught by the try/catch in `seize`, which would block seizure.
    function setResolver(address resolver_) external onlyOwner {
        if (resolver_ != address(0) && resolver_.code.length == 0) revert NotAContract();
        resolver = resolver_;
        emit ResolverSet(resolver_);
    }

    function setGracePeriod(uint64 v) external onlyOwner {
        if (v > MAX_WINDOW) revert ParamOutOfBounds();
        gracePeriod = v;
        emit ParameterSet("gracePeriod", v);
    }

    function setDisputeWindow(uint64 v) external onlyOwner {
        if (v > MAX_WINDOW) revert ParamOutOfBounds();
        disputeWindow = v;
        emit ParameterSet("disputeWindow", v);
    }

    function setAuctionDuration(uint64 v) external onlyOwner {
        if (v == 0 || v > MAX_WINDOW) revert ParamOutOfBounds();
        auctionDuration = v;
        emit ParameterSet("auctionDuration", v);
    }

    function setResolutionTimeout(uint64 v) external onlyOwner {
        if (v == 0 || v > MAX_WINDOW) revert ParamOutOfBounds();
        resolutionTimeout = v;
        emit ParameterSet("resolutionTimeout", v);
    }

    function setRecoveryPeriod(uint64 v) external onlyOwner {
        if (v > 365 days) revert ParamOutOfBounds();
        recoveryPeriod = v;
        emit ParameterSet("recoveryPeriod", v);
    }

    function setFloorBps(uint16 v) external onlyOwner {
        if (v < MIN_FLOOR_BPS || v > BPS) revert ParamOutOfBounds();
        floorBps = v;
        emit ParameterSet("floorBps", v);
    }

    function setDisputeBond(uint256 v) external onlyOwner {
        disputeBond = v;
        emit ParameterSet("disputeBond", v);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function statusOf(uint256 tokenId) external view returns (Status) {
        return cases[tokenId].status;
    }

    function timeline(uint256 tokenId) external view returns (Checkpoint[] memory) {
        return _timeline[tokenId];
    }

    /// @notice Current Dutch-auction price to buy a seized receivable (0 if it is not in auction).
    function currentPrice(uint256 tokenId) public view returns (uint256) {
        Case storage c = cases[tokenId];
        if (c.status != Status.Seized) return 0;
        uint256 debt = vault.debtOf(tokenId);
        uint256 floorPrice = (debt * floorBps) / BPS;
        uint256 elapsed = block.timestamp - c.seizedAt;
        if (elapsed >= auctionDuration) return floorPrice;
        return debt - ((debt - floorPrice) * elapsed) / auctionDuration;
    }

    // ------------------------------------------------------------------ vault hooks

    function onAdvanced(uint256 tokenId) external onlyVault {
        Status s = cases[tokenId].status;
        // A receivable that went through default (or is mid-default) can never be financed again.
        if (s != Status.None && s != Status.Repaid) revert BadStatus();
        delete cases[tokenId];
        _set(tokenId, Status.Performing, bytes32(0));
    }

    function onRepaid(uint256 tokenId) external onlyVault {
        _set(tokenId, Status.Repaid, bytes32(0));
    }

    // ------------------------------------------------------------------ lifecycle

    /// @notice Anyone can flag a loan once it is past due plus the grace period.
    function flagOverdue(uint256 tokenId) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Performing || !vault.isActive(tokenId)) revert BadStatus();
        if (block.timestamp < uint256(vault.dueDateOf(tokenId)) + gracePeriod) revert NotYet();

        c.disputeDeadline = uint64(block.timestamp) + disputeWindow;
        _set(tokenId, Status.Overdue, bytes32(0));
        emit FlaggedOverdue(tokenId, c.disputeDeadline);
    }

    /// @notice The borrower contests the default once, inside the window, posting an optional bond.
    function dispute(uint256 tokenId, bytes32 evidence) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Overdue) revert BadStatus();
        if (msg.sender != vault.borrowerOf(tokenId)) revert NotBorrower();
        if (c.disputeUsed) revert AlreadyDisputed();
        if (block.timestamp >= c.disputeDeadline) revert WindowClosed();

        c.disputeUsed = true;
        c.disputedAt = uint64(block.timestamp);
        c.evidence = evidence;
        uint256 bond = disputeBond;
        c.bond = bond;
        _set(tokenId, Status.Disputed, evidence);
        if (bond > 0) stable.safeTransferFrom(msg.sender, address(this), bond);
        emit Disputed(tokenId, msg.sender, evidence, bond);
    }

    /// @notice Resolver ruling. Upheld: loan returns to Performing with a new due date and the bond is refunded.
    ///         Rejected: the bond is forfeited to LPs and the loan can be seized immediately.
    function resolveDispute(uint256 tokenId, bool upheld, uint64 newDueDate) external nonReentrant {
        if (msg.sender != resolver) revert NotResolver();
        Case storage c = cases[tokenId];
        if (c.status != Status.Disputed) revert BadStatus();

        uint256 bond = c.bond;
        c.bond = 0;
        if (upheld) {
            if (newDueDate <= block.timestamp) revert BadDueDate();
            vault.setDueDate(tokenId, newDueDate);
            _set(tokenId, Status.Performing, "upheld");
            if (bond > 0) stable.safeTransfer(vault.borrowerOf(tokenId), bond);
        } else {
            c.disputeDeadline = uint64(block.timestamp);
            _set(tokenId, Status.Overdue, "rejected");
            if (bond > 0) {
                stable.safeTransfer(address(vault), bond);
                vault.bookYield(bond);
            }
        }
        emit DisputeResolved(tokenId, upheld, upheld ? newDueDate : 0);
    }

    /// @notice If the resolver never rules, anyone can expire the dispute. The bond is refunded to the borrower.
    function expireDispute(uint256 tokenId) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Disputed) revert BadStatus();
        if (block.timestamp < uint256(c.disputedAt) + resolutionTimeout) revert NotYet();

        uint256 bond = c.bond;
        c.bond = 0;
        c.disputeDeadline = uint64(block.timestamp);
        _set(tokenId, Status.Overdue, "expired");
        if (bond > 0) stable.safeTransfer(vault.borrowerOf(tokenId), bond);
        emit DisputeExpired(tokenId);
    }

    /// @notice Take custody of the collateral once the dispute window has closed.
    function seize(uint256 tokenId) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Overdue) revert BadStatus();
        if (block.timestamp < c.disputeDeadline) revert DisputeWindowOpen();

        address r = resolver;
        if (r != address(0)) {
            // fail-open on resolver errors, fail-closed on an explicit veto
            try IDefaultResolver(r).validateDefault(tokenId, abi.encode(c.evidence)) returns (bool ok) {
                if (!ok) revert DefaultNotValidated();
            } catch {}
        }

        vault.seize(tokenId, floorBps);
        c.seizedAt = uint64(block.timestamp);
        _set(tokenId, Status.Seized, bytes32(0));
        emit Seized(tokenId);

        if (r != address(0)) {
            try IDefaultResolver(r).onSeized(tokenId) {} catch {}
        }
    }

    /// @notice Buy the collateral at the current auction price. `maxPrice` protects against price changes.
    function liquidate(uint256 tokenId, uint256 maxPrice) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Seized) revert BadStatus();
        uint256 price = currentPrice(tokenId);
        if (price > maxPrice) revert PriceTooHigh(price, maxPrice);

        uint256 shortfall = vault.applyLiquidation(tokenId, price, msg.sender);
        nft.transferFrom(address(this), msg.sender, tokenId);

        c.shortfall = shortfall;
        c.liquidatedAt = uint64(block.timestamp);
        _set(tokenId, shortfall == 0 ? Status.Recovered : Status.Liquidated, bytes32(price));
        emit Liquidated(tokenId, msg.sender, price, shortfall);

        address r = resolver;
        if (r != address(0)) {
            try IDefaultResolver(r).onLiquidated(tokenId, price) {} catch {}
        }
    }

    /// @notice Anyone (borrower, insurer, the asset buyer) can pay back part of the remaining shortfall to LPs.
    function recover(uint256 tokenId, uint256 amount) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Liquidated) revert BadStatus();
        if (amount == 0) revert ZeroAmount();
        if (amount > c.shortfall) revert ExceedsShortfall();

        c.shortfall -= amount;
        vault.creditRecovery(msg.sender, amount);
        emit Recovered(tokenId, msg.sender, amount, c.shortfall);
        if (c.shortfall == 0) _set(tokenId, Status.Recovered, bytes32("recovered"));
    }

    /// @notice Accept the remaining shortfall as a loss. Owner at any time, anyone after `recoveryPeriod`.
    function writeOff(uint256 tokenId) external nonReentrant whenNotPaused {
        Case storage c = cases[tokenId];
        if (c.status != Status.Liquidated) revert BadStatus();
        if (msg.sender != owner() && block.timestamp < uint256(c.liquidatedAt) + recoveryPeriod) revert NotYet();

        _set(tokenId, Status.WrittenOff, bytes32("writeoff"));
        emit WrittenOff(tokenId, c.shortfall);
    }

    // ------------------------------------------------------------------ internal

    function _set(uint256 tokenId, Status status, bytes32 ref) internal {
        cases[tokenId].status = status;
        _timeline[tokenId].push(Checkpoint({status: status, timestamp: uint64(block.timestamp), ref: ref}));
    }
}
