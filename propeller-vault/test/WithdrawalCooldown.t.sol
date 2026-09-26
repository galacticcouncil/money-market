// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {SubLoopUnwindTest} from "./SubLoopUnwind.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";

contract WithdrawalCooldownTest is PluggableYieldSourceTest {
    function _deposit(uint256 amount) internal returns (uint256) {
        eth.mint(address(this), amount);
        eth.approve(address(vault), amount);
        return vault.deposit(amount, address(this));
    }

    function _ready(uint256 id) internal {
        vm.warp(vault.unwindEligibleAt(id));
        vault.startUnwinds(16);
    }

    function test_defaultWaitsTwelveHoursBeforeAnyUnwind() public {
        uint256 shares = _deposit(1e18);
        uint256 sourceShares = vault.loopShares();
        uint256 id = vault.requestRedeem(shares, address(this));
        uint256 ready = vault.unwindEligibleAt(id);
        assertEq(vault.withdrawalDelay(), 12 hours);
        assertEq(ready, block.timestamp + 12 hours);
        assertEq(vault.pendingWithdrawalShares(), shares);
        assertEq(vault.totalQueuedShares(), 0);
        assertEq(vault.totalQueuedCollateral(), 0);

        vm.warp(ready - 1);
        vault.startUnwinds(16);
        vault.pokeSettle();
        assertEq(vault.queueUnwind(), 0);
        assertEq(vault.queueHead(), 0);
        assertEq(source.sharesOf(address(vault)), sourceShares);
        assertEq(source.pendingUnwindOf(address(vault)), 0);
        vm.expectRevert(CollateralVault.NothingToClaim.selector);
        vault.claim(id, address(this));

        vm.warp(ready);
        vm.prank(address(0xB0B));
        vault.startUnwinds(1);
        assertEq(vault.queueUnwind(), 1);
        assertEq(vault.pendingWithdrawalShares(), 0);
        assertEq(vault.totalQueuedShares(), shares);
        assertGt(source.pendingUnwindOf(address(vault)), 0);
        uint256 left = source.sharesOf(address(vault));
        vault.startUnwinds(16);
        assertEq(source.sharesOf(address(vault)), left, "cannot start twice");
        vault.pokeSettle();
        assertGt(vault.claim(id, address(this)), 0);
    }

    function test_delayChangesOnlyAffectFutureRequestsAndPreserveFifo() public {
        uint256 shares = _deposit(3e18);
        uint256 first = vault.requestRedeem(shares / 3, address(this));
        uint256 ready = vault.unwindEligibleAt(first);
        vault.setWithdrawalDelay(1 hours);
        uint256 second = vault.requestRedeem(shares / 3, address(this));
        assertEq(vault.unwindEligibleAt(second), block.timestamp + 1 hours);
        assertEq(vault.unwindEligibleAt(first), ready);
        vm.warp(block.timestamp + 1 hours);
        vault.startUnwinds(16);
        assertEq(vault.queueUnwind(), 0, "later shorter wait does not jump the queue");
        vm.warp(ready);
        vault.startUnwinds(1);
        assertEq(vault.queueUnwind(), 1, "bounded batch");
        vault.startUnwinds(0);
        assertEq(vault.queueUnwind(), 1);
        vault.startUnwinds(1);
        assertEq(vault.queueUnwind(), 2);
        assertEq(vault.pendingWithdrawalShares(), 0);
        assertEq(vault.loopShares(), source.sharesOf(address(vault)));
    }

    function test_governanceCanDisableDelayButStillRequiresExplicitStart() public {
        uint256 shares = _deposit(1e18);
        vault.setWithdrawalDelay(0);
        uint256 id = vault.requestRedeem(shares, address(this));
        assertEq(vault.unwindEligibleAt(id), block.timestamp);
        assertEq(source.pendingUnwindOf(address(vault)), 0);
        vault.pokeSettle();
        assertEq(vault.queueHead(), 0);
        vault.startUnwinds(1);
        vault.pokeSettle();
        assertGt(vault.claim(id, address(this)), 0);
    }

    function test_waitingSharesKeepTheirYieldAndDebtUntilStart() public {
        uint256 shares = _deposit(2e18);
        uint256 id = vault.requestRedeem(shares / 2, address(this));
        uint256 supply = vault.totalSupply();
        aEth.mint(address(vault), 1e18);
        eth.mint(address(pool), 1e18);
        hollarDebt.mint(address(vault), 100e18);
        uint256 expectedAssets = 3e18 * (shares / 2) / supply;
        uint256 expectedDebt = hollarDebt.balanceOf(address(vault)) * (shares / 2) / supply;
        _ready(id);
        (, , uint256 owed, uint256 debtShare, , , , , ) = vault.redemptions(id);
        assertEq(owed, expectedAssets);
        assertEq(debtShare, expectedDebt, "waiting debt is not shifted to remaining holders");
    }

    function test_depositDuringWaitDoesNotDilutePendingShares() public {
        uint256 shares = _deposit(1e18);
        uint256 id = vault.requestRedeem(shares, address(this));
        address user = address(0xB0B);
        eth.mint(user, 1e18);
        vm.startPrank(user);
        eth.approve(address(vault), 1e18);
        uint256 minted = vault.deposit(1e18, user);
        vm.stopPrank();
        assertEq(minted, 1e18);
        _ready(id);
        vault.pokeSettle();
        assertEq(vault.claim(id, address(this)), shares);
        assertEq(vault.convertToAssets(minted), 1e18);
    }

    function test_fundingCannotBypassCooldown() public {
        uint256 shares = _deposit(1e18);
        uint256 id = vault.requestRedeem(shares, address(this));
        hollar.mint(address(vault), hollarDebt.balanceOf(address(vault)));
        vault.pokeSettle();
        assertEq(vault.queueHead(), 0);
        assertEq(vault.totalQueuedCollateral(), 0);
        vm.expectRevert(CollateralVault.NothingToClaim.selector);
        vault.claim(id, address(this));
    }

    function test_delegatedAndSplitRequestsCannotReuseAnOldTimer() public {
        uint256 shares = _deposit(3e18);
        vault.requestRedeem(shares / 3, address(this));
        vm.warp(vm.getBlockTimestamp() + 11 hours);
        address spender = address(0xB0B);
        vault.approve(spender, shares / 3);
        vm.prank(spender);
        uint256 second = vault.requestRedeem(shares / 3, address(this));
        uint256 secondReady = vault.unwindEligibleAt(second);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.startUnwinds(16);
        assertEq(vault.queueUnwind(), 1);
        assertEq(secondReady, vm.getBlockTimestamp() + 11 hours);
        assertEq(vault.balanceOf(address(vault)), 2 * (shares / 3));
    }

    function test_freezeBlocksMatureStartTransfersAndNewRequests() public {
        uint256 shares = _deposit(2e18);
        uint256 id = vault.requestRedeem(shares / 2, address(this));
        address spender = address(0xB0B);
        vault.approve(spender, 1);
        vault.pause();
        vm.warp(vault.unwindEligibleAt(id));
        vm.expectRevert("Pausable: paused");
        vault.startUnwinds(1);
        vm.expectRevert("Pausable: paused");
        vault.requestRedeem(1, address(this));
        vm.expectRevert("Pausable: paused");
        vault.transfer(spender, 1);
        vm.prank(spender);
        vm.expectRevert("Pausable: paused");
        vault.transferFrom(address(this), spender, 1);
        vm.expectRevert("Pausable: paused");
        vault.deposit(1, address(this));
        vault.pokeSettle();
        assertEq(source.pendingUnwindOf(address(vault)), 0);
        vault.unpause();
        vault.startUnwinds(1);
        assertEq(vault.queueUnwind(), 1);
    }

    function test_freezeStopsFifoAndAlreadySettledClaims() public {
        uint256 shares = _deposit(2e18);
        uint256 first = vault.requestRedeem(shares / 2, address(this));
        uint256 second = vault.requestRedeem(shares - shares / 2, address(this));
        _ready(first);
        pool.setRepayLimit(100e18);
        vault.pokeSettle();
        (, , , , , uint256 repaid, uint256 settled, , ) = vault.redemptions(first);
        assertGt(settled, 0);
        vault.pause();
        pool.setRepayLimit(type(uint256).max);
        vault.pokeSettle();
        (, , , , , uint256 afterRepaid, , , ) = vault.redemptions(first);
        assertEq(afterRepaid, repaid);
        assertEq(vault.queueHead(), first);
        vm.expectRevert("Pausable: paused");
        vault.claim(first, address(this));
        vm.expectRevert("Pausable: paused");
        vault.claim(second, address(this));
        vault.unpause();
        assertEq(vault.claim(first, address(this)), settled);
        vault.pokeSettle();
        assertGt(vault.claim(first, address(this)), 0);
        assertGt(vault.claim(second, address(this)), 0);
    }

    function test_freezeKeepsPegAndCommittedMainRepaymentAvailable() public {
        uint256 shares = _deposit(2e18);
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0);
        vault.requestRedeem(shares / 2, address(this));
        vault.pause();
        hollarDebt.mint(address(vault), 100e18);
        uint256 beforeSynth = vault.syntheticSupplied();
        vault.maintainPeg();
        assertGt(vault.syntheticSupplied(), beforeSynth);
        uint256 beforeDebt = hollarDebt.balanceOf(address(vault));
        vault.pokeSettle();
        assertLt(hollarDebt.balanceOf(address(vault)), beforeDebt);
        assertEq(vault.deleverTarget(), 0);
        assertEq(vault.queueUnwind(), 0);
    }

    function test_onlyGovernanceChangesDelayOrReopensAfterGuardianFreeze() public {
        address guardian = address(0x7EC);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vm.prank(guardian);
        vault.pause();
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.Unauthorized.selector, guardian, vault.ADMIN_ROLE()));
        vault.setWithdrawalDelay(0);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.Unauthorized.selector, guardian, vault.ADMIN_ROLE()));
        vault.unpause();
        vm.stopPrank();
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_sourceFreezeCannotBeBypassedByLocalUnpause() public {
        uint256 shares = _deposit(1e18);
        uint256 id = vault.requestRedeem(shares, address(this));
        _ready(id);
        vault.pokeSettle();
        source.setEmergencyPaused(true);
        assertTrue(vault.paused());
        vault.unpause();
        assertTrue(vault.paused());
        vm.expectRevert("Pausable: paused");
        vault.claim(id, address(this));
        vault.maintainPeg();
        source.setEmergencyPaused(false);
        assertGt(vault.claim(id, address(this)), 0);
    }
}

