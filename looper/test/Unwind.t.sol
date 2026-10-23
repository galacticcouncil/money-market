// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract UnwindTest is Fixture {
    uint256 internal constant LEV_TOL = 0.01e18;
    uint256 internal constant HF_TOL = 0.01e18;

    LooperPosition internal pos;

    function setUp() public override {
        super.setUp();
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
    }

    function _withdraw(uint256 amount) internal returns (uint256 paid) {
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.withdraw(amount);
        drive(pos, 80);
        paid = prime.balanceOf(alice) - before;
    }

    function _close() internal returns (uint256 paid) {
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        paid = prime.balanceOf(alice) - before;
    }

    function _hf() internal view returns (uint256 hf) {
        (,,, hf) = account(pos);
    }

    function test_withdraw_should_end_near_l_dep_and_scale_principal_by_the_paid_fraction_when_the_market_is_flat()
        public
    {
        uint256 principal = pos.principal();
        uint256 navBefore = pos.nav();
        uint256 paid = _withdraw(300e6);
        assertEq(paid, 300e6);
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
        assertApproxEqAbs(_hf(), deployHf(pos), HF_TOL);
        // g = paid / equity before the payout; the cost basis keeps (1 - g)
        uint256 expected = Math.mulDiv(principal, navBefore - paid, navBefore);
        assertApproxEqRel(pos.principal(), expected, 0.005e18);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
    }

    function test_close_should_leave_zero_token_debt_and_sweep_everything_when_the_unwind_completes() public {
        uint256 paid = _close();
        assertEq(vHollar.balanceOf(address(pos)), 0);
        assertEq(aPrime.balanceOf(address(pos)), 0);
        assertEq(hollar.balanceOf(address(pos)), 0);
        assertEq(prime.balanceOf(address(pos)), 0);
        assertEq(pos.principal(), 0);
        assertTrue(pos.isClosed());
        assertGt(paid, 900e6);
        assertLane(pos);
    }

    function test_withdraw_should_repay_idle_cash_before_measuring_when_a_returned_entry_left_it() public {
        topUp(alice, pos, 100e6);
        uint128 id = liveId();
        vm.prank(alice);
        pos.cancel(id);
        uint256 cash = hollar.balanceOf(address(pos));
        uint256 debt = vHollar.balanceOf(address(pos));
        vm.prank(alice);
        pos.withdraw(50e6);
        assertEq(vHollar.balanceOf(address(pos)), debt - cash);
        drive(pos, 80);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
    }

    function test_withdraw_should_finish_at_l_dep_when_price_and_lt_move_during_a_multi_block_unwind() public {
        vm.prank(alice);
        pos.withdraw(400e6);
        fillOnly(FILL_BPS);
        pool.setPrice(address(prime), 2.45e8);
        (bool ok,) = dispatchTop();
        assertTrue(ok);
        fillOnly(FILL_BPS);
        pool.setLtvLt(address(prime), 7_500, 7_900);
        (ok,) = dispatchTop();
        assertTrue(ok);
        drive(pos, 80);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
        assertApproxEqAbs(_hf(), deployHf(pos), HF_TOL);
    }

    function test_withdraw_should_land_within_one_slivers_cost_of_deploy_hf_when_fills_lose_to_execution() public {
        vm.prank(alice);
        pos.withdraw(300e6);
        while (hasPending(pos)) fill(95);
        assertGe(_hf() + 1, deployHf(pos));
        assertApproxEqAbs(_hf(), deployHf(pos), HF_TOL);
    }

    function test_withdraw_zero_should_restore_min_hf_when_an_lt_drop_left_hf_under_it() public {
        pool.setLtvLt(address(prime), 7_000, 7_200);
        uint256 hf = _hf();
        assertLt(hf, 1.15e18);
        vm.roll(block.number + 100);
        assertEq(_hf(), hf, "nothing restores it on its own");
        uint256 paid = _withdraw(0);
        assertEq(paid, 0);
        assertGe(_hf() + 1, 1.15e18);
        assertApproxEqAbs(_hf(), 1.15e18, HF_TOL);
    }

    function test_withdraw_should_exit_when_hf_is_exactly_step_hf() public {
        // LT that puts HF at 1.05: 1.2 * lt / 0.8 = 1.05
        pool.setLtvLt(address(prime), 6_900, 7_000);
        // Rounding leaves HF a hair above 1.05, which takes the stepHf cap; HF scales with the collateral price,
        // so the floored proportional price lands it on the boundary.
        pool.setPrice(address(prime), 2.5e8 * 1.05e18 / _hf());
        assertApproxEqAbs(_hf(), 1.05e18, 0.001e18);
        assertLe(_hf(), 1.05e18);
        uint256 paid = _withdraw(100e6);
        assertEq(paid, 100e6);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        _close();
        assertTrue(pos.isClosed());
    }

    function test_withdraw_should_keep_in_flight_hf_at_or_above_step_hf_when_hf_is_above_step_hf() public {
        // 1.2 * 0.7067 / 0.8 = 1.06
        pool.setLtvLt(address(prime), 6_967, 7_067);
        uint256 hf = _hf();
        assertApproxEqAbs(hf, 1.06e18, 0.001e18);
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.withdraw(100e6);
        while (hasPending(pos)) {
            assertGe(_hf(), 1.05e18, "in-flight sliver crossed stepHf");
            fill(FILL_BPS);
        }
        assertEq(prime.balanceOf(alice) - before, 100e6);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
    }

    function test_withdraw_should_stall_without_crossing_step_hf_when_hf_is_barely_above_it_and_the_cap_is_under_floor_in(
    ) public {
        // 1.2 * 0.7001 / 0.8 = 1.05015
        pool.setLtvLt(address(prime), 6_901, 7_001);
        pokeMinIntentDebt(pos, 2e18);
        (uint256 c, uint256 d, uint256 lt,) = account(pos);
        uint256 hf = _hf();
        assertGt(hf, 1.05e18);
        uint256 cap = Math.mulDiv(c - Math.mulDiv(1.05e18, d, lt * 1e14, Math.Rounding.Up), 1e6, 2.5e8) * 9_000 / 10_000;
        uint256 gross = Math.mulDiv(2e18 / 1e10, 10_000, 10_000 - SLIP, Math.Rounding.Up);
        uint256 floorIn = Math.mulDiv(gross, 1e6, 2.5e8, Math.Rounding.Up);
        assertLt(cap, floorIn, "precondition: the stepHf cap cannot fund the smallest exit");
        uint256 submits = pallet.submits();
        vm.prank(alice);
        pos.withdraw(0);
        assertEq(pallet.submits(), submits);
        assertFalse(hasPending(pos));
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.TailUnfunded));
        assertGe(_hf(), hf);
    }

    function test_withdraw_should_raise_hf_every_rung_when_exiting_under_step_hf_through_the_emergency_floor() public {
        pool.setLtvLt(address(prime), 6_700, 6_800);
        uint256 hf = _hf();
        assertLt(hf, 1.05e18);
        vm.prank(alice);
        pos.withdraw(0);
        uint256 rungs;
        (hf, rungs) = _riseEveryRung(hf, rungs);
        assertGt(rungs, 2);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertGe(_hf() + 1, 1.15e18);
    }

    function _riseEveryRung(uint256 hf, uint256 rungs) internal returns (uint256, uint256) {
        while (hasPending(pos)) {
            fill(FILL_BPS);
            uint256 next = pos.effectiveHealthFactor();
            assertGt(next, hf);
            hf = next;
            ++rungs;
        }
        return (hf, rungs);
    }

    function test_withdraw_should_stall_insufficient_headroom_at_1_01_and_continue_after_a_debt_asset_transfer()
        public
    {
        pool.setLtvLt(address(prime), 6_600, 6_700);
        assertLt(_hf(), 1.01e18);
        vm.prank(alice);
        pos.withdraw(0);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.InsufficientHeadroom));
        assertFalse(hasPending(pos));
        uint256 debt = vHollar.balanceOf(address(pos));
        uint256 cash = hollar.balanceOf(address(pos));
        hollar.mint(address(pos), 400e18);
        vm.prank(alice);
        pos.resume(0);
        assertEq(vHollar.balanceOf(address(pos)), debt - (cash + 400e18));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Exit));
    }

    function test_withdraw_should_pay_in_full_when_a_price_drop_pushed_the_position_above_l_dep() public {
        pool.setPrice(address(prime), 2.3e8);
        assertGt(pos.aaveLeverage(), 3.1e18);
        uint256 paid = _withdraw(100e6);
        assertEq(paid, 100e6);
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
    }

    function test_withdraw_should_replace_the_request_when_called_on_a_stalled_unwind() public {
        vm.prank(alice);
        pos.withdraw(400e6);
        pallet.setFailures(true, false, false);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        pallet.setFailures(false, false, false);
        uint256 paid = _withdraw(100e6);
        assertEq(paid, 100e6);
        assertEq(pos.request(), 100e6);
    }

    function test_close_should_revert_nothing_to_do_when_the_position_is_closed() public {
        _close();
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.NothingToDo.selector);
        pos.close();
    }

    function test_close_should_repay_residual_token_debt_under_one_base_unit_exactly() public {
        uint256 debt = vHollar.balanceOf(address(pos));
        hollar.mint(address(pos), debt - 1e9 - hollar.balanceOf(address(pos)));
        vm.prank(alice);
        pos.withdraw(0);
        assertEq(vHollar.balanceOf(address(pos)), 1e9, "under one base unit of 18-decimal debt");
        (, uint256 d,,) = account(pos);
        assertEq(d, 0, "Aave reads it as zero");
        _close();
        assertEq(vHollar.balanceOf(address(pos)), 0);
        assertTrue(pos.isClosed());
    }

    function test_views_should_not_divide_by_zero_when_equity_is_zero() public {
        pool.setPrice(address(prime), 0.5e8);
        assertEq(pos.aaveLeverage(), type(uint256).max);
        assertEq(pos.nav(), 0);
        assertEq(pos.leverage(), 0);
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.NothingToDo.selector);
        pos.withdraw(1e6);
    }

    function test_rung_down_should_repay_an_unwind_remainder_under_the_floor_from_cash() public {
        pokeMinIntentAToken(pos, 1_000e6);
        hollar.mint(address(pos), 10e18);
        uint256 debt = vHollar.balanceOf(address(pos));
        uint256 paid = _withdraw(0.5e6);
        assertEq(paid, 0.5e6);
        assertLt(vHollar.balanceOf(address(pos)), debt);
        assertEq(pallet.submits(), pallet.counter());
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
    }

    function test_rung_down_should_stall_tail_unfunded_and_finish_after_a_top_up_when_cash_cannot_cover_the_tail()
        public
    {
        pokeMinIntentAToken(pos, 1_000e6);
        uint256 submits = pallet.submits();
        vm.prank(alice);
        pos.withdraw(50e6);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.TailUnfunded));
        assertEq(hollar.balanceOf(address(pos)), 0, "the cash went into the tail");
        assertEq(pallet.submits(), submits);
        hollar.mint(address(pos), 500e18);
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.resume(0);
        assertEq(prime.balanceOf(alice) - before, 50e6);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
    }

    function test_rung_down_should_stall_with_the_remainder_and_resume_when_cap_clipped_headroom_returns() public {
        pokeMinIntentAToken(pos, 100e6);
        // HF 1.08: cap = 0.9 * (C - 1.05 D / LT) is about 74 PRIME, under the 100 PRIME floor
        pool.setLtvLt(address(prime), 7_000, 7_200);
        vm.recordLogs();
        vm.prank(alice);
        pos.withdraw(0);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.TailUnfunded));
        assertFalse(hasPending(pos));
        (uint256 c, uint256 d,,) = account(pos);
        uint256 target = Math.mulDiv(c - d, 7_200e14, 1.15e18 - 7_200e14);
        uint256 remainder = Math.mulDiv(d - target, 1e18, 1e8, Math.Rounding.Up);
        assertEq(_stopRemainder(), remainder);
        assertGt(remainder, 100e18, "a cap-clipped remainder is large, reported as a stall");

        pool.setPrice(address(prime), 2.55e8);
        vm.prank(alice);
        pos.resume(0);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Exit));
    }

    function _stopRemainder() internal returns (uint256 remainder) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILooperPosition.LadderStopped.selector) {
                (, remainder) = abi.decode(logs[i].data, (ILooperPosition.Stall, uint256));
            }
        }
    }

    function test_rung_down_should_not_submit_an_exit_when_min_intent_debt_exceeds_any_min_out() public {
        pokeMinIntentDebt(pos, 1_000_000e18);
        uint256 submits = pallet.submits();
        vm.prank(alice);
        pos.withdraw(100e6);
        assertEq(pallet.submits(), submits);
        assertFalse(hasPending(pos));
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.TailUnfunded));
    }

    function test_withdraw_should_return_a_floored_slivers_excess_as_collateral_leaving_no_cash() public {
        uint256 paid = _withdraw(5e6);
        assertEq(paid, 5e6);
        assertEq(hollar.balanceOf(address(pos)), 0, "excess proceeds repaid");
    }

    function test_close_should_replace_a_stalled_partial_unwind_and_ignore_its_request() public {
        vm.prank(alice);
        pos.withdraw(100e6);
        pallet.setFailures(true, false, false);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        pallet.setFailures(false, false, false);
        uint256 paid = _close();
        assertGt(paid, 900e6);
        assertTrue(pos.isClosed());
    }

    function test_close_should_sweep_raw_collateral_sent_to_the_clone() public {
        prime.mint(address(pos), 5e6);
        uint256 before = prime.balanceOf(alice);
        uint256 poolBefore = prime.balanceOf(address(pool));
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        uint256 withdrawn = poolBefore - prime.balanceOf(address(pool));
        assertEq(prime.balanceOf(address(pos)), 0);
        assertEq(prime.balanceOf(alice) - before, withdrawn + 5e6);
    }

    function test_normalise_should_disable_a_gifted_foreign_atoken_before_sizing_and_close_should_sweep_it() public {
        topUp(alice, pos, 100e6);
        giftAToken(dot, aDot, address(pos), 10e10);
        assertTrue(pool.isCollateral(address(pos), address(dot)), "Aave auto-enabled the gift");
        fill(FILL_BPS);
        assertFalse(pool.isCollateral(address(pos), address(dot)));
        (uint256 c,,,) = account(pos);
        assertEq(c, pool.toBase(address(pos), address(prime), aPrime.balanceOf(address(pos))));
        ramp(pos);
        _close();
        assertEq(aDot.balanceOf(alice), 10e10);
        assertTrue(pos.isClosed());
    }

    function test_withdraw_should_exit_when_a_gifted_collateral_was_given_zero_ltv() public {
        giftAToken(dot, aDot, address(pos), 10e10);
        pool.setLtvLt(address(dot), 0, 7_000);
        uint256 paid = _withdraw(100e6);
        assertEq(paid, 100e6);
        assertFalse(pool.isCollateral(address(pos), address(dot)));
    }
}
