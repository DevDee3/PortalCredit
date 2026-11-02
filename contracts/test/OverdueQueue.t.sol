// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {DefaultEngine} from "../src/DefaultEngine.sol";
import {IDefaultEngine} from "../src/interfaces/IDefaultEngine.sol";

/// @dev The due-date queue, the stale-loan sync, the exit/deposit gates and the write-down hooks.
contract OverdueQueueTest is Base {
    uint128 internal constant SMALL = 100e6; // 80e6 principal

    function _loan(uint64 dueIn) internal returns (uint256 id) {
        id = _mintReceivable(SMALL, dueIn);
        _advance(id);
    }

    function _repayFull(uint256 id) internal {
        uint256 d = vault.debtOf(id);
        vm.prank(borrower);
        vault.repay(id, d);
    }

    /// @dev Redeems as much as the vault can currently pay out.
    function _redeemMax(address who) internal returns (uint256) {
        uint256 sh = vault.maxRedeem(who);
        vm.prank(who);
        return vault.redeem(sh, who, who);
    }

    // ------------------------------------------------------------ queue bookkeeping

    function test_queue_tracks_performing_loans() public {
        assertEq(vault.dueQueueLength(), 0);
        assertFalse(vault.needsSync());
        uint256 a = _loan(10 days);
        uint256 b = _loan(20 days);
        assertEq(vault.dueQueueLength(), 2);
        assertFalse(vault.needsSync());

        _repayFull(a);
        assertEq(vault.dueQueueLength(), 1);

        vm.warp(uint256(vault.dueDateOf(b)) + engine.gracePeriod());
        assertTrue(vault.needsSync());
        vault.sync(5);
        assertEq(vault.dueQueueLength(), 0);
        assertFalse(vault.needsSync());
        assertEq(uint8(_status(b)), uint8(IDefaultEngine.Status.Overdue));
    }

    function test_removing_the_last_queue_entry() public {
        uint256 a = _loan(10 days);
        uint256 b = _loan(20 days); // pushed last, sits at the end of the array
        _repayFull(b);
        assertEq(vault.dueQueueLength(), 1);
        _repayFull(a);
        assertEq(vault.dueQueueLength(), 0);
    }

    function test_queue_orders_by_due_date_and_flags_oldest_first() public {
        // due offsets chosen so the heap needs both sift-up and sift-down with a smaller right child
        uint64[7] memory offs = [uint64(50 days), 10 days, 60 days, 20 days, 5 days, 40 days, 30 days];
        uint256[7] memory ids;
        for (uint256 i; i < 7; ++i) {
            ids[i] = _loan(offs[i]);
        }
        // repay the earliest (a root removal) so the heap must rebalance
        _repayFull(ids[4]);
        assertEq(vault.dueQueueLength(), 6);

        // recognise exactly the loans due within 25 days (+ grace): offsets 10d and 20d
        vm.warp(block.timestamp + 20 days + engine.gracePeriod() + 1);
        vault.sync(10);
        assertEq(uint8(_status(ids[1])), uint8(IDefaultEngine.Status.Overdue));
        assertEq(uint8(_status(ids[3])), uint8(IDefaultEngine.Status.Overdue));
        assertEq(uint8(_status(ids[6])), uint8(IDefaultEngine.Status.Performing)); // 30d not yet
        assertEq(vault.dueQueueLength(), 4);
    }

    function testFuzz_queue_recognises_exactly_the_overdue_loans(uint64[6] memory offs, uint8 repaySeed, uint32 later)
        public
    {
        uint256[6] memory ids;
        for (uint256 i; i < 6; ++i) {
            offs[i] = uint64(bound(offs[i], 1 days, 90 days));
            ids[i] = _loan(offs[i]);
        }
        uint256 repaid = repaySeed % 6;
        _repayFull(ids[repaid]);

        vm.warp(block.timestamp + bound(later, 0, 120 days));
        vault.sync(20);
        for (uint256 i; i < 6; ++i) {
            bool due = block.timestamp >= uint256(vault.dueDateOf(ids[i])) + engine.gracePeriod();
            IDefaultEngine.Status st = _status(ids[i]);
            if (i == repaid) {
                assertEq(uint8(st), uint8(IDefaultEngine.Status.Repaid));
            } else if (due) {
                assertEq(uint8(st), uint8(IDefaultEngine.Status.Overdue), "overdue loans are recognised");
            } else {
                assertEq(uint8(st), uint8(IDefaultEngine.Status.Performing), "performing loans are untouched");
            }
        }
        assertFalse(vault.needsSync());
    }

    // ------------------------------------------------------------ backlog larger than one call can clear

    function test_backlog_blocks_exit_until_synced() public {
        uint256 maxSteps = vault.MAX_SYNC_STEPS();
        uint256 loans_ = maxSteps + 2;
        for (uint256 i; i < loans_; ++i) {
            _loan(10 days);
        }
        vm.warp(block.timestamp + 10 days + engine.gracePeriod() + 1);
        assertTrue(vault.needsSync());
        assertEq(vault.maxRedeem(lp), 0, "no exits at a stale price");
        assertEq(vault.maxWithdraw(lp), 0);

        // a redemption clears at most MAX_SYNC_STEPS loans, so it still cannot go through
        vm.prank(lp);
        vm.expectRevert();
        vault.redeem(1e6, lp, lp);
        // (the reverted call rolled its partial sync back; the backlog is intact)
        assertEq(vault.dueQueueLength(), loans_);

        vault.sync(loans_);
        assertEq(vault.dueQueueLength(), 0);
        assertGt(vault.maxRedeem(lp), 0);
        assertGt(_redeemMax(lp), 0);
    }

    function test_withdraw_path_also_syncs() public {
        uint256 id = _loan(10 days);
        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, LP_DEPOSIT); // stale until something touches the vault
        vm.prank(lp);
        vault.withdraw(1_000e6, lp, lp);
        assertEq(uint8(_status(id)), uint8(IDefaultEngine.Status.Overdue));
        assertLt(vault.totalAssets(), navBefore - 1_000e6, "withdrawal was priced after the write-down");
    }

    function test_mint_path_syncs_and_is_gated_while_impaired() public {
        uint256 id = _loan(10 days);
        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
        _fund(buyer, 1_000e6);
        vm.prank(buyer);
        vm.expectRevert(); // sync recognises the loan, which opens a write-down, which closes deposits
        vault.mint(1e12, buyer);
        // mint reverted, so nothing was synced; a poke recognises it and the gate holds
        vault.sync(1);
        assertEq(vault.maxMint(buyer), 0);
        assertEq(vault.maxDeposit(buyer), 0);
    }

    function test_deposit_syncs_before_pricing() public {
        // a new depositor never buys in at the stale price: recognition happens first, then the gate closes
        uint256 id = _loan(10 days);
        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
        _fund(buyer, 1_000e6);
        vm.prank(buyer);
        vm.expectRevert();
        vault.deposit(1_000e6, buyer);
    }

    function test_sync_is_blocked_while_paused() public {
        vault.pause();
        vm.expectRevert();
        vault.sync(1);
    }

    // ------------------------------------------------------------ write-down life cycle

    function test_partial_repayment_scales_the_write_down() public {
        uint256 id = _financed(); // principal 800
        _flag(id);
        assertEq(vault.totalImpairment(), 480e6); // 800 * 60%
        (, , , , uint128 principal,,) = vault.loans(id);
        assertEq(principal, 800e6);

        vm.prank(borrower);
        vault.repay(id, FEE + 400e6); // fee first, then half of the principal
        (, , , , principal,,) = vault.loans(id);
        assertEq(principal, 400e6);
        assertEq(vault.totalImpairment(), 240e6, "write-down follows the principal still at risk");
    }

    function test_fee_only_payment_leaves_write_down_untouched() public {
        uint256 id = _financed();
        _flag(id);
        vm.prank(borrower);
        vault.repay(id, FEE);
        assertEq(vault.totalImpairment(), 480e6);
    }

    function test_seize_resizes_write_down_to_the_current_floor() public {
        uint256 id = _financed();
        _flag(id);
        assertEq(vault.totalImpairment(), 480e6); // 40% floor
        engine.setFloorBps(5_000);
        (, , uint64 deadline,,,,,,) = engine.cases(id);
        vm.warp(deadline);
        engine.seize(id);
        assertEq(vault.totalImpairment(), 400e6, "re-sized to a 50% floor at seizure");
    }

    function test_upheld_dispute_requeues_the_loan() public {
        uint256 id = _financed();
        _flag(id);
        assertEq(vault.dueQueueLength(), 0);
        vm.prank(borrower);
        engine.dispute(id, keccak256("paid"));
        arbiter.resolve(id, true, uint64(block.timestamp + 10 days));
        assertEq(vault.dueQueueLength(), 1);
        assertEq(vault.totalImpairment(), 0);

        // and it can go overdue again later
        vm.warp(block.timestamp + 10 days + engine.gracePeriod() + 1);
        vault.sync(1);
        assertEq(uint8(_status(id)), uint8(IDefaultEngine.Status.Overdue));
        assertEq(vault.totalImpairment(), 480e6);
    }

    function test_liquidation_clears_the_write_down_and_reopens_deposits() public {
        uint256 id = _financed();
        _seize(id);
        assertEq(vault.maxDeposit(buyer), 0);
        vm.warp(block.timestamp + engine.auctionDuration() + 1);
        vm.prank(buyer);
        engine.liquidate(id, type(uint256).max);
        assertEq(vault.totalImpairment(), 0);
        assertGt(vault.maxDeposit(buyer), 0);
    }

    // ------------------------------------------------------------ hook guards

    function test_markOverdue_and_clearImpairment_guards() public {
        uint256 id = _financed();
        vm.startPrank(stranger);
        vm.expectRevert();
        vault.markOverdue(id, 4_000);
        vm.expectRevert();
        vault.clearImpairment(id);
        vm.stopPrank();

        vm.startPrank(address(engine));
        vm.expectRevert(CreditVault.NoLoan.selector);
        vault.markOverdue(999, 4_000);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.markOverdue(id, 10_001);
        vm.expectRevert(CreditVault.NoLoan.selector);
        vault.clearImpairment(999);
        vm.stopPrank();
    }

    function test_engine_onOverdue_guards() public {
        uint256 id = _financed();
        vm.prank(stranger);
        vm.expectRevert(DefaultEngine.NotVault.selector);
        engine.onOverdue(id);

        _flag(id); // now Overdue
        vm.prank(address(vault));
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.onOverdue(id);
    }
}
