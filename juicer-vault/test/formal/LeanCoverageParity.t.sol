// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "../PluggableYieldSource.t.sol";
import {JuicerMainDebt} from "../../src/JuicerMainDebt.sol";
import {ExecutionController} from "../../src/ExecutionController.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ParityFeeSink {
    IERC20 immutable token;
    uint256 public collected;
    constructor(IERC20 t) { token = t; }
    function collectSourceFee(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        collected += amount;
    }
}

contract ParityPolicy is ExecutionController {
    constructor() ExecutionController(msg.sender, 60, 5) {}
    function seed(uint256[] memory r, address consumer, address input, address output) external returns (bytes32 key) {
        bytes32 group = bytes32(uint256(1));
        budgets[group] = Budget(input, uint128(r[0]), uint128(r[1]), uint128(r[2]), uint64(r[3]), uint64(r[4]));
        key = lane(consumer, input, output);
        limits[key] = Limit(group, uint128(r[5]), uint128(r[6]));
        pacing[group] = Pacing(0, uint64(r[7]), r[8]);
        safetyLanes[key] = r[9] != 0;
    }
}

contract ParityConsumer {
    ExecutionController immutable controller;
    constructor(ExecutionController c) { controller = c; }
    function trade(uint256 amount, uint256 fair, uint256 expected) external {
        uint256 minimum = controller.consume(address(1), address(2), amount, fair);
        require(minimum == expected, "minimum differs from Lean");
        controller.record(address(1), address(2), minimum);
    }
}

contract ParityQueue is CollateralVault {
    function seed(uint256[] memory r, address owner, IERC20 token, address source_) external {
        yieldSource = IYieldSource(source_);
        collateral = token;
        redemptions[0] = Redemption(owner, r[0], r[1], r[2], 0, r[3], r[4], r[5], r[7] != 0);
        claimedCollateral[0] = r[6];
        totalQueuedCollateral = r[1] - r[6];
        totalQueuedShares = r[0] - r[5];
        _mint(address(this), totalQueuedShares);
    }
}

