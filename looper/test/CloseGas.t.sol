// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// The last close rung runs inside the 2M fill callback, so it must not walk the reserve list (36 on mainnet).
// Checks the close skips that list and that its last callback fits the budget.

import {console2} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract CloseGasTest is Fixture {
    /// @dev Lists empty reserves until the pool has `n`, like mainnet's money market.
    function listReserves(uint256 n) internal {
        for (uint256 i = pool.getReservesList().length; i < n; ++i) {
            MockERC20 t = new MockERC20("filler", "FILL", 18);
            pool.addReserve(address(t), 18, 5_000, 6_000, 1e8);
        }
    }

    function test_close_should_finish_without_reading_the_reserve_list() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.expectCall(address(pool), abi.encodeCall(MockPool.getReservesList, ()), 0);
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        assertTrue(pos.isClosed());
    }

    /// @dev The bound bites under `forge test --isolate`, where each callback starts cold like a real one; mock
    /// reads are cheaper than Aave's, so the last callback keeps half the 2M budget as headroom.
    function test_close_should_finish_inside_the_fill_callback_with_36_reserves() public {
        listReserves(36);
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        vm.prank(alice);
        pos.close();
        uint256 last;
        for (uint256 i; i < 80 && hasPending(pos); ++i) {
            fillOnly(FILL_BPS);
            uint256 g = gasleft();
            (bool ok,) = dispatchTop();
            last = g - gasleft();
            assertTrue(ok, "callback reverted");
        }
        console2.log("gas of the last close callback", last);
        assertLt(last, GAS_LIMIT / 2, "last close callback within half the budget");
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None), "no stall on the last rung");
        assertTrue(pos.isClosed(), "closed in the callback, no resume needed");
    }
}
