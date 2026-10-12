// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";

/// @notice regression search around lazy-rescale rounding. storage is seeded like
/// LeanLazyHistoryParityTest, so this measures the arithmetic surface of _allocate and
/// balanceOf only; public-call traces are covered separately.
///
/// mechanism: a rescale shifts totalUnits, rewardIndex, and each current-epoch account's
/// stored units down by 64 bits on next view. indices shift upward with ceil division, capped
/// at the current reward index. this prevents fractional pending accrual discarded by the
/// rescale from being credited again.
contract RescaleAmplificationTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant D = 1 << 64;

    address constant OLD = address(0xa11ce);
    address constant FIRST = address(0xb0b);
    address constant SECOND = address(0xcafe);

    function _map(JuicerYieldAccounting y, uint256 slot, address owner, uint256 value) private {
        vm.store(address(y), keccak256(abi.encode(owner, slot)), bytes32(value));
    }

    function _seed(
        uint256 total,
        uint256 index,
        uint256 sourceShares,
        uint256 held,
        uint256 equity
    ) internal returns (JuicerYieldAccounting y, ParityVault v) {
        v = new ParityVault();
        y = new JuicerYieldAccounting(address(v));
        uint256[] memory input = new uint256[](14);
        input[6] = held;
        input[7] = equity;
        v.configure(input);
        vm.store(address(y), bytes32(uint256(0)), bytes32(sourceShares));
        vm.store(address(y), bytes32(uint256(2)), bytes32(total));
        vm.store(address(y), bytes32(uint256(3)), bytes32(index));
    }

    function _allocate(JuicerYieldAccounting y, ParityVault v) internal {
        vm.prank(address(v));
        y.checkpoint(address(0), address(0));
    }

    /// the original counterexample now finishes one unit below totalUnits.
    function test_singleRescaleDoesNotOverclaim() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        _map(y, 4, OLD, D - 1);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _map(y, 5, SECOND, D - 1);
        assertEq(
            y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND),
            y.totalUnits(),
            "seeded state must be exactly conserved"
        );
        _allocate(y, v);
        emit log_named_uint("totalUnits", y.totalUnits());
        emit log_named_uint("rewardIndex", y.rewardIndex());
        emit log_named_uint("sourceShares", y.sourceShares());
        assertEq(y.unitScale(), 64, string.concat("scale ", vm.toString(y.unitScale())));
        uint256 sum = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        assertEq(sum, y.totalUnits() - 1, "ceil-shifted indices remove the seeded excess");
        vm.prank(address(v));
        y.settle(FIRST, SECOND, 0);
        assertEq(
            y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND), y.totalUnits() - 1,
            "settlement preserves the aggregate bound"
        );
    }

    /// concentrated stale weight remains capped without creating aggregate excess.
    function test_concentratedWeightStaysWithinTotalUnits() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        // one holder carries all the stale weight: 2*RAY behind index D-1.
        v.mint(FIRST, 2 * RAY);
        _map(y, 4, OLD, D - 1);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _allocate(y, v);
        uint256 firstUnits = y.balanceOf(FIRST);
        uint256 sum = y.balanceOf(OLD) + firstUnits + y.balanceOf(SECOND);
        assertLe(sum, y.totalUnits(), "aggregate claims stay within totalUnits");
        assertLe(firstUnits, y.totalUnits(), "per-account cap binds");
    }

    /// this checks a later allocation, not a second rescale.
    function test_secondAllocationPreservesNoOverclaim() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        _map(y, 4, OLD, D - 1);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _map(y, 5, SECOND, D - 1);
        _allocate(y, v);
        uint256 sum1 = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        assertLe(sum1, y.totalUnits());
        // raise equity so another allocation mints and check the aggregate again.
        uint256[] memory input = new uint256[](14);
        input[6] = 2;
        input[7] = 1e39;
        v.configure(input);
        _allocate(y, v);
        uint256 sum2 = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        emit log_named_uint("unitScale", y.unitScale());
        emit log_named_uint("first aggregate", sum1);
        emit log_named_uint("second aggregate", sum2);
        assertEq(y.unitScale(), 64, "only one rescale exercised");
        assertLe(sum2, y.totalUnits());
    }

    /// fuzz: arbitrary seeded totals, indices and up to two stale holders do not overclaim.
    function testFuzz_noAggregateOverclaim(uint96 totalSeed, uint64 indexSeed, uint8 holdersSeed)
        public
    {
        uint256 total = D + uint256(totalSeed) % D;
        uint256 index = uint256(indexSeed);
        vm.assume(index >= 1);
        (JuicerYieldAccounting y, ParityVault v) = _seed(total, index, 2, 2e38, 2e38);
        uint256 holders = 1 + uint256(holdersSeed) % 2;
        v.mint(FIRST, RAY);
        if (holders == 2) v.mint(SECOND, RAY);
        _map(y, 5, FIRST, index - 1);
        if (holders == 2) _map(y, 5, SECOND, index - 1);
        _allocate(y, v);
        uint256 sum = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        assertLe(sum, y.totalUnits(), "ceil-shifted indices prevent aggregate overclaim");
    }

    /// an intentionally saturated seeded state checks that the per-account cap and ceil shift
    /// remain safe even when the pre-rescale aggregate view is not conserved.
    function test_saturatedWeightsDoNotOverclaimAfterShift() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        v.mint(OLD, RAY);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        _map(y, 4, OLD, 0);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _map(y, 5, SECOND, D - 1);
        // wallets alone imply about 3d units against totalUnits = d+1 before the per-account
        // caps. this is an arithmetic stress fixture, not a valid aggregate-conservation witness.
        _allocate(y, v);
        assertEq(y.unitScale(), 64, "saturated fixture reaches the shift");
        uint256 sum = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        emit log_named_uint("aggregate view", sum);
        emit log_named_uint("totalUnits", y.totalUnits());
        assertLe(sum, y.totalUnits(), "ceil-shifted indices preserve the aggregate bound");
    }
}
