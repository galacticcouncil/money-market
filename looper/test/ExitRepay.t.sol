// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Filled exit proceeds stay repaid when the next rung cannot submit. Built from the audit PoC, where a
// FeeBudgetLow or IntentRejected revert rolled the repay back and left the proceeds idle at the in-flight HF.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract ExitRepayTest is Fixture {
    LooperPosition internal pos;

    function setUp() public override {
        super.setUp();
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        pool.setLtvLt(address(prime), 6_700, 6_800); // HF under stepHf: emergency slivers
    }

    function hf() internal view returns (uint256 h) {
        (,,, h) = account(pos);
    }

    function test_exit_fill_should_stay_repaid_when_the_next_rung_stalls_fee_budget_low() public {
        hdx.burn(address(pos), hdx.balanceOf(address(pos)) - FEE_RESERVE); // the fill's fee drops it under
        vm.prank(alice);
        pos.withdraw(0);
        uint256 debtInFlight = vHollar.balanceOf(address(pos));
        uint256 hfInFlight = hf();

        fill(FILL_BPS);

        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow));
        assertLt(vHollar.balanceOf(address(pos)), debtInFlight, "proceeds repaid");
        assertEq(hollar.balanceOf(address(pos)), 0, "no idle proceeds");
        assertGt(hf(), hfInFlight, "HF above the in-flight floor");
    }

    function test_exit_fill_should_stay_repaid_when_the_next_intent_is_rejected() public {
        vm.prank(alice);
        pos.withdraw(0);
        uint256 debtInFlight = vHollar.balanceOf(address(pos));
        uint256 hfInFlight = hf();

        fillOnly(FILL_BPS);
        pallet.setFailures(true, false, false);
        (bool ok,) = dispatchTop();
        assertTrue(ok, "callback acknowledges");

        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        assertLt(vHollar.balanceOf(address(pos)), debtInFlight, "proceeds repaid");
        assertEq(hollar.balanceOf(address(pos)), 0, "no idle proceeds");
        assertGt(hf(), hfInFlight, "HF above the in-flight floor");
    }

    /// @dev The exit stalls FeeBudgetLow and the fee budget stays under the reserve, so every next rung stalls too.
    function stalledFeeBudgetLow() internal {
        hdx.burn(address(pos), hdx.balanceOf(address(pos)) - FEE_RESERVE);
        vm.prank(alice);
        pos.withdraw(0);
        fill(FILL_BPS);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow));
    }

    function test_resume_should_keep_debt_asset_sent_in_repaid_when_the_next_rung_stalls_again() public {
        stalledFeeBudgetLow();
        uint256 debt = vHollar.balanceOf(address(pos));
        hollar.mint(address(pos), 400e18);

        vm.prank(alice);
        pos.resume(0);

        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow), "still stalls");
        assertEq(vHollar.balanceOf(address(pos)), debt - 400e18, "the 400 HOLLAR repaid");
        assertEq(hollar.balanceOf(address(pos)), 0, "nothing idle");
    }

    function test_close_should_keep_debt_asset_sent_in_repaid_when_its_first_rung_stalls() public {
        stalledFeeBudgetLow();
        uint256 debt = vHollar.balanceOf(address(pos));
        hollar.mint(address(pos), 400e18);

        vm.prank(alice);
        pos.close();

        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow), "still stalls");
        assertEq(vHollar.balanceOf(address(pos)), debt - 400e18, "the 400 HOLLAR repaid");
        assertEq(hollar.balanceOf(address(pos)), 0, "nothing idle");
    }

    function test_resume_should_keep_late_settled_exit_proceeds_repaid_when_the_next_intent_is_rejected() public {
        vm.prank(alice);
        pos.withdraw(0);
        uint256 debtInFlight = vHollar.balanceOf(address(pos));
        (uint128 id,) = fillOnly(FILL_BPS);
        dropForward(); // the callback never runs, so the fill is settled late by resume
        warpPastDeadline(pos);
        pallet.setFailures(true, false, false);

        vm.prank(alice);
        pos.resume(id);

        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.IntentRejected));
        assertLt(vHollar.balanceOf(address(pos)), debtInFlight, "proceeds repaid");
        assertEq(hollar.balanceOf(address(pos)), 0, "no idle proceeds");
    }
}
