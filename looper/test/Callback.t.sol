// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {IIntentForward} from "../src/interfaces/IIntentForward.sol";
import {LooperPosition} from "../src/LooperPosition.sol";
import {MockIntentDispatch} from "./mocks/MockIntentDispatch.sol";

contract CallbackTest is Fixture {
    LooperPosition internal pos;
    MockIntentDispatch.Forward internal f;

    function setUp() public override {
        super.setUp();
        pos = open(alice, DEPOSIT, 3e18);
        fillOnly(FILL_BPS);
        f = pallet.popTop();
    }

    function _execute(
        address sender,
        address owner_,
        uint256 id,
        address aIn,
        uint256 amtIn,
        address aOut,
        uint256 amtOut,
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender, sender);
        (ok, ret) = address(pos).call{gas: GAS_LIMIT}(
            abi.encodeCall(IIntentForward.execute, (owner_, id, aIn, amtIn, aOut, amtOut, data))
        );
    }

    function _expectWrongIntent(bool ok, bytes memory ret) internal {
        assertFalse(ok);
        assertEq(bytes4(ret), ILooperPosition.WrongIntent.selector);
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry), "record untouched");
    }

    function test_execute_should_revert_wrong_intent_when_the_sender_is_not_the_position() public {
        (bool ok, bytes memory ret) =
            _execute(stranger, address(pos), f.id, address(hollar), f.amountIn, address(aPrime), f.amountOut, f.data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_owner_argument_is_not_the_position() public {
        (bool ok, bytes memory ret) =
            _execute(address(pos), stranger, f.id, address(hollar), f.amountIn, address(aPrime), f.amountOut, f.data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_nonce_was_never_issued() public {
        bytes memory data = abi.encode(ILooperPosition.Kind.Entry, uint64(pos.nonce() + 1));
        (bool ok, bytes memory ret) =
            _execute(address(pos), address(pos), f.id, address(hollar), f.amountIn, address(aPrime), f.amountOut, data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_asset_in_differs() public {
        (bool ok, bytes memory ret) =
            _execute(address(pos), address(pos), f.id, address(prime), f.amountIn, address(aPrime), f.amountOut, f.data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_asset_out_differs() public {
        (bool ok, bytes memory ret) =
            _execute(address(pos), address(pos), f.id, address(hollar), f.amountIn, address(prime), f.amountOut, f.data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_amount_in_differs() public {
        (bool ok, bytes memory ret) = _execute(
            address(pos), address(pos), f.id, address(hollar), f.amountIn - 1, address(aPrime), f.amountOut, f.data
        );
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_amount_out_is_under_min_out() public {
        uint256 minOut = pend(pos).minOut;
        (bool ok, bytes memory ret) =
            _execute(address(pos), address(pos), f.id, address(hollar), f.amountIn, address(aPrime), minOut - 1, f.data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_revert_wrong_intent_when_the_id_is_from_another_second() public {
        uint256 id = (uint256(uint128((block.timestamp + 1) * 1000)) << 64) | 1;
        (bool ok, bytes memory ret) =
            _execute(address(pos), address(pos), id, address(hollar), f.amountIn, address(aPrime), f.amountOut, f.data);
        _expectWrongIntent(ok, ret);
    }

    function test_execute_should_acknowledge_and_ignore_when_the_intent_was_already_settled() public {
        (bool ok, bytes memory ret) = _execute(
            address(pos), address(pos), f.id, address(hollar), f.amountIn, address(aPrime), f.amountOut, f.data
        );
        assertTrue(ok);
        assertEq(bytes4(ret), IIntentForward.execute.selector);
        ILooperPosition.PendingIntent memory next = pend(pos);
        uint256 submits = pallet.submits();
        (ok, ret) = _execute(
            address(pos), address(pos), f.id, address(hollar), f.amountIn, address(aPrime), f.amountOut, f.data
        );
        assertTrue(ok);
        assertEq(bytes4(ret), IIntentForward.execute.selector);
        assertEq(pend(pos).nonce, next.nonce);
        assertEq(pallet.submits(), submits);
    }

    function test_execute_should_record_intent_rejected_on_the_reserved_gas_when_submit_intent_fails_in_the_callback()
        public
    {
        uint256 debtBefore = vHollar.balanceOf(address(pos));
        uint256 cashBefore = hollar.balanceOf(address(pos));
        pallet.setFailures(true, false, false);
        (bool ok, bytes memory ret) = _execute(
            address(pos), address(pos), f.id, address(hollar), f.amountIn, address(aPrime), f.amountOut, f.data
        );
        assertTrue(ok, "catch path completes inside the forward gas limit");
        assertEq(bytes4(ret), IIntentForward.execute.selector);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        assertFalse(hasPending(pos));
        assertEq(vHollar.balanceOf(address(pos)), debtBefore, "the borrow rolled back with the dispatch");
        assertEq(hollar.balanceOf(address(pos)), cashBefore);
        assertLane(pos);
    }
}

contract ExitCallbackTest is Fixture {
    function test_exit_callback_should_repay_all_proceeds_and_charge_the_fee_in_the_fee_asset_when_an_exit_fills()
        public
    {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.prank(alice);
        pos.withdraw(400e6);
        uint256 exits;
        while (hasPending(pos)) {
            uint256 budget = hdx.balanceOf(address(pos));
            fill(FILL_BPS);
            assertEq(budget - hdx.balanceOf(address(pos)), FEE, "fee paid from the budget");
            if (hasPending(pos)) assertEq(hollar.balanceOf(address(pos)), 0, "proceeds repaid by the next rung");
            ++exits;
        }
        assertGt(exits, 1);
    }

    function test_resume_should_settle_filled_when_an_exit_filled_near_min_out_had_its_fee_charged_and_callback_consumed(
    ) public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.prank(alice);
        pos.withdraw(400e6);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        assertEq(pi.reconcileOut, pi.minOut, "the fee is not taken from the proceeds");
        uint128 id = liveId();
        uint256 cash = hollar.balanceOf(address(pos));
        uint256 budget = hdx.balanceOf(address(pos));
        pallet.fill(id, pi.minOut);
        assertEq(hollar.balanceOf(address(pos)), cash + pi.minOut);
        assertEq(hdx.balanceOf(address(pos)), budget - FEE);
        dropForward();

        warpPastDeadline(pos);
        uint256 debtBefore = vHollar.balanceOf(address(pos));
        vm.expectEmit(address(pos));
        emit ILooperPosition.RungFilled(ILooperPosition.Kind.Exit, pi.nonce, pi.minOut);
        vm.prank(alice);
        pos.resume(id);
        assertLt(vHollar.balanceOf(address(pos)), debtBefore, "the next rung's normalise repaid the proceeds");
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Exit));
    }

    function test_rung_should_stall_fee_budget_low_with_the_shortfall_and_roll_back_the_borrow_when_the_budget_ran_low()
        public
    {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        hdx.burn(address(pos), hdx.balanceOf(address(pos)) - FEE_RESERVE);
        uint256 debtBefore = vHollar.balanceOf(address(pos));
        vm.recordLogs();
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow));
        assertFalse(hasPending(pos));
        assertEq(vHollar.balanceOf(address(pos)), debtBefore, "no borrow without a submitted rung");
        assertEq(_stopRemainder(), FEE, "the forward fee left the budget one fee short");
        assertLane(pos);
    }

    function test_resume_should_continue_the_ladder_when_anyone_topped_up_the_fee_budget() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        hdx.burn(address(pos), hdx.balanceOf(address(pos)) - FEE);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow));

        hdx.mint(stranger, 100e12);
        vm.prank(stranger);
        hdx.transfer(address(pos), 100e12);
        vm.prank(alice);
        pos.resume(0);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry));
    }

    function test_set_fee_reserve_should_stall_the_next_rung_when_raised_above_the_budget() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        setFeeReserve(pos, FEE_BUDGET);
        assertEq(pend(pos).reconcileOut, pi.reconcileOut, "the in-flight intent is untouched");
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow));
        setFeeReserve(pos, FEE_RESERVE);
        vm.prank(alice);
        pos.resume(0);
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry));
    }

    function _stopRemainder() internal returns (uint256 remainder) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILooperPosition.LadderStopped.selector) {
                (, remainder) = abi.decode(logs[i].data, (ILooperPosition.Stall, uint256));
            }
        }
    }
}
