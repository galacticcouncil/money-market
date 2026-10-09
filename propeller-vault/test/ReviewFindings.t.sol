// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";
import {PropellerYieldAccounting} from "../src/PropellerYieldAccounting.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";

/// @notice lane policy, waiting exits and pending source accounting must not
/// freeze unrelated maintenance
contract ReviewFindingsTest is HarvestTest {
    ExecutionController control;
    bytes32 constant ENTRY = keccak256("entry");
    bytes32 constant HARVEST = keccak256("harvest");
    bytes32 constant SERVICE = keccak256("service");
    bytes32 constant UNWIND = keccak256("unwind");
    bytes32 constant QUOTED_HASH = keccak256("quoted block");
    address constant NEWCOMER = address(0xB0B);

    function _enable() private {
        control = new ExecutionController(address(this), 60, 5);
        vm.roll(100);
        vm.setBlockhash(99, QUOTED_HASH);
        control.configureBudget(ENTRY, address(hollar), 5000e18, 1e18, uint64(block.timestamp + 30 days));
        control.configureBudget(HARVEST, address(prime), 150e6, 1e6, uint64(block.timestamp + 30 days));
        control.configureBudget(SERVICE, address(eth), 1e18, 1e15, uint64(block.timestamp + 30 days));
        control.configureBudget(UNWIND, address(aPrime), 5000e6, 1e6, uint64(block.timestamp + 30 days));
        control.configureLimit(address(loop), address(hollar), address(aPrime), ENTRY, 10e18, 2500e18);
        control.configureLimit(address(vault), address(prime), address(eth), HARVEST, 1e6, 100e6);
        control.configureLimit(address(vault.mainDebt()), address(eth), address(hollar), SERVICE, 1, 1e18);
        control.configureLimit(address(loop), address(aPrime), address(hollar), UNWIND, 1, 2500e6);
        control.configurePrice(control.lane(address(loop), address(hollar), address(aPrime)), 10, false);
        control.configurePrice(control.lane(address(vault), address(prime), address(eth)), 10, false);
        control.configurePrice(control.lane(address(vault.mainDebt()), address(eth), address(hollar)), 10, false);
        control.configurePrice(control.lane(address(loop), address(aPrime), address(hollar)), 10, true);
        control.configureAction(address(vault), CollateralVault.rebalance.selector, true);
        control.configureAction(address(loop), SubLoop.pokeBorrow.selector, true);
        control.configureAction(address(loop), SubLoop.pokeRepay.selector, true);
        control.configureAction(address(harvester), Harvester.harvest.selector, true);
        loop.setExecutionController(address(control));
        vault.setExecutionController(address(control));
        harvester.setExecutionController(address(control));
    }

    function _quotes(address target, bytes memory data) private returns (ExecutionController.Quote[] memory quotes) {
        (, ExecutionController.Trade[] memory fills) = control.preview(target, data);
        quotes = new ExecutionController.Quote[](fills.length);
        for (uint256 i; i < fills.length; ++i)
            quotes[i] = ExecutionController.Quote(fills[i].lane, fills[i].amountIn, fills[i].amountOut * 9998 / 10000);
    }

    function _execute(address target, bytes memory data) private returns (bytes memory) {
        vm.roll(block.number + 1);
        vm.setBlockhash(block.number - 1, QUOTED_HASH);
        ExecutionController.Quote[] memory quotes = _quotes(target, data);
        return control.execute(target, data, block.number - 1, QUOTED_HASH, block.timestamp + 60, quotes);
    }

    function _deposit(CollateralVault target, uint256 amount) private {
        eth.mint(address(this), amount);
        eth.approve(address(target), amount);
        target.deposit(amount, address(this));
    }

    function _ledger(CollateralVault target) private view returns (PropellerMainDebt) {
        return PropellerMainDebt(address(target.mainDebt()));
    }

    function _secondVault() private returns (CollateralVault second) {
        second = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, ("Second ETH", "pETH2", address(eth), address(pool),
                address(loop), address(swapper), address(hollar), address(synth), address(aEth),
                address(hollarDebt), 1000e18, address(this))))));
        synth.grantRole(synth.MINTER_ROLE(), address(second));
        RoundingReserveFixture.fund(second);
        loop.registerVault(address(second));
        second.setCompoundSlippageBps(100);
        second.setFeeController(address(fees));
        harvester.addVault(address(second));
        fees.registerVault(address(second), address(harvester));
    }

    /// two ramped vaults with carry and accrued main interest; the second
    /// vault's servicing policy lapses before the harvest
    function _twoVaultsWithLapsedService() private returns (CollateralVault second) {
        second = _secondVault();
        _deposit(vault, 1e18);
        _deposit(second, 1e18);
        vault.rebalance();
        second.rebalance();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 10);
        hollarDebt.mint(address(vault), 1e18);
        hollarDebt.mint(address(second), 1e18);
        _enable();
        second.setExecutionController(address(control));
        control.configureLimit(address(second), address(prime), address(eth), HARVEST, 1e6, 100e6);
        control.configurePrice(control.lane(address(second), address(prime), address(eth)), 10, false);
        bytes32 lapsing = keccak256("service2");
        control.configureBudget(lapsing, address(eth), 1e18, 1e15, uint64(block.timestamp + 1 hours));
        control.configureLimit(address(second.mainDebt()), address(eth), address(hollar), lapsing, 1, 1e18);
        control.configurePrice(control.lane(address(second.mainDebt()), address(eth), address(hollar)), 10, false);
        vm.warp(block.timestamp + 2 hours);
    }

    // interest below the service lane minimum must not revert the harvest
    function test_reviewSubMinimumServiceSellsTheLaneMinimum() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 10);
        hollarDebt.mint(address(vault), 1e18);
        _enable();
        // about three dollars of ETH: one HOLLAR of interest needs a third of it
        control.configureLimit(address(vault.mainDebt()), address(eth), address(hollar), SERVICE, 1e15, 1e18);
        uint256 harvested = abi.decode(
            _execute(address(harvester), abi.encodeCall(Harvester.harvest, (new uint256[](1)))), (uint256));
        assertGt(harvested, 0);
        assertEq(_ledger(vault).interestOf(0), 0, "interest serviced");
        (,, uint256 cash) = _ledger(vault).activePosition();
        assertGt(cash, 1e18, "the minimum sale's surplus stays as active cash");
    }

    // one vault's closed service lane must not roll back every vault's harvest
    function test_reviewLapsedServiceLaneSkipsOnlyThatVault() public {
        CollateralVault second = _twoVaultsWithLapsedService();
        uint256 sourceShares = loop.sharesOf(address(second));
        _execute(address(harvester), abi.encodeCall(Harvester.harvest, (new uint256[](2))));
        assertEq(_ledger(vault).interestOf(0), 0, "the healthy vault is harvested and serviced");
        assertEq(_ledger(second).interestOf(0), 1e18, "the blocked vault waits");
        assertEq(loop.sharesOf(address(second)), sourceShares, "its owned yield stays invested");
    }

    // a parked donation cannot route around the skipped vault's lane either
    function test_reviewDonationCannotForceABlockedServiceSale() public {
        CollateralVault second = _twoVaultsWithLapsedService();
        prime.mint(address(harvester), 20e6);
        _execute(address(harvester), abi.encodeCall(Harvester.harvest, (new uint256[](2))));
        assertEq(_ledger(second).interestOf(0), 1e18);
        assertEq(_ledger(vault).interestOf(0), 0);
    }

    // a waiting dust request cannot stop pending collateral from deploying
    function test_reviewWaitingRedeemDoesNotBlockDeployment() public {
        loop.setTranches(1000e18, 10_000_000e6);
        _deposit(vault, 1e18);
        vault.rebalance();
        uint256 debt = hollarDebt.balanceOf(address(vault));
        assertEq(debt, 1000e18);
        vault.requestRedeem(1e9, address(this));
        vault.rebalance();
        assertGt(hollarDebt.balanceOf(address(vault)), debt, "deployment continues");
    }

    // a settled request that is never claimed cannot block deployment forever
    function test_reviewUnclaimedSettledRedeemDoesNotBlockDeployment() public {
        loop.setTranches(1000e18, 10_000_000e6);
        _deposit(vault, 1e18);
        vault.rebalance();
        vault.requestRedeem(vault.balanceOf(address(this)) / 10, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        for (uint256 i; i < 20 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        assertEq(vault.queueHead(), vault.queueUnwind(), "settled");
        assertGt(vault.totalQueuedShares(), 0, "but never claimed");
        aPrime.mint(address(loop), 10e6);
        uint256 debt = hollarDebt.balanceOf(address(vault));
        vault.rebalance();
        assertGt(hollarDebt.balanceOf(address(vault)), debt, "deployment continues");
    }

    // an expired policy stops new risk, not user exits
    function test_reviewExpiredBudgetDoesNotFreezeExits() public {
        uint256 shares = _depositAndRamp();
        _enable();
        vault.requestRedeem(shares / 2, address(this));
        vm.warp(block.timestamp + 31 days);
        vault.startUnwinds(1);
        uint256 target = loop.unwindTargetEquity();
        assertGt(target, 0);
        _execute(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        assertLt(loop.unwindTargetEquity(), target, "the exit keeps selling after expiry");
    }

    // a delever on an unflagged lane falls back to the normal budget
    function test_reviewUnflaggedUnwindLaneStillServesDelever() public {
        _depositAndRamp();
        _enable();
        control.configurePrice(control.lane(address(loop), address(aPrime), address(hollar)), 10, false);
        pool.setPrice(address(prime), 0.99e18);
        loop.deLever();
        assertGt(loop.deleverDebtTarget(), 0);
        uint256 debt = hollarDebt.balanceOf(address(loop));
        _execute(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        assertLt(hollarDebt.balanceOf(address(loop)), debt);
    }

    // an exit whose remaining need is below the lane minimum still completes
    function test_reviewUnwindTailBelowLaneMinimumStillSells() public {
        uint256 shares = _depositAndRamp();
        _enable();
        control.configureLimit(address(loop), address(aPrime), address(hollar), UNWIND, 200e6, 2500e6);
        vault.requestRedeem(shares / 100, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        assertGt(loop.unwindTargetEquity(), 0);
        _execute(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        assertEq(loop.unwindTargetEquity(), 0, "a sub-minimum need sells the lane minimum");
    }

    // unallocated source accounting delays allocation, not share transfers
    function test_reviewPendingSourceAccountingKeepsTransfersAndHarvestLive() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.sync();
        PropellerYieldAccounting rewards = vault.yieldAccounting();
        uint256 earned = rewards.earnedAssets(address(this));
        assertGt(earned, 0);
        vm.mockCall(address(loop), abi.encodeWithSelector(loop.unwindExecutionCost.selector, address(vault)),
            abi.encode(uint256(1)));
        assertTrue(vault.mainDebt().pendingSourceAccounting());
        vault.transfer(NEWCOMER, vault.balanceOf(address(this)) / 2);
        assertEq(harvester.harvest(new uint256[](1)), 0, "the pending vault waits; the batch does not revert");
        vm.expectRevert(PropellerYieldAccounting.InvalidHarvest.selector);
        vault.claimYield(address(this));
        vm.clearMockedCalls();
        assertApproxEqAbs(rewards.earnedAssets(address(this)), earned, 1e9, "earlier yield stays with the sender");
        assertEq(rewards.earnedAssets(NEWCOMER), 0);
        assertGt(harvester.harvest(new uint256[](1)), 0, "harvest resumes once accounting settles");
        assertGt(vault.claimYield(address(this)), 0);
    }

    // new borrowing re-checks the synthetic floor
    function test_reviewRebalanceCannotBorrowAgainstBreachedSyntheticFloor() public {
        loop.setTranches(1000e18, 10_000_000e6);
        _deposit(vault, 1e18);
        vault.rebalance();
        aPrime.mint(address(loop), 300e6);
        hollarDebt.mint(address(vault), 100e18);
        assertLt(vault.syntheticSupplied() * vault.synthLtBps() / 1e4, hollarDebt.balanceOf(address(vault)));
        vm.expectRevert(CollateralVault.PrincipalNotFloored.selector);
        vault.rebalance();
        vault.maintainPeg();
        vault.rebalance();
        assertGt(hollarDebt.balanceOf(address(vault)), 1100e18, "borrowing resumes once the floor is restored");
    }

    // a slice below the entry lane minimum waits instead of reverting
    function test_reviewSubMinimumDeploymentWaitsWithoutReverting() public {
        _enable();
        _deposit(vault, 1e18);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(vault.reinvestAssets(), 0);
        _deposit(vault, 1e15);
        vm.roll(block.number + 1);
        uint256 debt = hollarDebt.balanceOf(address(vault));
        (bytes memory result,) = control.preview(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(abi.decode(result, (uint256)), 0, "a sub-minimum slice waits");
        assertEq(hollarDebt.balanceOf(address(vault)), debt);
        assertEq(vault.reinvestAssets(), 1e15);
    }
}
