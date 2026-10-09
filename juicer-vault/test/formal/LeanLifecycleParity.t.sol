// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "../Harvest.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";

contract LeanLifecycleParityTest is HarvestTest {
    address constant BOB = address(0xb0b);
    address constant CAROL = address(0xcafe);
    uint256 constant RAY = 1e27;

    function _ownerNumerator(JuicerYieldAccounting y, address owner) internal view returns (uint256) {
        uint256 stored;
        uint256 previous;
        if (y.accountEpoch(owner) == y.epoch()) {
            uint256 shift = y.unitScale() - y.accountScale(owner);
            stored = uint256(vm.load(address(y), keccak256(abi.encode(owner, uint256(4))))) >> shift;
            previous = y.accountIndex(owner) >> shift;
        }
        return stored * RAY + vault.walletOf(owner) * (y.rewardIndex() - previous);
    }

    function _assertLifecycle() internal view {
        JuicerYieldAccounting y = vault.yieldAccounting();
        assertEq(y.unitScale(), 0, "this public trace has no rescale budget");
        address[4] memory owners = [address(this), BOB, CAROL, address(0xdead)];
        uint256 numerator;
        uint256 weight;
        for (uint256 i; i < owners.length; ++i) {
            numerator += _ownerNumerator(y, owners[i]);
            weight += vault.walletOf(owners[i]);
        }
        uint256 waiting;
        for (uint256 id = vault.queueUnwind(); id < vault.queueTail(); ++id) {
            (, uint256 shares,,,,,,,) = vault.redemptions(id);
            uint256 committed;
            uint256 previous;
            if (y.requestEpoch(id) == y.epoch()) {
                uint256 shift = y.unitScale() - y.requestScale(id);
                committed = y.requestUnits(id) >> shift;
                previous = y.requestIndex(id) >> shift;
            }
            numerator += committed * RAY + shares * (y.rewardIndex() - previous);
            waiting += shares;
        }
        weight += waiting;
        uint256 funded = vault.walletOf(address(y));
        uint256 queued = vault.totalQueuedShares();
        uint256 parked = vault.walletOf(address(vault)) - queued - waiting;
        assertEq(weight + funded + queued + parked, vault.totalSupply(), "complete share partition");
        assertLe(weight, vault.totalSupply() - queued - funded, "derived allocation weight");
        assertLe(numerator, y.totalUnits() * RAY, "holders plus waiting liabilities");
    }

    function test_publicLifecycleIncludesWaitingRequestsAndClaims() public {
        _depositAndRamp();
        _assertLifecycle();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.sync();
        _assertLifecycle();
        vault.transfer(BOB, vault.walletOf(address(this)) / 3);
        _assertLifecycle();
        eth.mint(CAROL, 1e17);
        vm.startPrank(CAROL);
        eth.approve(address(vault), 1e17);
        vault.deposit(1e17, CAROL);
        vm.stopPrank();
        _assertLifecycle();
        harvester.harvest(new uint256[](1));
        _assertLifecycle();
        vault.transfer(address(vault.yieldAccounting()), vault.walletOf(address(this)) / 100);
        _assertLifecycle();
        vault.transfer(address(vault), 7);
        _assertLifecycle();
        uint256 bobRequest = vault.walletOf(BOB) / 2;
        vm.prank(BOB);
        uint256 first = vault.requestRedeem(bobRequest, BOB);
        _assertLifecycle();
        uint256 second = vault.requestRedeem(type(uint256).max, address(this));
        _assertLifecycle();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 100);
        vault.sync();
        _assertLifecycle();
        uint256 bobTransfer = vault.walletOf(BOB) / 5;
        vm.prank(BOB);
        vault.transfer(CAROL, bobTransfer);
        _assertLifecycle();
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        _assertLifecycle();
        vault.startUnwinds(1);
        _assertLifecycle();
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        pool.setRepayLimit(100e18);
        vault.pokeSettle();
        _assertLifecycle();
        (,,,,,, uint256 settled,,) = vault.redemptions(first);
        if (settled != 0) {
            vault.claim(first, BOB);
            _assertLifecycle();
        }
        pool.setRepayLimit(type(uint256).max);
        for (uint256 i; i < 10 && vault.queueHead() < vault.queueUnwind(); ++i) vault.pokeSettle();
        _assertLifecycle();
        (,,,,,, settled,,) = vault.redemptions(first);
        if (settled != 0) vault.claim(first, BOB);
        vault.claim(second, address(this));
        _assertLifecycle();
        assertEq(vault.totalQueuedShares(), 0);
        assertEq(vault.totalQueuedCollateral(), 0);
        assertEq(vault.queueHead(), vault.queueUnwind());
    }

    function test_failedRequestRollsBackCheckpointAndEscrow() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        JuicerYieldAccounting y = vault.yieldAccounting();
        uint256 totalBefore = y.totalUnits();
        uint256 indexBefore = y.rewardIndex();
        uint256 walletBefore = vault.walletOf(address(this));
        uint256 tailBefore = vault.queueTail();
        uint256 tooMuch = vault.balanceOf(address(this)) * 2;
        vm.expectRevert();
        vault.requestRedeem(tooMuch, address(this));
        assertEq(y.totalUnits(), totalBefore, "allocation rolled back");
        assertEq(y.rewardIndex(), indexBefore, "index rolled back");
        assertEq(vault.walletOf(address(this)), walletBefore, "escrow rolled back");
        assertEq(vault.queueTail(), tailBefore, "request id rolled back");
        assertEq(vault.pendingWithdrawalShares(), 0);
        _assertLifecycle();
    }
}
