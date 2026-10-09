// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockIntentDispatch} from "./mocks/MockIntentDispatch.sol";

/// @notice ICE entries: the ramp submits HOLLAR→aPRIME intents; the lazy executor's callback (or a
///         permissionless reconcile) settles them. The intent mock at 0x0401 plays the pallet:
///         tests fill (solver), cleanup (expiry) or remove, then call `execute` as the loop.
contract IceIntentsTest is Test {
    MockERC20 hollar;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt;
    MockERC20 hollarDebt;
    MockERC20 aHollar;
    MockPool pool;
    SubLoop loop;
    MockIntentDispatch dispatch;

    uint256 constant SEED = 1_000e18;
    uint256 constant TARGET_HF = 1.05e18;
    /// router dry run at $1/$1: 1e6 aPRIME units per 1e18 HOLLAR
    uint256 constant ENTRY_RATE = 1e6;
    uint8 constant ENTRY = 1;
    uint8 constant WAITING = 1;
    uint8 constant FILLED = 2;
    uint8 constant RETURNED = 3;

    event IntentSettled(uint8 indexed kind, uint64 indexed nonce, uint256 amountOut);

    function setUp() public {
        vm.warp(1_800_000_000);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("debtPRIME", "dPRIME", 6);
        hollarDebt = new MockERC20("debtHOLLAR", "dHOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);

        pool = new MockPool();
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        // live PRIME is isolated: an aPRIME arrival is not collateral until the loop enables it
        pool.setIsolationMode(address(prime), true);

        loop = SubLoop(address(new ERC1967Proxy(address(new SubLoop()), abi.encodeCall(SubLoop.initialize,
            (address(pool), address(hollar), address(prime), address(aPrime), TARGET_HF, 1.10e18, address(this))))));

        vm.etch(DcaDispatch.DISPATCH, address(new MockIntentDispatch()).code);
        dispatch = MockIntentDispatch(payable(DcaDispatch.DISPATCH));
        dispatch.configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000); // 1% oracle floor
        loop.registerVault(address(this));
        loop.grantRole(loop.KEEPER_ROLE(), address(this));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        loop.configureIntents(600, 5);
    }

    // ── helpers ──

    function _deposit(uint256 amount) internal {
        hollar.mint(address(this), amount);
        hollar.approve(address(loop), amount);
        loop.deposit(amount);
    }

    function _pending()
        internal view returns (uint64 nonce, uint64 deadline, uint8 kind, uint256 amountIn, uint256 minOut)
    {
        (nonce, deadline, kind,, amountIn, minOut,,,) = loop.pendingIntent();
    }

    function _token(uint32 asset) internal view returns (address) {
        return asset == 222 ? address(hollar) : address(aPrime);
    }

    function _callback(uint128 id, uint256 amountOut) internal returns (bytes4) {
        MockIntentDispatch.Intent memory it = dispatch.intent(id);
        vm.prank(address(loop), address(loop));
        return loop.execute(address(loop), id, _token(it.assetIn), it.amountIn, _token(it.assetOut), amountOut, it.data);
    }

    /// solver fill at the oracle-priced AMM output less its 1 bp haircut, then the lazy executor
    function _resolve() internal returns (uint256 out) {
        uint128 id = dispatch.lastId();
        out = dispatch.quote(id, 1);
        dispatch.fill(id, out);
        assertEq(_callback(id, out), SubLoop.execute.selector, "ack is the receiver selector");
    }

    function _rampSteps(uint256 steps) internal {
        for (uint256 i; i < steps; ++i) {
            if (loop.pokeBorrowQuoted(ENTRY_RATE) == 0) break;
            _resolve();
        }
    }

    // ── entries ──

    function test_depositWaitsAsCashAndTheRampSendsItByIntent() public {
        _deposit(SEED);
        assertEq(hollar.balanceOf(address(loop)), SEED, "no swap at deposit");
        assertEq(loop.totalEquity(), 1_000e8);

        // no collateral yet: nothing to borrow, the idle seed goes out
        assertEq(loop.pokeBorrowQuoted(ENTRY_RATE), SEED);
        assertEq(hollar.balanceOf(address(loop)), 0, "the pallet holds the input");
        assertEq(loop.totalEquity(), 1_000e8, "in flight at oracle value");
        (uint64 nonce, uint64 deadline, uint8 kind, uint256 amountIn, uint256 minOut) = _pending();
        assertEq(nonce, 1);
        assertEq(kind, ENTRY);
        assertEq(amountIn, SEED);
        assertEq(deadline, (block.timestamp + 600) * 1000);
        // keeper floor 1000e6 less 1 bp + 5 bp drift beats the 1% oracle floor
        assertEq(minOut, 999.4e6);
        MockIntentDispatch.Intent memory it = dispatch.intent(dispatch.lastId());
        assertEq(it.owner, address(loop));
        assertEq(it.forward, address(loop));
        assertEq(it.amountOut, minOut);
        assertEq(it.data, abi.encode(ENTRY, uint64(1)));

        assertEq(loop.pokeBorrowQuoted(ENTRY_RATE), 0, "the next ramp step waits");
        assertEq(dispatch.counter(), 1);

        uint128 id = dispatch.lastId();
        uint256 out = dispatch.quote(id, 1);
        dispatch.fill(id, out);
        vm.expectEmit(true, true, false, true, address(loop));
        emit IntentSettled(ENTRY, 1, out);
        _callback(id, out);
        (,, kind,,) = _pending();
        assertEq(kind, 0, "settled");
        assertEq(aPrime.balanceOf(address(loop)), out);
        assertTrue(pool.usingAsCollateral(address(loop), address(prime)), "callback enables the collateral");
        assertEq(loop.totalEquity(), out * 1e2, "equity is the fill: the 1 bp haircut is the entry cost");
    }

    function test_intentRampReachesTargetHf() public {
        _deposit(SEED);
        _rampSteps(40);
        assertApproxEqRel(loop.healthFactor(), TARGET_HF, 0.03e18, "HF ~ 1.05");
        assertApproxEqRel(loop.totalEquity(), 1_000e8, 0.01e18, "equity ~ seed less haircuts");
        (uint256 collBase8,,,,,) = pool.getUserAccountData(address(loop));
        assertApproxEqRel(collBase8, 6_177e8, 0.03e18, "collateral ~6.18x");
        assertEq(dispatch.routerSells(), 0, "no router trades on the way in");
    }

    function test_submitKeepsEquityAndHfAboveTheFloor() public {
        _deposit(SEED);
        _rampSteps(2);
        uint256 equity = loop.totalEquity();
        uint256 borrowed = hollarDebt.balanceOf(address(loop));
        assertGt(loop.pokeBorrowQuoted(ENTRY_RATE), 0);
        assertGt(hollarDebt.balanceOf(address(loop)), borrowed, "borrowed for the entry");
        assertApproxEqAbs(loop.totalEquity(), equity, 1, "borrow and in-flight input cancel out");
        assertGe(loop.healthFactor(), TARGET_HF, "sized against current collateral only");
    }

    function test_fillBelowMinOutRejected() public {
        _deposit(SEED);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        uint128 id = dispatch.lastId();
        MockIntentDispatch.Intent memory it = dispatch.intent(id);
        (,,,, uint256 minOut) = _pending();
        dispatch.fill(id, minOut);
        vm.prank(address(loop), address(loop));
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.execute(address(loop), id, address(hollar), it.amountIn, address(aPrime), minOut - 1, it.data);
        (uint64 nonce,,,,) = _pending();
        assertEq(nonce, 1, "still in flight");
    }

    function test_missedCallbackThenReconcile() public {
        _deposit(SEED);
        _rampSteps(2);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        uint128 id = dispatch.lastId();
        (uint64 nonce,,,,) = _pending();
        uint256 equity = loop.totalEquity();
        uint256 out = dispatch.quote(id, 1);
        uint256 filled = equity - dispatch.intent(id).amountIn / 1e10 + out * 1e2;
        dispatch.fill(id, out);
        // the callback never comes: the fill already counts once, as collateral
        assertEq(loop.totalEquity(), filled, "no double count before reconcile");

        vm.prank(address(0xBEEF));
        vm.expectEmit(true, true, false, true, address(loop));
        emit IntentSettled(ENTRY, nonce, out);
        assertEq(loop.reconcile(), FILLED);
        (,, uint8 kind,,) = _pending();
        assertEq(kind, 0);
        assertEq(loop.totalEquity(), filled);

        // a late callback is acknowledged and changes nothing
        uint256 collateral = aPrime.balanceOf(address(loop));
        vm.recordLogs();
        assertEq(_callback(id, out), SubLoop.execute.selector);
        assertEq(vm.getRecordedLogs().length, 0, "no-op");
        assertEq(aPrime.balanceOf(address(loop)), collateral);
        assertEq(loop.reconcile(), 0, "nothing in flight");
        assertGt(loop.pokeBorrowQuoted(ENTRY_RATE), 0, "the ramp moves on");
    }

    function test_expiryThenReconcile() public {
        _deposit(SEED);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        uint128 id = dispatch.lastId();
        (, uint64 deadline,,,) = _pending();
        assertEq(loop.reconcile(), WAITING);
        vm.warp(deadline / 1000);
        uint256 late = dispatch.quote(id, 1);
        vm.expectRevert("MockIntentDispatch: expired");
        dispatch.fill(id, late);
        dispatch.cleanup(id);
        assertEq(loop.totalEquity(), 1_000e8, "refund counts once, as cash");

        assertEq(loop.reconcile(), RETURNED);
        (,, uint8 kind,,) = _pending();
        assertEq(kind, 0);
        assertEq(hollar.balanceOf(address(loop)), SEED);
        assertEq(loop.pokeBorrowQuoted(ENTRY_RATE), SEED, "the refund goes out again");
    }

    function test_wrongSenderOwnerNonceOrAssetRejected() public {
        _deposit(SEED);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        uint128 id = dispatch.lastId();
        MockIntentDispatch.Intent memory it = dispatch.intent(id);
        uint256 out = dispatch.quote(id, 1);
        dispatch.fill(id, out);

        vm.prank(address(0xBEEF), address(0xBEEF));
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.execute(address(loop), id, address(hollar), it.amountIn, address(aPrime), out, it.data);

        vm.prank(address(loop), address(loop));
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.execute(address(0xBEEF), id, address(hollar), it.amountIn, address(aPrime), out, it.data);

        vm.prank(address(loop), address(loop));
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.execute(address(loop), id, address(hollar), it.amountIn, address(aPrime), out, abi.encode(ENTRY, uint64(2)));

        vm.prank(address(loop), address(loop));
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.execute(address(loop), id, address(hollar), it.amountIn, address(hollar), out, it.data);

        (uint64 nonce,,,,) = _pending();
        assertEq(nonce, 1, "nothing settled");
        assertEq(_callback(id, out), SubLoop.execute.selector);
    }

    function test_vaultFlowsWhileInFlightAreNotMistakenForARefund() public {
        _deposit(SEED);
        _rampSteps(2);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        (,,, uint256 amountIn,) = _pending();
        uint256 equity = loop.totalEquity();
        // a vault deposit larger than the in-flight input lands as cash
        _deposit(amountIn * 2);
        assertEq(loop.reconcile(), WAITING, "own deposit is not the refund");
        assertApproxEqAbs(loop.totalEquity(), equity + amountIn * 2 / 1e10, 1);
        _resolve();
        (,, uint8 kind,,) = _pending();
        assertEq(kind, 0);
    }

    function test_deLeverCountsInFlightHollarAsDebtBackedCash() public {
        _deposit(SEED);
        _rampSteps(1);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        uint128 id = dispatch.lastId();
        // PRIME -2%: the aave HF alone would ask for a safety de-lever
        pool.setPrice(address(prime), 0.98e18);
        assertLt(loop.healthFactor(), TARGET_HF);
        vm.expectRevert(SubLoop.HealthyEnough.selector);
        loop.deLever();

        (, uint64 deadline,,,) = _pending();
        vm.warp(deadline / 1000);
        dispatch.cleanup(id);
        loop.reconcile();
        // refunded cash is idle, not an aave repayment: the position itself is under target
        loop.deLever();
        assertGt(loop.deleverDebtTarget(), 0);
    }

    function test_keeperQuoteOnlyRaisesTheOracleFloor() public {
        _deposit(SEED);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        loop.pokeBorrowQuoted(ENTRY_RATE);

        // anyone may poke unquoted: the oracle floor (1%) applies
        vm.prank(address(0xBEEF));
        loop.pokeBorrow();
        (,,,, uint256 minOut) = _pending();
        assertEq(minOut, 990e6);
        _resolve();

        // a quote below the oracle floor cannot loosen it
        _deposit(SEED);
        loop.pokeBorrowQuoted(0.5e6);
        (,,, uint256 amountIn, uint256 lowQuoted) = _pending();
        assertEq(lowQuoted, amountIn / 1e12 * 99 / 100);
        _resolve();
    }

    function test_controllerAsyncLaneOpensAndCloses() public {
        ExecutionController control = new ExecutionController(address(this), 60, 5);
        bytes32 entryGroup = keccak256("entry");
        control.configureBudget(entryGroup, address(hollar), 5_000e18, 1e18, uint64(block.timestamp + 30 days));
        control.configureLimit(address(loop), address(hollar), address(aPrime), entryGroup, 10e18, 2_500e18);
        bytes32 lane = control.lane(address(loop), address(hollar), address(aPrime));
        control.configurePrice(lane, 10, false);
        loop.setExecutionController(address(control));
        _deposit(SEED);

        vm.expectRevert(ExecutionController.InvalidPolicy.selector);
        loop.pokeBorrowQuoted(ENTRY_RATE);

        control.configureAsync(lane, true);
        assertEq(loop.pokeBorrowQuoted(ENTRY_RATE), SEED, "direct call, no block-bound quote");
        (address consumer, uint64 nonce, uint256 minimum) = control.pendingAsync(lane);
        assertEq(consumer, address(loop));
        assertEq(nonce, 1);
        assertEq(minimum, 999e6, "10 bp price cap");
        (,,,, uint256 minOut) = _pending();
        assertGe(minOut, minimum);
        (,,, uint128 credit,,) = control.budgets(entryGroup);
        assertEq(credit, 4_000e18, "charged at submit");

        _resolve();
        (consumer, nonce,) = control.pendingAsync(lane);
        assertEq(nonce, 0, "recorded and closed by the callback");
    }

    function test_routerModeKeepsSynchronousEntries() public {
        loop.configureIntents(0, 0);
        _deposit(SEED);
        assertEq(dispatch.routerSells(), 1, "deposit swaps at once");
        assertEq(hollar.balanceOf(address(loop)), 0);
        assertGt(loop.pokeBorrowQuoted(ENTRY_RATE), 0);
        assertEq(dispatch.routerSells(), 2);
        assertEq(dispatch.counter(), 0, "no intents");
    }

    function test_configureIntentsBounds() public {
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.configureIntents(1 days, 5);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.configureIntents(600, 9_999);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        loop.configureIntents(600, 5);
    }
}
