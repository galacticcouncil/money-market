// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";
import {JuicerDiscount} from "../src/JuicerDiscount.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {MockDiscountDebtToken, MockDiscountAToken} from "./mocks/MockDiscount.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {Deficit} from "./helpers/Deficit.sol";

/// @notice parameter campaign on real contracts with mocked accrual and execution costs;
/// static crypto prices, no income donations or recovery funding
contract MainnetTuningTest is HarvestTest {
    struct Config {
        uint256 tvl;
        uint256 yieldRay;
        uint256 borrowRay;
        uint256 sourceBps;
        uint256 thresholdBps;
        uint256 every;
        uint256 minHarvest;
        uint256 borrowEvery;
        uint256 tranche;
        uint256 entryBps;
        uint256 exitBps;
        uint256 swapBps;
        uint256 discountBps;
        uint256 feeBps;
        uint256 stress;
        uint256 asset;
        uint256 days_;
    }

    struct Metrics {
        uint256 firstHarvest;
        uint256 firstCrypto;
        uint256 harvests;
        uint256 borrows;
        uint256 rebalances;
        uint256 repays;
        uint256 pegUpdates;
        uint256 blockedDays;
        uint256 mainInterest;
        uint256 loopInterest;
        uint256 waivedInterest;
        uint256 sourceIncome;
        uint256 minimumHf;
        uint256 maxHarvest;
        uint256 maxBorrow;
        uint256 maxRebalance;
    }

    function test_mainnetTuning() public {
        if (!vm.envOr("RUN_MAINNET_TUNING", false)) { vm.skip(true); return; }
        Config memory c = Config({
            tvl: vm.envOr("TUNE_TVL", uint256(10_000)),
            yieldRay: vm.envOr("TUNE_YIELD_RAY", uint256(55e24)),
            borrowRay: vm.envOr("TUNE_BORROW_RAY", uint256(44016888917752794e9)),
            sourceBps: vm.envOr("TUNE_SOURCE_BPS", uint256(100)),
            thresholdBps: vm.envOr("TUNE_THRESHOLD_BPS", uint256(10)),
            every: vm.envOr("TUNE_EVERY", uint256(1)),
            minHarvest: vm.envOr("TUNE_MIN_HARVEST", uint256(0)),
            borrowEvery: vm.envOr("TUNE_BORROW_EVERY", uint256(1)),
            tranche: vm.envOr("TUNE_TRANCHE", uint256(1_000)),
            entryBps: vm.envOr("TUNE_ENTRY_BPS", uint256(5)),
            exitBps: vm.envOr("TUNE_EXIT_BPS", uint256(7)),
            swapBps: vm.envOr("TUNE_SWAP_BPS", uint256(60)),
            discountBps: vm.envOr("TUNE_DISCOUNT_BPS", uint256(0)),
            feeBps: vm.envOr("TUNE_FEE_BPS", uint256(500)),
            stress: vm.envOr("TUNE_STRESS", uint256(0)),
            asset: vm.envOr("TUNE_ASSET", uint256(0)),
            days_: vm.envOr("TUNE_DAYS", uint256(365))
        });
        require(c.entryBps <= c.sourceBps && c.exitBps <= c.sourceBps, "infeasible source quote");
        require(c.swapBps <= 100 && c.every > 0 && c.borrowEvery > 0);
        // preserve liquidation thresholds, target hf and crypto swap floor
        uint256 price = c.asset == 0 ? 2691332262800000000000 : 84499828779940000000000;
        pool.setPrice(address(eth), price);
        pool.setLtv(address(eth), c.asset == 0 ? 7500 : 8000);
        loop.configureDca(222, 43, 1043, 143, uint32(c.sourceBps * 100));
        loop.setParams(1.05e18, 1.05e18, 1.10e18, c.thresholdBps * 1e14);
        loop.setTranches(c.tranche * 1e18, c.tranche * 1e6);
        vault.setTvlCap(type(uint128).max);
        fees.setProtocolFeeBps(address(vault), uint16(c.feeBps));
        swapper.setHaircut(c.swapBps);
        MockDispatch dispatch = MockDispatch(payable(DcaDispatch.DISPATCH));
        dispatch.setFeeBps(uint16(c.entryBps));
        _discount(c.discountBps);
        uint256 principal = c.tvl * 1e36 / price;
        eth.mint(address(this), principal);
        eth.approve(address(vault), principal);
        vault.deposit(principal, address(this));
        assertEq(hollarDebt.balanceOf(address(vault)), 0, "deposit creates no debt before execution");
        assertEq(vault.reinvestAssets(), principal, "the modeled keeper must deploy pending collateral");
        JuicerMainDebt main = JuicerMainDebt(address(vault.mainDebt()));
        Metrics memory m;
        m.minimumHf = type(uint256).max;
        uint256 previous = vault.totalAssets();
        uint256 initial = previous;
        for (uint256 day = 1; day <= c.days_; ++day) {
            _accrue(c, m, day);
            // a peg gap reduces source nav, never user collateral tokens
            if (c.stress == 3 && day == 180) pool.setPrice(address(prime), 0.97e18);
            uint256 hf = loop.healthFactor();
            if (hf < m.minimumHf) m.minimumHf = hf;
            // operator outage: missed actions don't run
            bool offline = c.stress == 2 && day >= 180 && day <= 193;
            if (!offline) {
                uint256 oldSynth = vault.syntheticSupplied();
                vault.maintainPeg();
                if (vault.syntheticSupplied() != oldSynth) ++m.pegUpdates;
                if (hf < loop.targetHf()) {
                    // an existing target can exceed today's; the keeper skips that revert and still repays
                    try loop.deLever() {} catch (bytes memory reason) {
                        assertEq(bytes4(reason), SubLoop.HealthyEnough.selector,
                            "unexpected safety scheduling failure");
                    }
                    dispatch.setFeeBps(uint16(c.exitBps));
                    for (uint256 i; i < 8 && loop.deleverDebtTarget() != 0; ++i) {
                        loop.pokeRepay();
                        ++m.repays;
                    }
                }
                uint256 capacity = loop.harvestCapacity();
                uint256 available = loop.totalShares() == 0 ? 0
                    : capacity * loop.totalEquity() * 1e10 / loop.totalShares();
                if (day % c.every == 0 && harvester.harvestable() && available >= c.minHarvest * 1e18) {
                    uint256 grossBefore = aPrime.balanceOf(address(loop));
                    harvester.harvest(new uint256[](0));
                    uint256 harvested = (grossBefore - aPrime.balanceOf(address(loop))) * 1e12;
                    if (harvested > m.maxHarvest) m.maxHarvest = harvested;
                    if (m.firstHarvest == 0) m.firstHarvest = day;
                    if (m.firstCrypto == 0 && vault.totalAssets() > initial) m.firstCrypto = day;
                    ++m.harvests;
                }
                vault.pokeSettle();
                dispatch.setFeeBps(uint16(c.entryBps));
                uint256 mainBefore = hollarDebt.balanceOf(address(vault));
                try vault.rebalance() {} catch (bytes memory reason) {
                    bytes4 selector = bytes4(reason);
                    assertTrue(selector == SubLoop.Underfunded.selector
                        || selector == JuicerMainDebt.OutstandingDebt.selector, "unexpected rebalance failure");
                }
                uint256 mainAfter = hollarDebt.balanceOf(address(vault));
                if (mainAfter > mainBefore) {
                    ++m.rebalances;
                    if (mainAfter - mainBefore > m.maxRebalance) m.maxRebalance = mainAfter - mainBefore;
                }
                if (!Deficit.ready(main)) ++m.blockedDays;
                if (day % c.borrowEvery == 0) {
                    // re-read guards after every transaction, as the keeper does
                    for (uint256 i; i < 8 && Deficit.ready(main) && loop.negativeCarryBps() == 0
                        && loop.healthFactor() > loop.targetHf() * 1_005_000 / 1_000_000
                        && loop.unwindTargetEquity() == 0 && loop.deleverDebtTarget() == 0; ++i) {
                        uint256 beforeDebt = hollarDebt.balanceOf(address(loop));
                        loop.pokeBorrow();
                        uint256 afterDebt = hollarDebt.balanceOf(address(loop));
                        if (afterDebt <= beforeDebt) break;
                        ++m.borrows;
                        if (afterDebt - beforeDebt > m.maxBorrow) m.maxBorrow = afterDebt - beforeDebt;
                    }
                }
            }
            assertGe(vault.totalAssets(), previous, "ordinary operation spent funded user crypto");
            previous = vault.totalAssets();
            assertLe(vault.yieldAccounting().reservedShares(), vault.loopShares());
            assertEq(vault.loopShares(), loop.sharesOf(address(vault)));
        }
        vault.sync();
        uint256 debt = hollarDebt.balanceOf(address(vault));
        uint256 equity = loop.equityOf(address(vault)) * 1e10;
        uint256 backing = equity + main.activeFunds();
        uint256 funded = (vault.totalAssets() - initial) * price / 1e18;
        uint256 protocolFees = eth.balanceOf(address(fees)) * price / 1e18;
        // all wealth must come from modeled income net of debt costs; swaps only decrease it
        assertLe(int256(funded + backing + protocolFees) - int256(debt),
            int256(m.sourceIncome) - int256(m.mainInterest + m.loopInterest) + 1e12,
            "economic wealth exceeds earned net income");
        _metric("fundedCryptoUsd", (vault.totalAssets() - initial) * price / 1e18);
        _metric("unconvertedUsd", vault.yieldAccounting().sourceValue());
        _metric("mainDebtUsd", debt);
        _metric("loopDebtUsd", hollarDebt.balanceOf(address(loop)));
        _metric("sourceEquityUsd", equity);
        _metric("cashUsd", main.activeFunds());
        _metric("backingDeficitUsd", debt > backing ? debt - backing : 0);
        _metric("sourceReserveUsd", loop.executionCostReserve());
        _metric("protocolFeeUsd", eth.balanceOf(address(fees)) * price / 1e18);
        _metric("firstHarvestDay", m.firstHarvest);
        _metric("firstCryptoDay", m.firstCrypto);
        _metric("harvests", m.harvests);
        _metric("borrows", m.borrows);
        _metric("rebalances", m.rebalances);
        _metric("repays", m.repays);
        _metric("pegUpdates", m.pegUpdates);
        _metric("blockedDays", m.blockedDays);
        _metric("mainInterestUsd", m.mainInterest);
        _metric("loopInterestUsd", m.loopInterest);
        _metric("waivedInterestUsd", m.waivedInterest);
        _metric("sourceIncomeUsd", m.sourceIncome);
        _metric("minimumHf", m.minimumHf);
        _metric("maxHarvestUsd", m.maxHarvest);
        _metric("maxBorrowUsd", m.maxBorrow);
        _metric("maxRebalanceUsd", m.maxRebalance);
        _metric("days", c.days_);
        assertEq(MockDiscountDebtToken(address(hollarDebt)).getDiscountPercent(address(loop)), 0);
    }

    function _metric(string memory name, uint256 value) private { emit log_named_uint(name, value); }

    function _discount(uint256 bps) private {
        vm.etch(address(hollarDebt), address(new MockDiscountDebtToken(address(pool))).code);
        vm.etch(address(aSynth), address(new MockDiscountAToken(address(pool), address(synth))).code);
        JuicerDiscount policy = new JuicerDiscount(address(hollarDebt), address(synth), address(aSynth), address(this), address(this));
        MockDiscountDebtToken(address(hollarDebt)).setPolicy(address(policy));
        vault.setDiscountController(address(policy));
        policy.registerVault(address(vault));
        policy.setDiscountBps(uint16(bps));
    }

    function _accrue(Config memory c, Metrics memory m, uint256 day) private {
        uint256 rate = c.stress == 1 && day >= 180 ? 8e25 : c.borrowRay;
        uint256 incomeRate = c.stress == 1 && day >= 180 ? 4e25 : c.yieldRay;
        pool.setVariableBorrowRate(uint128(rate));
        uint256 income = aPrime.balanceOf(address(loop)) * incomeRate / 1e27 / 365;
        aPrime.mint(address(loop), income);
        prime.mint(address(pool), income);
        m.sourceIncome += income * 1e12;
        uint256 cost = hollarDebt.balanceOf(address(loop)) * rate / 1e27 / 365;
        hollarDebt.mint(address(loop), cost);
        m.loopInterest += cost;
        uint256 grossCost = hollarDebt.balanceOf(address(vault)) * rate / 1e27 / 365;
        uint256 discount = MockDiscountDebtToken(address(hollarDebt)).getDiscountPercent(address(vault));
        cost = grossCost * (10_000 - discount) / 10_000;
        hollarDebt.mint(address(vault), cost);
        m.mainInterest += cost;
        m.waivedInterest += grossCost - cost;
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }
}
