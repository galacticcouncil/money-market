// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Fixture} from "./helpers/Fixture.t.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {ILooperFactory} from "../src/interfaces/ILooperFactory.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperFactory} from "../src/LooperFactory.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract FactoryTest is Fixture {
    function _expectOpenRevert(ILooperPosition.Params memory p, bytes4 err) internal {
        vm.prank(alice);
        vm.expectRevert(err);
        factory.open(p, DEPOSIT, FEE_BUDGET);
    }

    // ── open ──

    function test_open_should_mint_global_token_ids_whose_clone_address_depends_only_on_the_id() public {
        address predicted = factory.predict(2);
        LooperPosition a = open(alice, DEPOSIT, 3e18);
        LooperPosition b = open(bob, DEPOSIT, 2e18);
        LooperPosition c = open(alice, DEPOSIT, 1.5e18);
        assertEq(a.tokenId(), 1);
        assertEq(b.tokenId(), 2);
        assertEq(c.tokenId(), 3);
        assertEq(address(b), predicted);
        assertEq(address(c), factory.predict(3));
        assertEq(factory.nextId(), 4);
        assertEq(factory.balanceOf(alice), 2);
        assertEq(factory.ownerOf(2), bob);
    }

    function test_open_should_store_the_users_risk_terms_and_cap_leverage_with_their_min_hf() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.minHf = 1.5e18;
        p.stepHf = 1.2e18;
        p.slippageBps = 50;
        // L_max = 1.5 / (1.5 - 0.8) = 2.14
        assertEq(factory.maxLeverage(address(prime), 0, 1.5e18), uint256(1.5e18) * 1e18 / 0.7e18);
        _expectOpenRevert(p, ILooperFactory.LeverageTooHigh.selector);
        p.leverage = 2.1e18;
        LooperPosition pos = openWith(alice, DEPOSIT, p);
        ILooperPosition.Params memory stored = pos.params();
        assertEq(stored.minHf, 1.5e18);
        assertEq(stored.stepHf, 1.2e18);
        assertEq(stored.slippageBps, 50);
        assertEq(stored.leverage, 2.1e18);
        assertEq(stored.collateral, address(prime));
        assertEq(stored.debtAssetId, HOLLAR_ID);
        ramp(pos);
        (,,, uint256 hf) = account(pos);
        assertGe(hf, 1.5e18);
        assertApproxEqAbs(pos.aaveLeverage(), 2.1e18, 0.02e18);
    }

    function test_open_should_revert_leverage_too_high_when_above_the_ltv_bound_l_max() public {
        // LT 95 % leaves the HF floor loose; LTV 70 % caps L at 1 / (1 - 0.7) = 3.33
        pool.setLtvLt(address(prime), 7_000, 9_500);
        assertEq(factory.maxLeverage(address(prime), 0, 1.15e18), uint256(10_000) * 1e18 / 3_000);
        _expectOpenRevert(defaultParams(3.34e18), ILooperFactory.LeverageTooHigh.selector);
        open(alice, DEPOSIT, 3.33e18);
    }

    function test_open_should_revert_leverage_too_high_when_leverage_is_at_most_one() public {
        _expectOpenRevert(defaultParams(1e18), ILooperFactory.LeverageTooHigh.selector);
    }

    function test_open_should_revert_invalid_params_when_a_check_fails() public {
        ILooperPosition.Params[11] memory bad;
        for (uint256 i = 0; i < bad.length; ++i) {
            bad[i] = defaultParams(3e18);
        }
        bad[0].aCollateral = address(aDot);
        bad[1].variableDebt = address(aDot);
        bad[2].debt = address(prime);
        bad[3].collateral = address(0);
        bad[4].stepHf = 1.11e18;
        bad[5].stepHf = 1.009e18;
        bad[6].slippageBps = 10_000;
        bad[7].feeReserve = 0;
        bad[8].minIntentDebt = 0;
        bad[9].minIntentAToken = 0;
        bad[10].eMode = 3;
        for (uint256 i = 0; i < bad.length; ++i) {
            _expectOpenRevert(bad[i], ILooperFactory.InvalidParams.selector);
        }
    }

    function test_open_should_accept_the_fixed_floors_when_step_hf_is_1_01_and_min_hf_is_1_06() public {
        ILooperPosition.Params memory p = defaultParams(2e18);
        p.stepHf = 1.01e18;
        p.minHf = 1.06e18;
        LooperPosition pos = openWith(alice, DEPOSIT, p);
        assertEq(pos.params().minHf, 1.06e18);
    }

    function test_open_should_revert_invalid_params_when_a_reserve_is_frozen_or_paused() public {
        pool.setFlags(address(hollar), true, false, true, false);
        _expectOpenRevert(defaultParams(3e18), ILooperFactory.InvalidParams.selector);
        pool.setFlags(address(hollar), false, false, true, false);
        pool.setFlags(address(prime), true, false, true, false);
        _expectOpenRevert(defaultParams(3e18), ILooperFactory.InvalidParams.selector);
        pool.setFlags(address(prime), false, true, true, false);
        _expectOpenRevert(defaultParams(3e18), ILooperFactory.InvalidParams.selector);
    }

    function test_open_should_revert_nothing_to_do_when_the_amount_is_zero() public {
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.NothingToDo.selector);
        factory.open(defaultParams(3e18), 0, FEE_BUDGET);
    }

    function test_open_should_initialise_cleanly_when_the_predicted_address_was_poisoned_with_a_foreign_atoken()
        public
    {
        address predicted = factory.predict(1);
        giftAToken(dot, aDot, predicted, 10e10);
        assertTrue(pool.isCollateral(predicted, address(dot)));
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        assertEq(address(pos), predicted);
        assertFalse(pool.isCollateral(address(pos), address(dot)));
        assertTrue(pool.isCollateral(address(pos), address(prime)));
        assertEq(uint8(pend(pos).kind), uint8(ILooperPosition.Kind.Entry));
    }

    function test_constructor_should_revert_invalid_implementation_when_it_uses_another_pool_or_has_no_code() public {
        LooperPosition foreign = new LooperPosition(IAavePool(makeAddr("otherPool")), entryPoint);
        vm.expectRevert(ILooperFactory.InvalidImplementation.selector);
        new LooperFactory(IAavePool(address(pool)), address(foreign));
        vm.expectRevert(ILooperFactory.InvalidImplementation.selector);
        new LooperFactory(IAavePool(address(pool)), makeAddr("noCode"));
    }

    // ── deposit / initialize ──

    function test_factory_deposit_should_revert_not_owner_when_the_caller_does_not_own_the_position() public {
        uint256 id = open(alice, DEPOSIT, 3e18).tokenId();
        vm.prank(bob);
        vm.expectRevert(ILooperFactory.NotOwner.selector);
        factory.deposit(id, 10e6);
    }

    function test_factory_deposit_should_revert_when_the_token_id_does_not_exist() public {
        vm.prank(alice);
        vm.expectRevert("ERC721: invalid token ID");
        factory.deposit(1, 10e6);
    }

    function test_position_deposit_should_revert_not_factory_when_called_by_the_owner() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.NotFactory.selector);
        pos.deposit(10e6);
    }

    function test_initialize_should_revert_already_initialized_when_called_again_on_a_clone() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ILooperPosition.Params memory p = defaultParams(3e18);
        vm.prank(address(factory));
        vm.expectRevert(ILooperPosition.PositionAlreadyInitialized.selector);
        pos.initialize(9, p);
        vm.prank(bob);
        vm.expectRevert(ILooperPosition.PositionAlreadyInitialized.selector);
        pos.initialize(9, p);
    }

    // ── transfer ──

    function test_transfer_should_move_every_owner_right_to_the_new_holder_when_the_nft_changes_hands() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        uint256 id = pos.tokenId();
        vm.prank(alice);
        factory.transferFrom(alice, bob, id);
        assertEq(pos.owner(), bob);
        assertEq(factory.balanceOf(alice), 0);

        vm.startPrank(alice);
        vm.expectRevert(ILooperPosition.NotOwner.selector);
        pos.close();
        vm.expectRevert(ILooperPosition.NotOwner.selector);
        pos.setSlippage(10);
        vm.expectRevert(ILooperFactory.NotOwner.selector);
        factory.deposit(id, 10e6);
        vm.stopPrank();

        vm.prank(bob);
        pos.setSlippage(150);
        assertEq(pos.slippageBps(), 150);
        topUp(bob, pos, 100e6);
        assertEq(pos.principal(), DEPOSIT + 100e6);
    }

    function test_transfer_should_pay_the_close_to_the_new_holder_when_transferred_mid_ramp() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        fill(FILL_BPS);
        assertTrue(hasPending(pos));
        uint256 id = pos.tokenId();
        vm.prank(alice);
        factory.transferFrom(alice, bob, id);
        ramp(pos);
        assertApproxEqAbs(pos.aaveLeverage(), 3e18, 0.05e18);

        uint256 aliceBefore = prime.balanceOf(alice);
        uint256 bobBefore = prime.balanceOf(bob);
        vm.prank(bob);
        pos.close();
        drive(pos, 80);
        assertTrue(pos.isClosed());
        assertEq(prime.balanceOf(alice), aliceBefore);
        assertGt(prime.balanceOf(bob) - bobBefore, DEPOSIT * 95 / 100);
    }

    function test_owner_of_scan_should_list_a_holders_positions_when_ids_are_walked_off_chain() public {
        open(alice, DEPOSIT, 3e18);
        LooperPosition b = open(alice, DEPOSIT, 2e18);
        open(bob, DEPOSIT, 2e18);
        uint256 id = b.tokenId();
        vm.prank(alice);
        factory.transferFrom(alice, bob, id);

        address[] memory found = new address[](factory.nextId());
        uint256 n;
        for (uint256 i = 1; i < factory.nextId(); ++i) {
            if (factory.ownerOf(i) == bob) found[n++] = factory.predict(i);
        }
        assertEq(n, 2);
        assertEq(found[0], address(b));
        assertEq(found[1], factory.predict(3));
    }

    // ── owner setters ──

    function test_set_fee_reserve_should_revert_when_zero_or_not_the_owner() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        vm.prank(stranger);
        vm.expectRevert(ILooperPosition.NotOwner.selector);
        pos.setFeeReserve(2e12);
        vm.prank(alice);
        vm.expectRevert(ILooperPosition.InvalidParams.selector);
        pos.setFeeReserve(0);
        setFeeReserve(pos, 2e12);
        assertEq(pos.feeReserve(), 2e12);
    }

    // ── fee asset ──

    function test_open_should_pull_the_fee_budget_into_the_position_in_the_fee_asset() public {
        uint256 before = hdx.balanceOf(alice);
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        assertEq(hdx.balanceOf(address(pos)), FEE_BUDGET);
        assertEq(before - hdx.balanceOf(alice), FEE_BUDGET);
        assertEq(pallet.currencyOf(address(pos)), HDX_ID);
        assertEq(pos.params().feeAsset, address(hdx));
    }

    function test_open_should_revert_asset_id_mismatch_when_an_id_does_not_name_its_token() public {
        ILooperPosition.Params[4] memory bad;
        for (uint256 i = 0; i < bad.length; ++i) {
            bad[i] = defaultParams(3e18);
        }
        bad[0].debtAssetId = APRIME_ID;
        bad[1].aCollateralAssetId = ADOT_ID;
        bad[2].feeAssetId = HOLLAR_ID;
        bad[3].feeAssetId = 4242;
        for (uint256 i = 0; i < bad.length; ++i) {
            _expectOpenRevert(bad[i], ILooperFactory.AssetIdMismatch.selector);
        }
    }

    function test_open_should_revert_invalid_params_when_the_fee_asset_is_a_position_leg() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.feeAsset = address(hollar);
        p.feeAssetId = HOLLAR_ID;
        _expectOpenRevert(p, ILooperFactory.InvalidParams.selector);
        p.feeAsset = address(aPrime);
        p.feeAssetId = APRIME_ID;
        _expectOpenRevert(p, ILooperFactory.InvalidParams.selector);
    }

    function test_open_should_supply_at_one_x_and_stall_fee_budget_low_when_opened_without_a_budget() public {
        vm.prank(alice);
        (, address a) = factory.open(defaultParams(3e18), DEPOSIT, 0);
        LooperPosition pos = LooperPosition(payable(a));
        assertEq(uint8(pos.stalled()), uint8(ILooperPosition.Stall.FeeBudgetLow));
        assertFalse(hasPending(pos));
        assertEq(aPrime.balanceOf(a), DEPOSIT);
        assertEq(vHollar.balanceOf(a), 0);
    }

    function test_close_should_pay_the_unused_fee_budget_to_the_current_holder() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        ramp(pos);
        uint256 id = pos.tokenId();
        vm.prank(alice);
        factory.transferFrom(alice, bob, id);
        uint256 left = hdx.balanceOf(address(pos));
        uint256 before = hdx.balanceOf(bob);
        vm.prank(bob);
        pos.close();
        uint256 exits = drive(pos, 80);
        assertTrue(pos.isClosed());
        assertEq(hdx.balanceOf(address(pos)), 0);
        assertEq(hdx.balanceOf(bob) - before, left - exits * FEE);
    }

    function test_mock_supply_should_revert_when_the_reserve_is_frozen() public {
        pool.setFlags(address(prime), true, false, true, false);
        prime.mint(alice, 1e6);
        vm.startPrank(alice);
        prime.approve(address(pool), 1e6);
        vm.expectRevert("MockPool: not suppliable");
        pool.supply(address(prime), 1e6, alice, 0);
        vm.stopPrank();
    }
}
