// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {ReceivableNFT} from "../src/ReceivableNFT.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {DefaultEngine} from "../src/DefaultEngine.sol";
import {ArbiterResolver} from "../src/ArbiterResolver.sol";
import {IDefaultEngine} from "../src/interfaces/IDefaultEngine.sol";

/// @dev Shared deployment and helpers. Defaults: 80% advance rate, 2% fee (20% of it to treasury),
///      5% reserve, 3d grace, 3d dispute window, 2d auction, 40% auction floor.
abstract contract Base is Test {
    MockStable internal stable;
    ReceivableNFT internal nft;
    CreditVault internal vault;
    DefaultEngine internal engine;
    ArbiterResolver internal arbiter;

    address internal treasury = makeAddr("treasury");
    address internal lp = makeAddr("lp");
    address internal borrower = makeAddr("borrower");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant LP_DEPOSIT = 10_000e6;
    uint128 internal constant FACE = 1_000e6;
    uint256 internal constant PRINCIPAL = 800e6; // 80% of FACE
    uint256 internal constant FEE = 16e6; // 2% of PRINCIPAL
    uint256 internal constant DEBT = PRINCIPAL + FEE;

    function setUp() public virtual {
        stable = new MockStable(address(this));
        nft = new ReceivableNFT(address(this));
        vault = new CreditVault(stable, nft, address(this), treasury);
        engine = new DefaultEngine(vault, nft, stable, address(this));
        arbiter = new ArbiterResolver(engine, address(this));

        engine.setResolver(address(arbiter));
        nft.setWiring(address(vault), address(engine));
        vault.setEngine(address(engine));

        _fund(lp, LP_DEPOSIT);
        vm.startPrank(lp);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(LP_DEPOSIT, lp);
        vm.stopPrank();

        _fund(borrower, 5_000e6);
        _fund(buyer, 5_000e6);
        vm.prank(borrower);
        stable.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        stable.approve(address(engine), type(uint256).max);
        vm.prank(buyer);
        stable.approve(address(vault), type(uint256).max);
    }

    function _fund(address who, uint256 amount) internal {
        stable.mint(who, amount);
    }

    function _mintReceivable(uint128 face, uint64 dueIn) internal returns (uint256 id) {
        vm.prank(borrower);
        id = nft.mint(face, uint64(block.timestamp) + dueIn, keccak256("obligor"), "ipfs://invoice");
    }

    function _advance(uint256 id) internal {
        vm.startPrank(borrower);
        nft.approve(address(vault), id);
        vault.advance(id);
        vm.stopPrank();
    }

    /// @dev Mints a FACE receivable due in 30 days and finances it.
    function _financed() internal returns (uint256 id) {
        id = _mintReceivable(FACE, 30 days);
        _advance(id);
    }

    function _status(uint256 id) internal view returns (IDefaultEngine.Status) {
        return engine.statusOf(id);
    }

    /// @dev Moves past due + grace and flags the loan overdue.
    function _flag(uint256 id) internal {
        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
        engine.flagOverdue(id);
    }

    /// @dev Flags, waits out the dispute window and seizes.
    function _seize(uint256 id) internal {
        _flag(id);
        (, , uint64 deadline,,,,,,) = engine.cases(id);
        vm.warp(deadline);
        engine.seize(id);
    }
}