contract SourceEmergencyPauseTest is SubLoopUnwindTest {
    function test_emergencyStopsExistingUnwindAndNewRisk() public {
        _ramp();
        loop.requestUnwind(loop.sharesOf(address(this)) / 2);
        uint256 target = loop.unwindTargetEquity();
        uint256 assets = aPrime.balanceOf(address(loop));
        loop.pauseEmergency();
        vm.expectRevert(SubLoop.EmergencyPaused.selector);
        loop.pokeBorrow();
        vm.expectRevert(SubLoop.EmergencyPaused.selector);
        loop.harvest();
        vm.expectRevert(SubLoop.EmergencyPaused.selector);
        loop.deposit(1);
        vm.expectRevert(SubLoop.EmergencyPaused.selector);
        loop.requestUnwind(1);
        loop.pokeRepay();
        assertEq(loop.unwindTargetEquity(), target);
        assertEq(aPrime.balanceOf(address(loop)), assets);
        assertEq(loop.reservedFreed(), 0);
        loop.unpauseEmergency();
        loop.pokeRepay();
        assertLt(aPrime.balanceOf(address(loop)), assets);
    }

    function test_emergencyAllowsSafetyRepaymentWithoutExitAllocation() public {
        _ramp();
        loop.requestUnwind(loop.sharesOf(address(this)) / 2);
        uint256 target = loop.unwindTargetEquity();
        hollarDebt.mint(address(loop), hollarDebt.balanceOf(address(loop)) * 2 / 100);
        loop.pauseEmergency();
        loop.deLever();
        uint256 debt = hollarDebt.balanceOf(address(loop));
        loop.pokeRepay();
        assertLt(hollarDebt.balanceOf(address(loop)), debt);
        assertEq(loop.unwindTargetEquity(), target);
        assertEq(loop.reservedFreed(), 0);
        loop.pause();
        vm.expectRevert("Pausable: paused");
        loop.pokeRepay();
    }

    function test_onlyGuardianFreezesAndOnlyGovernanceReopensSource() public {
        address guardian = address(0x7EC);
        vm.prank(guardian);
        vm.expectRevert();
        loop.pauseEmergency();
        loop.grantRole(loop.GUARDIAN_ROLE(), guardian);
        vm.prank(guardian);
        loop.pauseEmergency();
        assertTrue(loop.emergencyPaused());
        vm.prank(guardian);
        vm.expectRevert();
        loop.unpauseEmergency();
        loop.unpauseEmergency();
        assertFalse(loop.emergencyPaused());
    }
}
