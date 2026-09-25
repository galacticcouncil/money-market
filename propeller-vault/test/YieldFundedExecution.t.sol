// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RecoveryE2ETest} from "./RecoveryE2E.t.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";

contract YieldFundedExecutionTest is RecoveryE2ETest {
    function _positions() internal {
        this.depositPosition(false, ETH_USER, 1e18);
        this.depositPosition(false, SECOND_ETH_USER, 1e18);
        this.depositPosition(true, BTC_USER, 1e17);
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
    }

    // Separate test calls avoid Solc 0.8.22 inlining three mint/prank/deposit
    // sequences into a Yul block that exceeds the stack allocator's limit.
    function depositPosition(bool btc, address user, uint256 amount) external {
        _deposit(btc ? tbtcVault : ethVault, btc ? tbtc : eth, user, amount);
    }

    function _earnedPrime(uint256 amount) internal {
        // Mock boundary: accumulated PRIME income, not a treasury HOLLAR top-up.
        aPrime.mint(address(loop), amount);
        prime.mint(address(pool), amount);
    }

    function _settleMainResize() internal {
        for (uint256 i; i < 200 && tbtcVault.deleverTarget() != 0; ++i) {
            loop.pokeRepay();
            tbtcVault.pokeSettle();
        }
        assertEq(tbtcVault.deleverTarget(), 0);
    }

    function test_tbtcFallShrinksPrimeLoopToRepayMainWithoutSponsoredCash() public {
        _positions();
        uint256 tbtcBefore = tbtcVault.totalAssets();
        uint256 mainBefore = hollarDebt.balanceOf(address(tbtcVault));
        uint256 loopDebtBefore = hollarDebt.balanceOf(address(loop));
        uint256 primeBefore = aPrime.balanceOf(address(loop));
        assertEq(PropellerMainDebt(address(tbtcVault.mainDebt())).ownedCash(), 0);
        pool.setPrice(address(tbtc), 48_000e18);
        tbtcVault.rebalance();
        assertGt(tbtcVault.deleverTarget(), 0);
        _settleMainResize();
        assertApproxEqAbs(hollarDebt.balanceOf(address(tbtcVault)), mainBefore * 8 / 10, 2e12);
        assertLt(aPrime.balanceOf(address(loop)), primeBefore);
        assertLt(hollarDebt.balanceOf(address(loop)), loopDebtBefore);
        assertEq(tbtcVault.totalAssets(), tbtcBefore);
    }

    function test_earnedPrimePaysResizeFrictionWithoutSellingUserCollateral() public {
        _positions();
        _earnedPrime(1_000e6);
        loop.configureDca(222, 43, 1043, 143, 1_000); // 10bp oracle ceiling
        harvester.harvest(new uint256[](0));
        uint256 surplus = loop.totalEquity() * 1e10 - loop.principalEquity();
        assertGe(surplus + 1e12, loop.executionCostReserve());
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(10);
        uint256 assets = tbtcVault.totalAssets();
        uint256 debt = hollarDebt.balanceOf(address(tbtcVault));
        pool.setPrice(address(tbtc), 48_000e18);
        tbtcVault.rebalance();
        _settleMainResize();
        assertLt(hollarDebt.balanceOf(address(tbtcVault)), debt);
        assertEq(tbtcVault.totalAssets(), assets);
    }

    function test_costHoldbackNeverCreatesOrRequiresStartupCapital() public {
        _positions();
        uint256 assets = aPrime.balanceOf(address(loop));
        uint256 debt = hollarDebt.balanceOf(address(loop));
        uint256 holdback = loop.executionCostReserve();
        assertGt(holdback, 0);
        _earnedPrime(holdback / 2 / 1e12);
        harvester.harvest(new uint256[](0));
        assertEq(hollarDebt.balanceOf(address(loop)), debt);
        assertGe(aPrime.balanceOf(address(loop)), assets);
        assertEq(prime.balanceOf(address(harvester)), 0);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
        assertEq(PropellerMainDebt(address(ethVault.mainDebt())).ownedCash(), 0);
    }

    function test_directPrimeRepaymentBecomesNetCollateralYieldWithoutChangingBasis() public {
        _positions();
        uint256 principal = loop.principalEquity();
        uint256 ethBefore = ethVault.totalAssets();
        uint256 btcBefore = tbtcVault.totalAssets();
        uint256 debt = hollarDebt.balanceOf(address(loop));
        hollar.mint(DONOR, 2_000e18);
        vm.startPrank(DONOR);
        hollar.approve(address(pool), 2_000e18);
        pool.repay(address(hollar), 2_000e18, 2, address(loop));
        vm.stopPrank();
        assertEq(hollarDebt.balanceOf(address(loop)), debt - 2_000e18);
        assertEq(loop.principalEquity(), principal);
        harvester.harvest(new uint256[](0));
        assertGt(ethVault.totalAssets(), ethBefore);
        assertGt(tbtcVault.totalAssets(), btcBefore);
        assertGt(fees.claimableProtocolFees(address(tbtc)), 0);
        assertEq(loop.principalEquity(), principal);
    }

    function test_slippageFailureRollsBackBorrowAndUnwindWithoutWidening() public {
        _positions();
        _earnedPrime(1_000e6);
        loop.configureDca(222, 43, 1043, 143, 1_000);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(11);
        uint256 debt = hollarDebt.balanceOf(address(loop));
        uint256 assets = aPrime.balanceOf(address(loop));
        vm.expectRevert(DcaDispatch.DispatchFailed.selector);
        loop.pokeBorrow();
        assertEq(hollarDebt.balanceOf(address(loop)), debt);
        assertEq(aPrime.balanceOf(address(loop)), assets);
        _request(tbtcVault, BTC_USER, tbtcVault.balanceOf(BTC_USER) / 2);
        vm.warp(vm.getBlockTimestamp() + tbtcVault.withdrawalDelay());
        tbtcVault.startUnwinds(64);
        uint256 pending = loop.unwindTargetEquity();
        vm.expectRevert(DcaDispatch.DispatchFailed.selector);
        loop.pokeRepay();
        assertEq(loop.unwindTargetEquity(), pending);
        assertEq(hollarDebt.balanceOf(address(loop)), debt);
        assertEq(aPrime.balanceOf(address(loop)), assets);
        assertEq(loop.dcaSlippagePpm(), 1_000);
    }

    function test_earnedCostAllowanceProtectsAllThreeExitsWithoutRecovery() public {
        _positions();
        _earnedPrime(1_000e6);
        loop.configureDca(222, 43, 1043, 143, 1_000);
        harvester.harvest(new uint256[](0));
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(10);
        uint256 a = _request(ethVault, ETH_USER, ethVault.balanceOf(ETH_USER));
        uint256 b = _request(ethVault, SECOND_ETH_USER, ethVault.balanceOf(SECOND_ETH_USER));
        uint256 c = _request(tbtcVault, BTC_USER, tbtcVault.balanceOf(BTC_USER));
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        ethVault.startUnwinds(64);
        tbtcVault.startUnwinds(64);
        for (uint256 i; i < 1500; ++i) {
            loop.pokeRepay();
            ethVault.pokeSettle();
            tbtcVault.pokeSettle();
            if (ethVault.totalQueuedDebt() == 0 && tbtcVault.totalQueuedDebt() == 0) break;
        }
        assertEq(ethVault.totalQueuedDebt(), 0);
        assertEq(tbtcVault.totalQueuedDebt(), 0);
        assertGe(_claim(ethVault, ETH_USER, a), 1e18);
        assertGe(_claim(ethVault, SECOND_ETH_USER, b), 1e18);
        assertGe(_claim(tbtcVault, BTC_USER, c), 1e17);
        assertGt(loop.unwindExecutionCost(address(ethVault)), 0);
        assertGt(loop.unwindExecutionCost(address(tbtcVault)), 0);
        assertEq(loop.negativeCarryBps(), 0, "spent yield is an expense, not a fictitious unpaid principal claim");
    }

    function test_realizedCostsCannotWriteOffSourcePrincipalWithoutYield() public {
        _positions();
        loop.configureDca(222, 43, 1043, 143, 1_000);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(10);
        _request(tbtcVault, BTC_USER, tbtcVault.balanceOf(BTC_USER));
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        tbtcVault.startUnwinds(64);
        uint256 claimBefore = loop.pendingUnwindOf(address(tbtcVault));
        uint256 allowance = loop.unwindYieldAllowance(address(tbtcVault));
        loop.pokeRepay();
        uint256 cash = loop.freedOf(address(tbtcVault));
        uint256 cost = loop.unwindExecutionCost(address(tbtcVault));
        assertLe(cost, allowance, "only previously un-compounded yield can absorb execution costs");
        tbtcVault.pokeSettle();
        assertEq(loop.pendingUnwindOf(address(tbtcVault)) + cash + cost, claimBefore);
        assertGt(tbtcVault.totalQueuedDebt(), 0, "unfunded debt remains owed");
    }
}
