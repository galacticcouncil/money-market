// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RecoveryE2ETest} from "./RecoveryE2E.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";
import {PropellerDiscount} from "../src/PropellerDiscount.sol";
import {MockDiscountDebtToken, MockDiscountAToken} from "./mocks/MockDiscount.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {SubLoop} from "../src/SubLoop.sol";

/// Real Propeller bytecode with explicit market fixtures, not a liquidity engine.
/// 180 main cases + 190 sensitivities cover the selected policy's comparison grid.
contract MainDebtCampaignTest is RecoveryE2ETest {
    struct Scenario {
        uint256 tvl;
        uint256 path; // flat, bull, bear, seesaw, rally/crash
        bool outage;
        uint16 discount;
        uint16 swapCost;
        uint16 loopCost;
        uint16 slippageBps;
        uint32 incentiveMode;
        uint32 exitLag;
        uint32 harvestEvery;
        uint32 halfExitDay;
        uint256 dimension;
    }
    struct Metrics {
        uint256 mainInterest;
        uint256 loopInterest;
        uint256 recovery;
        uint256 peakDebt;
        uint256 floorMisses;
        uint256 blocked;
        uint256 incentive;
        uint256 liquidations;
        uint256 ethReturnBps;
        uint256 btcReturnBps;
        uint256 bufferPaid;
        uint256 residualSourceClaim;
        uint256 recoveryLiquidity;
    }
    Metrics internal metrics;
    PropellerDiscount internal policy;
    uint256 internal unseededSnapshot;

    function _bootstrapVaults() internal override {
        unseededSnapshot = vm.snapshotState();
        super._bootstrapVaults();
    }

    function _default(uint256 tvl, uint256 path) internal view returns (Scenario memory s) {
        s = Scenario(tvl, path, false, 0, 10, 0, 100, 0, 2 days, 1, 60, 0);
        uint256 loopCost = vm.envOr("CAMPAIGN_LOOP_COST_BPS", uint256(s.loopCost));
        uint256 swapCost = vm.envOr("CAMPAIGN_SWAP_COST_BPS", uint256(s.swapCost));
        uint256 ceiling = vm.envOr("CAMPAIGN_CEILING_BPS", uint256(s.slippageBps));
        require(loopCost <= ceiling && ceiling <= 100 && swapCost <= 100, "invalid campaign costs");
        s.loopCost = uint16(loopCost);
        s.swapCost = uint16(swapCost);
        s.slippageBps = uint16(ceiling);
    }

    function _installDiscount() internal {
        vm.etch(address(hollarDebt), address(new MockDiscountDebtToken(address(pool))).code);
        vm.etch(address(aSynth), address(new MockDiscountAToken(address(pool), address(synth))).code);
        policy = new PropellerDiscount(address(hollarDebt), address(synth), address(aSynth), address(this), address(this));
        MockDiscountDebtToken(address(hollarDebt)).setPolicy(address(policy));
        ethVault.setDiscountController(address(policy));
        tbtcVault.setDiscountController(address(policy));
        policy.registerVault(address(ethVault));
        policy.registerVault(address(tbtcVault));
    }

    function _market(uint256 day, uint256 path) internal pure returns (uint256 ethPrice, uint256 btcPrice, uint256 rate, uint256 yieldRate) {
        uint256 e = 10_000;
        uint256 b = 10_000;
        rate = 44016888918e15; // snapshot APR rounded to 11 decimal places
        yieldRate = 65e24;
        if (path == 1) { e += day * 10_000 / 90; b += day * 6_000 / 90; }
        if (path == 2) { e -= day * 7_000 / 90; b -= day * 6_000 / 90; rate = 12e25; yieldRate = 4e25; }
        if (path == 3) {
            uint256 phase = day % 20;
            e = phase <= 10 ? 10_000 + phase * 400 : 14_000 - (phase - 10) * 800;
            b = e;
            rate = phase < 10 ? 25e24 : 12e25;
            yieldRate = 55e24;
        }
        if (path == 4) {
            if (day <= 45) { e += day * 5_000 / 45; b += day * 3_000 / 45; }
            else { e = 15_000 - (day - 45) * 12_000 / 45; b = 13_000 - (day - 45) * 9_000 / 45; rate = 12e25; yieldRate = 4e25; }
        }
        return (3_000e18 * e / 10_000, 60_000e18 * b / 10_000, rate, yieldRate);
    }

    function _accrue(uint256 rate, uint256 yieldRate, uint256 seconds_) internal {
        pool.setVariableBorrowRate(uint128(rate));
        uint256 earnings = aPrime.balanceOf(address(loop)) * yieldRate / 1e27 * seconds_ / 365 days;
        aPrime.mint(address(loop), earnings);
        prime.mint(address(pool), earnings);
        uint256 cost = hollarDebt.balanceOf(address(loop)) * rate / 1e27 * seconds_ / 365 days;
        hollarDebt.mint(address(loop), cost);
        metrics.loopInterest += cost;
        for (uint256 i; i < 2; ++i) {
            CollateralVault v = i == 0 ? ethVault : tbtcVault;
            uint256 discount = MockDiscountDebtToken(address(hollarDebt)).getDiscountPercent(address(v));
            cost = hollarDebt.balanceOf(address(v)) * rate / 1e27 * seconds_ / 365 days * (10_000 - discount) / 10_000;
            hollarDebt.mint(address(v), cost);
            metrics.mainInterest += cost;
            if (v.syntheticSupplied() * v.synthLtBps() / 10_000 < hollarDebt.balanceOf(address(v))) ++metrics.floorMisses;
        }
    }

    function _buffer(CollateralVault v) internal view returns (PropellerMainDebt) {
        return PropellerMainDebt(address(v.mainDebt()));
    }

    function _fundSource() internal {
        uint256 obligation = loop.principalEquity() + loop.unwindTargetEquity();
        uint256 equity = loop.totalEquity() * 1e10;
        if (obligation > equity) {
            uint256 amount = obligation - equity + 1e12;
            metrics.recovery += amount;
            _donate(address(loop), amount);
        }
    }

    function _fundCohorts(CollateralVault v) internal {
        PropellerMainDebt buffer = _buffer(v);
        for (uint256 key; key <= v.queueUnwind(); ++key) {
            (,,uint256 cash, uint256 pending,) = buffer.positions(key);
            uint256 debt = buffer.debtOf(key);
            uint256 backing = cash + pending;
            if (key == 0) backing += loop.equityOf(address(v)) * 1e10 + buffer.activeSourceRemaining();
            if (debt > backing) {
                uint256 amount = debt - backing + 1e12;
                metrics.recovery += amount;
                hollar.mint(address(this), amount);
                hollar.approve(address(buffer), amount);
                buffer.fundPosition(key, amount);
            }
        }
    }

    function _tryRebalance(CollateralVault v) internal {
        try v.rebalance() {} catch (bytes memory reason) {
            bytes4 selector;
            assembly { selector := mload(add(reason, 32)) }
            assertTrue(selector == CollateralVault.Underfunded.selector
                || selector == PropellerMainDebt.UnfundedInterest.selector
                || selector == PropellerMainDebt.OutstandingDebt.selector, "unexpected rebalance revert");
            ++metrics.blocked;
        }
    }

    function _run(Scenario memory s) internal {
        if (vm.envOr("REPLAY_CASE", false) && (s.path != vm.envOr("CASE_PATH", uint256(0))
            || s.dimension != vm.envOr("CASE_DIMENSION", uint256(0))
            || s.discount != vm.envOr("CASE_DISCOUNT", uint256(0))
            || s.outage != vm.envOr("CASE_OUTAGE", false))) return;
        delete metrics;
        policy.setDiscountBps(s.discount);
        pool.setVariableBorrowRate(44016888918e15);
        MockDispatch dispatch = MockDispatch(payable(DcaDispatch.DISPATCH));
        dispatch.setFeeBps(s.loopCost);
        swapper.setHaircut(s.swapCost);
        ethVault.setTvlCap(type(uint128).max);
        tbtcVault.setTvlCap(type(uint128).max);
        loop.configureDca(222, 43, 1043, 143, uint32(s.slippageBps) * 100);
        _deposit(ethVault, eth, address(this), 1e12);
        _fundSource();
        _deposit(tbtcVault, tbtc, address(this), 1e12);
        _fundSource();
        _fundCohorts(ethVault);
        _fundCohorts(tbtcVault);
        uint256 ethPrincipal = s.tvl * 1e18 / 6000 + 7;
        uint256 btcPrincipal = s.tvl * 1e18 / 120000 + 13;
        _deposit(ethVault, eth, ETH_USER, ethPrincipal);
        _fundSource(); // entry friction is explicit sponsorship, never hidden yield
        // Shared NAV rounding can leave the other seed one USD base unit short.
        // Fund that measured cohort deficit; do not weaken deposit admission.
        _fundCohorts(tbtcVault);
        _deposit(tbtcVault, tbtc, BTC_USER, btcPrincipal);
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        uint256 start = vm.getBlockTimestamp();
        uint256 previousEth = ethVault.totalAssets();
        uint256 previousBtc = tbtcVault.totalAssets();
        uint256 settlementAfter;
        bool halfRequested;
        for (uint256 day = 1; day <= 90; ++day) {
            vm.warp(start + day * 1 days);
            (uint256 e, uint256 b, uint256 rate, uint256 yieldRate) = _market(day, s.path);
            pool.setPrice(address(eth), e);
            pool.setPrice(address(tbtc), b);
            _accrue(rate, yieldRate, 1 days);
            if (day == 30 && s.incentiveMode != 0) this.applyIncentive(s.tvl, s.incentiveMode);
            if (loop.healthFactor() < 1e18 && metrics.liquidations == 0) {
                loop.pauseEmergency();
                _modelLoopLiquidation();
                ++metrics.liquidations;
            }
            bool outage = s.outage && day >= 21 && day <= 50;
            if (!outage && !loop.emergencyPaused()) {
                ethVault.maintainPeg();
                tbtcVault.maintainPeg();
                if (day % s.harvestEvery == 0) harvester.harvest(new uint256[](0));
                if (!halfRequested && day >= s.halfExitDay) {
                    _request(ethVault, ETH_USER, ethVault.balanceOf(ETH_USER) / 2);
                    _request(tbtcVault, BTC_USER, tbtcVault.balanceOf(BTC_USER) / 2);
                    settlementAfter = vm.getBlockTimestamp() + 12 hours + s.exitLag;
                    halfRequested = true;
                }
                ethVault.startUnwinds(64);
                tbtcVault.startUnwinds(64);
                if (loop.healthFactor() < loop.targetHf()) {
                    try loop.deLever() {} catch (bytes memory reason) {
                        assertEq(bytes4(reason), SubLoop.HealthyEnough.selector, "unexpected safety scheduling failure");
                    }
                }
                if (vm.getBlockTimestamp() >= settlementAfter) {
                    for (uint256 i; i < 8; ++i) loop.pokeRepay();
                    ethVault.pokeSettle();
                    tbtcVault.pokeSettle();
                }
                _tryRebalance(ethVault);
                _tryRebalance(tbtcVault);
                if (loop.unwindTargetEquity() == 0 && loop.negativeCarryBps() == 0
                    && ethVault.pendingWithdrawalShares() == 0 && tbtcVault.pendingWithdrawalShares() == 0
                    && _buffer(ethVault).ready() && _buffer(tbtcVault).ready()) {
                    for (uint256 i; i < 8; ++i) loop.pokeBorrow();
                }
            }
            assertGe(ethVault.totalAssets(), previousEth, "ordinary servicing consumed ETH backing");
            assertGe(tbtcVault.totalAssets(), previousBtc, "ordinary servicing consumed tBTC backing");
            previousEth = ethVault.totalAssets();
            previousBtc = tbtcVault.totalAssets();
            uint256 debt = hollarDebt.balanceOf(address(loop)) + hollarDebt.balanceOf(address(ethVault))
                + hollarDebt.balanceOf(address(tbtcVault));
            if (debt > metrics.peakDebt) metrics.peakDebt = debt;
        }
        // Manual governance recovery is a separate, measured source of money.
        _fundSource();
        _fundCohorts(ethVault);
        _fundCohorts(tbtcVault);
        if (loop.emergencyPaused()) loop.unpauseEmergency();
        ethVault.maintainPeg();
        tbtcVault.maintainPeg();
        _request(ethVault, ETH_USER, ethVault.balanceOf(ETH_USER));
        _request(tbtcVault, BTC_USER, tbtcVault.balanceOf(BTC_USER));
        vm.warp(vm.getBlockTimestamp() + 12 hours + s.exitLag);
        (,,uint256 endRate, uint256 endYield) = _market(90, s.path);
        _accrue(endRate, endYield, 12 hours + s.exitLag);
        ethVault.maintainPeg();
        tbtcVault.maintainPeg();
        // HF-safe sales converge geometrically; large books can need more than
        // 600 keeper calls even with only cents remaining. No debt is rounded off.
        for (uint256 i; i < 1500; ++i) {
            _fundSource();
            _fundCohorts(ethVault);
            _fundCohorts(tbtcVault);
            ethVault.startUnwinds(64);
            tbtcVault.startUnwinds(64);
            loop.pokeRepay();
            ethVault.pokeSettle();
            tbtcVault.pokeSettle();
            if (ethVault.queueHead() == ethVault.queueTail() && tbtcVault.queueHead() == tbtcVault.queueTail()) break;
        }
        // A source receivable is not spendable HOLLAR. If the bounded unwind
        // campaign stalls, governance bridges every remaining exit explicitly;
        // the original owners retain the source claims after Main is paid.
        _bridgeExitLiquidity(ethVault);
        _bridgeExitLiquidity(tbtcVault);
        ethVault.pokeSettle();
        tbtcVault.pokeSettle();
        assertEq(ethVault.queueHead(), ethVault.queueTail(), "ETH recovery incomplete");
        assertEq(tbtcVault.queueHead(), tbtcVault.queueTail(), "tBTC recovery incomplete");
        for (uint256 id; id < ethVault.queueTail(); ++id) _claim(ethVault, ETH_USER, id);
        for (uint256 id; id < tbtcVault.queueTail(); ++id) _claim(tbtcVault, BTC_USER, id);
        assertGe(eth.balanceOf(ETH_USER), ethPrincipal);
        assertGe(tbtc.balanceOf(BTC_USER), btcPrincipal);
        metrics.ethReturnBps = (eth.balanceOf(ETH_USER) - ethPrincipal) * 10_000 / ethPrincipal;
        metrics.btcReturnBps = (tbtc.balanceOf(BTC_USER) - btcPrincipal) * 10_000 / btcPrincipal;
        for (uint256 id; id < ethVault.queueTail(); ++id) metrics.bufferPaid += _buffer(ethVault).claimSurplus(id);
        for (uint256 id; id < tbtcVault.queueTail(); ++id) metrics.bufferPaid += _buffer(tbtcVault).claimSurplus(id);
        metrics.residualSourceClaim = loop.pendingUnwindOf(address(ethVault)) + loop.pendingUnwindOf(address(tbtcVault));
        assertEq(ethVault.totalQueuedCollateral(), 0);
        assertEq(tbtcVault.totalQueuedCollateral(), 0);
        if (s.discount == 10_000) assertEq(metrics.mainInterest, 0);
        _report(s, dispatch);
    }

    function _bridgeExitLiquidity(CollateralVault v) internal {
        PropellerMainDebt ledger = _buffer(v);
        for (uint256 id = v.queueHead(); id < v.queueUnwind(); ++id) {
            uint256 key = id + 1;
            (,,uint256 cash,,) = ledger.positions(key);
            uint256 debt = ledger.debtOf(key);
            if (debt <= cash) continue;
            uint256 amount = debt - cash;
            metrics.recovery += amount;
            metrics.recoveryLiquidity += amount;
            hollar.mint(address(this), amount);
            hollar.approve(address(ledger), amount);
            ledger.fundPosition(key, amount);
        }
    }

    function applyIncentive(uint256 tvl, uint32 mode) external {
        // Day-30 governance budget of 0.5% TVL. This is external funding, not yield.
        uint256 budget = tvl * 1e18 / 200;
        for (uint256 i; i < (mode == 3 ? 1 : 2); ++i) {
            address borrower = mode == 3 ? address(loop)
                : i == 0 ? address(ethVault) : address(tbtcVault);
            uint256 amount = mode == 3 ? budget : budget / 2;
            uint256 debt = hollarDebt.balanceOf(borrower);
            if (mode == 1) debt = _buffer(CollateralVault(borrower)).interestOf(0);
            if (amount > debt) amount = debt;
            if (amount == 0) continue;
            hollar.mint(address(this), amount);
            hollar.approve(address(pool), amount);
            metrics.incentive += pool.repay(address(hollar), amount, 2, borrower);
        }
    }

    function _report(Scenario memory s, MockDispatch dispatch) internal {
        uint256[26] memory values = [s.tvl, s.path, s.outage ? 1 : 0, uint256(s.discount), s.dimension,
            uint256(s.swapCost), uint256(s.loopCost), uint256(s.slippageBps), uint256(s.incentiveMode),
            uint256(s.exitLag), uint256(s.harvestEvery), uint256(s.halfExitDay), metrics.mainInterest,
            metrics.loopInterest, metrics.incentive, metrics.recovery, metrics.peakDebt,
            dispatch.hollarSold(), dispatch.hollarBought(), metrics.floorMisses, metrics.liquidations,
            metrics.ethReturnBps, metrics.btcReturnBps, metrics.bufferPaid, metrics.residualSourceClaim,
            metrics.recoveryLiquidity];
        string memory line = "CONTRACT_CASE";
        for (uint256 i; i < values.length; ++i) line = string.concat(line, ",", vm.toString(values[i]));
        emit log_string(line);
    }

    function _matrix(uint256 tvl) internal {
        if (!vm.envOr("RUN_MAIN_DEBT_CAMPAIGN", false)) vm.skip(true);
        assertTrue(vm.revertToStateAndDelete(unseededSnapshot));
        _installDiscount();
        for (uint256 path; path < 5; ++path) for (uint256 outage; outage < 2; ++outage) for (uint256 discount; discount < 3; ++discount) {
            uint256 snapshot = vm.snapshotState();
            Scenario memory s = _default(tvl, path);
            s.outage = outage != 0;
            s.discount = uint16(discount * 5000);
            _run(s);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function _sensitivities(uint256 tvl) internal {
        if (!vm.envOr("RUN_MAIN_DEBT_CAMPAIGN", false)) vm.skip(true);
        assertTrue(vm.revertToStateAndDelete(unseededSnapshot));
        _installDiscount();
        for (uint256 path; path < 5; ++path) for (uint256 variant; variant < 19; ++variant) {
            uint256 snapshot = vm.snapshotState();
            Scenario memory s = _default(tvl, path);
            s.dimension = variant + 1;
            if (variant < 3) s.swapCost = uint16(variant * 50);
            else if (variant < 6) s.exitLag = variant == 3 ? 0 : variant == 4 ? 12 hours : 14 days;
            else if (variant < 8) s.harvestEvery = variant == 6 ? 3 : 7;
            else if (variant == 8) s.loopCost = 10;
            else if (variant < 13) { s.loopCost = 10; s.slippageBps = variant == 9 ? 10 : variant == 10 ? 25 : variant == 11 ? 50 : 100; }
            else if (variant < 16) { s.loopCost = 10; s.incentiveMode = uint32(variant - 12); }
            else { s.loopCost = 10; s.halfExitDay = variant == 16 ? 1 : variant == 17 ? 3 : 7; }
            _run(s);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_campaign100k() public { _matrix(100_000); }
    function test_campaign500k() public { _matrix(500_000); }
    function test_campaign1m() public { _matrix(1_000_000); }
    function test_campaign10m() public { _matrix(10_000_000); }
    function test_campaign50m() public { _matrix(50_000_000); }
    function test_campaign100m() public { _matrix(100_000_000); }
    function test_campaignSensitivity100k() public { _sensitivities(100_000); }
    function test_campaignSensitivity1m() public { _sensitivities(1_000_000); }
}
