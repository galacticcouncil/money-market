// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {PropellerYieldAccounting} from "../src/PropellerYieldAccounting.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

/// @notice action ordering and realization delay; aprs are modeled inputs, not observed
contract YieldValidationTest is HarvestTest {
    function testFuzz_rewardFundConservesOwnershipAcrossMixedActions(uint256 seed) public {
        _depositAndRamp();
        address[4] memory owners = [address(this), address(0xA11CE), address(0xB0B), address(0xCA11)];
        PropellerYieldAccounting ledger = vault.yieldAccounting();
        for (uint256 i; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address owner = owners[(seed >> 8) % owners.length];
            uint256 action = seed % 5;
            if (action == 0) {
                uint256 amount = (seed % 100 + 1) * 1e14;
                eth.mint(owner, amount);
                vm.startPrank(owner);
                eth.approve(address(vault), amount);
                // 6dp source fills can leave a tiny principal deficit; entry must reject it
                if (vault.isUnderfunded()) vm.expectRevert(CollateralVault.Underfunded.selector);
                vault.deposit(amount, owner);
                vm.stopPrank();
            } else if (action == 1) {
                uint256 income = aPrime.balanceOf(address(loop)) / 50;
                aPrime.mint(address(loop), income);
                prime.mint(address(pool), income);
            } else if (action == 2) {
                uint256 shares = vault.balanceOf(owner) / 2;
                vm.prank(owner);
                vault.transfer(owners[(seed >> 16) % owners.length], shares);
            } else if (action == 3) {
                harvester.harvest(new uint256[](0));
            } else {
                uint256 earnedBefore = ledger.earnedAssets(owner);
                vm.prank(owner);
                uint256 claimed = vault.claimYield(owner);
                assertApproxEqAbs(ledger.earnedAssets(owner) + vault.convertToAssets(claimed), earnedBefore, 1e9,
                    "claim conserves funded plus unconverted owner value");
            }
            vault.prepareHarvest();
            uint256 ownedUnits;
            uint256 earned;
            for (uint256 j; j < owners.length; ++j) {
                ownedUnits += ledger.balanceOf(owners[j]);
                earned += ledger.earnedAssets(owners[j]);
            }
            assertLe(ownedUnits, ledger.totalUnits(), "holder units never exceed the reward fund");
            assertLe(earned, ledger.totalAssets(), "holder rewards never exceed owned fund assets");
            assertLe(ledger.reservedShares(), vault.loopShares(), "yield units remain backed by source shares");
            assertEq(vault.loopShares(), loop.sharesOf(address(vault)), "source and vault stay reconciled");
        }
    }

    function _accrueDay(uint256 primeAprBps, uint256 borrowAprBps) private {
        // daily aprime income and main/subloop debt growth
        uint256 income = aPrime.balanceOf(address(loop)) * primeAprBps / 10_000 / 365;
        aPrime.mint(address(loop), income);
        prime.mint(address(pool), income);
        hollarDebt.mint(address(loop), hollarDebt.balanceOf(address(loop)) * borrowAprBps / 10_000 / 365);
        hollarDebt.mint(address(vault), hollarDebt.balanceOf(address(vault)) * borrowAprBps / 10_000 / 365);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function _measureRealization(uint256 primeAprBps, uint256 borrowAprBps) private returns (uint256 firstDay) {
        _depositAndRamp();
        uint256 assetsBefore = vault.totalAssets();
        uint256 harvests;
        uint256 peakGas;
        uint256 firstGap;
        uint256 firstHarvest;
        for (uint256 day = 1; day <= 180; ++day) {
            _accrueDay(primeAprBps, borrowAprBps);
            if (!harvester.harvestable()) continue;
            uint256 beforeGas = gasleft();
            harvester.harvest(new uint256[](0));
            uint256 used = beforeGas - gasleft();
            if (used > peakGas) peakGas = used;
            if (firstHarvest == 0) firstHarvest = day;
            else if (firstGap == 0) firstGap = day - firstHarvest;
            if (firstDay == 0 && vault.totalAssets() > assetsBefore) firstDay = day;
            ++harvests;
            // reuse earned collateral; unconverted source earnings cannot fund leverage
            vault.pokeSettle();
            vault.rebalance();
            loop.pokeBorrow();
        }
        emit log_named_uint("first realized collateral day", firstDay);
        emit log_named_uint("first source harvest day", firstHarvest);
        emit log_named_uint("days from first to second harvest", firstGap);
        emit log_named_uint("harvests in 180 days", harvests);
        emit log_named_uint("peak modeled harvest gas", peakGas);
        emit log_named_uint("collateral earned in 180 days (wei)", vault.totalAssets() - assetsBefore);
        if (firstDay != 0) {
            assertGt(vault.totalAssets(), assetsBefore);
            assertGt(vault.yieldAccounting().earnedAssets(address(this)), 0);
        }
    }

    function test_realizationDelayWithFivePercentPrimeAndTwoPercentBorrow() public {
        uint256 firstDay = _measureRealization(500, 200);
        assertGt(firstDay, 1, "cost retention must be funded before the first harvest");
        assertLt(firstDay, 180, "positive modeled spread realizes collateral within the campaign");
    }

    function test_realizationWithTenBpsExecutionReserveIsStillNotImmediate() public {
        // sensitivity only; doesn't claim native routes support this ceiling
        loop.configureDca(222, 43, 1043, 143, 1_000);
        uint256 firstDay = _measureRealization(500, 200);
        assertGt(firstDay, 1);
        assertLt(firstDay, 180);
    }

    function test_negativeSpreadCannotFabricateHarvestedCollateral() public {
        assertEq(_measureRealization(200, 500), 0);
    }
}
