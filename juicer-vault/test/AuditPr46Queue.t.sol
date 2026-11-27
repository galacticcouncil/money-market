// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HarvestTest} from "./Harvest.t.sol";
import {JuicerYieldAccounting} from "./../src/JuicerYieldAccounting.sol";

contract AuditPr46QueueTest is HarvestTest {
    address constant HOLDER = address(0xA77);
    address constant HOLDER_WALLET = address(0xA78);
    address constant HONEST = address(0xB0B);

    function _publicDeposit(address who, uint256 amount) internal returns (uint256 shares) {
        eth.mint(who, amount);
        vm.startPrank(who);
        eth.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _folded(uint256 id) internal view returns (uint256) {
        JuicerYieldAccounting acc = vault.yieldAccounting();
        return Math.mulDiv(vault.walletOf(address(acc)), acc.requestUnits(id), acc.totalUnits());
    }

    function test_pr46_fundedRequestFoldingToNothingDoesNotBlockTheQueue() public {
        _depositAndRamp();
        _publicDeposit(HOLDER, 0.1e18);
        uint256 honestShares = _publicDeposit(HONEST, 1e18);
        vault.rebalance();
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        harvester.harvest(new uint256[](1));

        uint256 wallet = vault.walletOf(HOLDER);
        vm.startPrank(HOLDER);
        vault.transfer(HOLDER_WALLET, wallet);
        uint256 dust = vault.requestRedeem(1, HOLDER);
        vm.stopPrank();
        vm.prank(HONEST);
        uint256 honestId = vault.requestRedeem(honestShares, HONEST);

        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 1000);
        vault.sync();
        assertEq(_folded(dust), 0, "the funded request now folds to no shares");

        vm.warp(vault.unwindEligibleAt(honestId));
        vault.startUnwinds(10);
        assertEq(vault.queueUnwind(), honestId + 1, "both requests start");
        (, uint256 dustShares, uint256 dustOwed, uint256 dustDebt,,,,,) = vault.redemptions(dust);
        assertEq(dustShares, 0);
        assertEq(dustOwed, 0);
        assertEq(dustDebt, 0, "a debt-free exit");
        (,, uint256 honestOwed,,,,,,) = vault.redemptions(honestId);
        assertGt(honestOwed, 0, "the honest request is quoted");

        for (uint256 i; i < 200 && vault.queueHead() <= honestId; ++i) {
            loop.pokeRepay();
            vault.pokeSettle();
        }
        assertEq(vault.queueHead(), honestId + 1, "and settles past the empty one");
    }
}
