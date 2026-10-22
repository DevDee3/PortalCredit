// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {MockStable} from "../src/MockStable.sol";
import {ReceivableNFT} from "../src/ReceivableNFT.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {DefaultEngine} from "../src/DefaultEngine.sol";
import {ArbiterResolver} from "../src/ArbiterResolver.sol";
import {IDefaultEngine} from "../src/interfaces/IDefaultEngine.sol";

/// @dev Admin surface, guard clauses and engine-only hooks, so every line and branch is exercised.
contract CoverageTest is Base {
    // ------------------------------------------------------------ MockStable
    function test_faucet_once() public {
        vm.prank(stranger);
        stable.faucet();
        assertEq(stable.balanceOf(stranger), 10_000e6);
        assertTrue(stable.claimed(stranger));
        vm.prank(stranger);
        vm.expectRevert(MockStable.AlreadyClaimed.selector);
        stable.faucet();
    }

    // ------------------------------------------------------------ ReceivableNFT
    function test_nft_wiring_zero_and_once() public {
        ReceivableNFT n = new ReceivableNFT(address(this));
        vm.expectRevert(ReceivableNFT.ZeroAddress.selector);
        n.setWiring(address(0), address(1));
        vm.expectRevert(ReceivableNFT.ZeroAddress.selector);
        n.setWiring(address(1), address(0));
        n.setWiring(address(1), address(2));
        vm.expectRevert(ReceivableNFT.AlreadySet.selector);
        n.setWiring(address(3), address(4));
    }

    function test_nft_tokenURI_and_receivable_views() public {
        uint256 id = _mintReceivable(FACE, 5 days);
        assertEq(nft.tokenURI(id), "ipfs://invoice");
        assertEq(nft.receivable(id).faceValue, FACE);
        vm.expectRevert();
        nft.tokenURI(999);
        vm.expectRevert();
        nft.receivable(999);
    }

    function test_nft_vault_only_functions() public {
        uint256 id = _mintReceivable(FACE, 5 days);
        vm.startPrank(stranger);
        vm.expectRevert(ReceivableNFT.NotVault.selector);
        nft.lock(id);
        vm.expectRevert(ReceivableNFT.NotVault.selector);
        nft.unlock(id);
        vm.expectRevert(ReceivableNFT.NotVault.selector);
        nft.updateDueDate(id, uint64(block.timestamp + 1));
        vm.stopPrank();
    }

    function test_nft_mint_validation() public {
        vm.startPrank(borrower);
        vm.expectRevert(ReceivableNFT.InvalidReceivable.selector);
        nft.mint(0, uint64(block.timestamp + 1 days), keccak256("o"), "u");
        vm.expectRevert(ReceivableNFT.InvalidReceivable.selector);
        nft.mint(1, uint64(block.timestamp), keccak256("o"), "u");
        vm.expectRevert(ReceivableNFT.InvalidReceivable.selector);
        nft.mint(1, uint64(block.timestamp + 1 days), bytes32(0), "u");
        vm.stopPrank();
    }

    // ------------------------------------------------------------ ArbiterResolver
    function test_arbiter_hooks_engine_only() public {
        vm.startPrank(stranger);
        vm.expectRevert(ArbiterResolver.NotEngine.selector);
        arbiter.onSeized(1);
        vm.expectRevert(ArbiterResolver.NotEngine.selector);
        arbiter.onLiquidated(1, 1);
        vm.stopPrank();
        vm.startPrank(address(engine));
        arbiter.onSeized(1);
        arbiter.onLiquidated(1, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ DefaultEngine admin
    function test_engine_constructor_zero_address() public {
        vm.expectRevert(DefaultEngine.ZeroAddress.selector);
        new DefaultEngine(CreditVault(address(0)), nft, stable, address(this));
        vm.expectRevert(DefaultEngine.ZeroAddress.selector);
        new DefaultEngine(vault, ReceivableNFT(address(0)), stable, address(this));
        vm.expectRevert(DefaultEngine.ZeroAddress.selector);
        new DefaultEngine(vault, nft, MockStable(address(0)), address(this));
    }

    function test_engine_setters_and_bounds() public {
        engine.setGracePeriod(1 days);
        assertEq(engine.gracePeriod(), 1 days);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setGracePeriod(91 days);

        engine.setDisputeWindow(2 days);
        assertEq(engine.disputeWindow(), 2 days);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setDisputeWindow(91 days);

        engine.setAuctionDuration(1 days);
        assertEq(engine.auctionDuration(), 1 days);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setAuctionDuration(0);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setAuctionDuration(91 days);

        engine.setResolutionTimeout(1 days);
        assertEq(engine.resolutionTimeout(), 1 days);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setResolutionTimeout(0);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setResolutionTimeout(91 days);

        engine.setRecoveryPeriod(10 days);
        assertEq(engine.recoveryPeriod(), 10 days);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setRecoveryPeriod(366 days);

        engine.setFloorBps(5_000);
        assertEq(engine.floorBps(), 5_000);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setFloorBps(999);
        vm.expectRevert(DefaultEngine.ParamOutOfBounds.selector);
        engine.setFloorBps(10_001);
    }

    function test_engine_setters_owner_only() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        engine.setGracePeriod(1);
        vm.expectRevert();
        engine.setFloorBps(5_000);
        vm.expectRevert();
        engine.pause();
        vm.stopPrank();
    }

    function test_engine_pause_unpause() public {
        engine.pause();
        uint256 id = _mintReceivable(FACE, 30 days);
        vm.startPrank(borrower);
        nft.approve(address(vault), id);
        vm.stopPrank();
        vm.expectRevert();
        engine.flagOverdue(id);
        engine.unpause();
        assertFalse(engine.paused());
    }

    // ------------------------------------------------------------ DefaultEngine guards
    function test_engine_price_zero_outside_auction() public {
        uint256 id = _financed();
        assertEq(engine.currentPrice(id), 0);
    }

    function test_engine_wrong_state_guards() public {
        uint256 id = _financed(); // Performing
        vm.prank(borrower);
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.dispute(id, keccak256("e"));
        vm.prank(address(arbiter));
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.resolveDispute(id, true, uint64(block.timestamp + 1 days));
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.expireDispute(id);
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.writeOff(id);
        vm.expectRevert(DefaultEngine.BadStatus.selector);
        engine.recover(id, 1);
    }

    function test_engine_recover_zero_amount() public {
        uint256 id = _financed();
        _seize(id);
        vm.warp(block.timestamp + engine.auctionDuration() + 1);
        vm.prank(buyer);
        engine.liquidate(id, type(uint256).max);
        assertEq(uint8(_status(id)), uint8(IDefaultEngine.Status.Liquidated));
        vm.expectRevert(DefaultEngine.ZeroAmount.selector);
        engine.recover(id, 0);
    }

    // ------------------------------------------------------------ CreditVault admin
    function test_vault_constructor_zero_address() public {
        vm.expectRevert(CreditVault.ZeroAddress.selector);
        new CreditVault(stable, ReceivableNFT(address(0)), address(this), treasury);
        vm.expectRevert(CreditVault.ZeroAddress.selector);
        new CreditVault(stable, nft, address(this), address(0));
    }

    function test_vault_setEngine_guards() public {
        CreditVault v = new CreditVault(stable, nft, address(this), treasury);
        vm.expectRevert(CreditVault.ZeroAddress.selector);
        v.setEngine(address(0));
        v.setEngine(address(engine));
        vm.expectRevert(CreditVault.AlreadySet.selector);
        v.setEngine(address(engine));
    }

    function test_vault_setters_and_bounds() public {
        vault.setTreasury(stranger);
        assertEq(vault.treasury(), stranger);
        vm.expectRevert(CreditVault.ZeroAddress.selector);
        vault.setTreasury(address(0));

        vault.setAdvanceRateBps(9_000);
        assertEq(vault.advanceRateBps(), 9_000);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setAdvanceRateBps(0);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setAdvanceRateBps(9_501);

        vault.setOriginationFeeBps(500);
        assertEq(vault.originationFeeBps(), 500);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setOriginationFeeBps(1_001);

        vault.setProtocolFeeBps(1_000);
        assertEq(vault.protocolFeeBps(), 1_000);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setProtocolFeeBps(5_001);

        vault.setReserveBps(1_000);
        assertEq(vault.reserveBps(), 1_000);
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.setReserveBps(2_001);
    }

    function test_vault_setters_owner_only() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        vault.setTreasury(stranger);
        vm.expectRevert();
        vault.setOriginationFeeBps(1);
        vm.expectRevert();
        vault.pause();
        vm.stopPrank();
    }

    function test_vault_utilization() public {
        assertEq(vault.utilizationBps(), 0);
        _financed();
        assertEq(vault.utilizationBps(), (PRINCIPAL * 10_000) / vault.totalAssets());
        CreditVault empty = new CreditVault(stable, nft, address(this), treasury);
        assertEq(empty.utilizationBps(), 0);
    }

    function test_vault_paused_limits() public {
        vault.pause();
        assertEq(vault.maxDeposit(lp), 0);
        assertEq(vault.maxMint(lp), 0);
        assertEq(vault.maxWithdraw(lp), 0);
        assertEq(vault.maxRedeem(lp), 0);
        vault.unpause();
        assertGt(vault.maxDeposit(lp), 0);
        assertGt(vault.maxMint(lp), 0);
        assertGt(vault.maxWithdraw(lp), 0);
        assertGt(vault.maxRedeem(lp), 0);
    }

    // ------------------------------------------------------------ CreditVault guards
    function test_vault_advance_engine_unset() public {
        CreditVault v = new CreditVault(stable, nft, address(this), treasury);
        vm.expectRevert(CreditVault.EngineUnset.selector);
        v.advance(1);
    }

    function test_vault_advance_loan_exists() public {
        uint256 id = _financed(); // vault now owns the NFT and the loan is active
        vm.prank(address(vault));
        vm.expectRevert(CreditVault.LoanExists.selector);
        vault.advance(id);
    }

    function test_vault_advance_zero_principal() public {
        uint256 id = _mintReceivable(1, 30 days); // 80% of 1 wei-unit rounds to 0
        vm.startPrank(borrower);
        nft.approve(address(vault), id);
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.advance(id);
        vm.stopPrank();
    }

    function test_vault_repay_not_repayable_status() public {
        uint256 id = _financed();
        vm.mockCall(
            address(engine),
            abi.encodeWithSelector(engine.statusOf.selector, id),
            abi.encode(IDefaultEngine.Status.Liquidated)
        );
        vm.prank(borrower);
        vm.expectRevert(CreditVault.NotRepayable.selector);
        vault.repay(id, 1e6);
    }

    function test_vault_repay_zero_amount_and_inactive() public {
        uint256 id = _financed();
        vm.prank(borrower);
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.repay(id, 0);
        vm.prank(borrower);
        vm.expectRevert(CreditVault.NotRepayable.selector);
        vault.repay(999, 1e6);
    }

    // ------------------------------------------------------------ CreditVault engine hooks
    function test_vault_hooks_engine_only() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        vault.seize(1, 4_000);
        vm.expectRevert();
        vault.setDueDate(1, 1);
        vm.expectRevert();
        vault.applyLiquidation(1, 1, stranger);
        vm.expectRevert();
        vault.creditRecovery(stranger, 1);
        vm.expectRevert();
        vault.bookYield(1);
        vm.stopPrank();
    }

    function test_vault_seize_hook_guards() public {
        uint256 id = _financed();
        vm.startPrank(address(engine));
        vm.expectRevert(CreditVault.ParamOutOfBounds.selector);
        vault.seize(id, 10_001);
        vm.expectRevert(CreditVault.NoLoan.selector);
        vault.seize(999, 4_000);
        vm.expectRevert(CreditVault.NoLoan.selector);
        vault.setDueDate(999, uint64(block.timestamp + 1));
        vm.stopPrank();
    }

    function test_vault_applyLiquidation_guards() public {
        uint256 id = _financed();
        vm.prank(address(engine));
        vm.expectRevert(CreditVault.NotSeized.selector);
        vault.applyLiquidation(id, 1e6, buyer); // not seized yet

        _seize(id);
        vm.startPrank(address(engine));
        vm.expectRevert(CreditVault.BadRecovery.selector);
        vault.applyLiquidation(id, 0, buyer);
        vm.expectRevert(CreditVault.BadRecovery.selector);
        vault.applyLiquidation(id, DEBT + 1, buyer);
        vm.expectRevert(CreditVault.BadRecovery.selector);
        vault.applyLiquidation(id, 1e6, address(0));
        vm.expectRevert(CreditVault.NoLoan.selector);
        vault.setDueDate(id, uint64(block.timestamp + 1)); // seized loans cannot be re-dated
        vm.stopPrank();
    }

    function test_vault_creditRecovery_and_bookYield_guards() public {
        vm.startPrank(address(engine));
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.creditRecovery(buyer, 0);
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.creditRecovery(address(0), 1);
        vm.expectRevert(CreditVault.ZeroAmount.selector);
        vault.bookYield(0);
        vm.expectRevert(CreditVault.UnbackedYield.selector);
        vault.bookYield(1);
        vm.stopPrank();
    }
}
