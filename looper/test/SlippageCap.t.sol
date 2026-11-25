// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Slippage is capped at 5 %, so a seller cannot plant a near-zero minOut exit before an NFT sale. Built from the
// audit PoC, where a 99 % exit filled at minOut cost the buyer a third of the position.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperFactory} from "../src/interfaces/ILooperFactory.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract SlippageCapTest is Fixture {
    function test_set_slippage_should_revert_slippage_too_high_above_five_percent() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        vm.startPrank(alice);
        vm.expectRevert(ILooperPosition.SlippageTooHigh.selector);
        pos.setSlippage(501);
        vm.expectRevert(ILooperPosition.SlippageTooHigh.selector);
        pos.setSlippage(9_900);
        vm.stopPrank();
        assertEq(pos.slippageBps(), SLIP, "unchanged");
    }

    function test_set_slippage_should_accept_exactly_five_percent() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        vm.prank(alice);
        pos.setSlippage(500);
        assertEq(pos.slippageBps(), 500);
    }

    function test_open_should_revert_invalid_params_when_slippage_is_above_five_percent() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.slippageBps = 501;
        vm.prank(alice);
        vm.expectRevert(ILooperFactory.InvalidParams.selector);
        factory.open(p, DEPOSIT, FEE_BUDGET);
    }

    /// @dev The PoC again, at the widest slippage the cap allows: the buyer loses at most 5 % of the live sliver.
    function test_sale_with_a_live_exit_should_cost_the_buyer_at_most_five_percent_of_the_sliver() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.startPrank(alice);
        pos.setSlippage(500);
        pos.close();
        vm.stopPrank();
        ILooperPosition.PendingIntent memory p = pend(pos);
        uint256 navListed = pos.nav();

        uint256 id = pos.tokenId();
        vm.prank(alice);
        factory.transferFrom(alice, bob, id);

        uint256 fairOut = uint256(p.amountIn) * 2.5e8 * 1e18 / (1e8 * 1e6);
        assertGe(uint256(p.minOut), fairOut * 95 / 100, "minOut is at least 95 % of the sliver");
        pallet.fill(liveId(), p.minOut);
        (bool ok,) = dispatchTop();
        assertTrue(ok, "callback");

        assertGe(pos.nav(), navListed - uint256(p.amountIn) * 5 / 100, "buyer lost at most 5 % of the sliver");
    }
}
