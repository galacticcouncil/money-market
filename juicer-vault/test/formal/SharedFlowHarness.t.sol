// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MultiVaultFlowTest} from "../MultiVaultFlow.t.sol";
import {IceIntentsTest} from "../IceIntents.t.sol";
import {SubLoop} from "../../src/SubLoop.sol";

contract SharedHarvestFormalHarness is MultiVaultFlowTest {
    function test_repeatedTwoVaultHarvestHistory() public {
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        ethVault.deposit(1e18, ETH_USER);
        ethVault.rebalance();
        vm.stopPrank();

        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        tbtcVault.rebalance();
        vm.stopPrank();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();

        uint256 ethBefore = aEth.balanceOf(address(ethVault));
        uint256 btcBefore = aTbtc.balanceOf(address(tbtcVault));
        for (uint256 round; round < 3; ++round) {
            uint256 yieldPrime = aPrime.balanceOf(address(loop)) / 100;
            aPrime.mint(address(loop), yieldPrime);
            prime.mint(address(pool), yieldPrime);
            harvester.harvest(new uint256[](2));
            assertEq(
                loop.totalShares(),
                loop.sharesOf(address(ethVault)) + loop.sharesOf(address(tbtcVault)),
                "registered shares partition"
            );
            assertEq(aTbtc.balanceOf(address(ethVault)), 0, "no tBTC in ETH vault");
            assertEq(aEth.balanceOf(address(tbtcVault)), 0, "no ETH in tBTC vault");
        }
        assertGt(aEth.balanceOf(address(ethVault)), ethBefore);
        assertGt(aTbtc.balanceOf(address(tbtcVault)), btcBefore);
        assertGt(ethVault.yieldAccounting().fundedOf(ETH_USER), 0);
        assertGt(tbtcVault.yieldAccounting().fundedOf(BTC_USER), 0);
    }
}

contract IceSequenceFormalHarness is IceIntentsTest {
    function test_longEntryExpiryReconcileAndExitHistory() public {
        _deposit(SEED);
        _rampSteps(3);

        assertGt(loop.pokeBorrowQuoted(ENTRY_RATE), 0);
        uint128 expired = dispatch.lastId();
        (, uint64 deadline,,,) = _pending();
        vm.warp(deadline / 1000);
        dispatch.cleanup(expired);
        assertEq(loop.reconcile(), RETURNED);

        _rampSteps(40);
        assertApproxEqRel(loop.healthFactor(), TARGET_HF, 0.03e18);

        loop.requestUnwind(loop.sharesOf(address(this)) / 2);
        loop.pokeRepayQuoted(EXIT_RATE);
        (,, uint8 firstExitKind,,) = _pending();
        assertEq(firstExitKind, EXIT, "first exit intent submitted");
        uint128 filled = dispatch.lastId();
        uint256 out = dispatch.quote(filled, 1);
        dispatch.fill(filled, out);
        assertEq(loop.reconcile(), FILLED);
        assertEq(_callback(filled, out), SubLoop.execute.selector, "late callback acknowledged");

        uint256 intents;
        for (uint256 i; i < 200 && loop.unwindTargetEquity() != 0; ++i) {
            loop.pokeRepayQuoted(EXIT_RATE);
            (,, uint8 kind,,) = _pending();
            if (kind == 0) continue;
            assertEq(kind, EXIT);
            ++intents;
            _resolve();
        }
        assertGt(intents, 0);
        uint256 freed = loop.freedOf(address(this));
        assertGt(freed, 0);
        assertEq(loop.pullFreed(), freed);
        assertEq(loop.pendingUnwindOf(address(this)), 0);
    }
}
