// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";
import {JuicerDiscount} from "../src/JuicerDiscount.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {Harvester} from "../src/Harvester.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {MockDiscountDebtToken, MockDiscountAToken} from "./mocks/MockDiscount.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {Deficit} from "./helpers/Deficit.sol";

/// @notice parameter campaign on real contracts with mocked accrual and execution costs;
/// static crypto prices, no income donations or recovery funding
contract OperationsTuningTest is HarvestTest {
    ExecutionController internal control;
    bytes32 internal constant ENTRY = keccak256("operations-entry");
    bytes32 internal constant CARRY = keccak256("operations-carry");
    bytes32 internal constant SERVICE = keccak256("operations-service");
    bytes32 internal quotedHash;
    struct Config {
        uint256 tvl;
        uint256 yieldRay;
        uint256 borrowRay;
        uint256 sourceBps;
        uint256 thresholdBps;
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
        uint256 stepHours;
        uint256 assetPrice;
        uint256 primePrice;
        uint256 entryBurst;
        uint256 entryDaily;
        uint256 harvestMaximum;
        uint256 harvestDaily;
        uint256 gasBps;
        uint256 maxDelayHours;
        uint256 harvestGasUsd;
        uint256 serviceGasUsd;
        uint256 urgentInterest;
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
        uint256 deposits;
        uint256 settlements;
        uint256 safetySchedules;
        uint256 servicingHarvests;
        uint256 economicSkips;
        uint256 quoteSkips;
        uint256 admitted;
        uint256 admissionCompleteHour;
        uint256 harvestGross;
        uint256 maxGapHours;
        uint256 lastHarvestHour;
        uint256 entryVolume;
    }

    function test_operationsTuning() public {
        if (!vm.envOr("RUN_OPERATIONS_TUNING", false)) { vm.skip(true); return; }
        Config memory c = Config({
            tvl: vm.envOr("OPS_TVL", uint256(10_000)),
            yieldRay: vm.envOr("OPS_YIELD_RAY", uint256(55e24)),
            borrowRay: vm.envOr("OPS_BORROW_RAY", uint256(44016888917752794e9)),
            sourceBps: vm.envOr("OPS_SOURCE_BPS", uint256(100)),
            thresholdBps: vm.envOr("OPS_THRESHOLD_BPS", uint256(10)),
            minHarvest: vm.envOr("OPS_MIN_HARVEST", uint256(0)),
            borrowEvery: vm.envOr("OPS_BORROW_EVERY", uint256(1)),
            tranche: vm.envOr("OPS_TRANCHE", uint256(1_000)),
            entryBps: vm.envOr("OPS_ENTRY_BPS", uint256(5)),
            exitBps: vm.envOr("OPS_EXIT_BPS", uint256(7)),
            swapBps: vm.envOr("OPS_SWAP_BPS", uint256(60)),
            discountBps: vm.envOr("OPS_DISCOUNT_BPS", uint256(0)),
            feeBps: vm.envOr("OPS_FEE_BPS", uint256(500)),
            stress: vm.envOr("OPS_STRESS", uint256(0)),
            asset: vm.envOr("OPS_ASSET", uint256(0)),
            days_: vm.envOr("OPS_DAYS", uint256(365)),
            stepHours: vm.envOr("OPS_STEP_HOURS", uint256(1)),
            assetPrice: vm.envOr("OPS_ASSET_PRICE", uint256(2700e18)),
            primePrice: vm.envOr("OPS_PRIME_PRICE", uint256(106248121e10)),
            entryBurst: vm.envOr("OPS_ENTRY_BURST", uint256(8000)),
            entryDaily: vm.envOr("OPS_ENTRY_DAILY", uint256(1000)),
            harvestMaximum: vm.envOr("OPS_HARVEST_MAXIMUM", uint256(200)),
            harvestDaily: vm.envOr("OPS_HARVEST_DAILY", uint256(1000)),
            gasBps: vm.envOr("OPS_GAS_BPS", uint256(10)),
            maxDelayHours: vm.envOr("OPS_MAX_DELAY_HOURS", uint256(24)),
            harvestGasUsd: vm.envOr("OPS_HARVEST_GAS_USD", uint256(13e16)),
            serviceGasUsd: vm.envOr("OPS_SERVICE_GAS_USD", uint256(3e16)),
            urgentInterest: vm.envOr("OPS_URGENT_INTEREST", uint256(10))
        });
        require(c.entryBps <= c.sourceBps && c.exitBps <= c.sourceBps, "infeasible source quote");
        require(c.swapBps <= 100 && c.borrowEvery > 0);
        // preserve liquidation thresholds, target hf and crypto swap floor
        uint256 price = c.assetPrice;
        pool.setPrice(address(prime), c.primePrice);
        pool.setPrice(address(eth), price);
        pool.setLtv(address(eth), c.asset == 0 ? 7500 : 8000);
        loop.configureDca(222, 43, 1043, 143, uint32(c.sourceBps * 100));
        loop.setParams(1.05e18, 1.05e18, 1.10e18, c.thresholdBps * 1e14);
        loop.setTranches(c.tranche * 1e18, c.tranche * 1e24 / c.primePrice);
        vault.setTvlCap(type(uint128).max);
        fees.setProtocolFeeBps(address(vault), uint16(c.feeBps));
        swapper.setHaircut(c.swapBps);
        MockDispatch dispatch = MockDispatch(payable(DcaDispatch.DISPATCH));
        dispatch.setFeeBps(uint16(c.entryBps));
        _discount(c.discountBps);
        _controls(c);
        uint256 principal = c.tvl * 1e36 / price;
        eth.mint(address(this), principal);
        eth.approve(address(vault), principal);
        JuicerMainDebt main = JuicerMainDebt(address(vault.mainDebt()));
        Metrics memory m;
        m.minimumHf = type(uint256).max;
        require(c.stepHours > 0 && 24 % c.stepHours == 0);
        _admit(c, m, principal, 0);
        uint256 previous = vault.totalAssets();
        uint256 previousAdmitted = m.admitted;
        for (uint256 hour = c.stepHours; hour <= c.days_ * 24; hour += c.stepHours) {
            _accrue(c, m, hour);
            _clock();
            if (c.stress == 3 && hour == 180 * 24) pool.setPrice(address(prime), c.primePrice * 97 / 100);
            uint256 hf = loop.healthFactor();
            if (hf < m.minimumHf) m.minimumHf = hf;
            bool offline = c.stress == 2 && hour >= 180 * 24 && hour < 194 * 24;
            if (!offline) {
                if (vault.maintainPeg() != 0) ++m.pegUpdates;
                if (hf < loop.targetHf()) {
                    try loop.deLever() { ++m.safetySchedules; } catch (bytes memory reason) {
                        assertEq(bytes4(reason), SubLoop.HealthyEnough.selector);
                    }
                }
                dispatch.setFeeBps(uint16(c.exitBps));
                for (uint256 i; i < 8 && loop.deleverDebtTarget() != 0; ++i) {
                    if (loop.pokeRepay() == 0) break;
                    ++m.repays;
                }
                if (harvester.harvestable()) _harvest(c, m, hour, main);
                if (vault.pokeSettle() != 0) ++m.settlements;
                dispatch.setFeeBps(uint16(c.entryBps));
                _admit(c, m, principal, hour);
                if (hour % c.borrowEvery == 0) {
                    uint256 beforeDebt = hollarDebt.balanceOf(address(vault));
                    uint256 resized = _attempt(address(vault), abi.encodeCall(CollateralVault.rebalance, ()), m);
                    uint256 afterDebt = hollarDebt.balanceOf(address(vault));
                    if (resized != 0) ++m.rebalances;
                    if (afterDebt > beforeDebt) {
                        uint256 added = afterDebt - beforeDebt;
                        m.entryVolume += added;
                        m.maxRebalance = Math.max(m.maxRebalance, added);
                    }
                    for (uint256 i; i < 8 && Deficit.ready(main) && loop.negativeCarryBps() == 0
                        && loop.healthFactor() > loop.targetHf() * 1_005_000 / 1_000_000
                        && loop.unwindTargetEquity() == 0 && loop.deleverDebtTarget() == 0; ++i) {
                        uint256 added = _attempt(address(loop), abi.encodeCall(SubLoop.pokeBorrow, ()), m);
                        if (added == 0) break;
                        ++m.borrows;
                        m.entryVolume += added;
                        m.maxBorrow = Math.max(m.maxBorrow, added);
                    }
                }
                if (!Deficit.ready(main)) ++m.blockedDays; // reported below as blocked observations
            }
            assertGe(vault.totalAssets() - m.admitted, previous - previousAdmitted,
                "ordinary operation spent funded user crypto");
            previous = vault.totalAssets();
            previousAdmitted = m.admitted;
            assertLe(vault.yieldAccounting().reservedShares(), vault.loopShares());
            assertEq(vault.loopShares(), loop.sharesOf(address(vault)));
        }
        uint256 initial = m.admitted;
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
        int256 friction = int256(m.sourceIncome + debt) - int256(m.mainInterest + m.loopInterest
            + funded + backing + protocolFees);
        _metric("executionAndMarkLossUsd", friction > 0 ? uint256(friction) : 0);
        _metric("fundedCryptoUsd", (vault.totalAssets() - initial) * price / 1e18);
        uint256 combined = vault.yieldAccounting().sourceValue();
        uint256 reserved = vault.yieldAccounting().reservedShares();
        uint256 userCarry = reserved == 0 ? 0 : combined * vault.yieldAccounting().sourceShares() / reserved;
        _metric("unconvertedUserUsd", userCarry);
        _metric("unconvertedProtocolUsd", combined - userCarry);
        _metric("mainDebtUsd", debt);
        _metric("loopDebtUsd", hollarDebt.balanceOf(address(loop)));
        _metric("sourceEquityUsd", equity);
        _metric("cashUsd", main.activeFunds());
        _metric("backingDeficitUsd", debt > backing ? debt - backing : 0);
        _metric("sourceReserveUsd", loop.executionCostReserve());
        _metric("protocolFeeUsd", eth.balanceOf(address(fees)) * price / 1e18);
        _metric("firstHarvestHour", m.firstHarvest);
        _metric("firstCryptoHour", m.firstCrypto);
        _metric("harvests", m.harvests);
        _metric("borrows", m.borrows);
        _metric("rebalances", m.rebalances);
        _metric("repays", m.repays);
        _metric("pegUpdates", m.pegUpdates);
        _metric("blockedObservations", m.blockedDays);
        _metric("mainInterestUsd", m.mainInterest);
        _metric("loopInterestUsd", m.loopInterest);
        _metric("waivedInterestUsd", m.waivedInterest);
        _metric("sourceIncomeUsd", m.sourceIncome);
        _metric("minimumHf", m.minimumHf);
        _metric("maxHarvestUsd", m.maxHarvest);
        _metric("maxBorrowUsd", m.maxBorrow);
        _metric("maxRebalanceUsd", m.maxRebalance);
        _metric("deposits", m.deposits);
        _metric("settlements", m.settlements);
        _metric("safetySchedules", m.safetySchedules);
        _metric("servicingHarvests", m.servicingHarvests);
        _metric("economicSkips", m.economicSkips);
        _metric("quoteSkips", m.quoteSkips);
        _metric("admittedUsd", m.admitted * price / 1e18);
        _metric("unadmittedUsd", (principal - m.admitted) * price / 1e18);
        _metric("admissionCompleteHour", m.admissionCompleteHour);
        _metric("harvestGrossUsd", m.harvestGross);
        _metric("maxHarvestGapHours", m.maxGapHours);
        _metric("entryVolumeUsd", m.entryVolume);
        _metric("days", c.days_);
        assertEq(MockDiscountDebtToken(address(hollarDebt)).getDiscountPercent(address(loop)), 0);
    }

    function _controls(Config memory c) private {
        control = new ExecutionController(address(this), 60, 5);
        uint64 expiry = uint64(block.timestamp + (c.days_ + 1) * 1 days);
        control.configureBudget(ENTRY, address(hollar), uint128(c.entryBurst * 1e18),
            uint128(c.entryDaily * 1e18 / 1 days), expiry);
        control.configureLimit(address(loop), address(hollar), address(aPrime), ENTRY, 10e18, uint128(c.tranche * 1e18));
        uint256 maximum = c.harvestMaximum * 1e24 / c.primePrice;
        control.configureBudget(CARRY, address(prime), uint128(maximum),
            uint128(c.harvestDaily * 1e24 / c.primePrice / 1 days), expiry);
        control.configureLimit(address(vault), address(prime), address(eth), CARRY,
            uint128(1e24 / c.primePrice), uint128(maximum));
        uint256 service = c.harvestMaximum * 1e36 / c.assetPrice;
        control.configureBudget(SERVICE, address(eth), uint128(service),
            uint128(c.harvestDaily * 1e36 / c.assetPrice / 1 days), expiry);
        control.configureLimit(address(vault.mainDebt()), address(eth), address(hollar), SERVICE, 1, uint128(service));
        control.configureAction(address(vault), CollateralVault.deposit.selector, true);
        control.configureAction(address(vault), CollateralVault.rebalance.selector, true);
        control.configureAction(address(loop), SubLoop.pokeBorrow.selector, true);
        control.configureAction(address(harvester), Harvester.harvest.selector, true);
        loop.setExecutionController(address(control));
        vault.setExecutionController(address(control));
        harvester.setExecutionController(address(control));
        _clock();
    }

    function _clock() private {
        vm.roll(block.number + 1);
        quotedHash = keccak256(abi.encode(block.number, block.timestamp));
        vm.setBlockhash(block.number - 1, quotedHash);
    }

    function _quotes(ExecutionController.Trade[] memory fills) private view returns (ExecutionController.Quote[] memory q) {
        q = new ExecutionController.Quote[](fills.length);
        bytes32 service = control.lane(address(vault.mainDebt()), address(eth), address(hollar));
        for (uint256 i; i < fills.length; ++i) {
            uint256 factor = fills[i].lane == service ? 2 : 1;
            q[i] = ExecutionController.Quote(fills[i].lane, fills[i].amountIn * factor,
                (fills[i].amountOut * 9998 / 10000) * factor);
        }
    }

    function quoted(address target, bytes calldata data) external returns (uint256) {
        require(msg.sender == address(this));
        (bytes memory result, ExecutionController.Trade[] memory fills) = control.preview(target, data);
        uint256 work = abi.decode(result, (uint256));
        if (work != 0) control.execute(target, data, block.number - 1, quotedHash, block.timestamp + 60, _quotes(fills));
        return work;
    }

    function _attempt(address target, bytes memory data, Metrics memory m) private returns (uint256 work) {
        try this.quoted(target, data) returns (uint256 done) { return done; }
        catch (bytes memory reason) {
            bytes4 error = bytes4(reason);
            assertTrue(error == SubLoop.Underfunded.selector
                || error == JuicerMainDebt.OutstandingDebt.selector || error == ExecutionController.TradeSize.selector,
                "unexpected admission/rebalance failure");
            ++m.quoteSkips;
        }
    }

    function _admit(Config memory c, Metrics memory m, uint256 principal, uint256 hour) private {
        for (uint256 i; i < 8 && m.admitted < principal; ++i) {
            uint256 capacity = loop.admissionCapacity();
            uint256 amount = Math.min(principal - m.admitted,
                capacity * 1e18 * 10000 / c.assetPrice / (c.asset == 0 ? 7500 : 8000));
            if (amount * c.assetPrice / 1e18 < 20e18) break;
            uint256 debtBefore = hollarDebt.balanceOf(address(vault));
            uint256 accepted = _attempt(address(vault), abi.encodeCall(CollateralVault.deposit, (amount, address(this))), m);
            if (accepted == 0) break;
            m.admitted += amount;
            ++m.deposits;
            m.entryVolume += hollarDebt.balanceOf(address(vault)) - Math.min(debtBefore, hollarDebt.balanceOf(address(vault)));
            if (principal - m.admitted <= principal / 1_000_000) m.admissionCompleteHour = hour;
        }
    }

    function _harvest(Config memory c, Metrics memory m, uint256 hour, JuicerMainDebt main) private {
        bytes memory data = abi.encodeCall(Harvester.harvest, (new uint256[](0)));
        (bytes memory result, ExecutionController.Trade[] memory fills) = control.preview(address(harvester), data);
        uint256 primeAmount = abi.decode(result, (uint256));
        if (primeAmount == 0) return;
        uint256 value = primeAmount * (c.stress == 3 && hour >= 180 * 24 ? c.primePrice * 97 / 100 : c.primePrice) / 1e6;
        bool servicing = fills.length > 1;
        uint256 gasCost = c.harvestGasUsd + (servicing ? c.serviceGasUsd : 0);
        bool urgent = main.interestOf(0) >= c.urgentInterest * 1e18;
        bool overdue = block.timestamp - harvester.lastHarvestAt() >= c.maxDelayHours * 1 hours;
        if (!urgent && !overdue && (value < c.minHarvest * 1e18 || gasCost * 10000 > value * c.gasBps)) {
            ++m.economicSkips;
            return;
        }
        control.execute(address(harvester), data, block.number - 1, quotedHash, block.timestamp + 60, _quotes(fills));
        if (servicing) ++m.servicingHarvests;
        m.harvestGross += value;
        m.maxHarvest = Math.max(m.maxHarvest, value);
        if (m.firstHarvest == 0) m.firstHarvest = hour;
        if (m.firstCrypto == 0 && vault.totalAssets() > m.admitted) m.firstCrypto = hour;
        if (m.lastHarvestHour != 0) m.maxGapHours = Math.max(m.maxGapHours, hour - m.lastHarvestHour);
        m.lastHarvestHour = hour;
        ++m.harvests;
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

    function _accrue(Config memory c, Metrics memory m, uint256 hour) private {
        uint256 rate = c.stress == 1 && hour >= 180 * 24 ? 8e25 : c.borrowRay;
        uint256 incomeRate = c.stress == 1 && hour >= 180 * 24 ? 4e25 : c.yieldRay;
        pool.setVariableBorrowRate(uint128(rate));
        uint256 income = aPrime.balanceOf(address(loop)) * incomeRate / 1e27 * c.stepHours / (365 * 24);
        aPrime.mint(address(loop), income);
        prime.mint(address(pool), income);
        m.sourceIncome += income * (c.stress == 3 && hour >= 180 * 24 ? c.primePrice * 97 / 100 : c.primePrice) / 1e6;
        uint256 cost = hollarDebt.balanceOf(address(loop)) * rate / 1e27 * c.stepHours / (365 * 24);
        hollarDebt.mint(address(loop), cost);
        m.loopInterest += cost;
        uint256 grossCost = hollarDebt.balanceOf(address(vault)) * rate / 1e27 * c.stepHours / (365 * 24);
        uint256 discount = MockDiscountDebtToken(address(hollarDebt)).getDiscountPercent(address(vault));
        cost = grossCost * (10_000 - discount) / 10_000;
        hollarDebt.mint(address(vault), cost);
        m.mainInterest += cost;
        m.waivedInterest += grossCost - cost;
        vm.warp(vm.getBlockTimestamp() + c.stepHours * 1 hours);
    }
}
