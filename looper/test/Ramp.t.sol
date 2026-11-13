// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";
import {Units} from "../src/lib/Units.sol";

contract RampTest is Fixture {
    uint256 internal constant LEV_TOL = 0.01e18;

    function test_ramp_should_land_within_tolerance_of_target_when_every_rung_fills() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        while (hasPending(pos)) {
            fill(FILL_BPS);
            (uint256 c, uint256 d,, uint256 hf) = account(pos);
            assertGe(hf + 1, deployHf(pos), "hf at or above deployHf with the float included");
            assertLe(d * 10_000, c * 7_500, "debt never past C * LTV");
            assertLane(pos);
        }
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
    }

    function test_ramp_should_enable_collateral_and_reach_target_when_the_collateral_reserve_is_isolated() public {
        pool.setFlags(address(prime), false, false, true, true);
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        assertTrue(pool.isCollateral(address(pos), address(prime)));
        ramp(pos);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.None));
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
    }

    function test_open_should_land_the_first_deposit_through_initialize_and_the_factory_only_deposit_when_called()
        public
    {
        address predicted = factory.predict(1);
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        assertEq(address(pos), predicted);
        assertEq(pos.tokenId(), 1);
        assertEq(factory.ownerOf(1), alice);
        assertEq(pos.owner(), alice);
        assertEq(pos.factory(), address(factory));
        assertEq(pos.principal(), DEPOSIT);
        assertEq(aPrime.balanceOf(address(pos)), DEPOSIT);
        assertTrue(pool.isCollateral(address(pos), address(prime)));
        assertEq(pallet.currencyOf(address(pos)), HDX_ID);
        assertEq(factory.balanceOf(alice), 1);
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry));
        assertEq(pallet.liveCount(address(pos)), 1);
    }

    function test_factory_deposit_should_extend_the_ramp_when_the_owner_deposits_again() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        topUp(alice, pos, 500e6);
        assertEq(pos.principal(), DEPOSIT + 500e6);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.Ramp));
        ramp(pos);
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
    }

    function test_rung_should_stall_aave_refused_when_the_borrow_is_refused_after_a_settled_fill() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint256 debtBefore = vHollar.balanceOf(address(pos));
        uint256 aBefore = aPrime.balanceOf(address(pos));
        pool.setRefusals(true, false, false);
        (, uint256 out) = fillOnly(FILL_BPS);
        (bool ok,) = dispatchTop();
        assertTrue(ok);
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.AaveRefused));
        assertFalse(hasPending(pos));
        assertEq(vHollar.balanceOf(address(pos)), debtBefore);
        assertEq(aPrime.balanceOf(address(pos)), aBefore + out);
        assertLane(pos);
    }

    function test_rung_should_swap_idle_debt_cash_together_with_the_borrow_when_cash_sits_on_the_position() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        hollar.mint(address(pos), 50e18);
        uint256 debtBefore = vHollar.balanceOf(address(pos));
        topUp(alice, pos, 100e6);
        uint256 borrowed = vHollar.balanceOf(address(pos)) - debtBefore;
        assertGt(borrowed, 0);
        assertEq(pend(pos).amountIn, 50e18 + borrowed);
        assertEq(hollar.balanceOf(address(pos)), 0);
    }

    function test_initialize_should_enter_the_pair_emode_and_size_with_its_lt_and_price_source_when_listed() public {
        address source = makeAddr("eModeSource");
        pool.setEModeCategory(1, 8_500, 9_000, source, 1e8);
        pool.setReserveEMode(address(prime), 1);
        pool.setReserveEMode(address(hollar), 1);
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.eMode = 1;
        LooperPosition pos = openWith(alice, DEPOSIT, p);
        assertEq(pool.userEMode(address(pos)), 1);
        (uint256 c, uint256 d, uint256 lt,) = account(pos);
        assertEq(lt, 9_000);
        assertEq(c, DEPOSIT * 1e8 / 1e6, "collateral valued at the category price");
        // deployHf = max(0.9 * 3 / 2, 1.15) = 1.35
        assertEq(d, c * 9_000 * 1e14 / 1.35e18);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint256 fair =
            Units.fromBase(Units.toBase(pi.amountIn, 1e8, 18, Math.Rounding.Down), 1e8, 6, Math.Rounding.Down);
        assertEq(pi.minOut, fair * (10_000 - SLIP) / 10_000);
    }

    function test_rung_should_size_min_out_with_the_new_slippage_when_the_owner_changed_it_mid_ladder() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        vm.prank(alice);
        pos.setSlippage(50);
        fill(FILL_BPS);
        ILooperPosition.PendingIntent memory pi = pend(pos);
        uint256 fair =
            Units.fromBase(Units.toBase(pi.amountIn, 1e8, 18, Math.Rounding.Down), 2.5e8, 6, Math.Rounding.Down);
        assertEq(pi.minOut, fair * 9_950 / 10_000);
        assertEq(pos.slippageBps(), 50);
    }

    function test_rung_should_not_submit_when_the_amount_in_is_under_the_debt_floor() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.minIntentDebt = 1e30;
        LooperPosition pos = openWith(alice, DEPOSIT, p);
        assertEq(pallet.submits(), 0);
        assertFalse(hasPending(pos));
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
        assertEq(vHollar.balanceOf(address(pos)), 0);
    }

    function test_rung_should_not_submit_when_the_min_out_is_under_the_atoken_floor() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.minIntentAToken = 1e30;
        LooperPosition pos = openWith(alice, DEPOSIT, p);
        assertEq(pallet.submits(), 0);
        assertFalse(hasPending(pos));
        assertEq(uint8(pos.ladder()), uint8(ILooperPosition.Ladder.None));
    }

    function test_execute_should_run_exactly_one_rung_when_a_fill_settles() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint256 submits = pallet.submits();
        uint64 n = pos.nonce();
        fill(FILL_BPS);
        assertEq(pallet.submits(), submits + 1);
        assertEq(pos.nonce(), n + 1);
        assertEq(pallet.liveCount(address(pos)), 1);
    }

    function test_submit_should_carry_a_positive_reconcile_out_when_any_intent_is_submitted() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        uint256 checked;
        for (uint256 phase = 0; phase < 3; ++phase) {
            if (phase == 1) {
                vm.prank(alice);
                pos.withdraw(300e6);
            } else if (phase == 2) {
                vm.prank(alice);
                pos.close();
            }
            while (hasPending(pos)) {
                ILooperPosition.PendingIntent memory pi = pend(pos);
                uint256 cut = pi.kind == ILooperPosition.Kind.Entry ? 1_000 : 0;
                assertEq(pi.reconcileOut, pi.minOut - cut);
                assertGt(pi.reconcileOut, 0);
                ++checked;
                fill(FILL_BPS);
            }
        }
        assertTrue(pos.isClosed());
        assertGt(checked, 20);
    }

    function test_nav_should_equal_the_deposit_at_open_when_the_in_flight_input_is_counted() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        assertApproxEqAbs(pos.nav(), DEPOSIT, 1);
        assertApproxEqAbs(pos.pnl(), 0, 1);

        // a landed but unsettled output is in the balances once, not twice
        ILooperPosition.PendingIntent memory pi = pend(pos);
        (, uint256 out) = fillOnly(FILL_BPS);
        uint256 navBase = Units.toBase(aPrime.balanceOf(address(pos)), 2.5e8, 6, Math.Rounding.Down)
            + Units.toBase(hollar.balanceOf(address(pos)), 1e8, 18, Math.Rounding.Down)
            - Units.toBase(vHollar.balanceOf(address(pos)), 1e8, 18, Math.Rounding.Down);
        assertGe(out, pi.reconcileOut);
        assertEq(pos.nav(), Units.fromBase(navBase, 2.5e8, 6, Math.Rounding.Down));
        assertLt(pos.nav(), DEPOSIT);
    }

    function test_ladders_should_land_on_the_same_l_dep_when_lt_changes_between_rungs_and_before_a_withdrawal()
        public
    {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        fill(FILL_BPS);
        pool.setLtvLt(address(prime), 7_500, 8_200);
        ramp(pos);
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
        (,,, uint256 hf) = account(pos);
        assertApproxEqAbs(hf, 1.23e18, 0.01e18);

        pool.setLtvLt(address(prime), 7_500, 7_900);
        vm.prank(alice);
        pos.withdraw(200e6);
        drive(pos, 80);
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, LEV_TOL);
        (,,, hf) = account(pos);
        assertApproxEqAbs(hf, 1.185e18, 0.01e18);
    }
}
