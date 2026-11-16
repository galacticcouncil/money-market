// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Cash that lands in a position after it fully closed: close() hands it to the current NFT holder.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract LateRefundTest is Fixture {
    address internal carol = makeAddr("carol");

    /// @dev Alice's position closed while its first entry was still reserved; cleanup then refunded that entry's
    /// HOLLAR into the closed position. Returns the position and the refund.
    function stuckRefund() internal returns (LooperPosition pos, uint256 refund) {
        pos = open(alice, DEPOSIT, 3e18);
        uint128 id = liveId();
        refund = pend(pos).amountIn;
        warpPastDeadline(pos);
        pallet.setFailures(false, true, false);
        vm.prank(alice);
        pos.resume(id);
        pallet.setFailures(false, false, false);
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        pallet.cleanup(id);
    }

    /// @dev Alice's position opened, ramped and closed the normal way, with nothing left inside.
    function closedNormally() internal returns (LooperPosition pos) {
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
    }

    function test_close_should_pay_the_holder_when_a_refund_lands_after_the_position_closed() public {
        (LooperPosition pos, uint256 refund) = stuckRefund();
        assertEq(hollar.balanceOf(address(pos)), refund, "refund sits in the closed position");
        uint256 before = hollar.balanceOf(alice);

        vm.prank(alice);
        pos.close();

        assertEq(hollar.balanceOf(alice), before + refund);
        assertEq(hollar.balanceOf(address(pos)), 0);
        assertTrue(pos.isClosed());
    }

    function test_close_should_revert_nothing_to_do_when_a_closed_position_holds_nothing() public {
        LooperPosition pos = closedNormally();
        assertTrue(pos.isClosed());

        vm.prank(alice);
        vm.expectRevert(ILooperPosition.NothingToDo.selector);
        pos.close();
    }

    function test_close_should_pay_again_when_more_cash_arrives_after_a_sweep() public {
        (LooperPosition pos,) = stuckRefund();
        vm.prank(alice);
        pos.close();

        hollar.mint(carol, 5e18);
        vm.prank(carol);
        hollar.transfer(address(pos), 5e18);
        uint256 before = hollar.balanceOf(alice);

        vm.prank(alice);
        pos.close();

        assertEq(hollar.balanceOf(alice), before + 5e18);
        assertEq(hollar.balanceOf(address(pos)), 0);
    }

    function test_close_should_pay_the_new_holder_when_the_nft_changed_hands() public {
        (LooperPosition pos, uint256 refund) = stuckRefund();
        uint256 tokenId = pos.tokenId();
        vm.prank(alice);
        factory.transferFrom(alice, bob, tokenId);
        uint256 aliceBefore = hollar.balanceOf(alice);
        uint256 bobBefore = hollar.balanceOf(bob);

        vm.prank(bob);
        pos.close();

        assertEq(hollar.balanceOf(bob), bobBefore + refund);
        assertEq(hollar.balanceOf(alice), aliceBefore);
    }

    function test_close_should_revert_not_owner_when_a_stranger_calls_it() public {
        (LooperPosition pos, uint256 refund) = stuckRefund();

        vm.prank(stranger);
        vm.expectRevert(ILooperPosition.NotOwner.selector);
        pos.close();

        assertEq(hollar.balanceOf(address(pos)), refund);
    }

    function test_close_should_return_collateral_and_fee_token_when_they_sit_in_a_closed_position() public {
        LooperPosition pos = closedNormally();
        prime.mint(carol, 7e6);
        hdx.mint(carol, 3e12);
        vm.startPrank(carol);
        prime.transfer(address(pos), 7e6);
        hdx.transfer(address(pos), 3e12);
        vm.stopPrank();
        uint256 primeBefore = prime.balanceOf(alice);
        uint256 hdxBefore = hdx.balanceOf(alice);

        vm.prank(alice);
        pos.close();

        assertEq(prime.balanceOf(alice), primeBefore + 7e6);
        assertEq(hdx.balanceOf(alice), hdxBefore + 3e12);
        assertEq(prime.balanceOf(address(pos)), 0);
        assertEq(hdx.balanceOf(address(pos)), 0);
    }

    function test_is_closed_should_stay_true_when_a_refund_sits_in_a_closed_position() public {
        (LooperPosition pos, uint256 refund) = stuckRefund();

        assertEq(hollar.balanceOf(address(pos)), refund);
        assertTrue(pos.isClosed());
    }
}
