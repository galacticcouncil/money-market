// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";

contract HarvestMainDebtTest is HarvestTest {
    function test_ownedIncomePaysBothSwapCostsAndRetainsUnusedAllowance() public {
        _depositAndRamp();
        PropellerMainDebt buffer = PropellerMainDebt(address(vault.mainDebt()));
        hollarDebt.mint(address(vault), 25e18);
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.maintainPeg();
        address newcomer = address(0xB0B);
        eth.mint(newcomer, 1e18);
        vm.startPrank(newcomer);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, newcomer);
        vm.stopPrank();
        // Both PRIME->collateral and collateral->HOLLAR have real friction.
        swapper.setHaircut(60);
        harvester.harvest(new uint256[](0));
        assertEq(buffer.interestOf(0), 0, "sufficient fresh yield pays interest after execution costs");
        assertGt(buffer.ownedCash(), 0, "the second swap can leave unused slippage allowance");
        vault.sync();
        assertLe(vault.convertToAssets(shares) + vault.yieldAccounting().earnedAssets(newcomer), 1e18 + 1e9,
            "unused servicing allowance stays with earlier reward owners");
        assertGt(vault.yieldAccounting().earnedAssets(address(this)), 0);
    }

    function test_feeThenInterestThenCollateralWithoutPrefunding() public {
        _depositAndRamp();
        PropellerMainDebt buffer = PropellerMainDebt(address(vault.mainDebt()));
        uint256 cash = buffer.ownedCash();
        uint256 debt = hollarDebt.balanceOf(address(vault));
        uint256 assets = vault.totalAssets();
        hollarDebt.mint(address(vault), 100e18);
        prime.mint(address(harvester), 3_000e6);
        harvester.harvest(new uint256[](0));
        assertEq(fees.claimableProtocolFees(address(eth)), 0.05e18,
            "fee remains based on gross harvested collateral, before Main interest");
        assertEq(hollarDebt.balanceOf(address(vault)), debt);
        assertEq(buffer.interestOf(0), 0);
        assertLt(buffer.ownedCash(), 2e18, "only swap rounding/slippage surplus, no cash target");
        uint256 compoundedUsd = (vault.totalAssets() - assets) * 3000;
        assertApproxEqAbs(compoundedUsd + 100e18 + buffer.ownedCash() - cash, 2_850e18, 3000);
        assertEq(eth.allowance(address(vault), address(buffer)), 0);
        assertEq(eth.allowance(address(buffer), address(swapper)), 0);
        assertEq(hollar.allowance(address(buffer), address(pool)), 0);
    }

    function test_insufficientYieldNeverPullsPreviouslyCompoundedCollateral() public {
        _depositAndRamp();
        PropellerMainDebt buffer = PropellerMainDebt(address(vault.mainDebt()));
        uint256 assets = vault.totalAssets();
        hollarDebt.mint(address(vault), 1_000e18);
        prime.mint(address(harvester), 30e6);
        harvester.harvest(new uint256[](0));
        assertEq(vault.totalAssets(), assets);
        assertGt(buffer.interestOf(0), 0);
        assertEq(buffer.ownedCash(), 0);
        assertEq(fees.claimableProtocolFees(address(eth)), 0.0005e18);
    }
}
