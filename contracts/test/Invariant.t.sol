// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {MockStable} from "../src/MockStable.sol";
import {ReceivableNFT} from "../src/ReceivableNFT.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {DefaultEngine} from "../src/DefaultEngine.sol";
import {ArbiterResolver} from "../src/ArbiterResolver.sol";
import {IDefaultEngine} from "../src/interfaces/IDefaultEngine.sol";

/// @dev Randomly drives the whole protocol: deposits, withdrawals, originations, repayments, time travel,
///      flagging, seizure, liquidation and recovery. Reverting actions are simply skipped.
contract Handler is Test {
    MockStable internal stable;
    ReceivableNFT internal nft;
    CreditVault internal vault;
    DefaultEngine internal engine;
    ArbiterResolver internal arbiter;
    address internal arbiterOwner;
    address internal lp;
    address internal borrower;
    address internal buyer;

    uint256[] public ids;

    constructor(
        MockStable stable_,
        ReceivableNFT nft_,
        CreditVault vault_,
        DefaultEngine engine_,
        ArbiterResolver arbiter_,
        address arbiterOwner_,
        address lp_,
        address borrower_,
        address buyer_
    ) {
        arbiter = arbiter_;
        arbiterOwner = arbiterOwner_;
        stable = stable_;
        nft = nft_;
        vault = vault_;
        engine = engine_;
        lp = lp_;
        borrower = borrower_;
        buyer = buyer_;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 5_000e6);
        vm.prank(lp);
        try vault.deposit(amount, lp) {} catch {}
    }

    function withdraw(uint256 shareSeed) external {
        uint256 max = vault.maxRedeem(lp);
        if (max == 0) return;
        vm.prank(lp);
        try vault.redeem(bound(shareSeed, 1, max), lp, lp) {} catch {}
    }

    function originate(uint256 faceSeed, uint256 dueSeed) external {
        uint128 face = uint128(bound(faceSeed, 10e6, 3_000e6));
        uint64 due = uint64(block.timestamp + bound(dueSeed, 1 days, 40 days));
        vm.startPrank(borrower);
        uint256 id = nft.mint(face, due, keccak256(abi.encode(faceSeed, dueSeed)), "uri");
        nft.approve(address(vault), id);
        try vault.advance(id) {
            ids.push(id);
        } catch {}
        vm.stopPrank();
    }

    function repay(uint256 idSeed, uint256 amount) external {
        if (ids.length == 0) return;
        uint256 id = _pick(idSeed);
        vm.prank(borrower);
        try vault.repay(id, bound(amount, 1, 1_000e6)) {} catch {}
    }

    function warpForward(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 20 days));
    }

    function flag(uint256 idSeed) external {
        if (ids.length == 0) return;
        try engine.flagOverdue(_pick(idSeed)) {} catch {}
    }

    function seize(uint256 idSeed) external {
        if (ids.length == 0) return;
        try engine.seize(_pick(idSeed)) {} catch {}
    }

    function liquidate(uint256 idSeed) external {
        if (ids.length == 0) return;
        vm.prank(buyer);
        try engine.liquidate(_pick(idSeed), type(uint256).max) {} catch {}
    }

    function syncQueue(uint256 steps) external {
        try vault.sync(bound(steps, 1, 20)) {} catch {}
    }

    function dispute(uint256 idSeed) external {
        if (ids.length == 0) return;
        vm.prank(borrower);
        try engine.dispute(_pick(idSeed), keccak256("evidence")) {} catch {}
    }

    function rule(uint256 idSeed, bool upheld) external {
        if (ids.length == 0) return;
        vm.prank(arbiterOwner);
        try arbiter.resolve(_pick(idSeed), upheld, uint64(block.timestamp + 5 days)) {} catch {}
    }

    function recover(uint256 idSeed, uint256 amount) external {
        if (ids.length == 0) return;
        vm.prank(buyer);
        try engine.recover(_pick(idSeed), bound(amount, 1, 500e6)) {} catch {}
    }
}

contract InvariantTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        _fund(lp, 1e12);
        _fund(borrower, 1e12);
        _fund(buyer, 1e12);
        vm.prank(buyer);
        stable.approve(address(engine), type(uint256).max);
        vm.prank(lp);
        stable.approve(address(vault), type(uint256).max);

        handler = new Handler(stable, nft, vault, engine, arbiter, address(this), lp, borrower, buyer);
        targetContract(address(handler));
    }

    /// @dev Tracked cash never exceeds what the vault actually holds.
    function invariant_cashIsBacked() public view {
        assertGe(stable.balanceOf(address(vault)), vault.idleCash());
    }

    /// @dev The aggregate counters always equal the sum over individual loans.
    function invariant_aggregatesMatchLoans() public view {
        uint256 principalSum;
        uint256 impairmentSum;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            (,,,, uint128 principal,, uint128 impairment) = vault.loans(handler.ids(i));
            principalSum += principal;
            impairmentSum += impairment;
        }
        assertEq(vault.outstandingPrincipal(), principalSum);
        assertEq(vault.totalImpairment(), impairmentSum);
    }

    /// @dev Impairment never exceeds the principal it writes down, so NAV cannot underflow or go negative.
    function invariant_navIsNeverNegative() public view {
        assertLe(vault.totalImpairment(), vault.outstandingPrincipal());
        assertEq(vault.totalAssets(), vault.idleCash() + vault.outstandingPrincipal() - vault.totalImpairment());
    }

    /// @dev LP claims can never exceed the assets backing them.
    function invariant_sharesNeverOverclaim() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets());
    }

    /// @dev Collateral custody follows the loan state.
    function invariant_collateralCustody() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            (, bool active, bool seized,,,,) = vault.loans(id);
            if (active && !seized) assertEq(nft.ownerOf(id), address(vault));
            if (active && seized) assertEq(nft.ownerOf(id), address(engine));
            if (active) assertTrue(nft.locked(id));
        }
    }

    /// @dev The overdue queue holds exactly the loans that are active, unseized and still Performing.
    function invariant_queueMatchesPerformingLoans() public view {
        uint256 performing;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            (, bool active, bool seized,,,,) = vault.loans(id);
            if (active && !seized && engine.statusOf(id) == IDefaultEngine.Status.Performing) performing++;
        }
        assertEq(vault.dueQueueLength(), performing);
    }

    /// @dev A loan is written down exactly when the engine no longer treats it as performing.
    function invariant_writeDownFollowsStatus() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            (, bool active,,, uint128 principal,, uint128 impairment) = vault.loans(id);
            if (!active) {
                assertEq(impairment, 0);
                continue;
            }
            IDefaultEngine.Status st = engine.statusOf(id);
            if (st == IDefaultEngine.Status.Performing) assertEq(impairment, 0);
            else if (principal > 0) assertGt(impairment, 0);
        }
    }

    /// @dev The core fairness property: whenever redemptions are open, no loan is past due + grace
    ///      while still unrecognised, so an exit can never be priced before a visible default.
    function invariant_exitsOnlyAtRecognisedPrice() public view {
        if (vault.maxRedeem(lp) == 0) return;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            (, bool active, bool seized, uint64 dueDate,,,) = vault.loans(id);
            if (active && !seized && engine.statusOf(id) == IDefaultEngine.Status.Performing) {
                assertLt(block.timestamp, uint256(dueDate) + engine.gracePeriod());
            }
        }
    }
}
