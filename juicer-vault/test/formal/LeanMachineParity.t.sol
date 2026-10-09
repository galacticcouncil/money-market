// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {JuicerMainDebt} from "../../src/JuicerMainDebt.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";
import {LeanCoverageParityTest, ParityQueue} from "./LeanCoverageParity.t.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HistoryQueue is ParityQueue {
    function observeSettlement(uint256 repaid, uint256 settled) external {
        redemptions[0].repaid = repaid;
        redemptions[0].collateralSettled = settled;
    }
}

contract MachineArithmetic {
    function calculate(uint256 op, uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        if (op == 0) return a + b;
        if (op == 1) return a - b;
        if (op == 2) return a * b;
        if (op == 3) return a / b;
        if (op == 4) return Math.ceilDiv(a, b);
        if (op == 5) return Math.mulDiv(a, b, d);
        if (op == 6) return Math.mulDiv(a, b, d, Math.Rounding.Up);
        return a >> b;
    }
}

contract LeanMachineParityTest is Test {
    string internal machine = vm.readFile("formal/machine-vectors.json");

    function _result(bool ok, bytes memory data, uint256 code, uint256 value) internal pure {
        if (code == 0) {
            assertTrue(ok, "Lean expected success");
            assertEq(abi.decode(data, (uint256)), value, "checked result");
        } else {
            assertFalse(ok, "Lean expected revert");
            bytes memory expected = code == 3
                ? abi.encodeWithSignature("Error(string)", "Math: mulDiv overflow")
                : abi.encodeWithSignature("Panic(uint256)", code == 1 ? 0x11 : 0x12);
            assertEq(data, expected, "checked revert data");
        }
    }

    function test_leanUint256BoundaryVectors() public {
        MachineArithmetic target = new MachineArithmetic();
        uint256 count = vm.parseJsonUint(machine, ".arithmeticCount");
        for (uint256 i; i < count; ++i) {
            uint256[] memory r = vm.parseJsonUintArray(machine, string.concat(".arithmetic[", vm.toString(i), "]"));
            (bool ok, bytes memory data) = address(target).staticcall(
                abi.encodeCall(target.calculate, (r[0], r[1], r[2], r[3])));
            _result(ok, data, r[4], r[5]);
        }
    }

    function test_leanAccountOverflowAndEpochVectors() public {
        uint256 count = vm.parseJsonUint(machine, ".accountsCount");
        address owner = address(0xa11ce);
        for (uint256 i; i < count; ++i) {
            uint256[] memory r = vm.parseJsonUintArray(machine, string.concat(".accounts[", vm.toString(i), "]"));
            ParityVault v = new ParityVault();
            JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
            v.mint(owner, r[8]);
            vm.store(address(y), bytes32(uint256(2)), bytes32(r[0]));
            vm.store(address(y), bytes32(uint256(3)), bytes32(r[1]));
            vm.store(address(y), bytes32(uint256(10)), bytes32(r[2]));
            vm.store(address(y), bytes32(uint256(13)), bytes32(r[3]));
            vm.store(address(y), keccak256(abi.encode(owner, uint256(4))), bytes32(r[4]));
            vm.store(address(y), keccak256(abi.encode(owner, uint256(5))), bytes32(r[5]));
            vm.store(address(y), keccak256(abi.encode(owner, uint256(11))), bytes32(r[6]));
            vm.store(address(y), keccak256(abi.encode(owner, uint256(14))), bytes32(r[7]));
            (bool ok, bytes memory data) = address(y).staticcall(abi.encodeCall(y.balanceOf, (owner)));
            _result(ok, data, r[9], r[10]);
        }
    }

    function test_leanBackingOverflowVectors() public {
        uint256 count = vm.parseJsonUint(machine, ".backingCount");
        for (uint256 i; i < count; ++i) {
            uint256[] memory r = vm.parseJsonUintArray(machine, string.concat(".backing[", vm.toString(i), "]"));
            ParityVault v = new ParityVault();
            JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
            v.configureFunding(r[0], r[1], r[2], r[3]);
            (bool ok, bytes memory data) = address(y).staticcall(abi.encodeCall(y.requiredSourceBacking, ()));
            _result(ok, data, r[4], r[5]);
        }
    }
}

