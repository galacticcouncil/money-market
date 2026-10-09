// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";
import {PropellerYieldAccounting} from "../src/PropellerYieldAccounting.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {Deficit} from "./helpers/Deficit.sol";

/// @notice new capital must not receive carry earned before entry, even if it exits
/// before the harvest runs
contract YieldEntryFairnessTest is HarvestTest {
    address internal constant NEWCOMER = address(0xB0B);

    function _enterAfterYield() internal returns (uint256 shares) {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) * 5 / 100);
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        shares = vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
    }

    function test_newcomerCannotCaptureEarlierCarryAtHarvest() public {
        uint256 shares = _enterAfterYield();
        harvester.harvest(new uint256[](1));
        assertLe(vault.convertToAssets(shares), 1e18 + 1e9,
            "harvesting earlier carry cannot enrich a newcomer");
        assertLe(_rewardValue(NEWCOMER), 1e9, "newcomer cannot hide old yield in reward units");
        assertGt(_rewardValue(address(this)), 0.1e18, "earlier earnings remain with incumbent");
    }

    function test_newcomerCannotCaptureEarlierCarryByExitingBeforeHarvest() public {
        uint256 shares = _enterAfterYield();
        vm.prank(NEWCOMER);
        uint256 id = vault.requestRedeem(shares, NEWCOMER);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        vm.prank(NEWCOMER);
        uint256 collateralOut = vault.claim(id, NEWCOMER);
        uint256 hollarOut = PropellerMainDebt(address(vault.mainDebt())).claimSurplus(id);
        assertLe(collateralOut + hollarOut / 3000, 1e18 + 1e9,
            "an exit cannot take carry that predates its deposit");
        assertGe(collateralOut, 1e18, "full funded collateral is returned");
        assertEq(PropellerMainDebt(address(vault.mainDebt())).debtOf(id + 1), 0);
    }

    function test_anyoneDeliversASettledClaimToItsOwner() public {
        uint256 shares = _enterAfterYield();
        vm.prank(NEWCOMER);
        uint256 id = vault.requestRedeem(shares, NEWCOMER);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        uint256 before = eth.balanceOf(NEWCOMER);
        vm.prank(address(0xD00D));
        uint256 out = vault.claim(id, address(0xD00D));
        assertGt(out, 0);
        assertEq(eth.balanceOf(NEWCOMER), before + out, "the keeper delivers to the owner");
        assertEq(eth.balanceOf(address(0xD00D)), 0, "a caller cannot redirect someone else's claim");
    }

    function test_fullExitRedeemsEarnedRewardSharesInOneTransaction() public {
        uint256 shares = _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        harvester.harvest(new uint256[](1));
        assertGt(vault.yieldAccounting().claimableShares(address(this)), 0);
        uint256 id = vault.requestRedeem(type(uint256).max, address(this));
        (, uint256 escrowed,,,,,,,) = vault.redemptions(id);
        assertGt(escrowed, shares, "earned reward shares join the redemption");
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.yieldAccounting().claimableShares(address(this)), 0);
    }

    function test_onlyTheOwnerRequestsAFullExit() public {
        _depositAndRamp();
        vm.prank(NEWCOMER);
        vm.expectRevert(CollateralVault.NotRequestOwner.selector);
        vault.requestRedeem(type(uint256).max, address(this));
    }

    function _rewardValue(address owner) internal view returns (uint256) {
        return vault.yieldAccounting().earnedAssets(owner);
    }

    function test_transferBetweenEventsLeavesYieldToTheNextAllocation() public {
        uint256 shares = _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        uint256 snapshot = vm.snapshotState();
        vault.sync();
        vault.transfer(NEWCOMER, shares);
        vault.sync();
        assertEq(_rewardValue(NEWCOMER), 0, "an allocation before the transfer keeps the yield with the sender");
        vm.revertToStateAndDelete(snapshot);
        vault.transfer(NEWCOMER, shares);
        vault.sync();
        assertGt(_rewardValue(NEWCOMER), 0, "between events it follows the balances at the next one");
    }

    function test_transferRetainsAllocatedYieldWithSender() public {
        uint256 shares = _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.sync();
        vault.transfer(NEWCOMER, shares);
        assertGt(_rewardValue(address(this)), 0);
        assertEq(_rewardValue(NEWCOMER), 0);
        harvester.harvest(new uint256[](1));
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(NEWCOMER)), 1e18, 1e9);
        assertLe(_rewardValue(NEWCOMER), 1e9);
        assertGt(vault.claimYield(address(this)), 0, "sender can claim its earned BTC/ETH shares");
    }

    function test_partialRewardClaimPreservesUnconvertedValue() public {
        _enterAfterYield();
        harvester.harvest(new uint256[](1));
        uint256 beforeValue = _rewardValue(address(this));
        uint256 claimed = vault.claimYield(address(this));
        assertGt(claimed, 0);
        assertGt(_rewardValue(address(this)), 0, "retained source yield remains owned");
        assertApproxEqAbs(vault.convertToAssets(claimed) + _rewardValue(address(this)), beforeValue, 1e9);
    }

    function test_waitingWithdrawalKeepsEarningUntilUnwindStarts() public {
        uint256 shares = _depositAndRamp();
        uint256 id = vault.requestRedeem(shares / 2, address(this));
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.sync();
        uint256 firstHalf = _rewardValue(address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        // the waiting half keeps its checkpointed units; its source yield follows the exit
        (,,,uint256 sourceClaim,) = PropellerMainDebt(address(vault.mainDebt())).positions(id + 1);
        uint256 debt = PropellerMainDebt(address(vault.mainDebt())).debtOf(id + 1);
        assertGt(sourceClaim, debt);
        assertGt(firstHalf, 0);
        assertApproxEqAbs(_rewardValue(address(this)) + (sourceClaim - debt) * 95 / 100 / 3000,
            firstHalf * 2, 1e9);
    }

    function test_smallHarvestReborrowsWithoutFivePointLtvDrift() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 50);
        harvester.harvest(new uint256[](1));
        uint256 collateralNow = vault.totalAssets();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        uint256 sourceBefore = vault.loopShares();
        assertGt(debtBefore * 10_000 / (collateralNow * 3000), 7000,
            "the old five-point hysteresis would suppress this borrow");
        assertGt(vault.reinvestAssets(), 0);
        vault.rebalance();
        assertGt(hollarDebt.balanceOf(address(vault)), debtBefore);
        assertGt(vault.loopShares(), sourceBefore);
        assertEq(vault.reinvestAssets(), 0);
        assertLe(hollarDebt.balanceOf(address(vault)), collateralNow * 3000 * 75 / 100);
    }

    function test_rewardCollateralCompoundsBeforeOwnerClaims() public {
        _enterAfterYield();
        harvester.harvest(new uint256[](1));
        PropellerYieldAccounting y = vault.yieldAccounting();
        uint256 firstFunded = vault.balanceOf(address(y));
        uint256 firstValue = _rewardValue(address(this));
        vault.rebalance();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        harvester.harvest(new uint256[](1));
        assertGt(vault.balanceOf(address(y)), firstFunded);
        assertGt(_rewardValue(address(this)), firstValue);
        assertGt(_rewardValue(NEWCOMER), 0, "new holders earn subsequent yield");
        assertEq(vault.loopShares(), loop.sharesOf(address(vault)));
        assertLe(y.sourceShares(), vault.loopShares());
    }

    function test_unconvertedEarningsAreNotLeveredAgain() public {
        _depositAndRamp();
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        uint256 baselineDebt = hollarDebt.balanceOf(address(loop));
        vm.revertToState(snapshot);
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        // Forty native 6-decimal buys plus repeated loop/oracle rounding.
        assertApproxEqAbs(hollarDebt.balanceOf(address(loop)), baselineDebt, 4e14,
            "pending BTC earnings must not fund another PRIME leverage cycle");
    }

    function test_feeOwnershipSurvivesLaterRateChange() public {
        _depositAndRamp();
        fees.setProtocolFeeBps(address(vault), 10_000);
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.sync();
        assertEq(vault.yieldAccounting().sourceShares(), 0);
        assertGt(vault.yieldAccounting().protocolShares(), 0);
        fees.setProtocolFeeBps(address(vault), 0);
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
        harvester.harvest(new uint256[](1));
        assertGt(fees.claimableProtocolFees(address(eth)), 0.1e18);
        assertApproxEqAbs(vault.convertToAssets(shares), 1e18, 1e9);
        assertLe(_rewardValue(NEWCOMER), 1e9);
    }

    function test_recoveryCashIsNotTaxedOrGivenToNewEntrant() public {
        _depositAndRamp();
        uint256 shortfall = loop.principalEquity() - loop.totalEquity() * 1e10;
        uint256 expected = (300e18 - shortfall) / 3000;
        PropellerMainDebt ledger = PropellerMainDebt(address(vault.mainDebt()));
        hollar.mint(address(this), 300e18);
        hollar.approve(address(ledger), 300e18);
        ledger.fundPosition(0, 300e18);
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
        assertApproxEqAbs(_rewardValue(address(this)), expected, 1e9);
        harvester.harvest(new uint256[](1));
        assertLe(fees.claimableProtocolFees(address(eth)), 1e9);
        assertLe(_rewardValue(NEWCOMER), 1e9);
        assertApproxEqAbs(vault.convertToAssets(vault.claimYield(address(this)))
            + _rewardValue(address(this)), expected, 1e9);
    }

    function test_unrealizedYieldAbsorbsLossBeforeMainRecovery() public {
        _depositAndRamp();
        // Repair the fixture's accumulated native PRIME conversion dust first.
        hollar.mint(address(loop), loop.principalEquity() - loop.totalEquity() * 1e10);
        uint256 income = aPrime.balanceOf(address(loop)) / 20;
        aPrime.mint(address(loop), income);
        vault.sync();
        assertGt(_rewardValue(address(this)), 0);
        aPrime.burn(address(loop), income);
        vault.sync();
        assertEq(_rewardValue(address(this)), 0);
        assertEq(vault.yieldAccounting().reservedShares(), 0);
        assertFalse(Deficit.underfunded(vault), "return to borrowed basis still backs Main");
    }

    function test_repeatedYieldWriteOffDoesNotInflateAccountingUnits() public {
        _depositAndRamp();
        hollar.mint(address(loop), loop.principalEquity() - loop.totalEquity() * 1e10);
        PropellerYieldAccounting y = vault.yieldAccounting();
        for (uint256 i; i < 16; ++i) {
            aPrime.mint(address(loop), 100e6);
            vault.sync();
            assertGt(y.balanceOf(address(this)), 0);
            assertLe(y.totalUnits(), 100e18);
            aPrime.burn(address(loop), 100e6);
            vault.sync();
            assertEq(y.totalUnits(), 0);
            assertEq(y.balanceOf(address(this)), 0);
            assertEq(y.epoch(), i + 1);
        }
    }

    function test_mainRecoveryCannotMakeHarvesterWithdrawPastHealthFloor() public {
        _depositAndRamp();
        PropellerMainDebt ledger = PropellerMainDebt(address(vault.mainDebt()));
        uint256 debt = ledger.debtOf(0);
        hollar.mint(address(this), debt);
        hollar.approve(address(ledger), debt);
        ledger.fundPosition(0, debt);
        vault.sync();
        harvester.harvest(new uint256[](1));
        assertGe(loop.healthFactor(), loop.deployHfFloor());
        assertGt(_rewardValue(address(this)), 0.7e18,
            "unrealized released capital stays owned until safely convertible");
    }

    function test_dustRemainingAfterLossRescalesUnitsWithoutChangingOwnership() public {
        uint256 shares = _depositAndRamp();
        hollar.mint(address(loop), loop.principalEquity() - loop.totalEquity() * 1e10);
        vault.transfer(NEWCOMER, shares / 2);
        PropellerYieldAccounting y = vault.yieldAccounting();
        for (uint256 i; i < 12; ++i) {
            aPrime.mint(address(loop), 1_000e6);
            vault.sync();
            assertApproxEqAbs(_rewardValue(address(this)), _rewardValue(NEWCOMER), 1e9);
            assertLe(y.balanceOf(address(this)) + y.balanceOf(NEWCOMER), y.totalUnits());
            assertLe(y.totalUnits(), uint256(1) << 162);
            // leave one prime base unit per loss to hit normalization, not the full write-off reset
            aPrime.burn(address(loop), 1_000e6 - 1);
            vault.sync();
            assertGt(y.totalUnits(), 0);
        }
        assertGt(y.unitScale(), 0);
        aPrime.mint(address(loop), 1_000e6);
        prime.mint(address(pool), 1_000e6);
        harvester.harvest(new uint256[](1));
        uint256 earned = _rewardValue(NEWCOMER);
        vm.prank(NEWCOMER);
        uint256 claimed = vault.claimYield(NEWCOMER);
        assertGt(claimed, 0);
        assertApproxEqAbs(vault.convertToAssets(claimed) + _rewardValue(NEWCOMER), earned, 1e9);
        assertApproxEqAbs(_rewardValue(address(this)), earned, 1e9);
    }

    function test_vestedExitRewardsKeepEarningAndRemainClaimable() public {
        _enterAfterYield();
        harvester.harvest(new uint256[](1));
        uint256 id = vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        PropellerYieldAccounting y = vault.yieldAccounting();
        uint256 vested = y.vestedShares(address(this));
        assertGt(vested, 0);
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        vault.claim(id, address(this));
        assertEq(vault.balanceOf(address(this)), 0);
        uint256 before_ = _rewardValue(address(this));
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        harvester.harvest(new uint256[](1));
        assertGt(_rewardValue(address(this)), before_, "escrowed funded rewards still earn");
        uint256 claimable = y.claimableShares(address(this));
        assertGe(claimable, vested);
        assertEq(vault.claimYield(address(this)), claimable);
        assertEq(y.vestedShares(address(this)), 0);
        assertEq(y.totalVestedShares(), 0);
    }

    function test_newcomerDoesNotReceiveOldMainInterestReserve() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        hollarDebt.mint(address(vault), 25e18);
        vault.maintainPeg();
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
        harvester.harvest(new uint256[](1));
        assertEq(PropellerMainDebt(address(vault.mainDebt())).interestOf(0), 0);
        assertLe(vault.convertToAssets(shares) + _rewardValue(NEWCOMER), 1e18 + 1e9);
    }

    function test_deficitSeesMainInterestCoveredOnlyBeforeFees() public {
        _depositAndRamp();
        aPrime.mint(address(loop), 25_500_000); // $25.50 gross; less than $25 net of fees
        hollarDebt.mint(address(vault), 25e18);
        vault.maintainPeg();
        assertGt(loop.equityOf(address(vault)) * 1e10, hollarDebt.balanceOf(address(vault)));
        assertTrue(Deficit.underfunded(vault), "gross receivables cannot fund a net servicing obligation");
    }

    function test_fullFeeNeedsNetFundingForMainInterest() public {
        _depositAndRamp();
        fees.setProtocolFeeBps(address(vault), 10_000);
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        hollarDebt.mint(address(vault), 25e18);
        vault.maintainPeg();
        assertTrue(Deficit.underfunded(vault), "100 percent fees leave no net interest funding");
        eth.mint(NEWCOMER, 1e18);
        vm.prank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        PropellerMainDebt ledger = PropellerMainDebt(address(vault.mainDebt()));
        hollar.mint(address(this), 25e18);
        hollar.approve(address(ledger), 25e18);
        ledger.fundPosition(0, 25e18);
        vm.prank(NEWCOMER);
        vault.deposit(1e18, NEWCOMER);
        assertEq(ledger.interestOf(0), 0);
        assertEq(fees.claimableProtocolFees(address(hollar)), 0, "recovery funding is untaxed");
    }

    function test_exitFeeUsesActualYieldAndLockedRateAcrossPartialReceipts() public {
        _depositAndRamp();
        PropellerMainDebt ledger = PropellerMainDebt(address(vault.mainDebt()));
        vm.prank(address(vault));
        ledger.startExit(0, address(this), 1, 2, 1_000e18, 900e18, 5e18);
        fees.setProtocolFeeBps(address(vault), 10_000);
        hollar.mint(address(this), 25e18);
        hollar.approve(address(ledger), 25e18);
        ledger.fundPosition(1, 25e18);
        assertEq(fees.claimableProtocolFees(address(hollar)), 0, "donations are not fees");
        for (uint256 i; i < 10; ++i) {
            hollar.mint(address(vault), 100e18);
            vm.startPrank(address(vault));
            hollar.approve(address(ledger), 100e18);
            ledger.creditSource(100e18);
            vm.stopPrank();
            if (i < 9) assertEq(fees.claimableProtocolFees(address(hollar)), 0,
                "late execution costs must still be able to reduce the fee");
        }
        assertEq(fees.claimableProtocolFees(address(hollar)), 5e18);
        (,,uint256 cash,uint256 remaining,) = ledger.positions(1);
        assertEq(remaining, 0);
        assertEq(cash, 1_020e18, "principal plus net yield plus untaxed recovery donation");
        assertEq(ledger.ownedCash(), cash);
        assertEq(hollar.balanceOf(address(ledger)), cash);
    }

    function test_ownedFeeAndYieldBearExitExecutionCostsTogether() public {
        _depositAndRamp();
        loop.configureDca(222, 43, 1043, 143, 1_000);
        uint256 income = aPrime.balanceOf(address(loop)) / 20;
        aPrime.mint(address(loop), income);
        prime.mint(address(pool), income);
        harvester.harvest(new uint256[](1));
        vault.claimYield(address(this));
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(10);
        uint256 id = vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        for (uint256 i; i < 500; ++i) {
            loop.pokeRepay();
            vault.pokeSettle();
            if (vault.totalQueuedDebt() == 0) break;
        }
        assertEq(vault.totalQueuedDebt(), 0, "fees cannot consume principal's execution budget");
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), promised);
    }

    function test_lateExecutionCostReducesReservedFeeAfterPartialSurplus() public {
        _depositAndRamp();
        PropellerMainDebt ledger = PropellerMainDebt(address(vault.mainDebt()));
        vm.prank(address(vault));
        ledger.startExit(0, address(this), 1, 2, 1_000e18, 900e18, 5e18);
        hollar.mint(address(vault), 900e18);
        vm.startPrank(address(vault));
        hollar.approve(address(ledger), 900e18);
        ledger.creditSource(900e18);
        vm.stopPrank();
        uint256 main = hollarDebt.balanceOf(address(vault));
        hollar.mint(address(this), main);
        hollar.approve(address(pool), main);
        pool.repay(address(hollar), main, 2, address(vault));
        vm.prank(address(vault));
        ledger.repay(1, type(uint256).max, 0);
        assertEq(ledger.surplusOf(0), 895e18);
        assertEq(ledger.claimSurplus(0), 895e18);
        assertEq(ledger.sourceFeeReserve(), 5e18);
        vm.mockCall(address(loop), abi.encodeWithSelector(loop.unwindExecutionCost.selector, address(vault)),
            abi.encode(60e18));
        hollar.mint(address(vault), 40e18);
        vm.startPrank(address(vault));
        hollar.approve(address(ledger), 40e18);
        ledger.creditSource(40e18);
        vm.stopPrank();
        assertEq(fees.claimableProtocolFees(address(hollar)), 2e18,
            "5 percent applies to forty actually realized yield, not the original hundred");
        assertEq(ledger.sourceFeeReserve(), 0);
        assertEq(ledger.claimSurplus(0), 43e18);
        assertEq(ledger.ownedCash(), 0);
    }

    function test_transferDuringMainResizeKeepsEarlierYieldOwnership() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        pool.setPrice(address(eth), 2_400e18);
        vault.sync();
        uint256 earned = _rewardValue(address(this));
        vault.rebalance();
        assertGt(vault.mainDebt().activeSourceRemaining(), 0);
        vault.transfer(NEWCOMER, vault.balanceOf(address(this)) / 2);
        assertApproxEqAbs(_rewardValue(address(this)), earned, 1e9);
        assertEq(_rewardValue(NEWCOMER), 0);
        for (uint256 i; i < 400 && vault.deleverTarget() != 0; ++i) {
            loop.pokeRepay();
            vault.pokeSettle();
        }
        assertEq(vault.deleverTarget(), 0);
        vault.sync();
        assertApproxEqAbs(_rewardValue(address(this)), earned, 1e9);
        assertLe(_rewardValue(NEWCOMER), 1e9);
    }

    function test_fullyCashBackedExitNeedsNoActiveSourceSlice() public {
        uint256 shares = _depositAndRamp();
        PropellerMainDebt ledger = PropellerMainDebt(address(vault.mainDebt()));
        uint256 debt = ledger.debtOf(0);
        hollar.mint(address(this), debt);
        hollar.approve(address(ledger), debt);
        ledger.fundPosition(0, debt);
        vault.transfer(NEWCOMER, shares); // original owner keeps the released capital
        vm.prank(NEWCOMER);
        uint256 id = vault.requestRedeem(shares, NEWCOMER);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        vault.pokeSettle();
        vm.prank(NEWCOMER);
        assertGe(vault.claim(id, NEWCOMER), 1e18 - 1000);
        assertEq(ledger.debtOf(id + 1), 0);
    }

    function test_btcEightDecimalsPreservesEntryOwnership() public {
        eth = new MockERC20("BTC", "BTC", 8);
        aEth = new MockERC20("aBTC", "aBTC", 8);
        ethDebt = new MockERC20("dBTC", "dBTC", 8);
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 8, 60_000e18);
        vault = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, ("Propeller BTC", "pBTC", address(eth), address(pool),
                address(loop), address(swapper), address(hollar), address(synth), address(aEth),
                address(hollarDebt), 1_000e8, address(this))))));
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        vault.setCompoundSlippageBps(100);
        vault.setFeeController(address(fees));
        fees.registerVault(address(vault), address(harvester));
        harvester.addVault(address(vault));
        eth.mint(address(this), 1e8);
        eth.approve(address(vault), 1e8);
        vault.deposit(1e8, address(this));
        vault.rebalance();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        eth.mint(NEWCOMER, 1e8);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e8);
        uint256 shares = vault.deposit(1e8, NEWCOMER);
        vm.stopPrank();
        harvester.harvest(new uint256[](2));
        assertLe(vault.convertToAssets(shares) + _rewardValue(NEWCOMER), 1e8 + 1);
        assertGt(vault.convertToAssets(vault.claimYield(address(this))), 1e6);
        assertLe(vault.yieldAccounting().reservedShares(), vault.loopShares());
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_transferAndPartialClaimsConserveOwnership(uint16 fraction) public {
        uint256 shares = _enterAfterYield();
        uint256 part = shares * bound(fraction, 1, 10_000) / 10_000;
        vm.prank(NEWCOMER);
        vault.transfer(address(0xCAFE), part);
        harvester.harvest(new uint256[](1));
        uint256 before_ = _rewardValue(address(this));
        uint256 claimed = vault.claimYield(address(this));
        assertApproxEqAbs(vault.convertToAssets(claimed) + _rewardValue(address(this)), before_, 1e9);
        assertLe(_rewardValue(NEWCOMER) + _rewardValue(address(0xCAFE)), 1e9);
        PropellerYieldAccounting y = vault.yieldAccounting();
        assertLe(y.balanceOf(address(this)) + y.balanceOf(NEWCOMER) + y.balanceOf(address(0xCAFE)), y.totalUnits());
        assertEq(loop.sharesOf(address(vault)), vault.loopShares());
    }
}
