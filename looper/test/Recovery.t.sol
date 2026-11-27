// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {Units} from "../src/lib/Units.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";
import {MockIntentDispatch} from "./mocks/MockIntentDispatch.sol";

contract RecoveryTest is Fixture {
    using stdStorage for StdStorage;

    function _openRamped() internal returns (LooperPosition pos) {
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
    }

    function _exitPending() internal returns (LooperPosition pos) {
        pos = _openRamped();
        vm.prank(alice);
        pos.withdraw(400e6);
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Exit));
    }

    function _resume(LooperPosition pos, uint128 id) internal {
        vm.prank(alice);
        pos.resume(id);
    }

    function _state(uint128 id) internal view returns (MockIntentDispatch.State) {
        return pallet.intent(id).state;
    }

    function test_donation_should_leave_the_record_untouched_when_the_output_arrives_before_the_deadline() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint128 id = liveId();
        giftAToken(prime, aPrime, address(pos), pi.minOut);
        assertEq(abi.encode(pend(pos)), abi.encode(pi));
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.Busy.selector);
        pos.resume(id);
        assertEq(uint8(_state(id)), uint8(MockIntentDispatch.State.Open));
        fill(FILL_BPS);
        assertEq(pend(pos).nonce, pi.nonce + 1);
    }

    function test_resume_should_settle_returned_then_resubmit_with_new_slippage_when_an_entry_expired() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint128 id = liveId();
        warpPastDeadline(pos);
        pallet.cleanup(id);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));
        assertFalse(hasPending(pos));

        vm.prank(alice);
        pos.setSlippage(250);
        _resume(pos, 0);
        ILooperPosition.PendingIntent memory next = pend(pos);
        assertEq(uint8(next.kind), uint8(ILooperPosition.Kind.Entry));
        assertEq(next.amountIn, pi.amountIn, "the returned input is the next rung's idle cash");
        uint256 fair =
            Units.fromBase(Units.toBase(next.amountIn, 1e8, 18, Math.Rounding.Down), 2.5e8, 6, Math.Rounding.Down);
        assertEq(next.minOut, fair * 9_750 / 10_000);
        assertLane(pos);
    }

    function test_resume_should_settle_returned_then_resubmit_with_new_slippage_when_an_exit_expired() public {
        LooperPosition pos = _exitPending();
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint128 id = liveId();
        warpPastDeadline(pos);
        pallet.cleanup(id);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));

        vm.prank(alice);
        pos.setSlippage(250);
        _resume(pos, 0);
        ILooperPosition.PendingIntent memory next = pend(pos);
        assertEq(uint8(next.kind), uint8(ILooperPosition.Kind.Exit));
        assertLe(next.amountIn, pi.amountIn);
        uint256 fair =
            Units.fromBase(Units.toBase(next.amountIn, 2.5e8, 6, Math.Rounding.Down), 1e8, 18, Math.Rounding.Down);
        assertEq(next.minOut, fair * 9_750 / 10_000);
        assertLane(pos);
    }

    function test_cancel_should_stall_without_resubmitting_when_called_mid_ladder() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        fill(FILL_BPS);
        uint128 id = liveId();
        uint256 submits = pallet.submits();
        vm.expectEmit(address(pos));
        emit ILooperPosition.Cancelled();
        vm.prank(alice);
        pos.cancel(id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Cancelled));
        assertFalse(hasPending(pos));
        assertEq(pallet.submits(), submits);
        assertEq(uint8(_state(id)), uint8(MockIntentDispatch.State.Returned));
        assertLane(pos);
    }

    function test_resume_should_remove_and_settle_returned_when_an_expired_intent_was_never_cleaned_up() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId();
        uint256 cash = hollar.balanceOf(address(pos));
        uint256 amountIn = pend(pos).amountIn;
        warpPastDeadline(pos);
        _resume(pos, id);
        assertEq(uint8(_state(id)), uint8(MockIntentDispatch.State.Returned));
        assertEq(hollar.balanceOf(address(pos)), cash + amountIn);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));
        assertLane(pos);
    }

    function test_cancel_should_revert_wrong_intent_when_the_id_is_from_another_second() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId() + (uint128(1000) << 64);
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.WrongIntent.selector);
        pos.cancel(id);
    }

    function test_cancel_should_revert_wrong_intent_when_the_id_is_a_strangers_from_the_same_second() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        open(bob, DEPOSIT, 3e18);
        uint128 bobs = liveId();
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.WrongIntent.selector);
        pos.cancel(bobs);
        assertEq(uint8(_state(bobs)), uint8(MockIntentDispatch.State.Open));
    }

    function test_cancel_should_revert_wrong_intent_when_the_id_is_the_positions_own_earlier_intent() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 first = liveId();
        fillOnly(FILL_BPS);
        vm.warp(block.timestamp + 2);
        (bool ok,) = dispatchTop();
        assertTrue(ok);
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.WrongIntent.selector);
        pos.cancel(first);
    }

    function test_resume_should_revert_busy_when_called_before_the_deadline_whatever_the_balances() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId();
        fillOnly(FILL_BPS);
        dropForward();
        vm.warp(pend(pos).deadline / 1000 - 1);
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.Busy.selector);
        pos.resume(id);
    }

    function test_resume_should_settle_returned_and_absorb_the_late_return_when_removal_fails_with_the_input_reserved()
        public
    {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId();
        uint256 amountIn = pend(pos).amountIn;
        warpPastDeadline(pos);
        pallet.setFailures(false, true, false);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));
        assertEq(uint8(_state(id)), uint8(MockIntentDispatch.State.Open), "still reserved: the owner's inference");

        pallet.cleanup(id);
        pallet.setFailures(false, false, false);
        _resume(pos, 0);
        assertEq(pend(pos).amountIn, amountIn, "the late return is the next rung's input");
        assertEq(pallet.liveCount(address(pos)), 1);
    }

    function test_resume_should_settle_returned_when_the_returned_input_is_one_wei_short() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId();
        ILooperPosition.PendingIntent memory pi = pend(pos);
        warpPastDeadline(pos);
        pallet.cleanup(id);
        hollar.burn(address(pos), 1);
        vm.expectEmit(address(pos));
        emit ILooperPosition.RungReturned(ILooperPosition.Kind.Entry, pi.nonce);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));
    }

    function test_resume_should_run_one_rung_when_a_stalled_entry_has_nothing_pending() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        pool.setRefusals(true, false, false);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.AaveRefused));
        pool.setRefusals(false, false, false);
        _resume(pos, 0);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry));
    }

    function test_resume_should_run_one_rung_when_a_stalled_exit_has_nothing_pending() public {
        LooperPosition pos = _exitPending();
        pallet.setFailures(true, false, false);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        pallet.setFailures(false, false, false);
        _resume(pos, 0);
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Exit));
    }

    function test_resume_should_reach_the_callbacks_aave_state_when_a_dropped_forward_is_reconciled_as_filled()
        public
    {
        LooperPosition a = open(alice, DEPOSIT, 3e18);
        uint128 idA = liveId();
        LooperPosition b = open(bob, DEPOSIT, 3e18);
        uint128 idB = liveId();
        pallet.resetCurrency(address(b));

        fillId(idA, FILL_BPS);
        (bool ok,) = dispatchTop();
        assertTrue(ok);
        fillId(idB, FILL_BPS);
        assertEq(pallet.queueLength(), 1, "b's forward was not queued");

        vm.warp(pend(b).deadline / 1000 + 1);
        vm.prank(bob);
        b.resume(idB);
        (uint256 ca, uint256 da,,) = account(a);
        (uint256 cb, uint256 db,,) = account(b);
        assertEq(cb, ca);
        assertEq(db, da);
        assertTrue(pool.isCollateral(address(b), address(prime)));
        assertEq(pend(b).amountIn, pend(a).amountIn);
        assertEq(hdx.balanceOf(address(b)) - hdx.balanceOf(address(a)), FEE, "b paid no forward fee");
    }

    function test_resume_should_settle_filled_when_the_budget_could_not_pay_the_forward_fee() public {
        LooperPosition pos = _exitPending();
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint128 id = liveId();
        uint256 budget = hdx.balanceOf(address(pos));
        pallet.setFee(budget + 1);
        pallet.fill(id, pi.minOut);
        assertEq(pallet.queueLength(), pallet.head(), "forward not queued");
        assertEq(hdx.balanceOf(address(pos)), budget, "no fee charged");
        pallet.setFee(FEE);
        warpPastDeadline(pos);
        vm.expectEmit(address(pos));
        emit ILooperPosition.RungFilled(ILooperPosition.Kind.Exit, pi.nonce, pi.minOut);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
    }

    /// @dev Intents submitted in the same block share the id prefix, so `resume` accepts another account's
    /// id; its removal fails and the pending intent is classified by its output delta, as after a cleanup.
    function test_resume_should_classify_by_output_delta_when_given_another_accounts_same_block_id() public {
        LooperPosition a = open(alice, DEPOSIT, 3e18);
        uint128 idA = liveId();
        LooperPosition b = open(bob, DEPOSIT, 3e18);
        uint128 idB = liveId();
        assertEq(idA >> 64, idB >> 64, "same submission prefix");
        uint256 cashB = hollar.balanceOf(address(b));
        uint256 amountIn = pend(b).amountIn;

        vm.warp(pend(b).deadline / 1000 + 1);
        vm.prank(bob);
        b.resume(idA);
        assertEq(uint8(b.stalled()), uint8(ILooperPosition.Stall.Returned));
        assertFalse(hasPending(b));
        assertEq(pallet.liveCount(address(b)), 1, "b's real intent stays until cleaned up");
        assertEq(pallet.liveCount(address(a)), 1, "a's intent untouched");
        assertEq(hollar.balanceOf(address(b)), cashB, "nothing returned yet");

        pallet.cleanup(idB);
        assertEq(hollar.balanceOf(address(b)), cashB + amountIn);
        vm.prank(bob);
        b.resume(0);
        assertEq(pend(b).amountIn, amountIn, "the late return is swapped by the next rung");
        assertEq(hollar.balanceOf(address(b)), 0);
    }

    function test_resume_should_not_infer_a_fill_when_the_index_grows_over_a_long_wait_on_a_large_position() public {
        LooperPosition pos = open(alice, 100_000e6, 1.005e18);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint128 id = liveId();
        assertLt(pi.reconcileOut, aPrime.balanceOf(address(pos)) / 100, "a small rung on a large position");
        aPrime.setIndex(2e27);
        assertGt(aPrime.balanceOf(address(pos)), 100_000e6 + pi.reconcileOut, "balanceOf alone would cross it");
        assertGt(pos.nav(), 0);
        warpPastDeadline(pos);
        pallet.setFailures(false, true, false);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));
    }

    function test_normalise_should_stall_with_assets_intact_when_enabling_collateral_fails() public {
        pallet.setFailures(true, false, false);
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        pallet.setFailures(false, false, false);
        // with no debt the position's own flag can be off with a balance, which normalise must restore
        vm.prank(address(pos));
        pool.setUserUseReserveAsCollateral(address(prime), false);
        pool.setRefusals(false, true, false);
        _resume(pos, 0);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.AaveRefused));
        assertFalse(hasPending(pos));
        assertEq(vHollar.balanceOf(address(pos)), 0);
        assertEq(aPrime.balanceOf(address(pos)), DEPOSIT);
        assertEq(pallet.liveCount(address(pos)), 0);

        pool.setRefusals(false, false, false);
        vm.prank(alice);
        pos.close();
        assertTrue(pos.isClosed());
        assertEq(aPrime.balanceOf(address(pos)), 0);
    }

    function test_normalise_should_stall_with_assets_intact_when_the_repay_fails() public {
        LooperPosition pos = _exitPending();
        pool.setRefusals(false, false, true);
        uint256 debt = vHollar.balanceOf(address(pos));
        (, uint256 out) = fillOnly(FILL_BPS);
        uint256 cash = hollar.balanceOf(address(pos));
        (bool ok,) = dispatchTop();
        assertTrue(ok);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.AaveRefused));
        assertFalse(hasPending(pos));
        assertEq(vHollar.balanceOf(address(pos)), debt);
        assertEq(hollar.balanceOf(address(pos)), cash);
        assertGe(cash, out);

        pool.setRefusals(false, false, false);
        vm.prank(alice);
        pos.withdraw(100e6);
        drive(pos, 80);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
    }

    function test_resume_should_classify_an_entry_donation_one_unit_below_and_exactly_at_reconcile_out() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId();
        uint256 r = pend(pos).reconcileOut;
        warpPastDeadline(pos);
        pallet.setFailures(false, true, false);
        uint256 snap = vm.snapshot();

        giftAToken(prime, aPrime, address(pos), r - 1);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));

        vm.revertTo(snap);
        giftAToken(prime, aPrime, address(pos), r);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry), "filled: one rung attempt");
    }

    function test_resume_should_classify_an_exit_donation_one_unit_below_and_exactly_at_reconcile_out() public {
        LooperPosition pos = _exitPending();
        uint128 id = liveId();
        uint256 r = pend(pos).reconcileOut;
        warpPastDeadline(pos);
        pallet.setFailures(false, true, false);
        uint256 snap = vm.snapshot();

        hollar.mint(address(pos), r - 1);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));

        vm.revertTo(snap);
        uint64 n = pend(pos).nonce;
        hollar.mint(address(pos), r);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Exit), "filled: one rung attempt");
        assertEq(pend(pos).nonce, n + 1);
    }

    function test_entry_point_should_reassert_the_fee_currency_when_it_was_dropped_after_the_budget_hit_zero() public {
        LooperPosition pos = _openRamped();
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        assertEq(hdx.balanceOf(address(pos)), 0, "the budget was paid out on close");
        pallet.resetCurrency(address(pos));
        assertFalse(pallet.hasCurrency(address(pos)));

        vm.prank(alice);
        hdx.transfer(address(pos), FEE_BUDGET);
        topUp(alice, pos, DEPOSIT);
        assertTrue(pallet.hasCurrency(address(pos)));
        assertEq(pallet.currencyOf(address(pos)), HDX_ID);
        fillOnly(FILL_BPS);
        assertEq(pallet.queueLength(), pallet.head() + 1, "forward queued and paid");
    }

    function test_withdraw_should_unwind_a_stalled_ramp_when_an_entry_expired() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        topUp(alice, pos, 200e6);
        uint128 id = liveId();
        warpPastDeadline(pos);
        _resume(pos, id);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.Returned));
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.withdraw(100e6);
        drive(pos, 80);
        assertEq(prime.balanceOf(alice) - before, 100e6);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
    }

    function test_close_should_close_a_stalled_ramp_when_the_next_rung_failed() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        pool.setRefusals(true, false, false);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.AaveRefused));
        pool.setRefusals(false, false, false);
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        assertTrue(pos.isClosed());
        assertEq(vHollar.balanceOf(address(pos)), 0);
    }

    function test_entries_should_revert_fee_currency_rejected_when_set_currency_fails() public {
        LooperPosition pos = _openRamped();
        pallet.setFailures(false, false, true);
        ILooperPosition.Params memory p = defaultParams(3e18);
        uint256 id = pos.tokenId();
        vm.startPrank(alice);
        vm.expectRevert(ILooperPosition.FeeCurrencyRejected.selector);
        factory.open(p, DEPOSIT, FEE_BUDGET);
        vm.expectRevert(ILooperPosition.FeeCurrencyRejected.selector);
        factory.deposit(id, 10e6);
        vm.stopPrank();
    }

    /// @dev Without a fee currency no forward is queued; every fill still lands and `resume` settles it.
    function test_close_should_complete_through_resume_when_the_fee_asset_is_no_longer_accepted() public {
        LooperPosition pos = _openRamped();
        pallet.resetCurrency(address(pos));
        pallet.setFailures(false, false, true);
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.close();
        uint256 rungs;
        while (hasPending(pos) && rungs < 80) {
            uint128 id = liveId();
            fillId(id, FILL_BPS);
            assertEq(pallet.queueLength(), pallet.head(), "no forward without a fee currency");
            warpPastDeadline(pos);
            vm.prank(alice);
            pos.resume(id);
            ++rungs;
        }
        assertTrue(pos.isClosed());
        assertGt(prime.balanceOf(alice) - before, DEPOSIT * 95 / 100);
    }

    function test_is_closed_should_stay_false_when_principal_rounds_to_zero_with_assets_left() public {
        LooperPosition pos = _openRamped();
        stdstore.target(address(pos)).sig("principal()").checked_write(uint256(0));
        assertEq(pos.principal(), 0);
        assertFalse(pos.isClosed());
    }
}
