// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";

contract LeanLazyHistoryParityTest is Test {
    address constant OLD = address(0xa11ce);
    address constant FIRST = address(0xb0b);
    address constant SECOND = address(0xcafe);

    function _map(JuicerYieldAccounting y, uint256 slot, address owner, uint256 value) private {
        vm.store(address(y), keccak256(abi.encode(owner, slot)), bytes32(value));
    }

    function test_rescaleCeilIndexPreventsLazyUnitExcess() public {
        ParityVault v = new ParityVault();
        JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
        uint256 divisor = 1 << 64;
        uint256 equity = 2e38;
        uint256[] memory input = new uint256[](14);
        input[6] = equity;
        input[7] = equity;
        v.configure(input);
        v.mint(FIRST, 1e27);
        v.mint(SECOND, 1e27);
        vm.store(address(y), bytes32(uint256(0)), bytes32(uint256(2)));
        vm.store(address(y), bytes32(uint256(2)), bytes32(divisor + 1));
        vm.store(address(y), bytes32(uint256(3)), bytes32(divisor));
        _map(y, 4, OLD, divisor - 1);
        _map(y, 5, OLD, divisor - 1);
        _map(y, 5, FIRST, divisor - 1);
        _map(y, 5, SECOND, divisor - 1);
        assertEq(y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND), y.totalUnits());

        vm.prank(address(v));
        y.checkpoint(address(0), address(0));

        uint256 minted = (equity - 2) * 2 / 3;
        assertEq(y.unitScale(), 64);
        assertEq(y.totalUnits(), minted + 1);
        assertEq(y.rewardIndex(), 1 + minted / 2);
        assertEq(y.balanceOf(OLD), 0);
        assertEq(y.balanceOf(FIRST) + y.balanceOf(SECOND), y.totalUnits() - 1);
        vm.prank(address(v));
        y.settle(FIRST, SECOND, 0);
        assertEq(y.balanceOf(FIRST) + y.balanceOf(SECOND), y.totalUnits() - 1);
    }
}
