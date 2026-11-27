// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SubLoopUnwindSizingTest} from "./SubLoopUnwindSizing.t.sol";

contract AuditPr46SafetyTest is SubLoopUnwindSizingTest {
    function test_pr46_safetyDeleverSellsBelowTheRoutineStepFloor() public {
        _ramp();
        uint256 hf0 = loop.healthFactor();
        pool.setPrice(address(prime), 1.01e18 * 1e18 / hf0);
        uint256 hf = loop.healthFactor();
        assertLt(hf, 1.02e18);
        assertGt(hf, 1.005e18);

        vm.prank(address(0xBEEF));
        loop.deLever();
        uint256 collateral = aPrime.balanceOf(address(loop));
        assertGt(loop.pokeRepay(), 0, "the first safety step sells and repays");
        assertLt(aPrime.balanceOf(address(loop)), collateral);
        assertGt(loop.healthFactor(), hf, "and lifts the health factor");

        for (uint256 i; i < 80 && loop.deleverDebtTarget() != 0; ++i) loop.pokeRepay();
        assertEq(loop.deleverDebtTarget(), 0);
        assertGt(loop.healthFactor(), 1.04e18);
    }

    function test_pr46_routineUnwindKeepsTheStepFloor() public {
        _ramp();
        uint256 hf0 = loop.healthFactor();
        loop.requestUnwind(loop.sharesOf(address(this)) / 2);
        pool.setPrice(address(prime), 1.01e18 * 1e18 / hf0);
        uint256 collateral = aPrime.balanceOf(address(loop));
        loop.pokeRepay();
        assertEq(aPrime.balanceOf(address(loop)), collateral, "no routine sale below 1.02");
    }
}
