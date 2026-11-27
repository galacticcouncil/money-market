// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "./PluggableYieldSource.t.sol";
import {IceForwarder} from "./JuicerIceDepositAdapter.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {JuicerIceDepositAdapter} from "../src/JuicerIceDepositAdapter.sol";

contract JuicerIceDepositAdapterIntegrationTest is PluggableYieldSourceTest {
    function _prepare() internal returns (JuicerIceDepositAdapter adapter, IceForwarder forwarder, address user) {
        eth.mint(address(this), 1 ether);
        eth.approve(address(vault), 1 ether);
        vault.deposit(1 ether, address(this));
        adapter = new JuicerIceDepositAdapter();
        forwarder = new IceForwarder();
        user = makeAddr("ice depositor");
        eth.mint(user, 2 ether);
        vm.prank(user);
        eth.approve(address(forwarder), 2 ether);
    }

    function test_iceDepositsIntoJuicerForTheOwner() public {
        (JuicerIceDepositAdapter adapter, IceForwarder forwarder, address user) = _prepare();
        uint256 shares = vault.convertToShares(2 ether);
        bytes4 ack = forwarder.forward(adapter, user, 42, eth, 2 ether, address(vault), shares);

        assertEq(ack, JuicerIceDepositAdapter.execute.selector);
        assertEq(vault.balanceOf(user), shares);
        assertEq(eth.balanceOf(user), 0);
        assertEq(eth.balanceOf(address(adapter)), 0);
        assertEq(eth.allowance(address(adapter), address(vault)), 0);
    }

    function test_fullJuicerRestoresAllOutputWithoutPartialDeposit() public {
        (JuicerIceDepositAdapter adapter, IceForwarder forwarder, address user) = _prepare();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        vault.setTvlCap(assetsBefore + 1 ether);

        vm.expectRevert(CollateralVault.ExceedsTvlCap.selector);
        forwarder.forward(adapter, user, 42, eth, 2 ether, address(vault), 0);

        assertEq(eth.balanceOf(user), 2 ether);
        assertEq(eth.balanceOf(address(adapter)), 0);
        assertEq(eth.allowance(address(adapter), address(vault)), 0);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.totalSupply(), supplyBefore);
    }

    function test_pausedJuicerRestoresAllOutput() public {
        (JuicerIceDepositAdapter adapter, IceForwarder forwarder, address user) = _prepare();
        vault.pauseDeposits();

        vm.expectRevert(CollateralVault.DepositsArePaused.selector);
        forwarder.forward(adapter, user, 42, eth, 2 ether, address(vault), 0);

        assertEq(eth.balanceOf(user), 2 ether);
        assertEq(eth.balanceOf(address(adapter)), 0);
        assertEq(eth.allowance(address(adapter), address(vault)), 0);
        assertEq(vault.balanceOf(user), 0);
    }
}
