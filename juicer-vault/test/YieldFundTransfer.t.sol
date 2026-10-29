// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {HarvestTest} from "./Harvest.t.sol";
import {JuicerYieldAccounting} from "../src/JuicerYieldAccounting.sol";

contract YieldFundTransferTest is HarvestTest {
    using stdStorage for StdStorage;

    address constant DEPOSITOR = address(0xA11CE);

    function _accrueInSmallSteps() internal {
        for (uint256 i; i < 200; ++i) {
            uint256 step = aPrime.balanceOf(address(loop)) * 50 / 1_000_000;
            aPrime.mint(address(loop), step);
            vault.sync();
        }
    }

    function test_walletSharesCannotReachTheFund() public {
        uint256 wallet = _depositAndRamp();
        JuicerYieldAccounting accounting = vault.yieldAccounting();
        vm.expectRevert(JuicerYieldAccounting.Unauthorized.selector);
        vault.transfer(address(accounting), wallet / 1000);

        vault.approve(DEPOSITOR, wallet);
        vm.prank(DEPOSITOR);
        vm.expectRevert(JuicerYieldAccounting.Unauthorized.selector);
        vault.transferFrom(address(this), address(accounting), wallet / 1000);
    }

    function test_depositCannotMintIntoTheFund() public {
        _depositAndRamp();
        address fund = address(vault.yieldAccounting());
        eth.mint(DEPOSITOR, 1e17);
        vm.startPrank(DEPOSITOR);
        eth.approve(address(vault), 1e17);
        vm.expectRevert(JuicerYieldAccounting.Unauthorized.selector);
        vault.deposit(1e17, fund);
        vault.deposit(1e17, DEPOSITOR);
        vm.stopPrank();
    }

    function test_smallAllocationsOwnAFundThatHeldSharesBeforeAnyUnits() public {
        uint256 wallet = _depositAndRamp();
        JuicerYieldAccounting accounting = vault.yieldAccounting();
        assertEq(accounting.totalUnits(), 0);
        uint256 forced = wallet / 1000;
        stdstore.target(address(vault)).sig(vault.walletOf.selector).with_key(address(accounting)).checked_write(forced);
        stdstore.target(address(vault)).sig(vault.totalSupply.selector).checked_write(vault.totalSupply() + forced);

        _accrueInSmallSteps();
        assertGt(accounting.totalUnits(), 0, "the first allocation creates owners");
        assertGt(accounting.earnedAssets(address(this)), 0, "the holder owns the yield");
        assertEq(vault.balanceOf(address(accounting)), 0, "and the fund's shares");
    }
}
