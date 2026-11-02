// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base} from "./Base.t.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {DefaultEngine} from "../src/DefaultEngine.sol";
import {ReceivableNFT} from "../src/ReceivableNFT.sol";
import {IDefaultEngine} from "../src/interfaces/IDefaultEngine.sol";
import {IDefaultResolver} from "../src/interfaces/IDefaultResolver.sol";

contract RevertingResolver is IDefaultResolver {
    function validateDefault(uint256, bytes calldata) external pure returns (bool) {
        revert("boom");
    }

    function onSeized(uint256) external pure {
        revert("boom");
    }

    function onLiquidated(uint256, uint256) external pure {
        revert("boom");
    }
}

contract VaultTest is Base {
    // ---------------------------------------------------------------- happy path

    function test_depositMintsSharesAndTracksCash() public view {
        assertEq(vault.totalAssets(), LP_DEPOSIT);
        assertEq(vault.idleCash(), LP_DEPOSIT);
        assertEq(vault.convertToAssets(vault.balanceOf(lp)), LP_DEPOSIT);
    }

    function test_advanceThenFullRepay_paysYieldAndReleasesNft() public {
        uint256 id = _financed();

        assertEq(stable.balanceOf(borrower), 5_000e6 + PRINCIPAL);
        assertEq(nft.ownerOf(id), address(vault));
        assertTrue(nft.locked(id));
        assertEq(vault.outstandingPrincipal(), PRINCIPAL);
        assertEq(vault.totalAssets(), LP_DEPOSIT); // nothing earned until fees are paid
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Performing));

        vm.prank(borrower);
        (uint256 p, uint256 f) = vault.repay(id, DEBT);
        assertEq(p, PRINCIPAL);
        assertEq(f, FEE);

        uint256 protocolCut = (FEE * 2_000) / 10_000;
        assertEq(stable.balanceOf(treasury), protocolCut);
        assertEq(vault.totalAssets(), LP_DEPOSIT + FEE - protocolCut);
        assertEq(vault.outstandingPrincipal(), 0);
        assertEq(nft.ownerOf(id), borrower);
        assertFalse(nft.locked(id));
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Repaid));
        assertGt(vault.sharePrice(), 1e6 - 1);
    }

    function test_partialRepay_settlesFeeFirstAndKeepsCollateral() public {
        uint256 id = _financed();
        vm.prank(borrower);
        (uint256 p, uint256 f) = vault.repay(id, 100e6);
        assertEq(f, FEE);
        assertEq(p, 100e6 - FEE);
        assertEq(nft.ownerOf(id), address(vault));
        assertEq(vault.debtOf(id), DEBT - 100e6);
    }

    function test_repayCapsAtDebt() public {
        uint256 id = _financed();
        uint256 before = stable.balanceOf(borrower);
        vm.prank(borrower);
        vault.repay(id, 5_000e6);
        assertEq(before - stable.balanceOf(borrower), DEBT);
    }

    function test_anyoneCanRepayOnBehalf() public {
        uint256 id = _financed();
        _fund(stranger, DEBT);
        vm.startPrank(stranger);
        stable.approve(address(vault), DEBT);
        vault.repay(id, DEBT);
        vm.stopPrank();
        assertEq(nft.ownerOf(id), borrower); // collateral still goes back to the borrower
    }

    function test_receivableCanBeFinancedAgainAfterRepayment() public {
        uint256 id = _financed();
        vm.prank(borrower);
        vault.repay(id, DEBT);
        _advance(id);
        assertTrue(vault.isActive(id));
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Performing));
    }

    // ---------------------------------------------------------------- guards

    function test_advance_onlyOwnerAndOnlyOnce() public {
        uint256 id = _mintReceivable(FACE, 30 days);
        vm.prank(stranger);
        vm.expectRevert(CreditVault.NotBorrower.selector);
        vault.advance(id);

        _advance(id);
        vm.prank(borrower);
        vm.expectRevert(); // vault owns it now
        vault.advance(id);
    }

    function test_advance_revertsWithoutLiquidity() public {
        // 9_500e6 spendable at 5% reserve; face of 12_000e6 -> 9_600e6 principal
        uint256 id = _mintReceivable(12_000e6, 30 days);
        vm.startPrank(borrower);
        nft.approve(address(vault), id);
        vm.expectRevert(CreditVault.InsufficientLiquidity.selector);
        vault.advance(id);
        vm.stopPrank();
    }

    function test_advance_revertsIfDuePassed() public {
        uint256 id = _mintReceivable(FACE, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(borrower);
        nft.approve(address(vault), id);
        vm.expectRevert(CreditVault.DueDatePassed.selector);
        vault.advance(id);
        vm.stopPrank();
    }

    function test_mintValidation() public {
        vm.startPrank(borrower);
        vm.expectRevert(ReceivableNFT.InvalidReceivable.selector);
        nft.mint(0, uint64(block.timestamp + 1 days), keccak256("o"), "");
        vm.expectRevert(ReceivableNFT.InvalidReceivable.selector);
        nft.mint(FACE, uint64(block.timestamp), keccak256("o"), "");
        vm.expectRevert(ReceivableNFT.InvalidReceivable.selector);
        nft.mint(FACE, uint64(block.timestamp + 1 days), bytes32(0), "");
        vm.stopPrank();
    }

    function test_financedNftCannotBeMovedByAnyoneButVaultAndEngine() public {
        uint256 id = _financed();
        vm.prank(address(vault));
        vm.expectRevert(ReceivableNFT.TransferWhileFinanced.selector);
        nft.transferFrom(address(vault), stranger, id);

        // wiring is one-shot
        vm.expectRevert(ReceivableNFT.AlreadySet.selector);
        nft.setWiring(address(1), address(2));
    }

    function test_repayRevertsForUnknownLoanAndZero() public {
        vm.expectRevert(CreditVault.NotRepayable.selector);
        vault.repay(999, 1);

        uint256 id = _financed();
        vm.prank(borrower);
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.repay(id, 0);
    }

    function test_engineOnlyEntryPoints() public {
        uint256 id = _financed();
        vm.startPrank(stranger);
        vm.expectRevert(CreditVault.NotEngine.selector);
        vault.seize(id, 4_000);
        vm.expectRevert(CreditVault.NotEngine.selector);
        vault.applyLiquidation(id, 1, stranger);
        vm.expectRevert(CreditVault.NotEngine.selector);
        vault.creditRecovery(stranger, 1);
        vm.expectRevert(CreditVault.NotEngine.selector);
        vault.bookYield(1);
        vm.expectRevert(CreditVault.NotEngine.selector);
        vault.setDueDate(id, uint64(block.timestamp + 1));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- LP side

    function test_withdrawLimitedByLiquidityAndReserve() public {
        _financed();
        // idle 9_200e6, reserve 5% of 10_000e6 = 500e6 -> 8_700e6 withdrawable
        assertEq(vault.spendableCash(), 8_700e6);
        assertEq(vault.maxWithdraw(lp), 8_700e6);

        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxRedeem.selector);
        vault.redeem(shares, lp, lp);

        vm.prank(lp);
        vault.withdraw(8_700e6, lp, lp);
        assertEq(stable.balanceOf(lp), 8_700e6);
    }

    function test_pauseBlocksDepositAdvanceAndWithdraw() public {
        uint256 id = _mintReceivable(FACE, 30 days);
        vault.pause();
        assertEq(vault.maxDeposit(lp), 0);
        assertEq(vault.maxWithdraw(lp), 0);

        vm.prank(lp);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1e6, lp);

        vm.startPrank(borrower);
        nft.approve(address(vault), id);
        vm.expectRevert();
        vault.advance(id);
        vm.stopPrank();

        vault.unpause();
        _advance(id);
    }

    function test_donationsDoNotMoveSharePrice() public {
        uint256 before = vault.sharePrice();
        _fund(address(this), 1_000_000e6);
        stable.transfer(address(vault), 1_000_000e6);
        assertEq(vault.sharePrice(), before);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
    }

    function test_firstDepositorInflationAttackFails() public {
        // fresh vault: attacker deposits 1 wei, donates, victim must still receive shares worth ~what they put in
        CreditVault v2 = new CreditVault(stable, nft, address(this), treasury);
        address attacker = makeAddr("attacker");
        _fund(attacker, 1_000_001e6);
        vm.startPrank(attacker);
        stable.approve(address(v2), type(uint256).max);
        v2.deposit(1, attacker);
        stable.transfer(address(v2), 1_000_000e6);
        vm.stopPrank();

        _fund(stranger, 1_000e6);
        vm.startPrank(stranger);
        stable.approve(address(v2), type(uint256).max);
        uint256 shares = v2.deposit(1_000e6, stranger);
        vm.stopPrank();
        assertGt(shares, 0);
        assertApproxEqAbs(v2.convertToAssets(shares), 1_000e6, 1e6);
    }

    function test_zeroDepositReverts() public {
        vm.prank(lp);
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.deposit(0, lp);
    }

    function test_parameterBoundsAndAccess() public {
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setAdvanceRateBps(9_600);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setOriginationFeeBps(1_001);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setProtocolFeeBps(5_001);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setReserveBps(2_001);
        vm.prank(stranger);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        vault.setAdvanceRateBps(5_000);
        vm.expectRevert(CreditVault.AlreadySet.selector);
        vault.setEngine(address(3));
    }

    function testFuzz_advancePrincipalMatchesRate(uint128 face, uint16 rate) public {
        rate = uint16(bound(rate, 1, 9_500));
        face = uint128(bound(face, 1e6, 9_000e6));
        vault.setAdvanceRateBps(rate);
        uint256 id = _mintReceivable(face, 30 days);
        uint256 expected = (uint256(face) * rate) / 10_000;
        if (expected > vault.spendableCash() || expected == 0) return;
        _advance(id);
        (, , , , uint128 principal,,) = vault.loans(id);
        assertEq(principal, expected);
    }
}

