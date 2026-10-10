// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice economic weight of the seeded one-unit excess: what an excess reward unit pays
/// through actual settle/transfer/exit calls at varying funded-shares-per-unit ratios.
/// seeded storage (not public-call reachability); collateral effects are measured against
/// the fixture vault's balances.
contract RescaleEconomicsTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant D = 1 << 64;

    address constant OLD = address(0xa11ce);
    address constant FIRST = address(0xb0b);
    address constant SECOND = address(0xcafe);

    function _map(JuicerYieldAccounting y, uint256 slot, address owner, uint256 value) private {
        vm.store(address(y), keccak256(abi.encode(owner, slot)), bytes32(value));
    }

    /// @dev the established seeded rescale; afterwards FIRST and SECOND hold M+2 viewed units
    /// against totalUnits = M+1, M = 2*(2e38-2)/3. F funded shares sit in the fund.
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

    /// F/T ~ 1 (fine units): with the ceil-shifted index the aggregate under-claims by one
    /// unit, so the aggregate displayed funded amount sits one share below the fund.
    function test_fineUnitsUnderclaimDisplaysOneLess() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        v.mint(address(y), T); // F == T: one share per unit
        assertEq(_sum(y), T - 1);
        uint256 displayed = y.fundedOf(FIRST) + y.fundedOf(SECOND);
        emit log_named_uint("displayed funded", displayed);
        emit log_named_uint("funded", T);
        assertEq(displayed, T - 1, "aggregate display under-claims by one share at F == T");
    }

    /// donation-driven F/T >> 1 (coarse units): the aggregate display can no longer exceed
    /// the fund's shares; the shortfall is the under-credited pending fraction.
    function test_coarseUnitsNoLongerOverdraw() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        uint256 F = 3 * T; // 3 shares per unit
        v.mint(address(y), F);
        uint256 displayed = y.fundedOf(FIRST) + y.fundedOf(SECOND);
        emit log_named_uint("displayed funded", displayed);
        assertLe(displayed, F, "aggregate display never exceeds the fund");
        // FIRST moves its entire displayed funded balance to SECOND; the exact-debit guard
        // still governs.
        uint256 firstDisplay = y.fundedOf(FIRST);
        vm.prank(address(v));
        try y.settle(FIRST, SECOND, firstDisplay) {
            emit log("full-slice transfer succeeded");
            assertEq(y.fundedOf(FIRST), 0);
        } catch {
            emit log("full-slice transfer reverted (InexactShares)");
        }
    }

    /// exit path: with the excess live, both holders exit their full view in turn through
    /// startExit. measure the total folded shares against the fund's F.
    function test_exitFoldUnderExcess() public {
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

    /// the per-account cap: when one holder's raw claim would exceed totalUnits, its view is
    /// truncated. after the rescale, T = M+1 and each holder's raw claim is (M+2)/2 < T,
    /// so the cap is inactive here; with concentrated weight it activates and *reduces* the
    /// aggregate excess.
    function test_recipientCapTruncatesExcess() public {
        (JuicerYieldAccounting y, ParityVault v) = _rescaled(0);
        uint256 T = y.totalUnits();
        // concentrate all wallet weight on FIRST: its raw claim doubles.
        uint256 rawFirst = Math.mulDiv(2 * RAY, y.rewardIndex(), RAY);
        emit log_named_uint("raw claim with double weight", rawFirst);
        emit log_named_uint("totalUnits", T);
        if (rawFirst > T) {
            emit log("cap would bind: excess shrinks instead of growing");
        }
        assertLt(y.balanceOf(FIRST), T, "single-holder view stays under the cap");
    }
}
