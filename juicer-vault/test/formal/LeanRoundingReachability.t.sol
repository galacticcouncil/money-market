// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "../Harvest.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LeanRoundingReachabilityTest is HarvestTest {
    address constant DONOR = address(0xD010);
    address constant SPENDER = address(0x5EED);

    function _donateFundedShares() internal returns (JuicerYieldAccounting y) {
        _depositAndRamp();
        hollar.mint(address(loop), loop.principalEquity() - loop.totalEquity() * 1e10);
        aPrime.mint(address(loop), 1);
        vault.sync();
        y = vault.yieldAccounting();
        assertGt(y.totalUnits(), 0);
        vault.transfer(DONOR, vault.walletOf(address(this)));
        uint256 donation = vault.walletOf(DONOR);
        vm.prank(DONOR);
        vault.transfer(address(y), donation);
        assertGt(vault.walletOf(address(y)), y.totalUnits());
        assertEq(vault.walletOf(address(this)), 0);
    }

    function _oneUnitDebit(JuicerYieldAccounting y) internal view returns (uint256) {
        return y.fundedOf(address(this))
            - Math.mulDiv(vault.walletOf(address(y)), y.balanceOf(address(this)) - 1, y.totalUnits());
    }

    function test_publicDonationCannotOverspendTransferAllowance() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 beforeBalance = vault.balanceOf(address(this));
        uint256 beforeUnits = y.balanceOf(address(this));
        vault.approve(SPENDER, 1);
        vm.prank(SPENDER);
        vm.expectRevert(JuicerYieldAccounting.InexactShares.selector);
        vault.transferFrom(address(this), SPENDER, 1);
        assertEq(vault.balanceOf(address(this)), beforeBalance);
        assertEq(y.balanceOf(address(this)), beforeUnits);
        assertEq(vault.balanceOf(SPENDER), 0);
        assertEq(y.balanceOf(SPENDER), 0);
        assertEq(vault.allowance(address(this), SPENDER), 1);
    }

    function test_publicDonationRejectsInexactDirectTransfer() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 beforeBalance = vault.balanceOf(address(this));
        vm.expectRevert(JuicerYieldAccounting.InexactShares.selector);
        vault.transfer(SPENDER, 1);
        assertEq(vault.balanceOf(address(this)), beforeBalance);
        assertEq(y.balanceOf(SPENDER), 0);
    }

    function test_publicDonationCannotOverspendRedeemAllowance() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 beforeBalance = vault.balanceOf(address(this));
        uint256 beforeUnits = y.balanceOf(address(this));
        uint256 tail = vault.queueTail();
        assertGt(vault.convertToAssets(1), 0);
        vault.approve(SPENDER, 1);
        vm.prank(SPENDER);
        vm.expectRevert(JuicerYieldAccounting.InexactShares.selector);
        vault.requestRedeem(1, address(this));
        assertEq(vault.balanceOf(address(this)), beforeBalance);
        assertEq(y.balanceOf(address(this)), beforeUnits);
        assertEq(vault.queueTail(), tail);
        assertEq(y.requestUnits(tail), 0);
        assertEq(vault.allowance(address(this), SPENDER), 1);
    }

    function test_publicDonationAllowsRepresentableTransfer() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 beforeBalance = vault.balanceOf(address(this));
        uint256 beforeUnits = y.balanceOf(address(this));
        uint256 deadBalance = vault.balanceOf(address(0xdead));
        uint256 total = y.totalUnits();
        uint256 shares = _oneUnitDebit(y);
        vault.approve(SPENDER, shares);
        vm.prank(SPENDER);
        vault.transferFrom(address(this), SPENDER, shares);
        assertEq(beforeBalance - vault.balanceOf(address(this)), shares);
        assertEq(y.balanceOf(address(this)), beforeUnits - 1);
        assertEq(y.balanceOf(SPENDER), 1);
        assertApproxEqAbs(vault.balanceOf(SPENDER), shares, 1);
        assertEq(vault.balanceOf(address(0xdead)), deadBalance);
        assertEq(y.totalUnits(), total);
        assertEq(vault.allowance(address(this), SPENDER), 0);
    }

    function test_publicDonationAllowsRepresentableDelegatedRedeem() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 beforeBalance = vault.balanceOf(address(this));
        uint256 beforeUnits = y.balanceOf(address(this));
        uint256 shares = _oneUnitDebit(y);
        vault.approve(SPENDER, shares);
        vm.prank(SPENDER);
        uint256 id = vault.requestRedeem(shares, address(this));
        assertEq(beforeBalance - vault.balanceOf(address(this)), shares);
        assertEq(y.balanceOf(address(this)), beforeUnits - 1);
        assertEq(y.requestUnits(id), 1);
        assertEq(vault.allowance(address(this), SPENDER), 0);
    }

    function test_publicDonationPreservesFullTransfer() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 shares = vault.balanceOf(address(this));
        uint256 units = y.balanceOf(address(this));
        vault.approve(SPENDER, shares);
        vm.prank(SPENDER);
        vault.transferFrom(address(this), SPENDER, shares);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(y.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(SPENDER), shares);
        assertEq(y.balanceOf(SPENDER), units);
        assertEq(vault.allowance(address(this), SPENDER), 0);
    }

    function test_publicDonationPreservesFullExit() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 shares = vault.balanceOf(address(this));
        uint256 units = y.balanceOf(address(this));
        uint256 id = vault.requestRedeem(type(uint256).max, address(this));
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(y.balanceOf(address(this)), 0);
        assertEq(y.requestUnits(id), units);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        (, uint256 escrowed,,,,,,,) = vault.redemptions(id);
        assertEq(escrowed, shares);
        assertEq(y.requestUnits(id), 0);
    }

    function test_publicDonationPreservesSelfTransfer() public {
        JuicerYieldAccounting y = _donateFundedShares();
        uint256 beforeBalance = vault.balanceOf(address(this));
        uint256 beforeUnits = y.balanceOf(address(this));
        vault.transfer(address(this), 1);
        vault.approve(SPENDER, 1);
        vm.prank(SPENDER);
        vault.transferFrom(address(this), address(this), 1);
        assertEq(vault.balanceOf(address(this)), beforeBalance);
        assertEq(y.balanceOf(address(this)), beforeUnits);
        assertEq(vault.allowance(address(this), SPENDER), 0);
        vm.expectRevert(JuicerYieldAccounting.ExceedsBalance.selector);
        vault.transfer(address(this), beforeBalance + 1);
    }
}
