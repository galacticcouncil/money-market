// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerOperatingBuffer} from "../src/PropellerOperatingBuffer.sol";

contract OperatingBufferTest is PluggableYieldSourceTest {
    function test_bootstrapSubsidyCanBeClaimedAcrossRepeatedEntries() public {
        _deposit(1e12); // Keep the governance seed invested across public entries.
        uint256 bootstrapBefore = _buffer().bootstrapCash();
        uint256 received;
        for (uint256 i; i < 2; ++i) {
            uint256 shares = _deposit(1e18);
            uint256 id = _start(shares);
            vault.pokeSettle();
            vault.claim(id, address(this));
            uint256 paid = _buffer().claimBuffer(id);
            assertGt(paid, 0, "sponsored cash is currently a gift, not repayable capital");
            received += paid;
        }
        assertGe(bootstrapBefore - _buffer().bootstrapCash(), received);
    }

    function test_scaledBorrowRoundingRecordsObservedDebt() public {
        pool.setDebtRounding(1, 0);
        _deposit(1e18);
        (,uint256 principal,,,) = _buffer().positions(0);
        assertEq(principal, hollarDebt.balanceOf(address(vault)));
        assertEq(_buffer().interestOf(0), 0);
        assertEq(vault.totalAssets(), 1e18);
    }

    function test_scaledRepaymentTailUsesOnlyOwnedCash() public {
        _deposit(1e18);
        uint256 bootstrap = _buffer().bootstrapCash();
        uint256 cash = _cash(0);
        pool.setDebtRounding(0, 1);
        hollarDebt.mint(address(vault), 1e18);
        vault.pokeSettle();
        assertEq(_buffer().interestOf(0), 0);
        assertEq(_buffer().bootstrapCash(), bootstrap);
        assertEq(cash - _cash(0), 1e18 + 3);
        assertEq(vault.totalAssets(), 1e18);
        _deposit(1e18);
        assertEq(vault.totalAssets(), 2e18);
    }

    function test_scaledExitRepaymentClearsDebtUnitsAndPreservesCollateral() public {
        uint256 shares = _deposit(1e18);
        pool.setDebtRounding(0, 1);
        uint256 id = _start(shares / 2);
        vault.pokeSettle();
        assertEq(_buffer().debtOf(id + 1), 0);
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), promised);
        _buffer().claimBuffer(id);
        assertEq(vault.totalAssets(), 1e18 - promised);
    }

    function _buffer() internal view returns (PropellerOperatingBuffer) {
        return PropellerOperatingBuffer(address(vault.operatingBuffer()));
    }

    function _deposit(uint256 amount) internal returns (uint256) {
        eth.mint(address(this), amount);
        eth.approve(address(vault), amount);
        return vault.deposit(amount, address(this));
    }

    function _cash(uint256 key) internal view returns (uint256 value) {
        (,,value,,) = _buffer().positions(key);
    }

    function _start(uint256 shares) internal returns (uint256 id) {
        id = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(64);
    }

    function _freshVault() internal {
        vault = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, ("ETH", "pETH", address(eth), address(pool),
                address(source), address(0), address(hollar), address(synth), address(aEth),
                address(hollarDebt), 1_000e18, address(this))))));
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
    }

    function test_bootstrapAndExplicitConfigurationRequiredAtomically() public {
        _freshVault();
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.deposit(1e18, address(this));
        PropellerOperatingBuffer buffer = new PropellerOperatingBuffer(address(vault));
        vault.setOperatingBuffer(address(buffer));
        vm.expectRevert(PropellerOperatingBuffer.InvalidConfiguration.selector);
        vault.deposit(1e18, address(this));
        buffer.configure(7 days, 10, 5e25);
        vm.expectRevert(PropellerOperatingBuffer.UnfundedBuffer.selector);
        vault.deposit(1e18, address(this));
        assertEq(vault.totalSupply(), 0);
        assertEq(hollarDebt.balanceOf(address(vault)), 0);
        assertEq(source.sharesOf(address(vault)), 0);
        hollar.mint(address(this), 100e18);
        hollar.approve(address(buffer), 100e18);
        buffer.fundBootstrap(100e18);
        vault.deposit(1e18, address(this));
        assertEq(buffer.ownedCash() + buffer.bootstrapCash(), 100e18);
        assertEq(buffer.ownedCash(), buffer.targetCash());
    }

    function test_lateDepositorDoesNotDiluteExistingBuffer() public {
        _deposit(1e18);
        PropellerOperatingBuffer buffer = _buffer();
        hollar.mint(address(this), 100e18);
        hollar.approve(address(buffer), 100e18);
        buffer.fundPosition(0, 100e18);
        uint256 priorCash = _cash(0);
        uint256 priorSupply = vault.totalSupply();
        uint256 minted = _deposit(1e18);
        assertGe(_cash(0) * priorSupply, priorCash * (priorSupply + minted));
        assertEq(vault.totalAssets(), 2e18);
    }

    function test_interestServiceDoesNotConsumeCollateralOrBootstrap() public {
        _deposit(1e18);
        PropellerOperatingBuffer buffer = _buffer();
        uint256 cash = _cash(0);
        uint256 bootstrap = buffer.bootstrapCash();
        hollarDebt.mint(address(vault), 1e18);
        vault.pokeSettle();
        assertEq(buffer.interestOf(0), 0);
        assertEq(_cash(0), cash - 1e18);
        assertEq(buffer.bootstrapCash(), bootstrap);
        assertEq(vault.totalAssets(), 1e18);
    }

    function test_exhaustionPreservesPrincipalAndBlocksNewDeposits() public {
        _deposit(1e18);
        hollarDebt.mint(address(vault), 100e18);
        vault.pokeSettle();
        assertEq(_cash(0), 0);
        assertGt(_buffer().interestOf(0), 0);
        assertEq(vault.totalAssets(), 1e18);
        vm.expectRevert(PropellerOperatingBuffer.UnfundedBuffer.selector);
        vault.deposit(1, address(this));
    }

    function test_exitInterestUsesItsOwnBufferAndFullPrincipalIsPaid() public {
        uint256 shares = _deposit(1e18);
        uint256 id = _start(shares / 2);
        uint256 activeCash = _cash(0);
        uint256 exitCash = _cash(id + 1);
        hollarDebt.mint(address(vault), 2e18);
        uint256 activeInterest = _buffer().interestOf(0);
        uint256 exitInterest = _buffer().interestOf(id + 1);
        vault.pokeSettle();
        assertApproxEqAbs(activeCash - _cash(0), activeInterest, 2);
        assertApproxEqAbs(exitCash - _cash(id + 1), exitInterest, 2);
        assertEq(_buffer().debtOf(id + 1), 0);
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), promised);
        uint256 cashBefore = hollar.balanceOf(address(this));
        uint256 paid = _buffer().claimBuffer(id);
        assertEq(hollar.balanceOf(address(this)) - cashBefore, paid);
        assertGt(paid, 0);
    }

    function test_earlyRepaymentRetainsLaterSourceRecoveryForOriginalOwner() public {
        uint256 shares = _deposit(1e18);
        source.setPullBps(0);
        uint256 id = _start(shares / 2);
        PropellerOperatingBuffer buffer = _buffer();
        uint256 debt = buffer.debtOf(id + 1);
        hollar.mint(address(this), debt);
        hollar.approve(address(buffer), debt);
        buffer.fundPosition(id + 1, debt);
        vault.pokeSettle();
        vault.claim(id, address(this));
        buffer.claimBuffer(id);
        uint256 activeCash = _cash(0);
        uint256 ownerCash = hollar.balanceOf(address(this));
        source.setPullBps(10_000);
        vault.pokeSettle();
        uint256 late = buffer.claimBuffer(id);
        assertGt(late, 0);
        assertEq(hollar.balanceOf(address(this)), ownerCash + late);
        assertEq(_cash(0), activeCash, "late source proceeds cannot subsidize remaining holders");
    }

    function test_pauseBlocksBufferPayoutButAllowsTargetedRecovery() public {
        uint256 id = _start(_deposit(1e18));
        PropellerOperatingBuffer buffer = _buffer();
        vault.pokeSettle();
        vault.pause();
        vm.expectRevert(PropellerOperatingBuffer.Paused.selector);
        buffer.claimBuffer(id);
        hollar.mint(address(this), 1e18);
        hollar.approve(address(_buffer()), 1e18);
        _buffer().fundPosition(id + 1, 1e18);
        vault.unpause();
        assertGe(_buffer().claimBuffer(id), 1e18);
    }

    function test_policyAuthorityAndNoLiveReplacement() public {
        PropellerOperatingBuffer buffer = _buffer();
        vm.prank(address(0xBAD));
        vm.expectRevert(PropellerOperatingBuffer.Unauthorized.selector);
        buffer.configure(7 days, 10, 5e25);
        vm.expectRevert(PropellerOperatingBuffer.InvalidConfiguration.selector);
        buffer.configure(0, 10, 5e25);
        _deposit(1e18);
        address replacement = address(new PropellerOperatingBuffer(address(vault)));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setOperatingBuffer(replacement);
    }

    function test_liveRateIncreaseRaisesTargetAndFullDiscountStillReservesCosts() public {
        _deposit(1e18);
        uint256 target = _buffer().targetCash();
        pool.setVariableBorrowRate(20e25);
        assertGt(_buffer().targetCash(), target);
        assertFalse(_buffer().ready());
    }

    function test_discountedGhoBudgetBoundsGrossIndexGrowth() public {
        _deposit(1e18);
        PropellerOperatingBuffer buffer = _buffer();
        buffer.configure(90 days, 10, 1);
        pool.setVariableBorrowRate(1e27);
        vm.mockCall(address(vault), abi.encodeWithSignature("discountController()"), abi.encode(address(1)));
        vm.mockCall(address(hollarDebt), abi.encodeWithSignature("getDiscountPercent(address)", address(vault)), abi.encode(9000));
        uint256 debt = hollarDebt.balanceOf(address(vault));
        uint256 grossBound = debt * 90 / (365 - 90);
        uint256 costBudget = source.exitCostExposure(address(vault)) / 1000;
        assertGe(buffer.targetCash(), grossBound / 10 + costBudget);
        assertEq(buffer.effectiveRateRay(), 1e26);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_partialRepaymentsAndPostStartInterest(uint96 interestSeed, uint96 limitSeed) public {
        uint256 id = _start(_deposit(1e18) / 2);
        uint256 interest = bound(uint256(interestSeed), 1, 2e18);
        uint256 limit = bound(uint256(limitSeed), 20e18, 400e18);
        hollarDebt.mint(address(vault), interest);
        pool.setRepayLimit(limit);
        for (uint256 i; i < 64 && vault.totalQueuedDebt() != 0; ++i) vault.pokeSettle();
        assertEq(vault.totalQueuedDebt(), 0);
        assertEq(_buffer().debtOf(id + 1), 0);
        (,,uint256 owed,,,,,,) = vault.redemptions(id);
        assertEq(vault.claim(id, address(this)), owed);
        assertEq(hollar.balanceOf(address(_buffer())), _buffer().bootstrapCash() + _buffer().ownedCash());
    }
}
