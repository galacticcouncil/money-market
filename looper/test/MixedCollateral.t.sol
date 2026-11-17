// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// A lower-LT gift that stays enabled as collateral: exit slivers and payouts still respect stepHf and minHf.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract MixedCollateralTest is Fixture {
    /// @dev Carol gifts DOT (LT 40%) into `pos`, then the DOT reserve is paused, so `_normalise` cannot disable it.
    function giftPausedDot(LooperPosition pos, uint256 amount) internal {
        pool.setLtvLt(address(dot), 3_000, 4_000);
        giftAToken(dot, aDot, address(pos), amount);
        pool.setFlags(address(dot), false, true, true, false);
    }

    function hfOf(LooperPosition pos) internal view returns (uint256 hf) {
        (,,, hf) = account(pos);
    }

    function test_close_should_keep_hf_at_step_hf_on_the_first_sliver_when_a_low_lt_gift_stays_collateral() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 500e10);

        vm.prank(alice);
        pos.close();

        assertTrue(pool.isCollateral(address(pos), address(dot)), "gift still collateral");
        assertTrue(hasPending(pos), "first exit sliver submitted");
        assertGe(hfOf(pos), 1.05e18);
    }

    function test_withdraw_should_keep_hf_at_min_hf_when_a_low_lt_gift_stays_collateral() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 500e10);
        uint256 before = prime.balanceOf(alice);

        vm.prank(alice);
        pos.withdraw(700e6);
        drive(pos, 80);

        assertTrue(pool.isCollateral(address(pos), address(dot)), "gift still collateral");
        assertGt(prime.balanceOf(alice), before, "something paid out");
        assertGe(hfOf(pos), 1.15e18);
    }

    function test_withdraw_should_keep_hf_at_min_hf_in_emode_when_a_low_lt_gift_stays_collateral() public {
        pool.setEModeCategory(1, 8_500, 9_000, makeAddr("eModeSource"), 1e8);
        pool.setPrice(address(prime), 1e8); // the mock pallet quotes fills at reserve prices, so match the category
        pool.setReserveEMode(address(prime), 1);
        pool.setReserveEMode(address(hollar), 1);
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.eMode = 1;
        LooperPosition pos = openWith(alice, DEPOSIT, p);
        ramp(pos);
        giftPausedDot(pos, 200e10);
        uint256 before = prime.balanceOf(alice);

        vm.prank(alice);
        pos.withdraw(950e6);
        drive(pos, 80);

        assertTrue(pool.isCollateral(address(pos), address(dot)), "gift still collateral");
        assertGt(prime.balanceOf(alice), before, "something paid out");
        assertGe(hfOf(pos), 1.15e18);
    }
}
