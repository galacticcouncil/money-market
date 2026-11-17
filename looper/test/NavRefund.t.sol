// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// An expired intent refunded by cleanup while still pending: the views count that input once, not twice.

import {Fixture} from "./helpers/Fixture.t.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract NavRefundTest is Fixture {
    /// @dev Alice's position with its first entry pending. Returns the position and that entry's intent id.
    function liveEntry() internal returns (LooperPosition pos, uint128 id) {
        pos = open(alice, DEPOSIT, 3e18);
        id = liveId();
    }

    /// @dev Alice's ramped position with its first exit pending after close(). Returns the position and the id.
    function liveExit() internal returns (LooperPosition pos, uint128 id) {
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.prank(alice);
        pos.close();
        id = liveId();
    }

    function test_nav_should_not_move_when_a_pending_entry_is_refunded() public {
        (LooperPosition pos, uint128 id) = liveEntry();
        uint256 before = pos.nav();

        warpPastDeadline(pos);
        pallet.cleanup(id);

        assertEq(pos.nav(), before);
    }

    function test_nav_should_not_move_when_a_pending_exit_is_refunded() public {
        (LooperPosition pos, uint128 id) = liveExit();
        uint256 before = pos.nav();

        warpPastDeadline(pos);
        pallet.cleanup(id);

        assertEq(pos.nav(), before);
    }

    function test_effective_hf_should_equal_hf_when_a_pending_exit_is_refunded() public {
        (LooperPosition pos, uint128 id) = liveExit();

        warpPastDeadline(pos);
        pallet.cleanup(id);

        assertEq(pos.effectiveHealthFactor(), pos.healthFactor());
    }

    function test_leverage_should_not_move_when_a_pending_entry_is_refunded() public {
        (LooperPosition pos, uint128 id) = liveEntry();
        uint256 before = pos.leverage();

        warpPastDeadline(pos);
        pallet.cleanup(id);

        assertEq(pos.leverage(), before);
    }

    function test_nav_should_count_a_gift_of_the_input_while_an_entry_is_live() public {
        (LooperPosition pos,) = liveEntry();
        uint256 before = pos.nav();
        hollar.mint(stranger, 100e18);

        vm.prank(stranger);
        hollar.transfer(address(pos), 100e18);

        assertEq(pos.nav(), before + 40e6, "100 HOLLAR at 2.50 per PRIME");
    }

    function test_nav_should_count_an_atoken_gift_while_an_exit_is_live() public {
        (LooperPosition pos,) = liveExit();
        uint256 before = pos.nav();

        giftAToken(prime, aPrime, address(pos), 10e6);

        assertEq(pos.nav(), before + 10e6);
    }

    function test_nav_should_stay_put_when_the_owner_resumes_a_refunded_entry() public {
        (LooperPosition pos, uint128 id) = liveEntry();
        uint256 before = pos.nav();
        warpPastDeadline(pos);
        pallet.cleanup(id);

        vm.prank(alice);
        pos.resume(id);

        assertEq(pos.nav(), before);
    }
}
