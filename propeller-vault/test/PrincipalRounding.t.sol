// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

contract PrincipalRoundingTest is PluggableYieldSourceTest {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        eth.mint(user, assets);
        vm.startPrank(user);
        eth.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _yield(uint256 assets) internal {
        aEth.mint(address(vault), assets);
        eth.mint(address(pool), assets);
    }

    function _request(address user, uint256 shares) internal returns (uint256 id) {
        vm.prank(user);
        id = vault.requestRedeem(shares, user);
    }

    function _settle() internal {
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
    }

    function _claim(address user, uint256 id) internal returns (uint256) {
        vm.prank(user);
        return vault.claim(id, user);
    }

    function test_oddDepositAtTwoToOnePriceCannotLosePrincipalOrDiluteHolder() public {
        uint256 oldShares = _deposit(address(this), 1e18);
        _yield(1e18);
        uint256 oldQuote = vault.convertToAssets(oldShares);
        uint256 reserve = vault.roundingReserve();
        uint256 assets = 1e18 + 1;
        uint256 shares = _deposit(ALICE, assets);
        assertEq(shares, 5e17 + 1);
        assertEq(vault.roundingReserve(), reserve - 1, "donor pays the missing base unit");
        assertGe(vault.convertToAssets(oldShares), oldQuote, "no dilution");
        uint256 id = _request(ALICE, shares);
        _settle();
        assertGe(_claim(ALICE, id), assets, "zero rounding tolerance on principal");
        assertGe(vault.convertToAssets(oldShares), oldQuote);
    }

    function test_splitTransferredSharesAndPartialClaimsKeepAllPrincipal() public {
        _deposit(address(this), 1e18);
        _yield(333_333_333_333_333_333);
        uint256 assets = 1e18 + 17;
        uint256 shares = _deposit(ALICE, assets);
        vm.prank(ALICE);
        vault.transfer(BOB, shares / 3);
        uint256 a = _request(ALICE, shares / 3);
        uint256 b = _request(BOB, shares / 3);
        uint256 c = _request(ALICE, shares - 2 * (shares / 3));
        pool.setRepayLimit(100e18);
        _settle();
        uint256 paid = _claim(ALICE, a);
        assertGt(paid, 0);
        pool.setRepayLimit(type(uint256).max);
        vault.pokeSettle();
        paid += _claim(ALICE, a) + _claim(BOB, b) + _claim(ALICE, c);
        assertGe(paid, assets, "splits and transfers cannot erase principal");
        assertEq(vault.totalQueuedCollateral(), 0);
        assertEq(vault.totalQueuedShares(), 0);
    }

    function test_roundingBufferIsNotShareBackingOrDepositorFunds() public {
        _deposit(address(this), 1e18);
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        uint256 reserve = vault.roundingReserve();
        vault.pause();
        eth.mint(ALICE, 123);
        vm.startPrank(ALICE);
        eth.approve(address(vault), 123);
        vault.fundRoundingReserve(123);
        vm.stopPrank();
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.roundingReserve(), reserve + 123);
        assertGe(eth.balanceOf(address(vault)), vault.roundingReserve());
    }

    function test_poolSupplyAndWithdrawalRoundingIsPaidByBuffer() public {
        uint256 oldShares = _deposit(address(this), 1e18);
        uint256 oldQuote = vault.convertToAssets(oldShares);
        uint256 reserve = vault.roundingReserve();
        pool.setCollateralRounding(address(eth), 1, 1);
        uint256 shares = _deposit(ALICE, 1e18 + 1);
        assertEq(vault.roundingReserve(), reserve - 1);
        assertGe(vault.convertToAssets(oldShares), oldQuote);
        uint256 id = _request(ALICE, shares);
        _settle();
        assertEq(_claim(ALICE, id), 1e18 + 1);
        assertEq(vault.roundingReserve(), reserve - 2);
        assertGe(vault.convertToAssets(oldShares), oldQuote);
    }

    function test_insufficientBufferRevertsDepositAtomically() public {
        _deposit(address(this), 1e18);
        _yield(1e18);
        pool.setCollateralRounding(address(eth), vault.roundingReserve(), 0);
        eth.mint(ALICE, 1e18 + 1);
        vm.startPrank(ALICE);
        eth.approve(address(vault), 1e18 + 1);
        vm.expectRevert(CollateralVault.InsufficientRoundingReserve.selector);
        vault.deposit(1e18 + 1, ALICE);
        vm.stopPrank();
        assertEq(eth.balanceOf(ALICE), 1e18 + 1);
        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.totalAssets(), 2e18);
        assertEq(vault.roundingReserve(), 1e9);
    }

    function test_splitRequestsCannotConsumeMoreThanFundedRounding() public {
        _deposit(address(this), 1e18);
        _yield(uint256(1e18) / 3);
        uint256 shares = _deposit(ALICE, 1e18 + 1);
        uint256 reserve = vault.roundingReserve();
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _request(ALICE, i + 1 == ids.length ? shares - (shares / 32) * 31 : shares / 32);
        }
        _settle();
        uint256 paid;
        for (uint256 i; i < ids.length; ++i) paid += _claim(ALICE, ids[i]);
        assertGe(paid, 1e18 + 1);
        assertLe(reserve - vault.roundingReserve(), ids.length, "at most one base unit per start");
        assertGe(eth.balanceOf(address(vault)), vault.roundingReserve());
    }

    function _exhaustBuffer() internal returns (uint256 shares) {
        _deposit(address(this), 1e18);
        pool.setCollateralRounding(address(eth), vault.roundingReserve(), 0);
        shares = _deposit(ALICE, 1e18);
        assertEq(vault.roundingReserve(), 0);
        pool.setCollateralRounding(address(eth), 0, 0);
    }

    function _fundOne() internal {
        eth.mint(address(this), 1);
        eth.approve(address(vault), 1);
        vault.fundRoundingReserve(1);
    }

    function test_exhaustedBufferPreservesWaitingRequestUntilRefilled() public {
        uint256 shares = _exhaustBuffer();
        _yield(1);
        uint256 id = _request(ALICE, shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        uint256 sourceShares = vault.loopShares();
        vm.expectRevert(CollateralVault.InsufficientRoundingReserve.selector);
        vault.startUnwinds(1);
        assertEq(vault.queueUnwind(), 0);
        assertEq(vault.pendingWithdrawalShares(), shares);
        assertEq(vault.loopShares(), sourceShares);
        assertEq(source.pendingUnwindOf(address(vault)), 0);
        _fundOne();
        vault.startUnwinds(1);
        vault.pokeSettle();
        assertGe(_claim(ALICE, id), 1e18);
    }

    function test_exhaustedBufferCannotHaircutSettlement() public {
        uint256 shares = _exhaustBuffer();
        uint256 id = _request(ALICE, shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        pool.setCollateralRounding(address(eth), 0, 1);
        uint256 debt = hollarDebt.balanceOf(address(vault));
        vm.expectRevert(CollateralVault.InsufficientRoundingReserve.selector);
        vault.pokeSettle();
        assertEq(hollarDebt.balanceOf(address(vault)), debt, "repayment rolls back with settlement");
        assertEq(vault.totalQueuedCollateral(), 1e18);
        (, , , , , uint256 repaid, uint256 settled, , bool active) = vault.redemptions(id);
        assertEq(repaid, 0);
        assertEq(settled, 0);
        assertTrue(active);
        _fundOne();
        vault.pokeSettle();
        assertEq(_claim(ALICE, id), 1e18);
    }

    function testFuzz_depositSplitExitPreservesPrincipalAndOtherHolder(uint96 seed, uint96 gain, uint96 amount) public {
        uint256 bootstrap = bound(uint256(seed), 1e15, 10e18);
        uint256 assets = bound(uint256(amount), 1e12, 10e18);
        uint256 oldShares = _deposit(address(this), bootstrap);
        _yield(bound(uint256(gain), 1, bootstrap * 3));
        uint256 oldQuote = vault.convertToAssets(oldShares);
        uint256 shares = _deposit(ALICE, assets);
        assertGe(vault.convertToAssets(oldShares), oldQuote);
        uint256 a = _request(ALICE, shares / 3);
        uint256 b = _request(ALICE, shares - shares / 3);
        _settle();
        assertGe(_claim(ALICE, a) + _claim(ALICE, b), assets);
        assertGe(vault.convertToAssets(oldShares), oldQuote);
        assertGe(eth.balanceOf(address(vault)), vault.roundingReserve());
    }
}
