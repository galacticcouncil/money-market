// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RecoveryE2ETest} from "./RecoveryE2E.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

/// Daily deterministic stress, not a forecast or an Aave interest-engine replica.
/// All recovery donations are counted separately from strategy earnings.
contract Market90DaysTest is RecoveryE2ETest {
    uint256 internal mainInterest;
    uint256 internal loopInterest;
    uint256 internal externallyFunded;
    uint256 internal missedFloorDays;
    uint256 internal blockedRebalances;
    uint256 internal modeledTvl = 6000;

    function _price(uint256 day, uint256 path, bool btc) internal pure returns (uint256) {
        uint256 start = btc ? 60_000e18 : 3_000e18;
        if (path == 0) return start * (10_000 + day * (btc ? 6000 : 10_000) / 90) / 10_000;
        if (path == 1) return start * (10_000 - day * (btc ? 6000 : 7000) / 90) / 10_000;
        uint256 phase = day % 20;
        uint256 bps = phase <= 10 ? 10_000 + phase * 400 : 14_000 - (phase - 10) * 800;
        return start * bps / 10_000;
    }

    function _fund(address destination, uint256 amount) internal {
        externallyFunded += amount;
        _donate(destination, amount);
    }

    function _accrue(uint256 path, uint256 day, uint256 discountBps) internal {
        uint256 borrowBps = path == 1 ? 1200 : path == 2 ? (day % 20 < 10 ? 250 : 1200) : 440;
        uint256 yieldBps = path == 1 ? 400 : path == 2 ? 550 : 650;
        uint256 earnings = aPrime.balanceOf(address(loop)) * yieldBps / 10_000 / 365;
        aPrime.mint(address(loop), earnings);
        prime.mint(address(pool), earnings);
        uint256 cost = hollarDebt.balanceOf(address(loop)) * borrowBps / 10_000 / 365;
        hollarDebt.mint(address(loop), cost);
        loopInterest += cost;
        for (uint256 i; i < 2; ++i) {
            CollateralVault v = i == 0 ? ethVault : tbtcVault;
            cost = hollarDebt.balanceOf(address(v)) * borrowBps * (10_000 - discountBps) / 1e8 / 365;
            hollarDebt.mint(address(v), cost);
            mainInterest += cost;
            if (v.syntheticSupplied() * v.synthLtBps() / 10_000 < hollarDebt.balanceOf(address(v))) missedFloorDays++;
        }
    }

    function _service(CollateralVault v) internal {
        v.maintainPeg();
        assertGe(v.syntheticSupplied() * v.synthLtBps() / 10_000, hollarDebt.balanceOf(address(v)));
        // A deficit is expected to block resizing; only those errors are allowed.
        try v.rebalance() {} catch (bytes memory reason) {
            bytes4 selector;
            assembly { selector := mload(add(reason, 32)) }
            assertEq(selector, bytes4(keccak256("Underfunded()")), "unexpected rebalance failure");
            blockedRebalances++;
        }
    }

    function _run90(uint256 path, bool outage, uint256 discountBps) internal {
        ethVault.setTvlCap(type(uint128).max);
        tbtcVault.setTvlCap(type(uint128).max);
        uint256 ethDeposit = modeledTvl * 1e18 / 6000 + 7;
        uint256 btcDeposit = modeledTvl * 1e18 / 120000 + 13;
        _deposit(ethVault, eth, ETH_USER, ethDeposit);
        _deposit(tbtcVault, tbtc, BTC_USER, btcDeposit); // equal initial USD weight
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        uint256 start = vm.getBlockTimestamp();
        uint256 previousEth = ethVault.totalAssets();
        uint256 previousBtc = tbtcVault.totalAssets();
        for (uint256 day = 1; day <= 90; ++day) {
            vm.warp(start + day * 1 days);
            pool.setPrice(address(eth), _price(day, path, false));
            pool.setPrice(address(tbtc), _price(day, path, true));
            _accrue(path, day, discountBps);
            // A 30-day keeper outage includes interest accrual and price moves.
            if (!(outage && day >= 21 && day <= 50)) {
                _service(ethVault);
                _service(tbtcVault);
                if (loop.healthFactor() < loop.targetHf()) loop.deLever();
                for (uint256 i; i < 8; ++i) loop.pokeRepay();
                ethVault.pokeSettle();
                tbtcVault.pokeSettle();
                harvester.harvest(new uint256[](0));
            }
            assertGe(ethVault.totalAssets(), previousEth, "ETH principal/backing consumed by market move");
            assertGe(tbtcVault.totalAssets(), previousBtc, "tBTC principal/backing consumed by market move");
            previousEth = ethVault.totalAssets();
            previousBtc = tbtcVault.totalAssets();
            assertEq(eth.balanceOf(ETH_USER), 0);
            assertEq(tbtc.balanceOf(BTC_USER), 0);
            assertGe(eth.balanceOf(address(ethVault)), ethVault.roundingReserve());
            assertGe(tbtc.balanceOf(address(tbtcVault)), tbtcVault.roundingReserve());
        }
        assertEq(vm.getBlockTimestamp() - start, 90 days);
        assertEq(externallyFunded, 0, "no hidden operating subsidies during the 90 days");
        uint256 ethPrincipal = ethVault.totalAssets();
        uint256 btcPrincipal = tbtcVault.totalAssets();

        loop.pauseEmergency();
        uint256 obligation = loop.principalEquity() + loop.unwindTargetEquity();
        uint256 equity = loop.totalEquity() * 1e10;
        if (obligation > equity) _fund(address(loop), obligation - equity + 1e12);
        // Fund only the Main shortfall, not the full Main debt. Accrued Main
        // interest can exceed the source's original share entitlement.
        for (uint256 i; i < 2; ++i) {
            CollateralVault v = i == 0 ? ethVault : tbtcVault;
            uint256 backing = loop.equityOf(address(v)) * 1e10 + loop.pendingUnwindOf(address(v))
                + hollar.balanceOf(address(v));
            uint256 debt = hollarDebt.balanceOf(address(v));
            if (debt > backing) _fund(address(v), debt - backing + 1e12);
            v.maintainPeg();
        }
        loop.unpauseEmergency();
        uint256 ethId = _request(ethVault, ETH_USER, ethVault.balanceOf(ETH_USER));
        uint256 btcId = _request(tbtcVault, BTC_USER, tbtcVault.balanceOf(BTC_USER));
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        ethVault.startUnwinds(16);
        tbtcVault.startUnwinds(16);
        for (uint256 i; i < 500; ++i) {
            uint256 debtBefore = ethVault.totalQueuedDebt() + tbtcVault.totalQueuedDebt();
            ethVault.startUnwinds(16);
            tbtcVault.startUnwinds(16);
            loop.pokeRepay();
            ethVault.pokeSettle();
            tbtcVault.pokeSettle();
            if (ethVault.queueHead() == ethVault.queueTail() && tbtcVault.queueHead() == tbtcVault.queueTail()) break;
            if (i > 100 && ethVault.totalQueuedDebt() + tbtcVault.totalQueuedDebt() == debtBefore) break;
        }
        // USD8 source quotes and proportional source repayments can leave a
        // token-unit tail at scale. Reconcile it explicitly before any claims.
        for (uint256 i; i < 2; ++i) {
            CollateralVault v = i == 0 ? ethVault : tbtcVault;
            uint256 debtTail = v.totalQueuedDebt() + v.deleverTarget();
            uint256 cash = hollar.balanceOf(address(v));
            if (debtTail > cash) {
                emit log_named_uint("Token-unit reconciliation HOLLAR wei", debtTail - cash);
                _fund(address(v), debtTail - cash);
                v.pokeSettle();
            }
        }
        assertEq(ethVault.totalQueuedDebt(), 0, "ETH exit must be funded, not silently stalled");
        assertEq(tbtcVault.totalQueuedDebt(), 0, "tBTC exit must be funded, not silently stalled");
        assertGe(_claim(ethVault, ETH_USER, ethId), ethDeposit);
        assertGe(_claim(tbtcVault, BTC_USER, btcId), btcDeposit);
        assertLe(ethVault.totalAssets(), ethPrincipal);
        assertLe(tbtcVault.totalAssets(), btcPrincipal);
        emit log_named_uint("path (0 bull, 1 bear, 2 seesaw)", path);
        emit log_named_uint("Modeled TVL USD", modeledTvl);
        emit log_named_uint("Main interest HOLLAR wei", mainInterest);
        emit log_named_uint("Loop interest HOLLAR wei", loopInterest);
        emit log_named_uint("External exit funding HOLLAR wei", externallyFunded);
        emit log_named_uint("Synthetic floor misses (vault-days)", missedFloorDays);
        emit log_named_uint("Deficit-blocked rebalances", blockedRebalances);
        if (discountBps == 10_000) assertEq(mainInterest, 0);
        else assertGt(mainInterest, 0);
    }

    function test_90DayBull() public { _run90(0, false, 0); }
    function test_90DayBear() public { _run90(1, false, 0); }
    function test_90DaySeesaw() public { _run90(2, false, 0); }
    function test_90DayBullKeeperOutage() public { _run90(0, true, 0); }
    function test_90DayBearKeeperOutage() public { _run90(1, true, 0); }
    function test_90DaySeesawKeeperOutage() public { _run90(2, true, 0); }
    function test_90DayBullFullMainDiscount() public { _run90(0, false, 10_000); }
    function test_90DayBearFullMainDiscount() public { _run90(1, false, 10_000); }
    function test_90DaySeesawFullMainDiscount() public { _run90(2, false, 10_000); }

    // Mock liquidity/caps are unconstrained; native capacity is checked separately.
    function test_90Day100kBull() public { modeledTvl = 100_000; _run90(0, false, 0); }
    function test_90Day100kBear() public { modeledTvl = 100_000; _run90(1, false, 0); }
    function test_90Day100kSeesaw() public { modeledTvl = 100_000; _run90(2, false, 0); }
    function test_90Day500kBull() public { modeledTvl = 500_000; _run90(0, false, 0); }
    function test_90Day500kBear() public { modeledTvl = 500_000; _run90(1, false, 0); }
    function test_90Day500kSeesaw() public { modeledTvl = 500_000; _run90(2, false, 0); }
    function test_90Day1mBull() public { modeledTvl = 1_000_000; _run90(0, false, 0); }
    function test_90Day1mBear() public { modeledTvl = 1_000_000; _run90(1, false, 0); }
    function test_90Day1mSeesaw() public { modeledTvl = 1_000_000; _run90(2, false, 0); }
    function test_90Day10mBull() public { modeledTvl = 10_000_000; _run90(0, false, 0); }
    function test_90Day10mBear() public { modeledTvl = 10_000_000; _run90(1, false, 0); }
    function test_90Day10mSeesaw() public { modeledTvl = 10_000_000; _run90(2, false, 0); }
    function test_90Day50mBull() public { modeledTvl = 50_000_000; _run90(0, false, 0); }
    function test_90Day50mBear() public { modeledTvl = 50_000_000; _run90(1, false, 0); }
    function test_90Day50mSeesaw() public { modeledTvl = 50_000_000; _run90(2, false, 0); }
    function test_90Day100mBull() public { modeledTvl = 100_000_000; _run90(0, false, 0); }
    function test_90Day100mBear() public { modeledTvl = 100_000_000; _run90(1, false, 0); }
    function test_90Day100mSeesaw() public { modeledTvl = 100_000_000; _run90(2, false, 0); }
}
