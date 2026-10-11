// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "../Harvest.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";

contract LeanRescalePublicTest is HarvestTest {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function _setPrime(uint256 amount) internal {
        uint256 before_ = aPrime.balanceOf(address(loop));
        if (amount > before_) aPrime.mint(address(loop), amount - before_);
        else aPrime.burn(address(loop), before_ - amount);
    }

    function test_positiveResidualLossRefillsReachRescale() public {
        _depositAndRamp();
        JuicerYieldAccounting y = vault.yieldAccounting();
        uint256 high = aPrime.balanceOf(address(loop)) * 105 / 100;
        _setPrime(high);
        vault.sync();
        assertGt(y.totalUnits(), 0);
        uint256 epoch = y.epoch();
        for (uint256 round; round < 12 && y.unitScale() == 0; ++round) {
            uint256 target = y.requiredSourceBacking() + 1e13;
            uint256 lo;
            uint256 hi = high;
            while (lo < hi) {
                uint256 mid = (lo + hi) / 2;
                _setPrime(mid);
                if (loop.equityOf(address(vault)) * 1e10 < target) lo = mid + 1;
                else hi = mid;
            }
            _setPrime(lo);
            vault.sync();
            emit log_named_uint("residual value", y.totalAssets());
            assertGt(y.totalAssets(), 0);
            assertEq(y.epoch(), epoch);
            _setPrime(high);
            vault.sync();
            emit log_named_uint("round", round);
            emit log_named_uint("units", y.totalUnits());
            emit log_named_uint("scale", y.unitScale());
        }
        assertGt(y.unitScale(), 0);
        assertEq(y.epoch(), epoch);
        assertEq(vault.walletOf(address(y)), 0);
    }

    function test_multiplePublicHoldersStayWithinTotalAtReachableRescale() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        eth.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, ALICE);
        vm.stopPrank();
        eth.mint(BOB, 1e18);
        vm.startPrank(BOB);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, BOB);
        vm.stopPrank();
        vault.rebalance();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();

        JuicerYieldAccounting y = vault.yieldAccounting();
        uint256 high = aPrime.balanceOf(address(loop)) * 105 / 100;
        _setPrime(high);
        vault.sync();
        uint256 epoch = y.epoch();
        for (uint256 round; round < 12 && y.unitScale() == 0; ++round) {
            uint256 target = y.requiredSourceBacking() + 1e13;
            uint256 lo;
            uint256 hi = high;
            while (lo < hi) {
                uint256 mid = (lo + hi) / 2;
                _setPrime(mid);
                if (loop.equityOf(address(vault)) * 1e10 < target) lo = mid + 1;
                else hi = mid;
            }
            _setPrime(lo);
            vault.sync();
            assertGt(y.totalAssets(), 0);
            assertEq(y.epoch(), epoch);
            _setPrime(high);
            vault.sync();
        }
        assertEq(y.unitScale(), 64);
        uint256 aggregate = y.balanceOf(address(this)) + y.balanceOf(ALICE) + y.balanceOf(BOB)
            + y.balanceOf(address(0xdead));
        emit log_named_uint("total units", y.totalUnits());
        emit log_named_uint("aggregate holder units", aggregate);
        emit log_named_uint("aggregate deficit", y.totalUnits() - aggregate);
        assertLe(aggregate, y.totalUnits());
        assertLe(y.totalUnits() - aggregate, 4);
    }
}
