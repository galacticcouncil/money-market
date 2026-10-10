// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";

/// @notice empirical boundary search around the lazy-rescale unit excess. storage is seeded
/// like LeanLazyHistoryParityTest, so this measures the arithmetic surface of _allocate and
/// balanceOf only; it is not public-call reachability evidence.
///
/// mechanism: a rescale shifts totalUnits, rewardIndex, and each current-epoch account's
/// stored units and index down by 64 bits on next view. pending accrual
/// w * (I' - floor(p/d)) / RAY overcounts the shifted entitlement w * (I - p) / (RAY * d)
/// by up to w * (d - 1) / (RAY * d) units per account. stored units only shrink
/// (floor(u/d) + pending <= (u + w*(I-p)/RAY) shifted), so the excess is purely the
/// fractional re-accrual of pending units that a rescale had floored away.
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

    /// the established case: one 64-bit rescale leaves exactly one excess unit.
    function test_singleRescaleOneExcess() public {
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
        uint256 excess = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND) - y.totalUnits();
        assertEq(excess, 1, string.concat("excess ", vm.toString(excess), " total ", vm.toString(y.totalUnits())));
        vm.prank(address(v));
        y.settle(FIRST, SECOND, 0);
        assertEq(
            y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND), y.totalUnits() + 1,
            "settlement preserves the excess"
        );
    }

    /// the per-holder gain is bounded by pending units lost to the shift; the per-account
    /// totalUnits cap then truncates it. raising stale weight cannot push one holder's
    /// excess past totalUnits.
    function test_excessCappedByTotalUnitsPerHolder() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        // one holder carries all the stale weight: 2*RAY behind index D-1.
        v.mint(FIRST, 2 * RAY);
        _map(y, 4, OLD, D - 1);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _allocate(y, v);
        uint256 firstUnits = y.balanceOf(FIRST);
        uint256 excess = y.balanceOf(OLD) + firstUnits + y.balanceOf(SECOND) - y.totalUnits();
        assertLe(excess, 2, "one stale holder contributes at most its lost fraction (< 1 + eps)");
        assertLe(firstUnits, y.totalUnits(), "per-account cap binds");
    }

    /// a second rescale applied to an already-rescaled state can add another excess unit,
    /// but only because the first excess sits in stored units that the next shift floors down
    /// while fresh pending accrual rounds separately. measure the two-cycle total.
    function test_twoRescalesFromSeededState() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        _map(y, 4, OLD, D - 1);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _map(y, 5, SECOND, D - 1);
        _allocate(y, v);
        uint256 excess1 =
            y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND) - y.totalUnits();
        // second allocation: raise equity so another allocation mints; check whether the
        // rescale loop runs again (unitScale grows) and how the excess moves.
        uint256[] memory input = new uint256[](14);
        input[6] = 2;
        input[7] = 1e39;
        v.configure(input);
        _allocate(y, v);
        uint256 excess2 =
            y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND) - y.totalUnits();
        emit log_named_uint("unitScale", y.unitScale());
        emit log_named_uint("excess1", excess1);
        emit log_named_uint("excess2", excess2);
        assertGe(excess2, excess1, "later allocations never reduce the seeded excess");
    }

    /// fuzz: for arbitrary seeded totals/indices and two stale holders, the post-rescale
    /// excess stays within the per-rescale envelope floor(W * (d - 1) / (RAY * d)) + holders.
    function testFuzz_excessEnvelope(uint96 totalSeed, uint64 indexSeed, uint8 holdersSeed)
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
        uint256 sum =
            y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        if (sum > y.totalUnits()) {
            // envelope: at most one lost-fraction unit per stale holder, and never more than
            // holders * totalUnits because of the per-account cap.
            uint256 excess = sum - y.totalUnits();
            assertLe(excess, holders, "per-rescale excess bounded by stale-holder count");
            assertLe(sum, 3 * y.totalUnits() + holders, "per-account cap envelope");
        }
    }

    /// a wallet-weight floor cannot block the seeded rescale: at index I >= d the
    /// weight-implied claim floor outsideSupply * I / RAY stays far below totalUnits >> 64
    /// whenever outsideSupply << RAY, and stored units from exits are invisible to wallets.
    /// probe: even with every holder's weight in wallets, the shift still runs.
    function test_weightFloorCannotSeeTheSeededDeficit() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        v.mint(OLD, RAY);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        _map(y, 4, OLD, 0);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _map(y, 5, SECOND, D - 1);
        // weight-implied floor at I = d: 3*RAY*d/RAY = 3d vs totalUnits = d+1. wallets alone
        // already claim ~3x totalUnits, yet the pre-rescale view caps each holder at
        // totalUnits, so the stored accounting is still self-consistent. the shift runs:
        _allocate(y, v);
        assertEq(y.unitScale(), 64, "no wallet-only guard blocks this shift");
        // and because every holder's units now cap at the shifted total, the excess is
        // bounded by the cap, not removed:
        uint256 sum = y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
        emit log_named_uint("aggregate view", sum);
        emit log_named_uint("totalUnits", y.totalUnits());
        assertLe(sum, 3 * y.totalUnits(), "per-account cap is the only aggregate bound");
    }
}