contract LeanOrchestrationParityTest is LeanCoverageParityTest {
    string internal machine = vm.readFile("formal/machine-vectors.json");

    function test_leanRepaymentRetryVectors() public {
        uint256 count = vm.parseJsonUint(machine, ".retriesCount");
        for (uint256 i; i < count; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256[] memory r = vm.parseJsonUintArray(machine, string.concat(".retries[", vm.toString(i), "]"));
            JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
            hollarDebt.mint(address(vault), 100);
            vm.prank(address(vault)); ledger.borrowed(0);
            hollar.mint(address(this), r[0]);
            hollar.approve(address(ledger), r[0]);
            ledger.fundPosition(0, r[0]);
            uint256 loss = r[2] - r[3];
            pool.setDebtRounding(0, loss);
            pool.setRepayLimit(r[2] < r[1] ? r[2] : type(uint256).max);
            vm.prank(address(vault));
            (uint256 paid,, uint256 reduced) = ledger.repay(0, r[1], 0);
            assertEq(paid, r[2] + r[5], "retry paid");
            assertEq(reduced, r[3] + (r[5] > loss ? r[5] - loss : 0), "retry reduction");
            (,, uint256 cash,,) = ledger.positions(0);
            assertEq(cash + paid, r[0], "retry cash conservation");
            vm.revertToStateAndDelete(snapshot);
        }
    }

    function _historyState(HistoryQueue q, uint256[] memory r, uint256 offset) internal view {
        (, uint256 shares, uint256 owed, uint256 debt,, uint256 repaid, uint256 settled, uint256 burned, bool active) = q.redemptions(0);
        assertEq(shares, r[offset]); assertEq(owed, r[offset + 1]); assertEq(debt, r[offset + 2]);
        assertEq(repaid, r[offset + 3]); assertEq(settled, r[offset + 4]); assertEq(burned, r[offset + 5]);
        assertEq(q.claimedCollateral(0), r[offset + 6]); assertEq(active, r[offset + 7] != 0);
        assertEq(q.totalQueuedShares(), shares - burned);
        assertEq(q.totalQueuedCollateral(), owed - q.claimedCollateral(0));
    }

    function test_leanRepeatedPartialClaims() public {
        uint256 count = vm.parseJsonUint(machine, ".historiesCount");
        for (uint256 i; i < count; ++i) {
            uint256[] memory r = vm.parseJsonUintArray(machine, string.concat(".histories[", vm.toString(i), "]"));
            HistoryQueue q = new HistoryQueue();
            MockERC20 token = new MockERC20("claim", "claim", 18);
            q.seed(r, OWNER, IERC20(address(token)), address(source));
            token.mint(address(q), r[1]);
            for (uint256 phase = 8; phase <= 40; phase += 16) {
                q.observeSettlement(r[phase + 3], r[phase + 4]);
                vm.prank(OWNER); q.claim(0, RECEIVER);
                _historyState(q, r, phase + 8);
            }
            assertEq(token.balanceOf(RECEIVER), r[1]);
            vm.expectRevert(CollateralVault.RequestNotActive.selector);
            q.claim(0, RECEIVER);
        }
    }

    function test_claimOverflowRollsBackEarlierWrites() public {
        HistoryQueue q = new HistoryQueue();
        MockERC20 token = new MockERC20("claim", "claim", 18);
        uint256[] memory r = new uint256[](8);
        r[0] = type(uint256).max; r[1] = 4; r[2] = 2; r[3] = 1; r[4] = 2; r[7] = 1;
        q.seed(r, OWNER, IERC20(address(token)), address(source));
        token.mint(address(q), 4);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        q.claim(0, RECEIVER);
        _historyState(q, r, 0);
        assertEq(token.balanceOf(address(q)), 4);
        assertEq(token.balanceOf(RECEIVER), 0);
    }

    function _batchState(JuicerMainDebt ledger, uint256[] memory r, uint256 offset) internal view {
        uint256 credited;
        uint256 remaining;
        for (uint256 key; key <= r[1]; ++key) {
            (,, uint256 cash, uint256 pending,) = ledger.positions(key);
            credited += cash;
            if (key != 0) remaining += pending;
        }
        remaining += ledger.activeSourceRemaining();
        assertEq(credited, r[offset + 1], "batch credited");
        assertEq(remaining, r[5] - r[offset + 1] - r[offset + 2], "batch remaining");
        assertEq(ledger.sourceOutstanding(), remaining, "batch source outstanding");
        assertEq(ledger.unallocatedSource(), r[offset + 5], "late source cash");
        assertEq(ledger.unallocatedCost(), r[offset + 6], "late source cost");
        assertEq(ledger.ownedCash(), credited + ledger.unallocatedSource(), "cash partition");
    }

    function test_leanResumableBatchesWithLateReceipts() public {
        uint256 count = vm.parseJsonUint(machine, ".batchesCount");
        for (uint256 n; n < count; ++n) {
            uint256 snapshot = vm.snapshotState();
            uint256[] memory r = vm.parseJsonUintArray(machine, string.concat(".batches[", vm.toString(n), "]"));
            JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
            vm.startPrank(address(vault));
            ledger.expectDelever(r[2], r[2]);
            for (uint256 i; i < r[1]; ++i) {
                uint256 weight = (i * 7 + n * 3) % 23;
                ledger.startExit(i, OWNER, 1, 1, weight, weight, 0);
            }
            vm.stopPrank();
            vm.mockCall(address(source), abi.encodeWithSelector(source.unwindExecutionCost.selector, address(vault)), abi.encode(r[4]));
            _credit(ledger, r[3]);
            _batchState(ledger, r, 6);
            vm.prank(address(vault));
            vm.expectRevert(JuicerMainDebt.OutstandingDebt.selector);
            ledger.startExit(r[1], RECEIVER, 1, 1, 13, 13, 0);
            vm.mockCall(address(source), abi.encodeWithSelector(source.unwindExecutionCost.selector, address(vault)), abi.encode(r[4] + 9));
            _credit(ledger, 17);
            _batchState(ledger, r, 13);
            if (r[17] != 0) {
                _credit(ledger, 0);
                _batchState(ledger, r, 20);
            }
            vm.clearMockedCalls();
            vm.revertToStateAndDelete(snapshot);
        }
    }

    function test_scaledRepaymentRetryUsesOnlyOwnCash() public {
        JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
        hollarDebt.mint(address(vault), 100);
        vm.prank(address(vault)); ledger.borrowed(0);
        hollar.mint(address(this), 50);
        hollar.approve(address(ledger), 50);
        ledger.fundPosition(0, 50);
        pool.setDebtRounding(0, 1);
        vm.prank(address(vault));
        (uint256 paid,, uint256 reduced) = ledger.repay(0, 20, 0);
        assertEq(paid, 23);
        assertEq(reduced, 21);
        (,, uint256 cash,,) = ledger.positions(0);
        assertEq(cash + paid, 50);
        assertEq(ledger.ownedCash(), cash);
    }

    function test_liquidityLimitedRepaymentDoesNotRetry() public {
        JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
        hollarDebt.mint(address(vault), 100);
        vm.prank(address(vault)); ledger.borrowed(0);
        hollar.mint(address(this), 50);
        hollar.approve(address(ledger), 50);
        ledger.fundPosition(0, 50);
        pool.setDebtRounding(0, 1);
        pool.setRepayLimit(7);
        vm.prank(address(vault));
        (uint256 paid,, uint256 reduced) = ledger.repay(0, 20, 0);
        assertEq(paid, 7);
        assertEq(reduced, 6);
    }

    function test_failedSourceReceiptRollsBackTokenTransferAndCheckpoint() public {
        JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
        vm.prank(address(vault)); ledger.expectDelever(100, 100);
        hollar.mint(address(vault), 101);
        vm.prank(address(vault)); hollar.approve(address(ledger), 101);
        vm.mockCall(address(source), abi.encodeWithSelector(source.unwindExecutionCost.selector, address(vault)), abi.encode(1));
        vm.prank(address(vault));
        vm.expectRevert(JuicerMainDebt.TransferMismatch.selector);
        ledger.creditSource(101);
        assertEq(hollar.balanceOf(address(vault)), 101);
        assertEq(hollar.balanceOf(address(ledger)), 0);
        assertEq(hollar.allowance(address(vault), address(ledger)), 101);
        assertEq(ledger.sourceCostCheckpoint(), 0);
        assertEq(ledger.ownedCash(), 0);
        assertEq(ledger.unallocatedSource(), 0);
        assertEq(ledger.unallocatedCost(), 0);
        assertEq(ledger.sourceOutstanding(), 100);
    }

    function test_borrowOverflowLeavesLedgerUntouched() public {
        JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
        vm.mockCall(address(hollarDebt), abi.encodeCall(hollarDebt.balanceOf, (address(vault))),
            abi.encode(type(uint256).max / 1e18 + 1));
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        ledger.borrowed(0);
        assertEq(ledger.totalUnits(), 0);
        (uint256 units, uint256 principal,,,) = ledger.positions(0);
        assertEq(units, 0);
        assertEq(principal, 0);
    }
}
