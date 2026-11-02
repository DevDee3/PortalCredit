// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {IDefaultEngine} from "../src/interfaces/IDefaultEngine.sol";

/// @dev Adversarial / fairness tests. The system must not let an LP who watches the chain shift a
///      default's loss onto slower LPs, and must not let a late depositor harvest a recovery it never carried.
///      Scenario (from an external review): 100,000 vault, 30,000 principal loan, 40% auction floor.
contract EconomicTest is Base {
    address internal exiter = makeAddr("exiter");

    uint256 internal constant STAYER_START = 80_000e6;

    /// @dev lp holds 80,000 and exiter holds 20,000 of a 100,000 vault; one 30,000-principal loan is open.
    function _scenario() internal returns (uint256 id) {
        _fund(lp, 70_000e6);
        vm.prank(lp);
        vault.deposit(70_000e6, lp);
        _fund(exiter, 20_000e6);
        vm.startPrank(exiter);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(20_000e6, exiter);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 100_000e6);

        id = _mintReceivable(37_500e6, 30 days); // 80% advance => 30,000 principal
        _advance(id);
        assertEq(vault.outstandingPrincipal(), 30_000e6);
    }

    function _exit() internal returns (uint256 got) {
        uint256 sh = vault.balanceOf(exiter);
        vm.prank(exiter);
        got = vault.redeem(sh, exiter, exiter);
    }

    function _stayerValue() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(lp));
    }

    /// @dev Settles a loan at the auction floor: flag (if needed), seize, wait out the auction, liquidate.
    function _settleAtFloor(uint256 id) internal {
        if (_status(id) == IDefaultEngine.Status.Performing) {
            vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
            engine.flagOverdue(id);
        }
        (, , uint64 deadline,,,,,,) = engine.cases(id);
        if (block.timestamp < deadline) vm.warp(deadline);
        engine.seize(id);
        vm.warp(block.timestamp + engine.auctionDuration() + 1);
        _fund(buyer, 40_000e6);
        vm.startPrank(buyer);
        stable.approve(address(vault), type(uint256).max);
        engine.liquidate(id, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ exit after the flag

    function test_flag_books_the_expected_loss_immediately() public {
        uint256 id = _scenario();
        _flag(id);
        // 30,000 principal at a 40% floor => 18,000 write-down as soon as the loan is flagged overdue
        assertEq(vault.totalAssets(), 82_000e6, "NAV must reflect the flagged default");
    }

    function test_exit_after_flag_does_not_shift_loss_to_stayers() public {
        uint256 id = _scenario();
        _flag(id);
        uint256 got = _exit();
        assertEq(got, 16_400e6, "exiter takes its 20% of the 18,000 loss");
        (, , uint64 deadline,,,,,,) = engine.cases(id);
        vm.warp(deadline);
        engine.seize(id);
        assertEq(_stayerValue(), 65_600e6, "stayers lose 18%, same as if nobody had exited");
    }

    // ------------------------------------------------------------ exit before anyone flags

    function test_exit_cannot_beat_a_pending_flag() public {
        uint256 id = _scenario();
        // due + grace has passed, but nobody has called flagOverdue yet
        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
        uint256 got = _exit();
        assertEq(got, 16_400e6, "exit must be priced after the loan is recognised as overdue");
        assertEq(uint8(_status(id)), uint8(IDefaultEngine.Status.Overdue), "redemption flags stale loans itself");
    }

    // ------------------------------------------------------------ late depositors

    function test_no_deposits_while_a_default_is_impaired() public {
        uint256 id = _scenario();
        _flag(id);
        assertEq(vault.maxDeposit(buyer), 0);
        assertEq(vault.maxMint(buyer), 0);
        vm.prank(buyer);
        vm.expectRevert();
        vault.deposit(1_000e6, buyer);

        _settleAtFloor(id);
        assertGt(vault.maxDeposit(buyer), 0, "deposits reopen once the loss is settled");
    }

    function test_late_deposit_cannot_harvest_the_auction_recovery() public {
        uint256 id = _scenario();
        _seize(id);
        address late = makeAddr("late");
        _fund(late, 10_000e6);
        vm.startPrank(late);
        stable.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.deposit(10_000e6, late);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ impairment is reversible

    function test_repaying_an_overdue_loan_restores_nav() public {
        uint256 id = _scenario();
        _flag(id);
        assertEq(vault.totalAssets(), 82_000e6);
        vm.prank(borrower);
        stable.approve(address(vault), type(uint256).max);
        _fund(borrower, 1_000e6);
        vm.prank(borrower);
        vault.repay(id, 30_600e6);
        assertEq(vault.totalImpairment(), 0);
        assertEq(vault.outstandingPrincipal(), 0);
        assertGt(vault.totalAssets(), 100_000e6, "fee is earned, no loss left behind");
    }

    function test_upheld_dispute_clears_the_write_down() public {
        uint256 id = _scenario();
        _flag(id);
        assertEq(vault.totalAssets(), 82_000e6);
        vm.prank(borrower);
        engine.dispute(id, keccak256("paid"));
        arbiter.resolve(id, true, uint64(block.timestamp + 10 days));
        assertEq(vault.totalImpairment(), 0);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_rejected_dispute_keeps_the_write_down() public {
        uint256 id = _scenario();
        _flag(id);
        vm.prank(borrower);
        engine.dispute(id, keccak256("paid"));
        arbiter.resolve(id, false, 0);
        assertEq(vault.totalAssets(), 82_000e6);
    }

    // ------------------------------------------------------------ property: timing never helps an exiter

    /// @notice For any exit time at or after due + grace, the stayer must end no worse off than if the
    ///         exiter had never left (up to rounding dust). Exits before due + grace are legitimate: the
    ///         loan is still performing and nobody can know it will default.
    function testFuzz_late_exit_never_hurts_stayers(uint256 delay) public {
        delay = bound(delay, 0, 12 days);
        uint256 id = _scenario();
        uint256 t0 = uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1;

        uint256 snap = vm.snapshotState();

        // baseline: nobody exits
        vm.warp(t0 + delay);
        _settleAtFloor(id);
        uint256 baseline = _stayerValue();

        vm.revertToState(snap);

        // scenario: the exiter tries to leave at t0 + delay
        vm.warp(t0 + delay);
        uint256 exiterShares = vault.balanceOf(exiter);
        vm.prank(exiter);
        try vault.redeem(exiterShares, exiter, exiter) returns (uint256) {} catch {}
        _settleAtFloor(id);
        uint256 withExit = _stayerValue();

        assertGe(withExit + 100, baseline, "an informed exit must not shift losses onto stayers");
    }
}
