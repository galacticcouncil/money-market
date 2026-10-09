// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "../Harvest.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";

/// @notice public-call reachability study for the lazy-rescale unit excess. every call below
/// is a public vault/loop/harvester entry point on the standard HarvestTest deployment; no
/// accounting storage is seeded and no vault-only call is impersonated. external token mints
/// to the SubLoop stand in for market moves (gains or losses); each use is labeled.
contract RescaleReachabilityTest is HarvestTest {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function _depositFor(address who, uint256 amount) internal returns (uint256 shares) {
        eth.mint(who, amount);
        vm.prank(who);
        eth.approve(address(vault), amount);
        if (vault.totalSupply() == 0) {
            // first deposit must come from an admin; bootstrap, then hand the shares over.
            eth.mint(address(this), 1e12);
            eth.approve(address(vault), 1e12);
            vault.deposit(1e12, who);
        }
        vm.prank(who);
        shares = vault.deposit(amount, who);
    }

    /// @dev external condition: the loop's prime position loses value (mock burn of aPRIME).
    function _applyLoss(uint256 fractionBps) internal {
        uint256 bal = aPrime.balanceOf(address(loop));
        uint256 loss = bal * fractionBps / 10_000;
        vm.prank(address(loop));
        aPrime.transfer(address(0xdead), loss);
        vault.sync();
    }

    /// @dev external condition: the loop's prime position gains value (mock mint of aPRIME).
    function _applyGain(uint256 fractionBps) internal {
        uint256 bal = aPrime.balanceOf(address(loop));
        aPrime.mint(address(loop), bal * fractionBps / 10_000);
        vault.sync();
    }

    function _aggregateUnits(JuicerYieldAccounting y, address[] memory holders)
        internal
        view
        returns (uint256 sum)
    {
        for (uint256 i; i < holders.length; ++i) sum += y.balanceOf(holders[i]);
    }

    /// drive a loss/refill cycle with two holders and measure the aggregate unit view against
    /// totalUnits after every public step.
    function test_publicLossRefillCyclesKeepAggregateWithinBound() public {
        _depositFor(ALICE, 1e18);
        _depositFor(BOB, 1e18);
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();

        JuicerYieldAccounting y = vault.yieldAccounting();
        address[] memory holders = new address[](2);
        holders[0] = ALICE;
        holders[1] = BOB;

        // first gain: allocate reward units publicly.
        _applyGain(500);
        assertGt(y.totalUnits(), 0, "allocation issued units");
        uint256 t0 = y.totalUnits();
        uint256 i0 = y.rewardIndex();
        emit log_named_uint("totalUnits after first allocation", t0);
        emit log_named_uint("rewardIndex after first allocation", i0);
        emit log_named_uint("unitScale", y.unitScale());
        assertLe(_aggregateUnits(y, holders), t0, "genesis trace cannot overclaim");

        // alternate losses and refills; transfers settle holders in between.
        for (uint256 round; round < 24; ++round) {
            _applyLoss(3000); // -30% of prime position
            vm.prank(ALICE);
            vault.transfer(BOB, 1); // small wallet transfer settles both holders
            _applyGain(4500); // +45% refill
            emit log_named_uint("round", round);
            emit log_named_uint("totalUnits", y.totalUnits());
            emit log_named_uint("unitScale", y.unitScale());
            uint256 sum = _aggregateUnits(y, holders);
            uint256 total = y.totalUnits();
            if (sum > total) {
                emit log_named_uint("EXCESS", sum - total);
            }
            assertLe(sum, total + 1, "aggregate excess bounded by one unit");
        }
        emit log_named_uint("final unitScale", y.unitScale());
        emit log_named_uint("final totalUnits", y.totalUnits());
    }

    /// check whether repeated deep-loss/refill cycles can ever trigger a rescale through
    /// public calls. the rescale predicate is totalUnits > 2^160 * den / max(den, outside),
    /// so reaching it needs index growth by ~2^160/unit-denominator: report the actual ratio.
    function test_publicCyclesApproachToRescale() public {
        _depositFor(ALICE, 1e18);
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();
        JuicerYieldAccounting y = vault.yieldAccounting();

        _applyGain(500);
        uint256 maxRatio; // totalUnits / denominator proxy, logged per round
        for (uint256 round; round < 60; ++round) {
            _applyLoss(9000); // -90%
            _applyGain(10000); // +100%
            uint256 total = y.totalUnits();
            if (total != 0) {
                uint256 assets = y.totalAssets();
                uint256 ratio = assets == 0 ? type(uint256).max : total / assets;
                if (ratio > maxRatio) maxRatio = ratio;
            }
            if (y.unitScale() != 0) {
                emit log_named_uint("RESCALE at round", round);
                break;
            }
        }
        emit log_named_uint("max totalUnits/totalAssets seen", maxRatio);
        emit log_named_uint("final unitScale", y.unitScale());
        assertEq(y.unitScale(), 0, "no rescale observed through public cycles");
    }

    /// account splitting: spread weight across many fresh holders between cycles and check
    /// the aggregate against totalUnits each time.
    function test_publicAccountSplittingDoesNotAmplify() public {
        _depositFor(ALICE, 1e18);
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();
        JuicerYieldAccounting y = vault.yieldAccounting();
        _applyGain(500);
        assertGt(y.totalUnits(), 0);

        address[] memory holders = new address[](9);
        holders[0] = ALICE;
        uint256 wallet = vault.walletOf(ALICE);
        for (uint256 i = 1; i < 9; ++i) {
            holders[i] = address(uint160(0x1000 + i));
            vm.prank(ALICE);
            vault.transfer(holders[i], wallet / 10);
        }
        for (uint256 round; round < 12; ++round) {
            _applyLoss(4000);
            _applyGain(6000);
            uint256 sum = _aggregateUnits(y, holders);
            uint256 total = y.totalUnits();
            assertLe(sum, total + 1, "split holders stay within one-unit excess");
        }
        emit log_named_uint("final unitScale", y.unitScale());
        assertEq(y.unitScale(), 0, "no rescale observed");
    }
}
