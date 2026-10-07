// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";

contract ExecutionControlsTest is HarvestTest {
    ExecutionController control;
    bytes32 constant ENTRY = keccak256("entry");
    bytes32 constant HARVEST = keccak256("harvest");
    bytes32 constant SERVICE = keccak256("service");
    bytes32 constant UNWIND = keccak256("unwind");
    bytes32 constant QUOTED_HASH = keccak256("quoted block");

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
        control.configureAction(address(vault), CollateralVault.deposit.selector, true);
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

    function _deposit(uint256 amount) private {
        eth.mint(address(this), amount);
        eth.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    function test_controlsLargeDepositWaitsAndDeploymentIsSliced() public {
        _enable();
        eth.mint(address(this), 2e18);
        eth.approve(address(vault), 2e18);
        vault.deposit(2e18, address(this));
        assertEq(vault.totalAssets(), 2e18);
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        assertEq(loop.admissionCapacity(), 2500e18, "deposit spends no trade budget");
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)), 2500e18);
        assertGt(vault.reinvestAssets(), 0, "remainder waits debt-free");
        assertEq(hollar.balanceOf(address(vault)), 0);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)), 4500e18);
        assertEq(vault.reinvestAssets(), 0);
    }

    function test_controlsPreviewCannotMoveFundsEvenWhenMined() public {
        _enable();
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        control.preview(address(vault), abi.encodeCall(CollateralVault.deposit, (1e18, address(this))));
        assertEq(vault.totalSupply(), 0);
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        assertEq(eth.balanceOf(address(this)), 1e18);
        assertEq(control.caller(), address(0));
        _deposit(1e18);
        assertGt(vault.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(address(control)), 0);
    }

    function test_controlsDirectDepositCannotBypassDeploymentQuotes() public {
        _enable();
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        vm.expectRevert(ExecutionController.QuoteRequired.selector);
        vault.rebalance();
        control.execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()),
            99, QUOTED_HASH, block.timestamp + 60, new ExecutionController.Quote[](0));
        assertEq(hollarDebt.balanceOf(address(vault)), 0, "no quotes means no deploy capacity");
        assertGt(vault.totalSupply(), 0, "collateral shares remain funded");
    }

    function test_controlsMinimumEntryAndGlobalBudgetAcrossDepositsAndRamp() public {
        _enable();
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        _deposit(2e18);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        vm.roll(block.number + 1);
        assertEq(loop.admissionCapacity(), 500e18);
        uint256 borrowed = abi.decode(_execute(address(loop), abi.encodeCall(SubLoop.pokeBorrow, ())), (uint256));
        assertEq(borrowed, 500e18);
        assertEq(loop.admissionCapacity(), 0);
        assertEq(abi.decode(_execute(address(loop), abi.encodeCall(SubLoop.pokeBorrow, ())), (uint256)), 0);
        vm.warp(block.timestamp + 9);
        assertEq(loop.admissionCapacity(), 0, "dust credit remains unusable");
        vm.warp(block.timestamp + 1);
        assertEq(loop.admissionCapacity(), 10e18);
    }

    function test_controlsExpiredForkedAndFutureQuotesRevert() public {
        _enable();
        bytes memory data = abi.encodeCall(SubLoop.pokeBorrow, ());
        ExecutionController.Quote[] memory q = new ExecutionController.Quote[](0);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        control.execute(address(loop), data, 99, bytes32(uint256(1)), block.timestamp + 60, q);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        control.execute(address(loop), data, 100, QUOTED_HASH, block.timestamp + 60, q);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        control.execute(address(loop), data, 99, QUOTED_HASH, block.timestamp + 61, q);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        control.execute(address(loop), data, 99, QUOTED_HASH, block.timestamp - 1, q);
        vm.roll(105);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        control.execute(address(loop), data, 99, QUOTED_HASH, block.timestamp + 60, q);
    }

    function test_controlsBoundedHarvestLeavesOwnedYieldInvested() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 10);
        _enable();
        uint256 before_ = aPrime.balanceOf(address(loop));
        bytes memory data = abi.encodeCall(Harvester.harvest, (new uint256[](1)));
        uint256 first = abi.decode(_execute(address(harvester), data), (uint256));
        assertGt(first, 99e6);
        assertLe(first, 100e6);
        assertEq(before_ - aPrime.balanceOf(address(loop)), first);
        assertGt(vault.yieldAccounting().sourceValue(), 0);
        uint256 second = abi.decode(_execute(address(harvester), data), (uint256));
        assertGt(second, 49e6);
        assertLe(first + second, 150e6);
        assertEq(abi.decode(_execute(address(harvester), data), (uint256)), 0);
        assertGt(vault.claimYield(address(this)), 0);
        assertGt(vault.yieldAccounting().earnedAssets(address(this)), 0);
    }

    function test_controlsNewcomerCannotTakeYieldBetweenPartialHarvests() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 10);
        _enable();
        _execute(address(harvester), abi.encodeCall(Harvester.harvest, (new uint256[](1))));
        address newcomer = address(0xB0B);
        eth.mint(newcomer, 1e18);
        vm.startPrank(newcomer);
        eth.approve(address(vault), 1e18);
        bytes memory deposit = abi.encodeCall(CollateralVault.deposit, (1e18, newcomer));
        ExecutionController.Quote[] memory q = _quotes(address(vault), deposit);
        control.execute(address(vault), deposit, 99, QUOTED_HASH, block.timestamp + 60, q);
        vm.stopPrank();
        _execute(address(harvester), abi.encodeCall(Harvester.harvest, (new uint256[](1))));
        assertLe(vault.yieldAccounting().earnedAssets(newcomer), 1e9);
        assertGt(vault.yieldAccounting().earnedAssets(address(this)), 0.1e18);
    }

    function test_controlsExpiredPolicyNeverBlocksSafetyRepayment() public {
        _depositAndRamp();
        _enable();
        vm.warp(block.timestamp + 31 days);
        assertEq(loop.admissionCapacity(), 0);
        pool.setPrice(address(prime), 0.99e18);
        loop.deLever();
        uint256 debt = hollarDebt.balanceOf(address(loop));
        _execute(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        assertLt(hollarDebt.balanceOf(address(loop)), debt);
    }

    function test_controlsPegHysteresisAndNoOpResults() public {
        _depositAndRamp();
        uint256 supplied = vault.syntheticSupplied();
        hollarDebt.mint(address(vault), 1e10);
        assertEq(vault.maintainPeg(), 0);
        assertEq(vault.syntheticSupplied(), supplied);
        hollarDebt.mint(address(vault), 10e18);
        assertGt(vault.maintainPeg(), 0);
        assertEq(vault.maintainPeg(), 0);
        assertEq(vault.pokeSettle(), 0);
    }

    function test_controlsQuoteDeteriorationRevertsAndRefundsBudget() public {
        _enable();
        _deposit(1e18);
        uint256 shares = vault.totalSupply();
        bytes memory data = abi.encodeCall(CollateralVault.rebalance, ());
        ExecutionController.Quote[] memory q = _quotes(address(vault), data);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(3);
        vm.expectRevert(DcaDispatch.DispatchFailed.selector);
        control.execute(address(vault), data, 99, QUOTED_HASH, block.timestamp + 60, q);
        assertEq(loop.admissionCapacity(), 2500e18);
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), shares, "waiting collateral remains funded");
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(11);
        q[0].minOut = 1; // cannot relax the independent 10bp MM-oracle floor
        vm.expectRevert(DcaDispatch.DispatchFailed.selector);
        control.execute(address(vault), data, 99, QUOTED_HASH, block.timestamp + 60, q);
    }

    function test_controlsUpwardRebalanceMakesBoundedProgress() public {
        _depositAndRamp();
        // 6dp prime rounding leaves a tiny shortfall; readiness blocks new debt until carry covers it
        aPrime.mint(address(loop), 1e6);
        _enable();
        pool.setPrice(address(eth), 9000e18);
        uint256 before_ = hollarDebt.balanceOf(address(vault));
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)) - before_, 2500e18);
        assertEq(hollar.balanceOf(address(vault)), 0, "no borrowed funds wait idle");
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)) - before_, 4500e18);
    }

    function test_controlsSecondVaultCannotObtainAnotherAdmissionBudget() public {
        CollateralVault second = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, ("Second ETH", "pETH2", address(eth), address(pool),
                address(loop), address(swapper), address(hollar), address(synth), address(aEth),
                address(hollarDebt), 1000e18, address(this))))));
        synth.grantRole(synth.MINTER_ROLE(), address(second));
        RoundingReserveFixture.fund(second);
        loop.registerVault(address(second));
        _enable();
        second.setExecutionController(address(control));
        control.configureAction(address(second), CollateralVault.rebalance.selector, true);
        _deposit(1e18);
        eth.mint(address(this), 2e18);
        eth.approve(address(second), 2e18);
        second.deposit(2e18, address(this));
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        _execute(address(second), abi.encodeCall(CollateralVault.rebalance, ()));
        vm.roll(block.number + 1);
        assertEq(loop.admissionCapacity(), 250e18);
        _execute(address(second), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(second)), 2750e18);
        assertEq(loop.admissionCapacity(), 0);
        assertGt(second.reinvestAssets(), 0);
    }

    function test_controlsCooldownAndSameBlockPreventBurstRefills() public {
        _enable();
        _deposit(2e18);
        control.configurePacing(ENTRY, 60);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(loop.admissionCapacity(), 0);
        control.configureBudget(ENTRY, address(hollar), 5000e18, 1e18, uint64(block.timestamp + 60 days));
        assertEq(loop.admissionCapacity(), 0, "refresh does not reset the cooldown");
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 59);
        assertEq(loop.admissionCapacity(), 0);
        vm.warp(block.timestamp + 1);
        assertGt(loop.admissionCapacity(), 0);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)), 4500e18);
    }

    function test_controlsStrictOracleFloorRejectsFeesAndAcceptsFairPrice() public {
        _enable();
        _deposit(1e18);
        control.configurePrice(control.lane(address(loop), address(hollar), address(aPrime)), 0, false);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(1);
        vm.expectRevert(DcaDispatch.DispatchFailed.selector);
        control.preview(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(0);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertEq(hollarDebt.balanceOf(address(vault)), 2250e18);
    }

    function test_controlsExitBeforeDeploymentNeedsNoSwapsOrDebt() public {
        _enable();
        _deposit(1e18);
        uint256 shares = vault.balanceOf(address(this));
        uint256 claim = vault.convertToAssets(shares);
        uint256 id = vault.requestRedeem(shares, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        assertEq(vault.loopShares(), 0);
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        vault.pokeSettle();
        assertEq(vault.claim(id, address(this)), claim);
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        assertLe(vault.reinvestAssets(), vault.totalAssets());
    }

    function test_controlsPartialDeploymentExitRemovesOnlyItsPendingCredit() public {
        _enable();
        _deposit(4e18);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        uint256 credit = vault.reinvestAssets();
        uint256 shares = vault.balanceOf(address(this)) / 2;
        uint256 expected = credit - credit * shares / vault.totalSupply();
        uint256 id = vault.requestRedeem(shares, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        assertEq(vault.reinvestAssets(), expected, "only exiting credit is removed");
        for (uint256 i; i < 5 && loop.unwindTargetEquity() != 0; ++i)
            _execute(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        vault.pokeSettle();
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), promised);
        assertEq(vault.reinvestAssets(), expected, "settlement does not recreate credit");
        // usd8 equity vs wei debt: deployment waits for source income to cover the fractional deficit
        vm.expectRevert(CollateralVault.Underfunded.selector);
        control.preview(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        aPrime.mint(address(loop), 1);
        _execute(address(vault), abi.encodeCall(CollateralVault.rebalance, ()));
        assertLe(hollarDebt.balanceOf(address(vault)), vault.totalAssets() * 2250);
        assertEq(hollar.balanceOf(address(vault)), 0, "only an executable slice is borrowed");
    }

    function test_controlsUnwindAlsoRequiresQuoteAndTightOracleFloor() public {
        uint256 shares = _depositAndRamp();
        _enable();
        vault.requestRedeem(shares / 2, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        uint256 before_ = aPrime.balanceOf(address(loop));
        assertEq(loop.pokeRepay(), 0, "direct call cannot sell without a quote");
        assertEq(aPrime.balanceOf(address(loop)), before_);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(11);
        vm.expectRevert(DcaDispatch.DispatchFailed.selector);
        control.preview(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        assertEq(aPrime.balanceOf(address(loop)), before_, "bad fill rolls back the whole slice");
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(0);
        _execute(address(loop), abi.encodeCall(SubLoop.pokeRepay, ()));
        assertLt(aPrime.balanceOf(address(loop)), before_);
    }

    function test_controlsHarvestCannotUseTheOlderWiderConsumerFloor() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 10);
        _enable();
        uint256 shares = vault.loopShares();
        uint256 assets = vault.totalAssets();
        swapper.setHaircut(11);
        vm.expectRevert("MockSwapper: minOut");
        control.preview(address(harvester), abi.encodeCall(Harvester.harvest, (new uint256[](1))));
        assertEq(vault.loopShares(), shares, "rejected swap cannot burn yield ownership");
        assertEq(vault.totalAssets(), assets);
    }

    function test_controlsClearingRecoveredSafetyTargetIsUsefulWork() public {
        _depositAndRamp();
        pool.setPrice(address(prime), 0.99e18);
        loop.deLever();
        assertGt(loop.deleverDebtTarget(), 0);
        pool.setPrice(address(prime), 1.01e18);
        assertGt(loop.pokeRepay(), 0, "keeper must submit the cleanup");
        assertEq(loop.deleverDebtTarget(), 0);
        assertEq(loop.pokeRepay(), 0, "next call is a no-op");
    }

    function test_controlsSmallerHarvestCanServiceDebtWhenFullBatchExceedsServiceLimit() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 10);
        hollarDebt.mint(address(vault), 20e18);
        _enable();
        control.configureLimit(address(vault.mainDebt()), address(eth), address(hollar), SERVICE, 1, 1e15);
        bytes memory data = abi.encodeCall(Harvester.harvest, (new uint256[](1)));
        vm.expectRevert(ExecutionController.TradeSize.selector);
        control.preview(address(harvester), data);
        ExecutionController.Quote[] memory caps = new ExecutionController.Quote[](1);
        caps[0] = ExecutionController.Quote(control.lane(address(vault), address(prime), address(eth)), 3e6, 0);
        (, ExecutionController.Trade[] memory fills) = control.previewBounded(address(harvester), data, caps);
        assertEq(fills.length, 2, "preview includes both the crypto and servicing legs");
        assertLe(fills[0].amountIn, 3e6);
        assertLe(fills[1].amountIn, 1e15);
        ExecutionController.Quote[] memory q = new ExecutionController.Quote[](fills.length);
        for (uint256 i; i < fills.length; ++i)
            q[i] = ExecutionController.Quote(fills[i].lane, fills[i].amountIn, fills[i].amountOut * 9998 / 10000);
        control.execute(address(harvester), data, 99, QUOTED_HASH, block.timestamp + 60, q);
        assertLt(PropellerMainDebt(address(vault.mainDebt())).interestOf(0), 20e18);
        assertGt(vault.yieldAccounting().sourceValue(), 0, "remaining owned yield stays invested");
    }
}
