// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HarvestTest} from "./Harvest.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {JuicerFeeController} from "../src/JuicerFeeController.sol";

contract EntryFeeTest is HarvestTest {
    address internal constant NEWCOMER = address(0xE17E);
    address internal constant STRANGER = address(0xBAD);

    function _newcomerDeposits(uint256 amount) internal returns (uint256 shares) {
        eth.mint(NEWCOMER, amount);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), amount);
        shares = vault.deposit(amount, NEWCOMER);
        vm.stopPrank();
    }

    function _active() internal view returns (uint256 assets, uint256 supply) {
        assets = vault.totalAssets() - vault.totalQueuedCollateral();
        supply = vault.totalSupply() - vault.totalQueuedShares();
    }

    function test_entryFeeIsGovernanceOnlyBoundedAndSeparateFromTheProtocolFee() public {
        assertEq(fees.entryFeeBps(address(vault)), 0, "zero until governance sets it");
        vm.prank(STRANGER);
        vm.expectRevert();
        fees.setEntryFeeBps(address(vault), 50);
        uint16 cap = fees.MAX_ENTRY_FEE_BPS();
        vm.expectRevert(JuicerFeeController.InvalidFee.selector);
        fees.setEntryFeeBps(address(vault), cap + 1);
        uint256 version = fees.configurationVersion();
        vm.expectEmit(true, false, false, true, address(fees));
        emit JuicerFeeController.EntryFeeUpdated(address(vault), 0, cap);
        fees.setEntryFeeBps(address(vault), cap);
        assertEq(fees.entryFeeBps(address(vault)), cap);
        assertEq(fees.protocolFeeBps(address(vault)), 500, "the harvest fee is untouched");
        assertEq(fees.configurationVersion(), version + 1);
        vm.expectRevert(JuicerFeeController.NotRegistered.selector);
        fees.entryFeeBps(STRANGER);
        vm.expectRevert(JuicerFeeController.NotRegistered.selector);
        fees.setEntryFeeBps(STRANGER, 10);
    }

    function test_bootstrapDepositPaysNoEntryFee() public {
        fees.setEntryFeeBps(address(vault), 200);
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));
        assertEq(shares, 1e18 - 1000, "nobody to compensate yet");
    }

    function test_depositMintsOnTheNetAndTheFeeStaysWithHolders() public {
        uint256 incumbent = _depositAndRamp();
        fees.setEntryFeeBps(address(vault), 100);
        (uint256 assets0, uint256 supply0) = _active();
        uint256 incumbentValue = vault.convertToAssets(incumbent);
        uint256 reserve = vault.roundingReserve();

        uint256 shares = _newcomerDeposits(1e18);

        assertEq(shares, Math.ceilDiv(0.99e18 * supply0, assets0), "shares on the 99% left after the fee");
        assertEq(vault.totalAssets(), assets0 + vault.totalQueuedCollateral() + 1e18, "the whole deposit is collateral");
        assertEq(vault.roundingReserve(), reserve, "the fee covers rounding; the reserve is not drawn");
        uint256 supply1 = vault.totalSupply() - vault.totalQueuedShares();
        uint256 gain = vault.convertToAssets(incumbent) - incumbentValue;
        assertApproxEqAbs(gain, Math.mulDiv(0.01e18, incumbent, supply1), 2, "holders get the fee pro rata");
        assertApproxEqAbs(vault.convertToAssets(shares), 0.99e18 + Math.mulDiv(0.01e18, shares, supply1), 2,
            "the newcomer keeps only its own share of the fee");
    }

    function test_zeroEntryFeeMintsAsBefore() public {
        _depositAndRamp();
        (uint256 assets0, uint256 supply0) = _active();
        assertEq(_newcomerDeposits(1e18), Math.ceilDiv(1e18 * supply0, assets0));
    }

    function test_aQuickRoundTripLeavesTheFeeWithHolders() public {
        uint256 incumbent = _depositAndRamp();
        fees.setEntryFeeBps(address(vault), 100);
        uint256 before = vault.convertToAssets(incumbent);
        uint256 shares = _newcomerDeposits(1e18);
        uint256 supply1 = vault.totalSupply() - vault.totalQueuedShares();
        vm.prank(NEWCOMER);
        uint256 id = vault.requestRedeem(shares, NEWCOMER);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
        vm.prank(NEWCOMER);
        uint256 got = vault.claim(id, NEWCOMER);
        assertApproxEqRel(got, 0.99e18 + Math.mulDiv(0.01e18, shares, supply1), 0.002e18, "the net and its own share of the fee");
        assertLt(got, 1e18, "never the whole deposit");
        assertApproxEqRel(vault.convertToAssets(incumbent) - before, Math.mulDiv(0.01e18, incumbent, supply1), 0.01e18,
            "the incumbent keeps the rest");
    }

    function test_admissionStillRefusesADeficit() public {
        _depositAndRamp();
        fees.setEntryFeeBps(address(vault), 200);
        pool.setPrice(address(prime), 0.99e18);
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.PrincipalShortfall.selector);
        vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
    }

    function testFuzz_feeNeverDilutesHolders(uint16 rate, uint96 amountSeed) public {
        uint256 incumbent = _depositAndRamp();
        uint16 bps = uint16(bound(rate, 0, fees.MAX_ENTRY_FEE_BPS()));
        uint256 amount = bound(amountSeed, 1e12, 100e18);
        fees.setEntryFeeBps(address(vault), bps);
        (uint256 assets0, uint256 supply0) = _active();
        uint256 before = vault.convertToAssets(incumbent);
        uint256 shares = _newcomerDeposits(amount);
        assertLe(shares, Math.ceilDiv(amount * supply0, assets0), "a fee never mints more");
        assertGe(vault.convertToAssets(incumbent) + 1, before, "holders never lose to an entry");
    }
}
