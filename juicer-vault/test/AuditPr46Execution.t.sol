// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {MultiVaultFlowTest} from "./MultiVaultFlow.t.sol";
import {KeeperOpsTest} from "./KeeperOps.t.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {Harvester} from "../src/Harvester.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockIntentDispatch} from "./mocks/MockIntentDispatch.sol";
import {Artifacts} from "./helpers/Artifacts.t.sol";

contract AuditPr46PacingTest is HarvestTest {
    ExecutionController control;
    bytes32 constant ENTRY = keccak256("entry");
    bytes32 constant HARVEST = keccak256("harvest");
    bytes32 constant SERVICE = keccak256("service");
    bytes32 constant UNWIND = keccak256("unwind");
    bytes32 constant QUOTED_HASH = keccak256("quoted block");
    address constant OUTSIDER = address(0xA77AC4);
    uint64 constant INTERVAL = 60;
    uint128 constant UNWIND_MIN = 10_000;
    uint128 constant UNWIND_MAX = 50e6;

    function _enable() internal {
        control = ExecutionController(Artifacts.executionController(address(this), 60, 5));
        vm.roll(100);
        vm.setBlockhash(99, QUOTED_HASH);
        control.configureBudget(ENTRY, address(hollar), 1000e18, 1e18);
        control.configureBudget(HARVEST, address(prime), 1000e6, 1e6);
        control.configureBudget(SERVICE, address(eth), 1e18, 1e15);
        control.configureBudget(UNWIND, address(aPrime), 1000e6, 1e6);
        control.configureLimit(address(loop), address(hollar), address(aPrime), ENTRY, 1e18, 50e18);
        control.configureLimit(address(vault), address(prime), address(eth), HARVEST, 10_000, 50e6);
        control.configureLimit(address(vault.mainDebt()), address(eth), address(hollar), SERVICE, 1, 1e18);
        control.configureLimit(address(loop), address(aPrime), address(hollar), UNWIND, UNWIND_MIN, UNWIND_MAX);
        control.configurePrice(control.lane(address(loop), address(hollar), address(aPrime)), 10, false);
        control.configurePrice(control.lane(address(vault), address(prime), address(eth)), 10, false);
        control.configurePrice(control.lane(address(vault.mainDebt()), address(eth), address(hollar)), 10, false);
        control.configurePrice(control.lane(address(loop), address(aPrime), address(hollar)), 10, true);
        control.configurePacing(ENTRY, INTERVAL);
        control.configurePacing(HARVEST, INTERVAL);
        control.configurePacing(SERVICE, INTERVAL);
        control.configurePacing(UNWIND, INTERVAL);
        control.configureAction(address(loop), SubLoop.pokeRepay.selector, true);
        loop.setExecutionController(address(control));
        vault.setExecutionController(address(control));
        harvester.setExecutionController(address(control));
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.setBlockhash(vm.getBlockNumber() - 1, QUOTED_HASH);
    }

    function _keeper(address target, bytes memory data) internal {
        _nextBlock();
        (, ExecutionController.Trade[] memory fills) = control.preview(target, data);
        ExecutionController.Quote[] memory q = new ExecutionController.Quote[](fills.length);
        for (uint256 i; i < fills.length; ++i) {
            q[i] = ExecutionController.Quote(fills[i].lane, fills[i].amountIn, fills[i].amountOut * 9998 / 10000);
        }
        control.execute(target, data, vm.getBlockNumber() - 1, QUOTED_HASH, vm.getBlockTimestamp() + 60, q);
    }

    function _outsider(address target, bytes memory data, bytes32 key, uint256 cap) internal {
        _nextBlock();
        ExecutionController.Quote[] memory q = new ExecutionController.Quote[](1);
        q[0] = ExecutionController.Quote(key, cap, 1);
        vm.prank(OUTSIDER);
        control.execute(target, data, vm.getBlockNumber() - 1, QUOTED_HASH, vm.getBlockTimestamp() + 60, q);
    }

    function _startHalfExit() internal {
        uint256 shares = _depositAndRamp();
        _enable();
        vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        assertGt(loop.unwindTargetEquity(), 0);
    }

    function test_pr46_minimumTradeClosesOnlyItsShareOfTheInterval() public {
        _startHalfExit();
        bytes32 unwindLane = control.lane(address(loop), address(aPrime), address(hollar));
        bytes memory poke = abi.encodeCall(SubLoop.pokeRepay, ());
        _outsider(address(loop), poke, unwindLane, UNWIND_MIN);
        (, uint64 nextAt,) = control.pacing(UNWIND);
        assertEq(nextAt, vm.getBlockTimestamp() + 1);

        uint256 before_ = aPrime.balanceOf(address(loop));
        _keeper(address(loop), poke);
        assertEq(before_ - aPrime.balanceOf(address(loop)), UNWIND_MAX, "the next block's full slice still runs");
        (, nextAt,) = control.pacing(UNWIND);
        assertEq(nextAt, vm.getBlockTimestamp() + INTERVAL, "a full slice closes the whole interval");
    }

    function test_pr46_outsiderMinimumsBarelySlowTheExit() public {
        _startHalfExit();
        bytes32 unwindLane = control.lane(address(loop), address(aPrime), address(hollar));
        bytes memory poke = abi.encodeCall(SubLoop.pokeRepay, ());
        uint256 start = aPrime.balanceOf(address(loop));
        for (uint256 i; i < 10; ++i) {
            _outsider(address(loop), poke, unwindLane, UNWIND_MIN);
            _keeper(address(loop), poke);
            vm.warp(vm.getBlockTimestamp() + INTERVAL);
        }
        assertEq(start - aPrime.balanceOf(address(loop)), 10 * (UNWIND_MAX + UNWIND_MIN));
    }
}

