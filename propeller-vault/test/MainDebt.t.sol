// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";

contract MainDebtTest is PluggableYieldSourceTest {
    function _ledger() internal view returns (PropellerMainDebt) {
        return PropellerMainDebt(address(vault.mainDebt()));
    }

    function _deposit(uint256 amount) internal returns (uint256) {
        eth.mint(address(this), amount);
        eth.approve(address(vault), amount);
        return vault.deposit(amount, address(this));
    }

    function _cash(uint256 key) internal view returns (uint256 value) {
        (,,value,,) = _ledger().positions(key);
    }

    function _fund(uint256 key, uint256 amount) internal {
        hollar.mint(address(this), amount);
        hollar.approve(address(_ledger()), amount);
        _ledger().fundPosition(key, amount);
    }

    function _start(uint256 shares) internal returns (uint256 id) {
        id = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(64);
    }

    function test_noSponsoredCashOrDepositCyclingReward() public {
        _deposit(1e12);
        for (uint256 i; i < 3; ++i) {
            uint256 id = _start(_deposit(1e18));
            vault.pokeSettle();
            vault.claim(id, address(this));
            assertLe(_ledger().claimSurplus(id), 1, "no sponsored withdrawal bonus");
        }
        assertEq(_ledger().ownedCash(), 0);
    }

    function test_wiringRequiredButNoPrefundingOrPolicyRequired() public {
        vault = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, ("ETH", "pETH", address(eth), address(pool),
                address(source), address(0), address(hollar), address(synth), address(aEth),
                address(hollarDebt), 1_000e18, address(this))))));
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.deposit(1e18, address(this));
        PropellerMainDebt ledger = new PropellerMainDebt(address(vault));
        vault.setMainDebt(address(ledger));
        vault.deposit(1e18, address(this));
        assertEq(ledger.ownedCash(), 0);
        assertEq(hollar.balanceOf(address(ledger)), 0);
        assertGt(hollarDebt.balanceOf(address(vault)), 0);
        assertTrue(ledger.ready());
    }

    function test_scaledBorrowRoundingRecordsObservedDebt() public {
        pool.setDebtRounding(1, 0);
        _deposit(1e18);
        (,uint256 principal,,,) = _ledger().positions(0);
        assertEq(principal, hollarDebt.balanceOf(address(vault)));
        assertEq(_ledger().interestOf(0), 0);
        assertEq(vault.totalAssets(), 1e18);
    }

    function test_scaledRepaymentTailUsesOnlyExplicitlyFundedCash() public {
        _deposit(1e18);
        _fund(0, 2e18);
        pool.setDebtRounding(0, 1);
        hollarDebt.mint(address(vault), 1e18);
        vault.pokeSettle();
        assertEq(_ledger().interestOf(0), 0);
        assertEq(2e18 - _cash(0), 1e18 + 3);
        assertEq(vault.totalAssets(), 1e18);
    }

    function test_scaledExitRepaymentClearsDebtUnitsAndPreservesCollateral() public {
        uint256 shares = _deposit(1e18);
        pool.setDebtRounding(0, 1);
        uint256 id = _start(shares / 2);
        _fund(id + 1, 10);
        vault.pokeSettle();
        assertEq(_ledger().debtOf(id + 1), 0);
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), promised);
        _ledger().claimSurplus(id);
        assertEq(vault.totalAssets(), 1e18 - promised);
    }

    function test_unfundedInterestPreservesPrincipalAndBlocksDeposits() public {
        _deposit(1e18);
        hollarDebt.mint(address(vault), 100e18);
        vault.pokeSettle();
        assertEq(_cash(0), 0);
        assertEq(_ledger().interestOf(0), 100e18);
        assertFalse(_ledger().ready());
        assertEq(vault.totalAssets(), 1e18);
        vm.expectRevert(PropellerMainDebt.UnfundedInterest.selector);
        vault.deposit(1, address(this));
        _fund(0, 100e18);
        vault.pokeSettle();
        assertEq(_ledger().interestOf(0), 0);
        assertEq(vault.totalAssets(), 1e18);
    }

    function test_exitInterestRemainsUnpaidUntilRecoveryWithoutHaircut() public {
        uint256 id = _start(_deposit(1e18) / 2);
        hollarDebt.mint(address(vault), 2e18);
        vault.maintainPeg();
        vault.pokeSettle();
        assertGt(_ledger().debtOf(id + 1), 0);
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        uint256 first = vault.claim(id, address(this));
        assertLt(first, promised);
        _fund(id + 1, _ledger().debtOf(id + 1) + 2);
        vault.pokeSettle();
        assertEq(first + vault.claim(id, address(this)), promised);
        assertGt(_ledger().interestOf(0), 0, "exit funding cannot service active holders");
    }

    function test_partialSourceCreditsAreProportionalNotFirstCome() public {
        uint256 shares = _deposit(1e18);
        uint256 a = vault.requestRedeem(shares / 2, address(this));
        uint256 b = vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(64);
        source.setPullBps(5000);
        vault.pokeSettle();
        (,,,,,uint256 paidA,,,) = vault.redemptions(a);
        // FIFO collateral processing is unchanged, but B's cash is already owned.
        assertApproxEqAbs(paidA, _cash(b + 1), 2);
        (,,,uint256 pendingA,) = _ledger().positions(a + 1);
        (,,,uint256 pendingB,) = _ledger().positions(b + 1);
        assertApproxEqAbs(pendingA, pendingB, 2);
        source.setPullBps(10_000);
        vault.pokeSettle();
        assertEq(vault.totalQueuedDebt(), 0);
    }

    function test_boundedSourceBatchExcludesNewExitsAndConservesRounding() public {
        PropellerMainDebt ledger = _ledger();
        for (uint256 id; id < 70; ++id) {
            vm.prank(address(vault));
            ledger.startExit(id, address(this), 1, 1000, 100e18);
        }
        hollar.mint(address(vault), 7100e18);
        vm.startPrank(address(vault));
        hollar.approve(address(ledger), 7100e18);
        ledger.creditSource(3500e18);
        vm.expectRevert(PropellerMainDebt.OutstandingDebt.selector);
        ledger.startExit(70, address(this), 1, 1000, 100e18);
        ledger.creditSource(0);
        ledger.startExit(70, address(this), 1, 1000, 100e18);
        assertEq(_cash(71), 0, "late exit cannot capture an earlier allocation");
        for (uint256 key = 1; key <= 70; ++key) assertEq(_cash(key), 50e18);
        ledger.creditSource(3600e18);
        ledger.creditSource(0);
        vm.stopPrank();
        for (uint256 key = 1; key <= 71; ++key) assertEq(_cash(key), 100e18);
        assertEq(ledger.unallocatedSource(), 0);
        assertEq(ledger.sourceOutstanding(), 0);
        assertEq(ledger.ownedCash(), 7100e18);
    }

    function test_earlyRepaymentRetainsLaterSourceRecoveryForOriginalOwner() public {
        uint256 shares = _deposit(1e18);
        source.setPullBps(0);
        uint256 id = _start(shares / 2);
        PropellerMainDebt ledger = _ledger();
        _fund(id + 1, ledger.debtOf(id + 1));
        vault.pokeSettle();
        vault.claim(id, address(this));
        ledger.claimSurplus(id);
        uint256 ownerCash = hollar.balanceOf(address(this));
        source.setPullBps(10_000);
        vault.pokeSettle();
        uint256 late = ledger.claimSurplus(id);
        assertGt(late, 0);
        assertEq(hollar.balanceOf(address(this)), ownerCash + late);
        assertEq(_cash(0), 0);
    }

    function test_costAndCashBatchesRemainProportionalAcrossBoundedCalls() public {
        PropellerMainDebt ledger = _ledger();
        for (uint256 id; id < 70; ++id) {
            vm.prank(address(vault));
            ledger.startExit(id, address(this), 1, 1000, 100e18);
        }
        hollar.mint(address(vault), 5950e18);
        vm.startPrank(address(vault));
        hollar.approve(address(ledger), 5950e18);
        vm.mockCall(address(source), abi.encodeWithSignature("unwindExecutionCost(address)", address(vault)),
            abi.encode(700e18));
        ledger.creditSource(2800e18);
        assertEq(ledger.unallocatedSource(), 240e18);
        assertEq(ledger.unallocatedCost(), 60e18);
        vm.mockCall(address(source), abi.encodeWithSignature("unwindExecutionCost(address)", address(vault)),
            abi.encode(1050e18));
        ledger.creditSource(700e18); // New receipt cannot alter the frozen first batch.
        for (uint256 key = 1; key <= 70; ++key) assertEq(_cash(key), 40e18);
        vm.expectRevert(PropellerMainDebt.OutstandingDebt.selector);
        ledger.startExit(70, address(this), 1, 1000, 100e18);
        ledger.creditSource(0);
        ledger.creditSource(0);
        ledger.creditSource(2450e18);
        ledger.creditSource(0);
        vm.stopPrank();
        for (uint256 key = 1; key <= 70; ++key) {
            (,,uint256 cash,uint256 remaining,) = ledger.positions(key);
            assertEq(cash, 85e18);
            assertEq(remaining, 0);
        }
        assertEq(ledger.sourceOutstanding(), 0);
        assertEq(ledger.unallocatedSource(), 0);
        assertEq(ledger.unallocatedCost(), 0);
        assertEq(ledger.ownedCash(), 5950e18);
        assertEq(hollar.balanceOf(address(ledger)), ledger.ownedCash());
    }

    function test_directMainRepaymentBenefitsAllDebtCohorts() public {
        uint256 id = _start(_deposit(1e18) / 2);
        source.setPullBps(0);
        uint256 active = _ledger().debtOf(0);
        uint256 exiting = _ledger().debtOf(id + 1);
        uint256 repayment = hollarDebt.balanceOf(address(vault)) / 10;
        hollar.mint(address(this), repayment);
        hollar.approve(address(pool), repayment);
        pool.repay(address(hollar), repayment, 2, address(vault));
        assertApproxEqAbs(_ledger().debtOf(0), active * 9 / 10, 1);
        assertApproxEqAbs(_ledger().debtOf(id + 1), exiting * 9 / 10, 1);
        uint256 assets = vault.totalAssets();
        vault.pokeSettle();
        assertEq(vault.totalAssets(), assets);
    }

    function test_pauseBlocksSurplusButAllowsTargetedRecovery() public {
        uint256 id = _start(_deposit(1e18));
        PropellerMainDebt ledger = _ledger();
        vault.pokeSettle();
        vault.pause();
        vm.expectRevert(PropellerMainDebt.Paused.selector);
        ledger.claimSurplus(id);
        _fund(id + 1, 1e18);
        vault.unpause();
        assertGe(_ledger().claimSurplus(id), 1e18);
    }

    function test_noLiveLedgerReplacement() public {
        _deposit(1e18);
        address replacement = address(new PropellerMainDebt(address(vault)));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setMainDebt(replacement);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_partialRepaymentsAndPostStartInterest(uint96 interestSeed, uint96 limitSeed) public {
        uint256 id = _start(_deposit(1e18) / 2);
        uint256 interest = bound(uint256(interestSeed), 1, 2e18);
        uint256 limit = bound(uint256(limitSeed), 20e18, 400e18);
        hollarDebt.mint(address(vault), interest);
        _fund(id + 1, _ledger().interestOf(id + 1) + 2);
        pool.setRepayLimit(limit);
        for (uint256 i; i < 64 && vault.totalQueuedDebt() != 0; ++i) vault.pokeSettle();
        assertEq(vault.totalQueuedDebt(), 0);
        assertEq(_ledger().debtOf(id + 1), 0);
        (,,uint256 owed,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), owed);
        assertEq(hollar.balanceOf(address(_ledger())), _ledger().ownedCash());
    }
}
