// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {SubLoopUnwindTest} from "./SubLoopUnwind.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

contract VaultAccountingSafetyTest is PluggableYieldSourceTest {
    function test_publicDepositorCannotPayBootstrapCost() public {
        address user = address(0xB0B);
        eth.mint(user, 1e18);
        vm.startPrank(user);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.BootstrapRequired.selector);
        vault.deposit(1e18, user);
        vm.stopPrank();
        assertEq(eth.balanceOf(user), 1e18);
    }

    function test_publicDepositorRecoversExactPrincipalAfterGovernanceBootstrap() public {
        _deposit(1e18);
        address user = address(0xB0B);
        eth.mint(user, 1e18);
        vm.startPrank(user);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, user);
        uint256 request = vault.requestRedeem(shares, user);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vm.stopPrank();
        vault.pokeSettle();
        vm.prank(user);
        assertEq(vault.claim(request, user), 1e18);
    }

    function _deposit(uint256 amount) internal returns (uint256) {
        eth.mint(address(this), amount);
        eth.approve(address(vault), amount);
        return vault.deposit(amount, address(this));
    }

    function test_twoQueuedHalvesReturnAllPrincipal() public {
        uint256 shares = _deposit(1e18);
        uint256 first = vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        uint256 second = vault.requestRedeem(shares - shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        uint256 returned = vault.claim(first, address(this)) + vault.claim(second, address(this));
        assertApproxEqAbs(returned, 1e18 - 1000, 1, "queued requests must not leave backing unrequested");
        assertEq(vault.queueHead(), vault.queueTail());
    }

    function test_unclaimedSettlementDoesNotHaircutNextRedeemer() public {
        uint256 shares = _deposit(3e18);
        uint256 first = vault.requestRedeem(shares / 3, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        uint256 quote = vault.convertToAssets(shares / 3);
        uint256 second = vault.requestRedeem(shares / 3, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        assertApproxEqAbs(vault.claim(second, address(this)), quote, 1);
        assertApproxEqAbs(vault.claim(first, address(this)), 1e18, 1000);
    }

    function test_deleverThenRedeemDoesNotCountDebtTwice() public {
        uint256 shares = _deposit(1e18);
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();
        uint256 pending = vault.deleverTarget();
        assertGt(pending, 0);
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        assertLe(vault.totalQueuedDebt() + pending, hollarDebt.balanceOf(address(vault)));
        vault.pokeSettle();
        assertApproxEqAbs(vault.claim(request, address(this)), 1e18 - 1000, 2);
    }

    function test_partialClaimsUseCumulativeSettlementRounding() public {
        uint256 shares = _deposit(1e18);
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        uint256 freed = source.freedOf(address(vault));
        vm.mockCall(address(source), abi.encodeWithSignature("pullFreed()"), abi.encode(freed / 3));
        hollar.mint(address(vault), freed / 3);
        vault.pokeSettle();
        uint256 first = vault.claim(request, address(this));
        vm.clearMockedCalls();
        vault.pokeSettle();
        uint256 last = vault.claim(request, address(this));
        assertApproxEqAbs(first + last, 1e18 - 1000, 1);
        assertEq(vault.totalQueuedShares(), 0);
    }

    function test_newDepositBlockedWhenMainDebtOutgrowsSource() public {
        _deposit(1e18);
        hollarDebt.mint(address(vault), 10e18);
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.Underfunded.selector);
        vault.deposit(1e18, address(this));
    }

    function test_shortfallPreservesPrincipalClaimAfterPartialPayment() public {
        uint256 shares = _deposit(1e18);
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        uint256 debt = vault.totalQueuedDebt();
        vm.mockCall(address(source), abi.encodeWithSignature("pullFreed()"), abi.encode(debt / 2));
        hollar.mint(address(vault), debt / 2);
        vm.mockCall(address(source), abi.encodeWithSignature("pendingUnwindOf(address)", address(vault)), abi.encode(0));
        vm.mockCall(address(source), abi.encodeWithSignature("freedOf(address)", address(vault)), abi.encode(0));
        vault.pokeSettle();
        uint256 paid = vault.claim(request, address(this));
        (, , uint256 owed, uint256 snapshot, , uint256 repaid, , , bool active) = vault.redemptions(request);
        assertTrue(active, "unpaid principal remains claimable");
        assertEq(snapshot, debt, "source shortfall cannot erase the obligation");
        assertLt(repaid, snapshot);
        assertLt(paid, owed);
        assertEq(vault.queueHead(), request);
        assertTrue(vault.isUnderfunded());
        vm.mockCall(address(source), abi.encodeWithSignature("pullFreed()"), abi.encode(0));
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.Underfunded.selector);
        vault.deposit(1e18, address(this));
        vault.pokeSettle();
        assertEq(vault.totalQueuedCollateral(), owed - paid);

        // Any donor can fund recovery; settlement pays only the recorded owner.
        hollar.mint(address(vault), debt - repaid);
        vault.pokeSettle();
        assertEq(paid + vault.claim(request, address(this)), owed);
        assertEq(vault.totalQueuedCollateral(), 0);
        (, , , , , , , , bool stillActive) = vault.redemptions(request);
        assertFalse(stillActive);
    }

    function test_rebalanceDoesNotAddDebtDuringExit() public {
        uint256 shares = _deposit(1e18);
        vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        uint256 debt = hollarDebt.balanceOf(address(vault));
        pool.setPrice(address(eth), 6_000e18);
        vault.rebalance();
        assertEq(hollarDebt.balanceOf(address(vault)), debt);
    }

    function test_settlementCreditsActualRepaymentOnly() public {
        uint256 shares = _deposit(1e18);
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        pool.setRepayLimit(100e18);
        vault.pokeSettle();
        (, , uint256 owed, uint256 debtShare, , uint256 repaid, uint256 settled, , ) = vault.redemptions(request);
        assertEq(repaid, 100e18);
        assertEq(settled, owed * repaid / debtShare);
        assertEq(vault.totalQueuedDebt(), debtShare - repaid);
        assertEq(hollar.allowance(address(vault), address(pool)), 0);
        pool.setRepayLimit(type(uint256).max);
        vault.pokeSettle();
        assertEq(vault.claim(request, address(this)), owed);
    }

    function test_idleCollateralDonationCanBeRedeemed() public {
        uint256 shares = _deposit(1e18);
        eth.mint(address(vault), 2e18);
        uint256 owed = vault.convertToAssets(shares);
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        assertEq(vault.claim(request, address(this)), owed);
    }
}

