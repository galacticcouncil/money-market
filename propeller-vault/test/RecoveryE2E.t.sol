// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MultiVaultFlowTest} from "./MultiVaultFlow.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {PropellerOperatingBuffer} from "../src/PropellerOperatingBuffer.sol";

/// @notice Full Propeller topology with modeled market loss/interest. Uses real
/// vault/source/harvest/fee logic, mock Aave/router, and external recovery funds.
/// No emergency indexer or pro-rata governance payout implementation is implied.
contract RecoveryE2ETest is MultiVaultFlowTest {
    address constant SECOND_ETH_USER = address(0xE2);
    address constant DONOR = address(0xD0);
    address constant LIQUIDATOR = address(0x11);

    function _deposit(CollateralVault vault, MockERC20 token, address user, uint256 assets) internal {
        token.mint(user, assets);
        vm.startPrank(user);
        token.approve(address(vault), assets);
        vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _request(CollateralVault vault, address user, uint256 shares) internal returns (uint256) {
        vm.prank(user);
        return vault.requestRedeem(shares, user);
    }

    function _donate(address to, uint256 amount) internal {
        hollar.mint(DONOR, amount);
        vm.prank(DONOR);
        hollar.transfer(to, amount);
    }

    function _fundInterest(CollateralVault v) internal {
        PropellerOperatingBuffer buffer = PropellerOperatingBuffer(address(v.operatingBuffer()));
        // Governance targets every debt cohort, including offline holders. A
        // donation to the FIFO head must not be mistaken for cohort-wide funding.
        for (uint256 key; key <= v.queueUnwind(); ++key) {
            uint256 interest = buffer.interestOf(key);
            if (interest == 0) continue;
            hollar.mint(DONOR, interest);
            vm.startPrank(DONOR);
            hollar.approve(address(buffer), interest);
            buffer.fundPosition(key, interest);
            vm.stopPrank();
        }
    }

    function _modelLoopLiquidation() internal {
        // Model the terminal liquidation outcome, not an Aave liquidation engine:
        // an outside liquidator pays the loop debt and receives its PRIME.
        uint256 debt = hollarDebt.balanceOf(address(loop));
        hollar.mint(LIQUIDATOR, debt);
        vm.startPrank(LIQUIDATOR);
        hollar.approve(address(pool), debt);
        pool.repay(address(hollar), debt, 2, address(loop));
        vm.stopPrank();
        pool.mockWithdrawTo(address(prime), aPrime.balanceOf(address(loop)), address(loop), LIQUIDATOR);
        assertEq(aPrime.balanceOf(address(loop)), 0);
        assertEq(hollarDebt.balanceOf(address(loop)), 0);
    }

    function _claim(CollateralVault vault, address user, uint256 id) internal returns (uint256 paid) {
        (, , uint256 promised, , , , , , ) = vault.redemptions(id);
        uint256 previous = vault.claimedCollateral(id);
        vm.prank(user);
        paid = vault.claim(id, user);
        assertEq(previous + paid, promised, "full recorded promise, no tolerance");
        (, , , , , , , , bool active) = vault.redemptions(id);
        assertFalse(active);
        vm.prank(user);
        vm.expectRevert(CollateralVault.RequestNotActive.selector);
        vault.claim(id, user);
    }

    function _recovery(bool reverseVaults, bool reverseClaims, uint256 firstFundingBps) internal {
        _deposit(ethVault, eth, ETH_USER, 1e18 + 7);
        _deposit(ethVault, eth, SECOND_ETH_USER, 2e18 + 11);
        _deposit(tbtcVault, tbtc, BTC_USER, 1e17 + 13);
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        uint256 earned = aPrime.balanceOf(address(loop)) / 20;
        aPrime.mint(address(loop), earned);
        prime.mint(address(pool), earned);
        harvester.harvest(new uint256[](0));
        uint256 ethFees = fees.claimableProtocolFees(address(eth));
        uint256 btcFees = fees.claimableProtocolFees(address(tbtc));
        assertGt(ethFees, 0);
        assertGt(btcFees, 0);

        uint256 id = _request(ethVault, ETH_USER, ethVault.balanceOf(ETH_USER) / 2);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        ethVault.startUnwinds(16);
        loop.pokeRepay();
        ethVault.pokeSettle();
        (, , uint256 promised, uint256 debt, , uint256 repaid, uint256 ready, , ) = ethVault.redemptions(id);
        assertGt(ready, 0, "freeze includes an already claimable request");
        assertLt(repaid, debt, "scenario includes unfinished Main repayment");
        uint256 ethBacking = ethVault.totalAssets();
        uint256 btcBacking = tbtcVault.totalAssets();
        uint256 offlineShares = tbtcVault.balanceOf(BTC_USER);
        uint256 offlineValue = tbtcVault.convertToAssets(offlineShares);
        uint256 sourceShares = loop.totalShares();
        uint256 sourceClaim = loop.pendingUnwindOf(address(ethVault));

        _modelLoopLiquidation();
        assertEq(ethVault.totalAssets(), ethBacking, "Main ETH was not seized");
        assertEq(tbtcVault.totalAssets(), btcBacking, "Main tBTC was not seized");
        assertTrue(ethVault.isUnderfunded());
        assertTrue(tbtcVault.isUnderfunded());
        loop.pauseEmergency();
        vm.prank(ETH_USER);
        vm.expectRevert("Pausable: paused");
        ethVault.claim(id, ETH_USER);
        vm.prank(BTC_USER);
        vm.expectRevert("Pausable: paused");
        tbtcVault.requestRedeem(offlineShares, BTC_USER);
        vm.prank(SECOND_ETH_USER);
        vm.expectRevert("Pausable: paused");
        ethVault.transfer(ETH_USER, 1);

        // Top up Main interest independently: a source recapitalization is not
        // proof that its original exit quote covers newly accrued Main debt.
        uint256 ethInterest = hollarDebt.balanceOf(address(ethVault)) / 100;
        uint256 btcInterest = hollarDebt.balanceOf(address(tbtcVault)) / 100;
        hollarDebt.mint(address(ethVault), ethInterest);
        hollarDebt.mint(address(tbtcVault), btcInterest);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        ethVault.maintainPeg();
        tbtcVault.maintainPeg();
        _fundInterest(ethVault);
        _fundInterest(tbtcVault);

        uint256 target = loop.principalEquity() + loop.unwindTargetEquity();
        uint256 current = loop.totalEquity() * 1e10;
        assertGt(target, current);
        uint256 shortfall = target - current;
        uint256 first = shortfall * firstFundingBps / 10_000;
        _donate(address(loop), first);
        loop.pokeRepay();
        ethVault.pokeSettle();
        tbtcVault.pokeSettle();
        assertTrue(ethVault.paused());
        assertEq(loop.totalShares(), sourceShares, "recovery funds mint no shares");
        assertEq(loop.pendingUnwindOf(address(ethVault)), sourceClaim, "no write-off or early credit");
        (, , uint256 owedAfter, , , uint256 repaidAfter, uint256 readyAfter, , ) = ethVault.redemptions(id);
        assertEq(owedAfter, promised);
        assertEq(repaidAfter, repaid);
        assertEq(readyAfter, ready);
        assertEq(tbtcVault.balanceOf(BTC_USER), offlineShares);
        assertGe(tbtcVault.convertToAssets(offlineShares), offlineValue);
        assertEq(eth.balanceOf(ETH_USER), 0);
        assertEq(tbtc.balanceOf(BTC_USER), 0);

        // No partial FIFO reopening: restore the full source backing first.
        _donate(address(loop), shortfall - first + 1e12);
        assertEq(loop.negativeCarryBps(), 0);
        loop.unpauseEmergency();
        uint256 rest = _request(ethVault, ETH_USER, ethVault.balanceOf(ETH_USER));
        uint256 second = _request(ethVault, SECOND_ETH_USER, ethVault.balanceOf(SECOND_ETH_USER));
        uint256 btc = _request(tbtcVault, BTC_USER, offlineShares);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        if (reverseVaults) { tbtcVault.startUnwinds(16); ethVault.startUnwinds(16); }
        else { ethVault.startUnwinds(16); tbtcVault.startUnwinds(16); }
        loop.pokeRepay();
        if (reverseVaults) { tbtcVault.pokeSettle(); ethVault.pokeSettle(); }
        else { ethVault.pokeSettle(); tbtcVault.pokeSettle(); }

        if (reverseClaims) {
            _claim(tbtcVault, BTC_USER, btc);
            _claim(ethVault, SECOND_ETH_USER, second);
            _claim(ethVault, ETH_USER, rest);
            _claim(ethVault, ETH_USER, id);
        } else {
            _claim(ethVault, ETH_USER, id);
            _claim(ethVault, ETH_USER, rest);
            _claim(ethVault, SECOND_ETH_USER, second);
            _claim(tbtcVault, BTC_USER, btc);
        }
        assertGe(eth.balanceOf(ETH_USER), 1e18 + 7);
        assertGe(eth.balanceOf(SECOND_ETH_USER), 2e18 + 11);
        assertGe(tbtc.balanceOf(BTC_USER), 1e17 + 13);
        assertEq(ethVault.totalQueuedCollateral(), 0);
        assertEq(tbtcVault.totalQueuedCollateral(), 0);
        assertEq(ethVault.totalQueuedShares(), 0);
        assertEq(tbtcVault.totalQueuedShares(), 0);
        assertEq(fees.claimableProtocolFees(address(eth)), ethFees, "fees not silently spent on recovery");
        assertEq(fees.claimableProtocolFees(address(tbtc)), btcFees);
        fees.claimProtocolFees(address(eth));
        fees.claimProtocolFees(address(tbtc));
        assertEq(eth.balanceOf(address(0xFEE)), ethFees);
        assertEq(tbtc.balanceOf(address(0xFEE)), btcFees);
    }

    function test_lossFreezeStagedFundingAndFullRecovery() public {
        _recovery(false, false, 4000);
    }

    function test_reverseVaultAndClaimOrderPreservesAllPrincipal() public {
        _recovery(true, true, 7000);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_recoveryFundingAndProcessingOrder(bool reverseVaults, bool reverseClaims, uint16 fraction) public {
        _recovery(reverseVaults, reverseClaims, bound(uint256(fraction), 1, 9999));
    }

    function test_zeroEquityCannotStartUnwindOrEraseWaitingShares() public {
        _deposit(ethVault, eth, ETH_USER, 1e18 + 7);
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        uint256 shares = ethVault.balanceOf(ETH_USER);
        uint256 id = _request(ethVault, ETH_USER, shares);
        _modelLoopLiquidation();
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        vm.expectRevert(SubLoop.Underfunded.selector);
        ethVault.startUnwinds(16);
        assertEq(ethVault.pendingWithdrawalShares(), shares);
        assertEq(ethVault.queueUnwind(), 0);
        assertEq(ethVault.balanceOf(address(ethVault)), shares);
        loop.pauseEmergency();
        _donate(address(loop), loop.principalEquity() + 1e12);
        loop.unpauseEmergency();
        ethVault.startUnwinds(16);
        loop.pokeRepay();
        ethVault.pokeSettle();
        assertGe(_claim(ethVault, ETH_USER, id), 1e18 + 7);
    }
}
