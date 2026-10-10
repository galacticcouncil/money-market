// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";

/// @notice feasibility boundary for the original seeded rescale counterexample: which
/// arithmetic preconditions contradict what public vault operations can produce, and which
/// are merely extreme. seeded storage; not reachability evidence.
contract RescaleFeasibilityTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant D = 1 << 64;

    address constant OLD = address(0xa11ce);
    address constant FIRST = address(0xb0b);
    address constant SECOND = address(0xcafe);

    function _map(JuicerYieldAccounting y, uint256 slot, address owner, uint256 value) private {
        vm.store(address(y), keccak256(abi.encode(owner, slot)), bytes32(value));
    }

    function _seed(uint256 total, uint256 index) internal returns (JuicerYieldAccounting y, ParityVault v) {
        v = new ParityVault();
        y = new JuicerYieldAccounting(address(v));
        uint256[] memory input = new uint256[](14);
        input[6] = 2e38; // held
        input[7] = 2e38; // equity
        v.configure(input);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        vm.store(address(y), bytes32(uint256(0)), bytes32(uint256(2))); // sourceShares
        vm.store(address(y), bytes32(uint256(2)), bytes32(total));
        vm.store(address(y), bytes32(uint256(3)), bytes32(index));
    }

    function test_settlementUsesPerHolderCap() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D);
        _map(y, 4, FIRST, D + 2);
        _map(y, 5, FIRST, D);
        assertEq(y.balanceOf(FIRST), D + 1);
        vm.prank(address(v));
        y.settle(FIRST, SECOND, 0);
        assertEq(uint256(vm.load(address(y), keccak256(abi.encode(FIRST, uint256(4))))), D + 1);
    }

    /// the seeded index I = d at outside supply 2*RAY means ~d/2 units were minted per holder
    /// of RAY weight in one index step. via public allocation, minted m adds
    /// floor(m*RAY/outsideSupply) to the index, so index d needs cumulative minted ~ 2d while
    /// totalUnits only ever reached d+1: inconsistent with monotone unit growth unless an
    /// intervening write-off reset totalUnits while an account kept a pre-reset index.
    function test_writeOffPreservesStaleAccountIndex() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D);
        _map(y, 4, FIRST, 0);
        _map(y, 5, FIRST, D - 1);
        // a write-off requires before_ == 0 with totalUnits != 0: zero equity, zero funded.
        uint256[] memory input = new uint256[](14);
        input[6] = 2e38;
        input[7] = 0; // equity collapses
        v.configure(input);
        vm.prank(address(v));
        y.checkpoint(address(0), address(0));
        assertEq(y.epoch(), 1, "write-off bumps epoch");
        assertEq(y.totalUnits(), 0);
        assertEq(y.rewardIndex(), 0);
        // stale account: its epoch no longer matches, so its view is zeroed — the write-off
        // wipes account claims. an old accountIndex is ignored after the epoch bump.
        assertEq(y.balanceOf(FIRST), 0, "epoch mismatch zeroes the account");
    }

    /// so the only pre-write-off route to I = d with totalUnits = d+1 is a total that once
    /// matched the index growth (T ~ 2d+1) and then halved via startExit burns. probe the
    /// required burn precision: burns are min(T, committed + exiting) with
    /// exiting = floor(owned * shares / (wallet + shares)); landing totalUnits on exactly
    /// d+1 from 2d+1 requires a burn of exactly d, which needs a holder whose owned, wallet
    /// and escrowed shares align to that exact value.
    function test_exitBurnGranularity() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(2 * D + 1, D);
        // OLD holds everything: units = 2d+1 at current index.
        _map(y, 4, OLD, 2 * D + 1);
        _map(y, 5, OLD, D);
        vm.store(address(y), bytes32(uint256(9)), bytes32(uint256(0))); // epoch 0
        // OLD has wallet weight 1e18 and exits half its shares.
        v.mint(OLD, 1e18);
        vm.prank(address(v));
        (,, uint256 folded) = y.startExit(1, OLD, 5e17);
        emit log_named_uint("totalUnits after half exit", y.totalUnits());
        emit log_named_uint("folded", folded);
        // burned = floor((2d+1) * 5e17 / 1.5e18) = floor((2d+1)/3): coarse thirds, not d.
        assertTrue(y.totalUnits() != D + 1, "a generic exit does not land on d+1");
    }

}
