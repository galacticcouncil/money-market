// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {PropellerOperatingBuffer} from "../src/PropellerOperatingBuffer.sol";

contract HarvestOperatingBufferTest is HarvestTest {
    function test_feeThenInterestThenBufferThenCollateral() public {
        _depositAndRamp();
        PropellerOperatingBuffer buffer = PropellerOperatingBuffer(address(vault.operatingBuffer()));
        uint256 cash = buffer.ownedCash();
        uint256 debt = hollarDebt.balanceOf(address(vault));
        uint256 assets = vault.totalAssets();
        uint256 bootstrap = buffer.bootstrapCash();
        hollarDebt.mint(address(vault), 100e18);
        prime.mint(address(harvester), 3_000e6);
        harvester.harvest(new uint256[](0));
        assertEq(fees.claimableProtocolFees(address(eth)), 0.05e18,
            "fee remains based on gross harvested collateral, before Main interest");
        assertEq(hollarDebt.balanceOf(address(vault)), debt);
        assertEq(buffer.interestOf(0), 0);
        assertGe(buffer.ownedCash(), buffer.targetCash());
        assertEq(buffer.bootstrapCash(), bootstrap);
        uint256 compoundedUsd = (vault.totalAssets() - assets) * 3000;
        assertApproxEqAbs(compoundedUsd + 100e18 + buffer.ownedCash() - cash, 2_850e18, 3000);
        assertEq(eth.allowance(address(vault), address(buffer)), 0);
        assertEq(eth.allowance(address(buffer), address(swapper)), 0);
        assertEq(hollar.allowance(address(buffer), address(pool)), 0);
    }

    function test_insufficientYieldNeverPullsPreviouslyCompoundedCollateral() public {
        _depositAndRamp();
        PropellerOperatingBuffer buffer = PropellerOperatingBuffer(address(vault.operatingBuffer()));
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
