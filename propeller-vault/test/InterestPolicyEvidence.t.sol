// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";

/// Regression evidence: collateral alone is not interest funding.
contract InterestPolicyEvidenceTest is PluggableYieldSourceTest {
    function _seed() internal returns (uint256 shares) {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        shares = vault.deposit(1e18, address(this));
    }

    function _growCollateral(uint256 amount) internal {
        // Isolate the result of compounding; swap/fee execution has separate tests.
        aEth.mint(address(vault), amount);
        eth.mint(address(pool), amount);
    }

    function test_compoundedYieldDoesNotSatisfyCurrentHollarBackingCheck() public {
        _seed();
        uint256 beforeAssets = vault.totalAssets();
        _growCollateral(1e17); // $300 at the fixture's ETH price
        hollarDebt.mint(address(vault), 100e18);
        vault.maintainPeg();
        assertEq(vault.totalAssets(), beforeAssets + 1e17);
        assertTrue(vault.isUnderfunded(), "collateral yield is not HOLLAR repayment cash");
        pool.setPrice(address(eth), 6000e18);
        vm.expectRevert(CollateralVault.Underfunded.selector);
        vault.rebalance();
    }

    function test_reborrowSubtractsAccruedMainInterest() public {
        _seed();
        uint256 sourceBefore = source.sharesOf(address(vault));
        hollarDebt.mint(address(vault), 100e18);
        // Isolate the headroom calculation from the separate backing guard.
        PropellerMainDebt buffer = PropellerMainDebt(address(vault.mainDebt()));
        hollar.mint(address(this), 100e18);
        hollar.approve(address(buffer), 100e18);
        buffer.fundPosition(0, 100e18);
        vault.pokeSettle();
        vault.maintainPeg();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        pool.setPrice(address(eth), 6000e18);
        vault.rebalance();
        assertEq(hollarDebt.balanceOf(address(vault)), 4500e18);
        assertEq(source.sharesOf(address(vault)) - sourceBefore, 4500e18 - debtBefore);
    }

    function test_currentExitPreservesGrossYieldPromiseButNeedsInterestFunding() public {
        uint256 shares = _seed();
        _growCollateral(1e17);
        hollarDebt.mint(address(vault), 100e18);
        vault.maintainPeg();
        uint256 id = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(16);
        (,,uint256 promised,,,,,,) = vault.redemptions(id);
        assertGt(promised, 1e18, "exit includes compounded yield");
        vault.pokeSettle();
        uint256 first = vault.claim(id, address(this));
        uint256 shortfall = vault.totalQueuedDebt();
        assertGt(shortfall, 0, "source principal did not fund Main interest");
        assertLt(first, promised);
        hollar.mint(address(vault), shortfall);
        vault.pokeSettle();
        assertEq(first + vault.claim(id, address(this)), promised);
        assertEq(vault.totalQueuedDebt(), 0);
    }
}