contract SourceAccountingSafetyTest is SubLoopUnwindTest {
    function _secondVault(uint256 amount) internal returns (address second) {
        second = address(0xB0B);
        loop.registerVault(second);
        hollar.mint(second, amount);
        vm.startPrank(second);
        hollar.approve(address(loop), amount);
        loop.deposit(amount);
        vm.stopPrank();
    }

    function test_backToBackVaultUnwindsDoNotOverbookEquity() public {
        _ramp();
        address second = _secondVault(SEED);
        uint256 gross = loop.totalEquity() * 1e10;
        loop.requestUnwind(loop.sharesOf(address(this)));
        uint256 secondShares = loop.sharesOf(second);
        vm.prank(second);
        loop.requestUnwind(secondShares);
        assertLe(loop.unwindTargetEquity(), gross, "one unit of equity backs one claim");
        assertApproxEqAbs(loop.unwindTargetEquity(), gross, 1e10);
    }

    function test_depositDuringPendingUnwindIsPricedOnLiveBacking() public {
        _ramp();
        _secondVault(SEED);
        loop.requestUnwind(loop.sharesOf(address(this)));
        address newcomer = address(0xCAFE);
        loop.registerVault(newcomer);
        hollar.mint(newcomer, SEED);
        vm.startPrank(newcomer);
        hollar.approve(address(loop), SEED);
        uint256 minted = loop.deposit(SEED);
        vm.stopPrank();
        assertApproxEqAbs(minted, SEED, 1e14, "pending withdrawals cannot dilute a new deposit");
    }

    function test_zeroProgressCannotWriteOffUnpaidClaims() public {
        _ramp();
        loop.requestUnwind(loop.sharesOf(address(this)));
        uint256 request = loop.pendingUnwindOf(address(this));
        vm.mockCall(
            address(pool), abi.encodeWithSignature("getUserAccountData(address)", address(loop)),
            abi.encode(uint256(1_020_000_001), uint256(880_000_000), uint256(0), uint256(8800), uint256(0), uint256(1.02e18))
        );
        loop.pokeRepay();
        assertEq(loop.pendingUnwindOf(address(this)), request);
        assertEq(loop.unwindTargetEquity(), request);
    }

    function test_unleveredExitSellsCollateralWithoutDebt() public {
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        loop.deposit(SEED);
        loop.requestUnwind(loop.sharesOf(address(this)));
        loop.pokeRepay();
        assertEq(loop.pullFreed(), SEED);
    }
}
