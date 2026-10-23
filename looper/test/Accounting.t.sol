// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {LooperPosition} from "../src/LooperPosition.sol";
import {Units} from "../src/lib/Units.sol";

contract AccountingTest is Fixture {
    LooperPosition internal pos;

    function setUp() public override {
        super.setUp();
        pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
    }

    /// Equity in collateral units after the payout, read back from Aave at the current prices.
    function _equity() internal view returns (uint256) {
        (uint256 c, uint256 d,,) = account(pos);
        return Units.fromBase(c - d, pool.getAssetPrice(address(prime)), 6, Math.Rounding.Down);
    }

    function _withdraw(uint256 amount) internal returns (uint256 paid) {
        uint256 before = prime.balanceOf(alice);
        vm.prank(alice);
        pos.withdraw(amount);
        drive(pos, 80);
        paid = prime.balanceOf(alice) - before;
    }

    function _assertScaled(uint256 principal, uint256 paid) internal view {
        uint256 equityBefore = _equity() + paid;
        assertApproxEqAbs(pos.principal(), Math.mulDiv(principal, equityBefore - paid, equityBefore), 2);
        assertTrue(pos.principal() != principal - paid, "not a return of capital");
    }

    function test_withdraw_should_remove_the_paid_fraction_of_cost_basis_when_equity_has_grown() public {
        pool.setPrice(address(hollar), 0.9e8);
        assertGt(pos.pnl(), 0);
        uint256 principal = pos.principal();
        uint256 paid = _withdraw(400e6);
        assertEq(paid, 400e6);
        _assertScaled(principal, paid);
    }

    function test_withdraw_should_remove_the_paid_fraction_of_cost_basis_when_equity_has_fallen() public {
        pool.setPrice(address(hollar), 1.05e8);
        assertLt(pos.pnl(), 0);
        uint256 principal = pos.principal();
        uint256 paid = _withdraw(300e6);
        assertEq(paid, 300e6);
        _assertScaled(principal, paid);
    }

    function test_close_should_zero_principal_when_it_pays_out_everything() public {
        vm.prank(alice);
        pos.close();
        drive(pos, 80);
        assertEq(pos.principal(), 0);
        assertEq(pos.nav(), 0);
    }

    function test_planned_volume_should_quote_amount_times_leverage_minus_one_in_debt_units() public view {
        // 100 PRIME at $2.50, 2x more = $250 of HOLLAR
        assertEq(pos.plannedVolume(100e6, 3e18), 500e18);
    }
}