contract EngineTest is Base {
    uint256 internal constant FLOOR_PRICE = 326_400_000; // 40% of DEBT

    // ---------------------------------------------------------------- flagging and disputes

    function test_flagOverdue_tooEarlyAndDoubleFlag() public {
        uint256 id = _financed();
        vm.expectRevert(DefaultEngine.NotYet.selector);
        engine.flagOverdue(id);

        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() - 1);
        vm.expectRevert(DefaultEngine.NotYet.selector);
        engine.flagOverdue(id);

        vm.warp(block.timestamp + 1);
        engine.flagOverdue(id);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Overdue));
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.flagOverdue(id);
    }

    function test_flagOverdue_rejectsUnfinancedTokens() public {
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.flagOverdue(12345);
    }

    function test_seizeBlockedDuringDisputeWindow() public {
        uint256 id = _financed();
        _flag(id);
        vm.expectRevert(DefaultEngine.DisputeWindowOpen.selector);
        engine.seize(id);
    }

    function test_disputeUpheld_restoresPerformingExtendsDueAndRefundsBond() public {
        engine.setDisputeBond(50e6);
        uint256 id = _financed();
        _flag(id);

        uint256 before = stable.balanceOf(borrower);
        vm.prank(borrower);
        engine.dispute(id, keccak256("proof of payment"));
        assertEq(stable.balanceOf(borrower), before - 50e6);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Disputed));

        uint64 newDue = uint64(block.timestamp + 10 days);
        arbiter.resolve(id, true, newDue);

        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Performing));
        assertEq(vault.dueDateOf(id), newDue);
        assertEq(nft.receivable(id).dueDate, newDue);
        assertEq(stable.balanceOf(borrower), before);
    }

    function test_disputeRejected_forfeitsBondToLpsAndAllowsSeizure() public {
        engine.setDisputeBond(50e6);
        uint256 id = _financed();
        _flag(id);
        vm.prank(borrower);
        engine.dispute(id, keccak256("weak evidence"));

        uint256 taBefore = vault.totalAssets();
        arbiter.resolve(id, false, 0);
        assertEq(vault.totalAssets(), taBefore + 50e6);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Overdue));

        engine.seize(id); // window is closed immediately after a rejection
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Seized));
    }

    function test_disputeAccessControlAndOneShot() public {
        uint256 id = _financed();
        _flag(id);

        vm.prank(stranger);
        vm.expectRevert(DefaultEngine.NotBorrower.selector);
        engine.dispute(id, bytes32("x"));

        vm.prank(borrower);
        engine.dispute(id, bytes32("x"));

        vm.prank(stranger);
        vm.expectRevert(DefaultEngine.NotResolver.selector);
        engine.resolveDispute(id, true, uint64(block.timestamp + 1 days));

        arbiter.resolve(id, false, 0);
        vm.prank(borrower);
        vm.expectRevert(DefaultEngine.AlreadyDisputed.selector); // one dispute per loan
        engine.dispute(id, bytes32("y"));
    }

    function test_disputeAfterWindowClosedReverts() public {
        uint256 id = _financed();
        _flag(id);
        (, , uint64 deadline,,,,,,) = engine.cases(id);
        vm.warp(deadline);
        vm.prank(borrower);
        vm.expectRevert(DefaultEngine.WindowClosed.selector);
        engine.dispute(id, bytes32("late"));
    }

    function test_upheldDisputeNeedsFutureDueDate() public {
        uint256 id = _financed();
        _flag(id);
        vm.prank(borrower);
        engine.dispute(id, bytes32("x"));
        vm.expectRevert(DefaultEngine.BadDueDate.selector);
        arbiter.resolve(id, true, uint64(block.timestamp));
    }

    function test_expireDispute_whenResolverIsSilent() public {
        engine.setDisputeBond(50e6);
        uint256 id = _financed();
        _flag(id);
        vm.prank(borrower);
        engine.dispute(id, bytes32("x"));

        vm.expectRevert(DefaultEngine.NotYet.selector);
        engine.expireDispute(id);

        uint256 before = stable.balanceOf(borrower);
        vm.warp(block.timestamp + engine.resolutionTimeout());
        engine.expireDispute(id);
        assertEq(stable.balanceOf(borrower), before + 50e6); // not the borrower's fault, bond refunded
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Overdue));
        engine.seize(id);
    }

    function test_repayStillPossibleWhileOverdueButNotAfterSeizure() public {
        uint256 id = _financed();
        _flag(id);
        _fund(stranger, DEBT);
        vm.prank(borrower);
        vault.repay(id, 100e6); // allowed while overdue
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Overdue));

        (, , uint64 deadline,,,,,,) = engine.cases(id);
        vm.warp(deadline);
        engine.seize(id);
        vm.prank(borrower);
        vm.expectRevert(CreditVault.NotRepayable.selector);
        vault.repay(id, 1e6);
    }

    // ---------------------------------------------------------------- seizure and liquidation

    function test_seize_writesLoanDownToFloorImmediately() public {
        uint256 id = _financed();
        assertEq(vault.totalAssets(), LP_DEPOSIT);
        _seize(id);

        uint256 impairment = (PRINCIPAL * 6_000) / 10_000; // 60% of principal
        assertEq(vault.totalImpairment(), impairment);
        assertEq(vault.totalAssets(), LP_DEPOSIT - impairment);
        assertEq(nft.ownerOf(id), address(engine));
    }

    function test_engineHoldsCollateralNobodyElseCanTakeIt() public {
        uint256 id = _financed();
        _seize(id);
        vm.prank(address(engine));
        vm.expectRevert(ReceivableNFT.TransferWhileFinanced.selector);
        nft.transferFrom(address(engine), stranger, id);
    }

    function test_liquidateAtParAfterSeizure_noLossAndFeeEarned() public {
        uint256 id = _financed();
        _seize(id);

        assertEq(engine.currentPrice(id), DEBT);
        vm.prank(buyer);
        engine.liquidate(id, DEBT);

        uint256 protocolCut = (FEE * 2_000) / 10_000;
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Recovered));
        assertEq(vault.totalAssets(), LP_DEPOSIT + FEE - protocolCut);
        assertEq(vault.totalImpairment(), 0);
        assertEq(nft.ownerOf(id), buyer);
        assertFalse(nft.locked(id));
    }

    function test_liquidateAtFloor_recognisesExactLoss() public {
        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration());
        assertEq(engine.currentPrice(id), FLOOR_PRICE);

        vm.prank(buyer);
        engine.liquidate(id, FLOOR_PRICE);

        uint256 shortfall = PRINCIPAL - FLOOR_PRICE;
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Liquidated));
        (,,,,,,,, uint256 recorded) = engine.cases(id);
        assertEq(recorded, shortfall);
        assertEq(vault.totalAssets(), LP_DEPOSIT - shortfall);
        assertEq(vault.totalImpairment(), 0);
        assertEq(vault.outstandingPrincipal(), 0);
    }

    function test_dutchPriceDecaysLinearly() public {
        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration() / 2);
        assertEq(engine.currentPrice(id), DEBT - (DEBT - FLOOR_PRICE) / 2);
        vm.warp(block.timestamp + 10 days);
        assertEq(engine.currentPrice(id), FLOOR_PRICE); // never goes below the floor
    }

    function test_liquidateRespectsSlippageLimit() public {
        uint256 id = _financed();
        _seize(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DefaultEngine.PriceTooHigh.selector, DEBT, DEBT - 1));
        engine.liquidate(id, DEBT - 1);
    }

    function test_recoverThenFullyRecovered_restoresLpValue() public {
        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration());
        vm.prank(buyer);
        engine.liquidate(id, FLOOR_PRICE);
        uint256 shortfall = PRINCIPAL - FLOOR_PRICE;

        _fund(stranger, shortfall);
        vm.startPrank(stranger);
        stable.approve(address(vault), type(uint256).max);
        vm.expectRevert(DefaultEngine.ExceedsShortfall.selector);
        engine.recover(id, shortfall + 1);
        engine.recover(id, shortfall / 2);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Liquidated));
        engine.recover(id, shortfall - shortfall / 2);
        vm.stopPrank();

        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Recovered));
        assertEq(vault.totalAssets(), LP_DEPOSIT); // principal fully restored (the fee is forgone)
    }

    function test_writeOff_ownerAnytimeStrangerOnlyAfterRecoveryPeriod() public {
        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration());
        vm.prank(buyer);
        engine.liquidate(id, FLOOR_PRICE);

        vm.prank(stranger);
        vm.expectRevert(DefaultEngine.NotYet.selector);
        engine.writeOff(id);

        vm.warp(block.timestamp + engine.recoveryPeriod());
        vm.prank(stranger);
        engine.writeOff(id);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.WrittenOff));

        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.recover(id, 1);
    }

    function test_writeOff_ownerImmediately() public {
        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration());
        vm.prank(buyer);
        engine.liquidate(id, FLOOR_PRICE);
        engine.writeOff(id);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.WrittenOff));
    }

    function test_liquidatedReceivableCanNeverBeFinancedAgain() public {
        uint256 id = _financed();
        _seize(id);
        vm.prank(buyer);
        engine.liquidate(id, DEBT);

        // the engine refuses to restart the lifecycle of a receivable that already defaulted
        vm.prank(address(vault));
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.onAdvanced(id);
    }

    function test_losingLpsBearLossProRata() public {
        address lp2 = makeAddr("lp2");
        _fund(lp2, 10_000e6);
        vm.startPrank(lp2);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, lp2);
        vm.stopPrank();

        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration());
        vm.prank(buyer);
        engine.liquidate(id, FLOOR_PRICE);

        uint256 v1 = vault.convertToAssets(vault.balanceOf(lp));
        uint256 v2 = vault.convertToAssets(vault.balanceOf(lp2));
        assertApproxEqAbs(v1, v2, 2);
        assertApproxEqAbs(v1 + v2, 20_000e6 - (PRINCIPAL - FLOOR_PRICE), 4);
    }

    // ---------------------------------------------------------------- resolver behaviour

    function test_resolverVetoBlocksSeizure() public {
        uint256 id = _financed();
        _flag(id);
        arbiter.setVeto(id, true);
        (, , uint64 deadline,,,,,,) = engine.cases(id);
        vm.warp(deadline);
        vm.expectRevert(DefaultEngine.DefaultNotValidated.selector);
        engine.seize(id);

        arbiter.setVeto(id, false);
        engine.seize(id);
    }

    function test_brokenResolverCannotBlockSeizureOrLiquidation() public {
        engine.setResolver(address(new RevertingResolver()));
        uint256 id = _financed();
        _seize(id);
        vm.prank(buyer);
        engine.liquidate(id, DEBT);
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Recovered));
    }

    function test_resolverHooksOnlyCallableByEngine() public {
        vm.prank(stranger);
        vm.expectRevert();
        arbiter.onSeized(1);
    }

    function test_timelineRecordsEveryTransition() public {
        uint256 id = _financed();
        _seize(id);
        vm.prank(buyer);
        engine.liquidate(id, DEBT);
        DefaultEngine.Checkpoint[] memory t = engine.timeline(id);
        assertEq(t.length, 4); // Performing, Overdue, Seized, Recovered
        assertEq(uint256(t[0].status), uint256(IDefaultEngine.Status.Performing));
        assertEq(uint256(t[1].status), uint256(IDefaultEngine.Status.Overdue));
        assertEq(uint256(t[2].status), uint256(IDefaultEngine.Status.Seized));
        assertEq(uint256(t[3].status), uint256(IDefaultEngine.Status.Recovered));
    }

    function test_engineParamBoundsAndHooksAccess() public {
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setGracePeriod(91 days);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setAuctionDuration(0);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setFloorBps(999);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setFloorBps(10_001);

        vm.prank(stranger);
        vm.expectRevert(DefaultEngine.NotVault.selector);
        engine.onAdvanced(1);
        vm.prank(stranger);
        vm.expectRevert(DefaultEngine.NotVault.selector);
        engine.onRepaid(1);
    }

    function test_resolverMustBeContractOrZero() public {
        vm.expectRevert(DefaultEngine.NotAContract.selector);
        engine.setResolver(makeAddr("eoa"));
        engine.setResolver(address(0)); // resolver can be disabled
        uint256 id = _financed();
        _seize(id); // still works with no resolver
        assertEq(uint256(_status(id)), uint256(IDefaultEngine.Status.Seized));
    }

    function test_pausedEngineBlocksTransitions() public {
        uint256 id = _financed();
        vm.warp(uint256(vault.dueDateOf(id)) + engine.gracePeriod() + 1);
        engine.pause();
        vm.expectPartialRevert(bytes4(keccak256("EnforcedPause()")));
        engine.flagOverdue(id);
    }
}
