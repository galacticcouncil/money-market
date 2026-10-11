// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "../Harvest.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LeanRoundingReachabilityTest is HarvestTest {
    address constant DONOR = address(0xD010);
    address constant SPENDER = address(0x5EED);

    function test_publicDonationMakesTransferRoundingExceedAllowance() public {
        _depositAndRamp();
        hollar.mint(address(loop), loop.principalEquity() - loop.totalEquity() * 1e10);
        aPrime.mint(address(loop), 1);
        vault.sync();
        JuicerYieldAccounting y = vault.yieldAccounting();
        assertGt(y.totalUnits(), 0);
        vault.transfer(DONOR, vault.walletOf(address(this)));
        uint256 donation = vault.walletOf(DONOR);
        vm.prank(DONOR);
        vault.transfer(address(y), donation);
        uint256 beforeBalance = vault.balanceOf(address(this));
        uint256 recipientBefore = vault.balanceOf(SPENDER);
        uint256 quantum = Math.ceilDiv(vault.walletOf(address(y)), y.totalUnits());
        vault.approve(SPENDER, 1);
        vm.prank(SPENDER);
        vault.transferFrom(address(this), SPENDER, 1);
        uint256 debit = beforeBalance - vault.balanceOf(address(this));
        uint256 credit = vault.balanceOf(SPENDER) - recipientBefore;
        emit log_named_uint("funded per reward unit (rounded up)", quantum);
        emit log_named_uint("allowance spent", 1);
        emit log_named_uint("displayed balance debit", debit);
        emit log_named_uint("displayed balance credit", credit);
        assertGt(debit, 1);
        assertGt(credit, 1);
        assertLe(debit, 1 + quantum);
        assertLe(credit, 2 + quantum);
        assertEq(vault.allowance(address(this), SPENDER), 0);
    }
}
