// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev stands in for a consumer contract (the SubLoop) holding the lane
contract AsyncConsumer {
    ExecutionController public immutable control;

    constructor(ExecutionController control_) {
        control = control_;
    }

    function consumeAsync(address tokenIn, address tokenOut, uint256 amount, uint256 fairOut, uint64 nonce)
        external returns (uint256)
    {
        return control.consumeAsync(tokenIn, tokenOut, amount, fairOut, nonce);
    }

    function prepareAsync(address tokenIn, address tokenOut, uint256 wanted, uint256 fairOut, uint64 nonce)
        external returns (uint256, uint256)
    {
        return control.prepareAsync(tokenIn, tokenOut, wanted, fairOut, nonce);
    }

    function consume(address tokenIn, address tokenOut, uint256 amount, uint256 fairOut) external returns (uint256) {
        return control.consume(tokenIn, tokenOut, amount, fairOut);
    }

    function recordAsync(bytes32 key, uint64 nonce, uint256 output) external {
        control.recordAsync(key, nonce, output);
    }
}

/// @notice two-phase lanes: an intent is charged at submit and closed by its fill or refund.
contract ExecutionAsyncTest is Test {
    ExecutionController control;
    AsyncConsumer consumer;
    AsyncConsumer other;
    MockERC20 hollar;
    MockERC20 aPrime;
    bytes32 constant ENTRY = keccak256("entry");
    bytes32 constant UNWIND = keccak256("unwind");
    bytes32 entryLane;
    bytes32 exitLane;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        control = new ExecutionController(address(this), 60, 5);
        consumer = new AsyncConsumer(control);
        other = new AsyncConsumer(control);
        control.configureBudget(ENTRY, address(hollar), 5000e18, 1e18, uint64(block.timestamp + 30 days));
        control.configureBudget(UNWIND, address(aPrime), 5000e6, 1e6, uint64(block.timestamp + 30 days));
        control.configureLimit(address(consumer), address(hollar), address(aPrime), ENTRY, 10e18, 2500e18);
        control.configureLimit(address(consumer), address(aPrime), address(hollar), UNWIND, 1e6, 2500e6);
        entryLane = control.lane(address(consumer), address(hollar), address(aPrime));
        exitLane = control.lane(address(consumer), address(aPrime), address(hollar));
        control.configurePrice(entryLane, 10, false);
        control.configurePrice(exitLane, 10, true);
        control.configureAsync(entryLane, true);
        control.configureAsync(exitLane, true);
    }

    function _pending(bytes32 key) internal view returns (address who, uint64 nonce, uint256 minimum) {
        (who, nonce, minimum) = control.pendingAsync(key);
    }

    function test_asyncConsumeChargesBudgetAndPriceCapWithoutCallerQuote() public {
        assertEq(control.caller(), address(0), "outside execute");
        vm.expectRevert(ExecutionController.QuoteRequired.selector);
        consumer.consume(address(hollar), address(aPrime), 1000e18, 940e6);

        uint256 minimum = consumer.consumeAsync(address(hollar), address(aPrime), 1000e18, 940e6, 7);
        assertEq(minimum, 939_060_000, "10 bp price cap, rounded up");
        (address who, uint64 nonce, uint256 stored) = _pending(entryLane);
        assertEq(who, address(consumer));
        assertEq(nonce, 7);
        assertEq(stored, minimum, "minimum kept for the record");
        (,,, uint128 credit,,) = control.budgets(ENTRY);
        assertEq(credit, 4000e18, "budget charged at submit");
        (, uint64 nextAt, uint256 lastBlock) = control.pacing(ENTRY);
        assertEq(nextAt, block.timestamp);
        assertEq(lastBlock, block.number);
    }

    function test_asyncOneInFlightPerLane() public {
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 1);
        vm.roll(block.number + 1);
        vm.expectRevert(ExecutionController.AsyncPending.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 2);
        // the other lane is independent
        aPrime.mint(address(consumer), 100e6);
        (uint256 amount,) = consumer.prepareAsync(address(aPrime), address(hollar), 100e6, 100e18, 3);
        assertEq(amount, 100e6);
        consumer.recordAsync(entryLane, 1, 94e6);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 2);
        (, uint64 nonce,) = _pending(entryLane);
        assertEq(nonce, 2, "lane reopened after the record");
    }

    function test_recordAsyncChecksNonceConsumerAndMinimum() public {
        uint256 minimum = consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 5);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        consumer.recordAsync(entryLane, 4, minimum);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        other.recordAsync(entryLane, 5, minimum);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        control.recordAsync(entryLane, 5, minimum);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        consumer.recordAsync(entryLane, 5, minimum - 1);
        consumer.recordAsync(entryLane, 5, minimum);
        (address who, uint64 nonce,) = _pending(entryLane);
        assertEq(who, address(0));
        assertEq(nonce, 0);
        vm.expectRevert(ExecutionController.InvalidQuote.selector);
        consumer.recordAsync(entryLane, 5, minimum);
    }

    function test_recordAsyncAcceptsARefund() public {
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 9);
        consumer.recordAsync(entryLane, 9, 0);
        (, uint64 nonce,) = _pending(entryLane);
        assertEq(nonce, 0, "expired or removed intent closes with no fill");
        (,,, uint128 credit,,) = control.budgets(ENTRY);
        assertEq(credit, 4900e18, "a refund does not return budget");
    }

    function test_asyncNeedsAnEnabledLaneAndANonce() public {
        control.configureAsync(entryLane, false);
        vm.expectRevert(ExecutionController.InvalidPolicy.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 1);
        control.configureAsync(entryLane, true);
        vm.expectRevert(ExecutionController.InvalidPolicy.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 0);
        bytes32 unconfigured = control.lane(address(other), address(hollar), address(aPrime));
        vm.expectRevert(ExecutionController.InvalidPolicy.selector);
        control.configureAsync(unconfigured, true);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        control.configureAsync(entryLane, false);
    }

    function test_asyncKeepsSizePacingAndExpiry() public {
        vm.expectRevert(ExecutionController.TradeSize.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 9e18, 9e6, 1);
        vm.expectRevert(ExecutionController.TradeSize.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 2501e18, 2400e6, 1);
        control.configurePacing(ENTRY, 60);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 1);
        consumer.recordAsync(entryLane, 1, 94e6);
        assertEq(control.available(address(consumer), address(hollar), address(aPrime)), 0,
            "an async submit does not open its group to more trades in the block");
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 59);
        vm.expectRevert(ExecutionController.TradeSize.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 2);
        vm.warp(block.timestamp + 1);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 2);
        consumer.recordAsync(entryLane, 2, 94e6);
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);
        vm.expectRevert(ExecutionController.TradeSize.selector);
        consumer.consumeAsync(address(hollar), address(aPrime), 100e18, 94e6, 3);
        aPrime.mint(address(consumer), 100e6);
        (uint256 amount,) = consumer.prepareAsync(address(aPrime), address(hollar), 100e6, 100e18, 4);
        assertEq(amount, 100e6, "expiry halts new risk, not the flagged exit lane");
    }

    function test_prepareAsyncFitsLikePrepare() public {
        aPrime.mint(address(consumer), 3e6);
        (uint256 amount, uint256 minimum) = consumer.prepareAsync(address(aPrime), address(hollar), 0, 1e18, 1);
        assertEq(amount, 0);
        assertEq(minimum, 0);
        (amount, minimum) = consumer.prepareAsync(address(aPrime), address(hollar), 0.5e6, 0.5e18, 1);
        assertEq(amount, 1e6, "a tail below the lane minimum sells the minimum");
        assertEq(minimum, 0.999e18, "fair output scales with the fitted amount");
        consumer.recordAsync(exitLane, 1, 0.999e18);
        vm.roll(block.number + 1);
        (amount,) = consumer.prepareAsync(address(aPrime), address(hollar), 10e6, 10e18, 2);
        assertEq(amount, 3e6, "capped at the consumer's balance");
    }
}