contract AuditPr46HarvestReconcileTest is MultiVaultFlowTest {
    MockIntentDispatch dispatch;

    function _bootstrapVaults() internal override {
        vm.etch(DcaDispatch.DISPATCH, address(new MockIntentDispatch()).code);
        dispatch = MockIntentDispatch(payable(DcaDispatch.DISPATCH));
        dispatch.configure(address(pool), address(hollar), address(prime), 222, 1043);
        super._bootstrapVaults();
    }

    function _positions() internal {
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        ethVault.deposit(1e18, ETH_USER);
        vm.stopPrank();
        ethVault.rebalance();
        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        vm.stopPrank();
        tbtcVault.rebalance();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        uint256 earned = aPrime.balanceOf(address(loop)) / 20;
        aPrime.mint(address(loop), earned);
        prime.mint(address(pool), earned);
        loop.configureIntents(600, 5);
        loop.setTranches(10_000_000e18, 50e6);
    }

    function test_pr46_landedFillSettlesBeforeTheHarvestReadsWeights() public {
        _positions();
        uint256 half = tbtcVault.balanceOf(BTC_USER) / 2;
        vm.prank(BTC_USER);
        tbtcVault.requestRedeem(half, BTC_USER);
        vm.warp(vm.getBlockTimestamp() + tbtcVault.withdrawalDelay());
        tbtcVault.startUnwinds(1);
        loop.pokeRepay();
        uint128 id = dispatch.lastId();
        dispatch.fill(id, dispatch.quote(id, 30));
        uint256 ethAssets = ethVault.totalAssets();
        uint256 btcAssets = tbtcVault.totalAssets();

        harvester.harvest(new uint256[](2));
        (,, uint8 kind,,,,,,) = loop.pendingIntent();
        assertEq(kind, 0, "the fill settled first");
        assertGt(ethVault.totalAssets(), ethAssets, "ETH harvests");
        assertEq(tbtcVault.totalAssets(), btcAssets, "the charged vault sits the round out");

        tbtcVault.pokeSettle();
        assertGt(tbtcVault.sync(), 0);
        harvester.harvest(new uint256[](2));
    }
}

contract AuditPr46DeleverRoundingTest is KeeperOpsTest {
    address constant USER = address(0xB0B);

    function test_pr46_roundedRepayStillClearsTheDeleverTarget() public {
        _ramp();
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0);
        pool.setDebtRounding(0, 1);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
        JuicerMainDebt ledger = JuicerMainDebt(address(vault.mainDebt()));
        (,, uint256 cash,,) = ledger.positions(0);
        assertEq(cash, 0, "the de-lever proceeds are spent");
        assertEq(vault.deleverTarget(), 0, "a debt reduction a wei short of the cash leaves no target");

        uint256 id = vault.requestRedeem(vault.balanceOf(address(this)) / 4, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(64);
        assertEq(vault.queueUnwind(), id + 1);
        eth.mint(USER, 1e18);
        vm.startPrank(USER);
        eth.approve(address(vault), 1e18);
        assertGt(vault.deposit(1e18, USER), 0);
        vm.stopPrank();
    }
}
