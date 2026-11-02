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
///   - A loan is written down to its expected recovery (the auction floor) the moment it is recognised
///     as overdue, i.e. when the engine flags it or when the vault's own stale-loan sync does. LPs
///     therefore see the loss when the default becomes visible on chain, not days later. The write-down
///     is scaled down on partial repayment, cleared on full repayment or an upheld dispute, and replaced
///     by the real result at liquidation.
///   - Timing games are closed on both sides. Before any deposit or withdrawal the vault recognises
///     loans whose due date plus grace has passed (a min-heap by due date, bounded work per call), and
///     redemptions are refused while an unrecognised overdue loan remains. Deposits are refused while any
///     write-down is open, so a late depositor cannot buy shares at a depressed price and then share in
///     an auction recovery it never carried.
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
    /// @notice Max queue entries processed by one deposit/withdraw call; `sync` can drain more.
    uint256 public constant MAX_SYNC_STEPS = 8;

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

    /// @dev Min-heap of (dueDate << 192 | tokenId) holding exactly the loans that are active, not seized
    ///      and still Performing in the engine. A loan leaves the heap when it is repaid, flagged overdue
    ///      or seized, and is re-queued with its new due date if a dispute is upheld.
    uint256[] private _dueHeap;
    /// @dev tokenId => index in `_dueHeap` plus one (0 means not queued).
    mapping(uint256 => uint256) private _heapPos;

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
    event Impaired(uint256 indexed tokenId, uint256 impairment);
    event ImpairmentCleared(uint256 indexed tokenId);
    event LiquidationApplied(uint256 indexed tokenId, address indexed payer, uint256 recovered, uint256 shortfall);
    event RecoveryCredited(address indexed payer, uint256 amount);
    event YieldBooked(uint256 amount);
    event EngineSet(address indexed engine);
    event TreasurySet(address indexed treasury);
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

    /// @notice True when a loan is past due + grace but not yet recognised, so the share price is stale.
    function needsSync() public view returns (bool) {
        if (_dueHeap.length == 0) return false;
        return block.timestamp >= (_dueHeap[0] >> 192) + engine.gracePeriod();
    }

    function dueQueueLength() external view returns (uint256) {
        return _dueHeap.length;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return (paused() || totalImpairment > 0 || needsSync()) ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return (paused() || totalImpairment > 0 || needsSync()) ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused() || needsSync()) return 0;
        uint256 claim = convertToAssets(balanceOf(owner_));
        uint256 cap = spendableCash();
        return claim < cap ? claim : cap;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused() || needsSync()) return 0;
        uint256 held = balanceOf(owner_);
        uint256 cap = convertToShares(spendableCash());
        return held < cap ? held : cap;
    }

    // Every entry point that prices shares first recognises overdue loans, so the price is never stale.

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _syncOverdue(MAX_SYNC_STEPS);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _syncOverdue(MAX_SYNC_STEPS);
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _syncOverdue(MAX_SYNC_STEPS);
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _syncOverdue(MAX_SYNC_STEPS);
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Permissionless: recognise up to `maxSteps` overdue loans (and discard stale queue entries).
    function sync(uint256 maxSteps) external nonReentrant whenNotPaused {
        _syncOverdue(maxSteps);
    }

    // The public entry points above hold the reentrancy lock and the pause check for the whole call.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        super._deposit(caller, receiver, assets, shares);
        idleCash += assets;
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
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
        _heapPush(r.dueDate, tokenId);

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
        if (principalPaid > 0 && loan.impairment > 0) {
            // the write-down follows the principal that is still at risk
            uint256 scaled = uint256(loan.impairment).mulDiv(loan.principal, uint256(loan.principal) + principalPaid);
            totalImpairment -= uint256(loan.impairment) - scaled;
            loan.impairment = scaled.toUint128();
        }
        idleCash += pull - protocolCut;

        IERC20 token = IERC20(asset());
        token.safeTransferFrom(msg.sender, address(this), pull);
        if (protocolCut > 0) token.safeTransfer(treasury, protocolCut);
        emit Repaid(tokenId, msg.sender, principalPaid, feePaid, protocolCut);

        if (loan.principal == 0 && loan.feeOwed == 0) {
            loan.active = false;
            _heapRemove(tokenId);
            address borrower = loan.borrower;
            nft.unlock(tokenId);
            nft.transferFrom(address(this), borrower, tokenId);
            engine.onRepaid(tokenId);
            emit LoanClosed(tokenId, borrower);
        }
    }

    // ------------------------------------------------------------------ engine hooks

    function markOverdue(uint256 tokenId, uint16 floorBps) external onlyEngine {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NoLoan();
        if (floorBps > BPS) revert ParamOutOfBounds();
        _heapRemove(tokenId); // recognised now; no longer waiting to be flagged
        _impair(loan, tokenId, floorBps);
    }

    function clearImpairment(uint256 tokenId) external onlyEngine {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NoLoan();
        totalImpairment -= loan.impairment;
        loan.impairment = 0;
        emit ImpairmentCleared(tokenId);
    }

    function seize(uint256 tokenId, uint16 floorBps) external onlyEngine {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NoLoan();
        if (floorBps > BPS) revert ParamOutOfBounds();

        loan.seized = true;
        _heapRemove(tokenId);
        _impair(loan, tokenId, floorBps); // normally already booked at flag time; re-sized to the current floor

        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Seized(tokenId, loan.impairment);
    }

    function setDueDate(uint256 tokenId, uint64 newDueDate) external onlyEngine {
        Loan storage loan = loans[tokenId];
        if (!loan.active || loan.seized) revert NoLoan();
        loan.dueDate = newDueDate;
        _heapRemove(tokenId);
        _heapPush(newDueDate, tokenId);
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
        // engine-only; `payer` is the engine's own msg.sender, who approved this vault
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(payer, address(this), recovered);
        if (protocolCut > 0) token.safeTransfer(treasury, protocolCut);
        nft.unlock(tokenId);

        emit LiquidationApplied(tokenId, payer, recovered, principalShortfall);
    }

    function creditRecovery(address payer, uint256 amount) external nonReentrant onlyEngine {
        if (amount == 0 || payer == address(0)) revert ZeroAmount();
        idleCash += amount;
        // engine-only; `payer` is the engine's own msg.sender, who approved this vault
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(asset()).safeTransferFrom(payer, address(this), amount);
        emit RecoveryCredited(payer, amount);
    }

    function bookYield(uint256 amount) external nonReentrant onlyEngine {
        if (amount == 0) revert ZeroAmount();
        if (IERC20(asset()).balanceOf(address(this)) < idleCash + amount) revert UnbackedYield();
        idleCash += amount;
        emit YieldBooked(amount);
    }

    // ------------------------------------------------------------------ overdue recognition

    /// @dev Sets the loan's write-down to principal * (1 - floor) and keeps `totalImpairment` in step.
    function _impair(Loan storage loan, uint256 tokenId, uint16 floorBps_) private {
        uint256 impairment = uint256(loan.principal).mulDiv(BPS - floorBps_, BPS);
        totalImpairment = totalImpairment - loan.impairment + impairment;
        loan.impairment = impairment.toUint128();
        emit Impaired(tokenId, impairment);
    }

    /// @dev Recognises loans whose due date + grace has passed, oldest first. Bounded by `maxSteps`.
    // the engine is a trusted, owner-wired contract, entry points hold the lock, work is bounded by maxSteps
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events,calls-loop
    function _syncOverdue(uint256 maxSteps) private {
        if (_dueHeap.length == 0) return;
        uint256 grace = engine.gracePeriod();
        for (uint256 i; i < maxSteps && _dueHeap.length > 0; ++i) {
            uint256 top = _dueHeap[0];
            if (block.timestamp < (top >> 192) + grace) break;

            uint256 tokenId = top & type(uint192).max;
            _heapRemove(tokenId);
            _impair(loans[tokenId], tokenId, engine.floorBps());
            engine.onOverdue(tokenId);
        }
    }

    function _heapPush(uint64 due, uint256 tokenId) private {
        // token ids are sequential and far below 2**192, so they fit under the due date in the packed key
        _dueHeap.push((uint256(due) << 192) | tokenId);
        _siftUp(_dueHeap.length - 1);
    }

    /// @dev No-op when the loan is not queued (already flagged, seized or closed).
    function _heapRemove(uint256 tokenId) private {
        uint256 pos = _heapPos[tokenId];
        if (pos == 0) return;
        uint256 i = pos - 1;
        uint256 lastIndex = _dueHeap.length - 1;
        uint256 last = _dueHeap[lastIndex];
        _dueHeap.pop();
        delete _heapPos[tokenId];
        if (i == lastIndex) return;
        _dueHeap[i] = last;
        _heapPos[last & type(uint192).max] = i + 1;
        _siftDown(i);
        _siftUp(i);
    }

    function _siftUp(uint256 i) private {
        uint256 key = _dueHeap[i];
        while (i > 0) {
            uint256 parent = (i - 1) / 2;
            uint256 parentKey = _dueHeap[parent];
            if (parentKey <= key) break;
            _dueHeap[i] = parentKey;
            _heapPos[parentKey & type(uint192).max] = i + 1;
            i = parent;
        }
        _dueHeap[i] = key;
        _heapPos[key & type(uint192).max] = i + 1;
    }

    function _siftDown(uint256 i) private {
        uint256 n = _dueHeap.length;
        uint256 key = _dueHeap[i];
        while (true) {
            uint256 child = 2 * i + 1;
            if (child >= n) break;
            if (child + 1 < n && _dueHeap[child + 1] < _dueHeap[child]) ++child;
            uint256 childKey = _dueHeap[child];
            if (childKey >= key) break;
            _dueHeap[i] = childKey;
            _heapPos[childKey & type(uint192).max] = i + 1;
            i = child;
        }
        _dueHeap[i] = key;
        _heapPos[key & type(uint192).max] = i + 1;
    }
}
