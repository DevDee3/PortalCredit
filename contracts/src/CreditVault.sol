// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICreditVault} from "./interfaces/ICreditVault.sol";
import {IDefaultEngine} from "./interfaces/IDefaultEngine.sol";
import {ReceivableNFT} from "./ReceivableNFT.sol";

/// @title CreditVault
/// @notice ERC-4626 vault. LPs deposit a stablecoin; borrowers draw advances against receivable NFTs.
///
/// Accounting model
///   totalAssets = idleCash + outstandingPrincipal - totalImpairment
///   - idleCash is tracked internally, so stray token donations cannot move the share price.
///   - The yield is an origination fee, owed on top of principal and paid on repayment.
///   - When the engine seizes collateral the loan is immediately written down to its expected
///     recovery (the auction floor). LPs therefore see the loss when the default is confirmed, not
///     only after liquidation. The write-down is reversed and replaced by the real result at liquidation.
///   - Shares use a 6-decimal virtual offset (OpenZeppelin) to defeat first-depositor inflation attacks.
contract CreditVault is ERC4626, Ownable, Pausable, ReentrancyGuard, ICreditVault {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_ADVANCE_RATE = 9_500;
    uint16 public constant MAX_ORIGINATION_FEE = 1_000;
    uint16 public constant MAX_PROTOCOL_FEE = 5_000;
    uint16 public constant MAX_RESERVE = 2_000;

    struct Loan {
        address borrower;
        bool active;
        bool seized;
        uint64 dueDate;
        uint128 principal;
        uint128 feeOwed;
        uint128 impairment;
    }

    ReceivableNFT public immutable nft;
    IDefaultEngine public engine;
    address public treasury;

    uint256 public idleCash;
    uint256 public outstandingPrincipal;
    uint256 public totalImpairment;

    uint16 public advanceRateBps = 8_000;
    uint16 public originationFeeBps = 200;
    uint16 public protocolFeeBps = 2_000; // share of fees sent to the treasury
    uint16 public reserveBps = 500; // share of NAV kept liquid for withdrawals

    mapping(uint256 => Loan) public loans;

    error ZeroAddress();
    error ZeroAmount();
    error EngineUnset();
    error AlreadySet();
    error NotEngine();
    error NotBorrower();
    error LoanExists();
    error DueDatePassed();
    error InsufficientLiquidity();
    error NotRepayable();
    error NoLoan();
    error NotSeized();
    error BadRecovery();
    error UnbackedYield();
    error ParamOutOfBounds();

    event Advanced(uint256 indexed tokenId, address indexed borrower, uint256 principal, uint256 fee);
    event Repaid(
        uint256 indexed tokenId, address indexed payer, uint256 principalPaid, uint256 feePaid, uint256 protocolCut
    );
    event LoanClosed(uint256 indexed tokenId, address indexed borrower);
    event Seized(uint256 indexed tokenId, uint256 impairment);
    event LiquidationApplied(uint256 indexed tokenId, address indexed payer, uint256 recovered, uint256 shortfall);
    event RecoveryCredited(address indexed payer, uint256 amount);
    event YieldBooked(uint256 amount);
    event EngineSet(address engine);
    event TreasurySet(address treasury);
    event ParameterSet(bytes32 indexed key, uint256 value);

    modifier onlyEngine() {
        if (msg.sender != address(engine)) revert NotEngine();
        _;
    }

    constructor(IERC20 asset_, ReceivableNFT nft_, address owner_, address treasury_)
        ERC20("PortalCredit Share", "pcSHARE")
        ERC4626(asset_)
        Ownable(owner_)
    {
        if (address(nft_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        nft = nft_;
        treasury = treasury_;
    }

    // ------------------------------------------------------------------ admin

    function setEngine(address engine_) external onlyOwner {
        if (address(engine) != address(0)) revert AlreadySet();
        if (engine_ == address(0)) revert ZeroAddress();
        engine = IDefaultEngine(engine_);
        emit EngineSet(engine_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setAdvanceRateBps(uint16 v) external onlyOwner {
        if (v == 0 || v > MAX_ADVANCE_RATE) revert ParamOutOfBounds();
        advanceRateBps = v;
        emit ParameterSet("advanceRateBps", v);
    }

    function setOriginationFeeBps(uint16 v) external onlyOwner {
        if (v > MAX_ORIGINATION_FEE) revert ParamOutOfBounds();
        originationFeeBps = v;
        emit ParameterSet("originationFeeBps", v);
    }

    function setProtocolFeeBps(uint16 v) external onlyOwner {
        if (v > MAX_PROTOCOL_FEE) revert ParamOutOfBounds();
        protocolFeeBps = v;
        emit ParameterSet("protocolFeeBps", v);
    }

    function setReserveBps(uint16 v) external onlyOwner {
        if (v > MAX_RESERVE) revert ParamOutOfBounds();
        reserveBps = v;
        emit ParameterSet("reserveBps", v);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function totalAssets() public view override returns (uint256) {
        return idleCash + outstandingPrincipal - totalImpairment;
    }

    /// @notice Liquid cash that can be lent out or withdrawn while keeping the reserve buffer intact.
    function spendableCash() public view returns (uint256) {
        uint256 reserve = totalAssets().mulDiv(reserveBps, BPS);
        return idleCash > reserve ? idleCash - reserve : 0;
    }

    /// @notice Asset units (6 decimals) redeemable for one whole share.
    function sharePrice() public view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    function utilizationBps() public view returns (uint256) {
        uint256 ta = totalAssets();
        return ta == 0 ? 0 : outstandingPrincipal.mulDiv(BPS, ta);
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return loans[tokenId].active;
    }

    function dueDateOf(uint256 tokenId) external view returns (uint64) {
        return loans[tokenId].dueDate;
    }

    function borrowerOf(uint256 tokenId) external view returns (address) {
        return loans[tokenId].borrower;
    }

    function debtOf(uint256 tokenId) public view returns (uint256) {
        Loan storage loan = loans[tokenId];
        return loan.active ? uint256(loan.principal) + loan.feeOwed : 0;
    }

    // ------------------------------------------------------------------ LP side (ERC-4626)

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 claim = convertToAssets(balanceOf(owner_));
        uint256 cap = spendableCash();
        return claim < cap ? claim : cap;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 held = balanceOf(owner_);
        uint256 cap = convertToShares(spendableCash());
        return held < cap ? held : cap;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotPaused
    {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        super._deposit(caller, receiver, assets, shares);
        idleCash += assets;
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotPaused
    {
        idleCash -= assets;
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ------------------------------------------------------------------ borrower side

    /// @notice Borrow against a receivable you own. The NFT must be approved to this vault first.
    function advance(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 principal, uint256 fee) {
        if (address(engine) == address(0)) revert EngineUnset();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotBorrower();
        if (loans[tokenId].active) revert LoanExists();

        ReceivableNFT.Receivable memory r = nft.receivable(tokenId);
        if (r.dueDate <= block.timestamp) revert DueDatePassed();

        principal = uint256(r.faceValue).mulDiv(advanceRateBps, BPS);
        if (principal == 0) revert ZeroAmount();
        fee = principal.mulDiv(originationFeeBps, BPS);
        if (principal > spendableCash()) revert InsufficientLiquidity();

        loans[tokenId] = Loan({
            borrower: msg.sender,
            active: true,
            seized: false,
            dueDate: r.dueDate,
            principal: principal.toUint128(),
            feeOwed: fee.toUint128(),
            impairment: 0
        });
        outstandingPrincipal += principal;
        idleCash -= principal;

        nft.transferFrom(msg.sender, address(this), tokenId);
        nft.lock(tokenId);
        IERC20(asset()).safeTransfer(msg.sender, principal);
        engine.onAdvanced(tokenId);

        emit Advanced(tokenId, msg.sender, principal, fee);
    }

    /// @notice Repay a loan (anyone may pay). Fees are settled first, then principal. Full repayment
    ///         releases the NFT to the borrower.
    function repay(uint256 tokenId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 principalPaid, uint256 feePaid)
    {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NotRepayable();
        IDefaultEngine.Status s = engine.statusOf(tokenId);
        if (
            s != IDefaultEngine.Status.Performing && s != IDefaultEngine.Status.Overdue
                && s != IDefaultEngine.Status.Disputed
        ) revert NotRepayable();
        if (amount == 0) revert ZeroAmount();

        feePaid = amount < loan.feeOwed ? amount : loan.feeOwed;
        uint256 rest = amount - feePaid;
        principalPaid = rest < loan.principal ? rest : loan.principal;
        // amount > 0 and an active loan always has fee or principal outstanding, so pull > 0.
        uint256 pull = feePaid + principalPaid;

        uint256 protocolCut = feePaid.mulDiv(protocolFeeBps, BPS);
        loan.feeOwed -= feePaid.toUint128();
        loan.principal -= principalPaid.toUint128();
        outstandingPrincipal -= principalPaid;
        idleCash += pull - protocolCut;

        IERC20 token = IERC20(asset());
        token.safeTransferFrom(msg.sender, address(this), pull);
        if (protocolCut > 0) token.safeTransfer(treasury, protocolCut);
        emit Repaid(tokenId, msg.sender, principalPaid, feePaid, protocolCut);

        if (loan.principal == 0 && loan.feeOwed == 0) {
            loan.active = false;
            address borrower = loan.borrower;
            nft.unlock(tokenId);
            nft.transferFrom(address(this), borrower, tokenId);
            engine.onRepaid(tokenId);
            emit LoanClosed(tokenId, borrower);
        }
    }

    // ------------------------------------------------------------------ engine hooks

    function seize(uint256 tokenId, uint16 floorBps) external onlyEngine {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NoLoan();
        if (floorBps > BPS) revert ParamOutOfBounds();

        loan.seized = true;
        uint256 impairment = uint256(loan.principal).mulDiv(BPS - floorBps, BPS);
        loan.impairment = impairment.toUint128();
        totalImpairment += impairment;

        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Seized(tokenId, impairment);
    }

    function setDueDate(uint256 tokenId, uint64 newDueDate) external onlyEngine {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NoLoan();
        loan.dueDate = newDueDate;
        nft.updateDueDate(tokenId, newDueDate);
    }

    function applyLiquidation(uint256 tokenId, uint256 recovered, address payer)
        external
        nonReentrant
        onlyEngine
        returns (uint256 principalShortfall)
    {
        Loan storage loan = loans[tokenId];
        if (!loan.active || !loan.seized) revert NotSeized();
        uint256 principal = loan.principal;
        uint256 fee = loan.feeOwed;
        if (recovered == 0 || recovered > principal + fee || payer == address(0)) revert BadRecovery();

        // Waterfall: principal first, then fee. Any shortfall is a loss to LPs.
        uint256 toPrincipal = recovered < principal ? recovered : principal;
        principalShortfall = principal - toPrincipal;
        uint256 toFee = recovered - toPrincipal;
        uint256 protocolCut = toFee.mulDiv(protocolFeeBps, BPS);

        outstandingPrincipal -= principal;
        totalImpairment -= loan.impairment;
        idleCash += recovered - protocolCut;
        loan.principal = 0;
        loan.feeOwed = 0;
        loan.impairment = 0;
        loan.active = false;

        IERC20 token = IERC20(asset());
        token.safeTransferFrom(payer, address(this), recovered);
        if (protocolCut > 0) token.safeTransfer(treasury, protocolCut);
        nft.unlock(tokenId);

        emit LiquidationApplied(tokenId, payer, recovered, principalShortfall);
    }

    function creditRecovery(address payer, uint256 amount) external nonReentrant onlyEngine {
        if (amount == 0 || payer == address(0)) revert ZeroAmount();
        idleCash += amount;
        IERC20(asset()).safeTransferFrom(payer, address(this), amount);
        emit RecoveryCredited(payer, amount);
    }

    function bookYield(uint256 amount) external nonReentrant onlyEngine {
        if (amount == 0) revert ZeroAmount();
        if (IERC20(asset()).balanceOf(address(this)) < idleCash + amount) revert UnbackedYield();
        idleCash += amount;
        emit YieldBooked(amount);
    }
}
