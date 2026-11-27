// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// A sliver refunded into a closed position still leaves when governance has set the collateral LTV to 0. Built
// from the audit PoC, where the collateral enable in `_normalise` reverted and locked the sliver.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract LtvZeroRefundTest is Fixture {
    /// @dev The first exit sliver expires and its removal fails, so the close finishes without it. Then PRIME's
    /// LTV goes to 0 and the cleanup refunds the sliver, which lands with the collateral flag off.
    function refundedAtLtvZero() internal returns (LooperPosition pos, uint256 sliver) {
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.prank(alice);
        pos.close();
        uint128 id = liveId();
        sliver = pend(pos).amountIn;
        warpPastDeadline(pos);
        pallet.setFailures(false, true, false);
        vm.prank(alice);
        pos.resume(id);
        pallet.setFailures(false, false, false);
        vm.prank(alice);
        pos.resume(0);
        drive(pos, 80);
        assertTrue(pos.isClosed(), "closed without the sliver");

        pool.setLtvLt(address(prime), 0, 8_000);
        pallet.cleanup(id);
        assertEq(aPrime.balanceOf(address(pos)), sliver, "sliver back as aPRIME");
        assertFalse(pool.isCollateral(address(pos), address(prime)), "no auto-enable at LTV 0");
    }

    function test_close_should_pay_out_a_refunded_sliver_when_the_collateral_ltv_is_zero() public {
        (LooperPosition pos, uint256 sliver) = refundedAtLtvZero();
        uint256 before = prime.balanceOf(alice);

        vm.prank(alice);
        pos.close();

        assertEq(prime.balanceOf(alice) - before, sliver, "Alice got the whole sliver");
        assertEq(aPrime.balanceOf(address(pos)), 0, "nothing left inside");
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertTrue(pos.isClosed());
    }
}
