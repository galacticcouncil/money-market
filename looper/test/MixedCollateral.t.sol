// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// A gift with another LT that stays enabled as collateral: exit slivers and payouts still respect stepHf and minHf.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract MixedCollateralTest is Fixture {
    /// @dev A donor gifts DOT with the given LTV/LT into `pos`, then the DOT reserve is paused, so `_normalise`
    /// cannot disable it.
    function giftPausedDot(LooperPosition pos, uint256 amount, uint16 ltv, uint16 lt) internal {
        pool.setLtvLt(address(dot), ltv, lt);
        giftAToken(dot, aDot, address(pos), amount);
        pool.setFlags(address(dot), false, true, true, false);
    }

    /// @dev Alice's ramped position in eMode 1 (LT 90%), PRIME and HOLLAR both priced at 1.
    function openEMode() internal returns (LooperPosition pos) {
        pool.setEModeCategory(1, 8_500, 9_000, makeAddr("eModeSource"), 1e8);
        pool.setPrice(address(prime), 1e8); // the mock pallet quotes fills at reserve prices, so match the category
        pool.setReserveEMode(address(prime), 1);
        pool.setReserveEMode(address(hollar), 1);
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.eMode = 1;
        pos = openWith(alice, DEPOSIT, p);
        ramp(pos);
    }

    function hfOf(LooperPosition pos) internal view returns (uint256 hf) {
        (,,, hf) = account(pos);
    }

    function withdrawAndDrive(LooperPosition pos, uint256 amount) internal returns (uint256 paid) {
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.withdraw(amount);
        drive(pos, 80);
        paid = prime.balanceOf(alice) - before;
    }

    function test_close_should_keep_hf_at_step_hf_on_the_first_sliver_when_a_low_lt_gift_stays_collateral() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 500e10, 3_000, 4_000);

        vm.prank(alice);
        pos.close();

        assertTrue(pool.isCollateral(address(pos), address(dot)), "gift still collateral");
        assertTrue(hasPending(pos), "first exit sliver submitted");
        assertGe(hfOf(pos), 1.05e18);
    }

    function test_close_should_keep_hf_at_step_hf_on_every_sliver_and_finish_with_a_low_lt_gift() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 500e10, 3_000, 4_000);

        vm.prank(alice);
        pos.close();
        uint256 rungs;
        while (hasPending(pos) && rungs < 80) {
            assertGe(hfOf(pos), 1.05e18, "sliver in flight");
            fill(FILL_BPS);
            ++rungs;
        }

        assertTrue(pos.isClosed());
        assertEq(aDot.balanceOf(address(pos)), 500e10, "a paused reserve refuses the sweep, the gift stays");
    }

    function test_close_should_submit_a_sliver_just_above_step_hf_with_a_tiny_gift() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 1e5, 7_000, 7_999);
        pool.setPrice(address(hollar), 1e8 * hfOf(pos) / 1.05008e18);

        vm.prank(alice);
        pos.close();

        assertTrue(hasPending(pos), "sliver submitted");
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
    }

    function test_withdraw_should_pay_the_request_and_keep_hf_at_min_hf_when_a_low_lt_gift_stays_collateral() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 500e10, 3_000, 4_000);

        uint256 paid = withdrawAndDrive(pos, 700e6);

        assertTrue(pool.isCollateral(address(pos), address(dot)), "gift still collateral");
        assertEq(paid, 700e6);
        assertGe(hfOf(pos), 1.15e18);
    }

    function test_withdraw_should_pay_the_request_and_keep_hf_at_min_hf_when_a_high_lt_gift_stays_collateral() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 500e10, 8_500, 9_000);

        uint256 paid = withdrawAndDrive(pos, 700e6);

        assertEq(paid, 700e6);
        assertGe(hfOf(pos), 1.15e18);
    }

    function test_close_should_keep_hf_at_step_hf_on_the_first_sliver_in_emode_with_a_low_lt_gift() public {
        LooperPosition pos = openEMode();
        giftPausedDot(pos, 200e10, 3_000, 4_000);

        vm.prank(alice);
        pos.close();

        assertTrue(hasPending(pos), "first exit sliver submitted");
        assertGe(hfOf(pos), 1.05e18);
    }

    function test_withdraw_should_pay_the_request_and_keep_hf_at_min_hf_in_emode_with_a_low_lt_gift() public {
        LooperPosition pos = openEMode();
        giftPausedDot(pos, 200e10, 3_000, 4_000);

        uint256 paid = withdrawAndDrive(pos, 950e6);

        assertTrue(pool.isCollateral(address(pos), address(dot)), "gift still collateral");
        assertEq(paid, 950e6);
        assertGe(hfOf(pos), 1.15e18);
    }

    function test_withdraw_should_pay_the_request_when_the_collateral_left_its_emode_category() public {
        LooperPosition pos = openEMode();
        pool.setReserveEMode(address(prime), 0);

        uint256 paid = withdrawAndDrive(pos, 300e6);

        assertEq(paid, 300e6);
        assertGe(hfOf(pos), 1.15e18);
    }

    function test_close_should_finish_when_the_own_lt_dropped_to_zero_beside_a_gift() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        giftPausedDot(pos, 3_000e10, 6_000, 7_000);
        pool.setLtvLt(address(prime), 0, 0);
        uint256 before = prime.balanceOf(alice);

        vm.prank(alice);
        pos.close();
        drive(pos, 80);

        assertTrue(pos.isClosed());
        assertGt(prime.balanceOf(alice), before, "collateral returned");
    }

    function test_effective_hf_should_count_escrow_at_the_own_lt_when_a_gift_stays_collateral() public {
        LooperPosition high = open(alice, DEPOSIT, 3e18);
        ramp(high);
        giftPausedDot(high, 500e10, 8_500, 9_000);
        uint256 highBefore = hfOf(high);
        vm.prank(alice);
        high.close();
        uint256 highShown = high.effectiveHealthFactor();

        pool.setFlags(address(dot), false, false, true, false); // unpause DOT so the next gift can land
        LooperPosition low = open(bob, DEPOSIT, 3e18);
        ramp(low);
        giftPausedDot(low, 500e10, 3_000, 4_000);
        uint256 lowBefore = hfOf(low);
        vm.prank(bob);
        low.close();
        uint256 lowShown = low.effectiveHealthFactor();

        assertTrue(hasPending(high) && hasPending(low), "both slivers in flight");
        assertApproxEqRel(highShown, highBefore, 0.001e18, "LT 90% gift: hf before the sliver left");
        assertApproxEqRel(lowShown, lowBefore, 0.001e18, "LT 40% gift: hf before the sliver left");
    }
}
