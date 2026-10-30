// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {IIntentForward} from "../src/interfaces/IIntentForward.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract FuzzTest is Fixture {
    uint256 internal seed;

    function _rand(uint256 lo, uint256 hi) internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return lo + seed % (hi - lo + 1);
    }

    /// Fill at the solver's quote (never under the limit), moving the PRIME price a little between rungs.
    function _drive(LooperPosition pos) internal {
        for (uint256 i = 0; i < 120 && hasPending(pos); ++i) {
            uint128 id = liveId();
            uint256 out = pallet.quote(id, _rand(0, 90));
            uint256 minOut = pend(pos).minOut;
            pallet.fill(id, out > minOut ? out : minOut);
            pool.setPrice(address(prime), pool.getAssetPrice(address(prime)) * _rand(9_900, 10_100) / 10_000);
            (bool ok, bytes memory ret) = dispatchTop();
            assertTrue(ok, "callbacks never revert after the guards");
            assertEq(bytes4(ret), IIntentForward.execute.selector);
            assertLane(pos);
        }
        assertFalse(hasPending(pos), "ladder terminates");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_ladders_should_never_call_aave_with_zero_when_seed_leverage_and_prices_vary(
        uint256 seed_,
        uint256 amount,
        uint256 lev,
        uint256 withdrawBps
    ) public {
        seed = seed_;
        amount = bound(amount, 10e6, 100_000e6);
        lev = bound(lev, 1.1e18, 3.2e18);
        withdrawBps = bound(withdrawBps, 0, 9_000);
        prime.mint(alice, amount);
        LooperPosition pos = open(alice, amount, lev);
        _drive(pos);

        if (pos.stalled() == ILooperPosition.Stall.None) {
            vm.prank(alice);
            pos.withdraw(amount * withdrawBps / 10_000);
            _drive(pos);
        }
        vm.prank(alice);
        pos.close();
        _drive(pos);
        assertFalse(pool.sawZeroAmount(), "no Aave call with a zero amount");
        if (pos.stalled() == ILooperPosition.Stall.None) {
            assertTrue(pos.isClosed());
            assertEq(vHollar.balanceOf(address(pos)), 0);
        }
    }
}