contract LeanCoverageParityTest is PluggableYieldSourceTest {
    string internal vectors = vm.readFile("formal/coverage-vectors.json");
    address constant OWNER = address(0xA11CE);
    address constant RECEIVER = address(0xB0B);
    function _count(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(vectors, string.concat(".", key, "Count"));
    }
    function _row(string memory key, uint256 i) internal view returns (uint256[] memory) {
        return vm.parseJsonUintArray(vectors, string.concat(".", key, "[", vm.toString(i), "]"));
    }
    function _assertPosition(JuicerMainDebt ledger, uint256 key, uint256[] memory r, uint256 offset) internal view {
        (uint256 units, uint256 principal, uint256 cash, uint256 remaining,) = ledger.positions(key);
        assertEq(units, r[offset], "Main units"); assertEq(principal, r[offset + 1], "Main principal");
        assertEq(cash, r[offset + 2], "Main cash"); assertEq(remaining, r[offset + 3], "Main claim");
    }
    function _credit(JuicerMainDebt ledger, uint256 amount) internal {
        hollar.mint(address(vault), amount);
        vm.startPrank(address(vault));
        hollar.approve(address(ledger), amount);
        ledger.creditSource(amount);
        vm.stopPrank();
    }
    function test_leanMainBorrowExitRepay() public {
        for (uint256 i; i < _count("main"); ++i) {
            uint256 snap = vm.snapshotState();
            uint256[] memory r = _row("main", i);
            JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
            hollarDebt.mint(address(vault), r[0]);
            vm.prank(address(vault)); ledger.borrowed(0);
            hollarDebt.mint(address(vault), r[1]);
            vm.prank(address(vault)); ledger.borrowed(r[0]);
            hollar.mint(address(this), r[2]); hollar.approve(address(ledger), r[2]); ledger.fundPosition(0, r[2]);
            vm.prank(address(vault)); ledger.startExit(0, OWNER, r[3], r[4], 0, 0, 0);
            _assertPosition(ledger, 0, r, 5); _assertPosition(ledger, 1, r, 9);
            assertEq(ledger.totalUnits(), r[13]);
            vm.prank(address(vault)); (uint256 paid,, uint256 reduced) = ledger.repay(1, type(uint256).max, 0);
            assertEq(paid, r[14]); assertEq(reduced, r[14]);
            _assertPosition(ledger, 1, r, 15); assertEq(ledger.totalUnits(), r[19]);
            vm.revertToStateAndDelete(snap);
        }
    }
    function test_leanSourceCashAndCostBatch() public {
        for (uint256 i; i < _count("batch"); ++i) {
            uint256 snap = vm.snapshotState();
            uint256[] memory r = _row("batch", i);
            JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
            vm.startPrank(address(vault));
            ledger.startExit(0, OWNER, 1, 2, r[0], r[0], 0);
            ledger.startExit(1, RECEIVER, 1, 1, r[1], r[1], 0);
            vm.stopPrank();
            vm.mockCall(address(source), abi.encodeWithSelector(source.unwindExecutionCost.selector, address(vault)), abi.encode(r[3]));
            _credit(ledger, r[2]);
            (,,uint256 cash1,uint256 remaining1,) = ledger.positions(1);
            (,,uint256 cash2,uint256 remaining2,) = ledger.positions(2);
            assertEq(cash1, r[4]); assertEq(remaining1, r[0] - r[4] - r[5]);
            assertEq(cash2, r[6]); assertEq(remaining2, r[1] - r[6] - r[7]);
            assertEq(ledger.ownedCash(), cash1 + cash2); assertEq(hollar.balanceOf(address(ledger)), cash1 + cash2);
            assertEq(ledger.sourceOutstanding(), remaining1 + remaining2);
            vm.clearMockedCalls(); vm.revertToStateAndDelete(snap);
        }
    }
    function test_leanVestedFeeAfterCosts() public {
        for (uint256 i; i < _count("fees"); ++i) {
            uint256 snap = vm.snapshotState();
            uint256[] memory r = _row("fees", i);
            ParityFeeSink sink = new ParityFeeSink(IERC20(address(hollar)));
            vm.mockCall(address(vault), abi.encodeWithSelector(vault.feeController.selector), abi.encode(address(sink)));
            JuicerMainDebt ledger = new JuicerMainDebt(address(vault));
            vm.prank(address(vault)); ledger.startExit(0, OWNER, 1, 1, r[0], r[1], r[2]);
            (uint256 yieldLeft, uint256 feeLeft) = ledger.sourceFees(1);
            assertEq(yieldLeft, r[4]); assertEq(feeLeft, r[5]);
            vm.mockCall(address(source), abi.encodeWithSelector(source.unwindExecutionCost.selector, address(vault)), abi.encode(r[3]));
            _credit(ledger, r[0] - r[3]);
            assertEq(sink.collected(), r[6]); assertEq(ledger.sourceFeeReserve(), 0);
            (,,uint256 cash,,) = ledger.positions(1);
            assertEq(cash + sink.collected() + r[3], r[0]);
            vm.clearMockedCalls(); vm.revertToStateAndDelete(snap);
        }
    }
    function test_leanPolicyAvailabilityAndRefresh() public {
        for (uint256 i; i < _count("policy"); ++i) {
            uint256[] memory r = _row("policy", i);
            ParityPolicy c = new ParityPolicy();
            c.seed(r, address(this), address(1), address(2));
            vm.warp(r[10]); vm.roll(r[11]);
            assertEq(c.available(address(this), address(1), address(2)), r[12]);
            assertEq(c.availableSafety(address(this), address(1), address(2)), r[13]);
            c.configureBudget(bytes32(uint256(1)), address(1), 800, uint128(r[1]), uint64(r[10] + 100));
            (,,,uint128 credit,,) = c.budgets(bytes32(uint256(1)));
            assertEq(credit, r[15]);
        }
    }
    function test_leanQuoteTightensOracleFloor() public {
        for (uint256 i; i < _count("prices"); ++i) {
            uint256[] memory r = _row("prices", i);
            ExecutionController c = new ExecutionController(address(this), 60, 5);
            ParityConsumer consumer = new ParityConsumer(c);
            vm.roll(100); vm.setBlockhash(99, keccak256("quote"));
            c.configureBudget(bytes32(uint256(1)), address(1), 1000, 0, uint64(block.timestamp + 100));
            c.configureLimit(address(consumer), address(1), address(2), bytes32(uint256(1)), 1, 100);
            bytes32 key = c.lane(address(consumer), address(1), address(2));
            c.configurePrice(key, uint16(r[1]), false); c.configureAction(address(consumer), ParityConsumer.trade.selector, true);
            ExecutionController.Quote[] memory quotes = new ExecutionController.Quote[](1);
            quotes[0] = ExecutionController.Quote(key, r[4], r[2]);
            c.execute(address(consumer), abi.encodeCall(ParityConsumer.trade, (r[3], r[0], r[5])),
                99, keccak256("quote"), block.timestamp + 60, quotes);
            (,,,uint128 credit,,) = c.budgets(bytes32(uint256(1)));
            assertEq(credit, 1000 - r[3]);
        }
    }
    function test_leanPartialAndFinalClaims() public {
        for (uint256 i; i < _count("claims"); ++i) {
            uint256[] memory r = _row("claims", i);
            ParityQueue q = new ParityQueue(); MockERC20 token = new MockERC20("c", "c", 18);
            q.seed(r, OWNER, IERC20(address(token)), address(source)); token.mint(address(q), r[4]);
            uint256 amount = q.claim(0, RECEIVER);
            (,,,,,,uint256 settled,uint256 burned,bool active) = q.redemptions(0);
            assertEq(amount, r[16]); assertEq(settled, r[12]); assertEq(burned, r[13]); assertEq(active, r[15] != 0);
            assertEq(q.claimedCollateral(0), r[14]); assertEq(q.totalQueuedShares(), r[0] - r[13]);
            assertEq(token.balanceOf(OWNER), amount); assertEq(token.balanceOf(RECEIVER), 0);
        }
    }
    function test_leanQueueFifoAndWorkLimit() public {
        for (uint256 i; i < _count("queue"); ++i) {
            uint256 snap = vm.snapshotState();
            uint256[] memory r = _row("queue", i);
            eth.mint(address(this), 1e18); eth.approve(address(vault), 1e18); vault.deposit(1e18, address(this));
            vm.warp(90);
            for (uint256 j; j < 5; ++j) {
                vault.setWithdrawalDelay(uint32(r[2 + j] - 90)); vault.requestRedeem(1e15, address(this));
            }
            vm.warp(r[0]); vault.startUnwinds(r[1]); assertEq(vault.queueUnwind(), r[7]);
            vm.revertToStateAndDelete(snap);
        }
    }
}
