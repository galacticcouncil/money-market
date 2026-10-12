// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice economic regression coverage for the corrected seeded rescale across
/// settle/transfer/exit calls and varying funded-shares-per-unit ratios.
contract RescaleEconomicsTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant D = 1 << 64;

    address constant OLD = address(0xa11ce);
    address constant FIRST = address(0xb0b);
    address constant SECOND = address(0xcafe);

    function _map(JuicerYieldAccounting y, uint256 slot, address owner, uint256 value) private {
        vm.store(address(y), keccak256(abi.encode(owner, slot)), bytes32(value));
    }

    /// @dev the original seeded counterexample after one corrected rescale.
    function _rescaled(uint256 funded) internal returns (JuicerYieldAccounting y, ParityVault v) {
        v = new ParityVault();
        y = new JuicerYieldAccounting(address(v));
        uint256[] memory input = new uint256[](14);
        input[6] = 2e38;
        input[7] = 2e38;
        v.configure(input);
        v.mint(FIRST, RAY);
        v.mint(SECOND, RAY);
        vm.store(address(y), bytes32(uint256(0)), bytes32(uint256(2)));
        vm.store(address(y), bytes32(uint256(2)), bytes32(D + 1));
        vm.store(address(y), bytes32(uint256(3)), bytes32(D));
        _map(y, 4, OLD, D - 1);
        _map(y, 5, OLD, D - 1);
        _map(y, 5, FIRST, D - 1);
        _map(y, 5, SECOND, D - 1);
        vm.prank(address(v));
        y.checkpoint(address(0), address(0));
        assertEq(y.unitScale(), 64);
        if (funded != 0) v.mint(address(y), funded); // donation raises F/T
    }

    function _sum(JuicerYieldAccounting y) private view returns (uint256) {
        return y.balanceOf(OLD) + y.balanceOf(FIRST) + y.balanceOf(SECOND);
    }

    /// F/T = 1: aggregate displayed funded claims stay within the fund.
    function test_fineUnitsStayFunded() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        v.mint(address(y), T); // F == T: one share per unit
        assertEq(_sum(y), T - 1);
        uint256 displayed = y.fundedOf(FIRST) + y.fundedOf(SECOND);
        emit log_named_uint("displayed funded", displayed);
        emit log_named_uint("funded", T);
        assertEq(displayed, T - 1, "aggregate display stays below funded");
    }

    /// donation-driven F/T = 3 remains bounded and a full displayed slice can move exactly.
    function test_coarseUnitsStayFundedAndSpendable() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        uint256 F = 3 * T; // 3 shares per unit
        v.mint(address(y), F);
        uint256 displayed = y.fundedOf(FIRST) + y.fundedOf(SECOND);
        emit log_named_uint("displayed funded", displayed);
        emit log_named_uint("funded headroom", F - displayed);
        assertLe(displayed, F, "aggregate display stays within funded shares");
        // FIRST tries to move its entire displayed funded balance to SECOND.
        uint256 firstDisplay = y.fundedOf(FIRST);
        vm.prank(address(v));
        y.settle(FIRST, SECOND, firstDisplay);
        assertEq(y.fundedOf(FIRST), 0);
    }

    /// both holders exit their full view in turn through startExit; folds and residue conserve F.
    function test_exitFoldConservesFund() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        uint256 F = 2 * T;
        v.mint(address(y), F);
        // FIRST exits everything: its units burn pro rata, folding funded shares to the vault.
        uint256 firstUnits = y.balanceOf(FIRST);
        vm.prank(address(v));
        (,, uint256 foldedFirst) = y.startExit(1, FIRST, RAY);
        emit log_named_uint("first units", firstUnits);
        emit log_named_uint("folded first", foldedFirst);
        emit log_named_uint("totalUnits after", y.totalUnits());
        // SECOND exits what's left of its view.
        uint256 secondUnits = y.balanceOf(SECOND);
        vm.prank(address(v));
        (,, uint256 foldedSecond) = y.startExit(2, SECOND, RAY);
        emit log_named_uint("second units", secondUnits);
        emit log_named_uint("folded second", foldedSecond);
        emit log_named_uint("fund shares left", v.balanceOf(address(y)));
        assertEq(foldedFirst + foldedSecond + v.balanceOf(address(y)), F,
            "folds and residue conserve the fund's shares");
    }

    /// concentrating wallet weight still cannot create an aggregate unit overclaim.
    function test_recipientConcentrationStaysWithinTotal() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        // concentrate all wallet weight on FIRST: its raw claim doubles.
        uint256 rawFirst = Math.mulDiv(2 * RAY, y.rewardIndex(), RAY);
        emit log_named_uint("raw claim with double weight", rawFirst);
        emit log_named_uint("totalUnits", T);
        assertGt(rawFirst, T);
        vm.prank(SECOND);
        v.transfer(FIRST, RAY);
        assertLe(y.balanceOf(FIRST), T, "concentrated view remains capped");
        assertEq(y.balanceOf(SECOND), 0);
        assertLe(_sum(y), T, "aggregate view stays within totalUnits");
    }
}
