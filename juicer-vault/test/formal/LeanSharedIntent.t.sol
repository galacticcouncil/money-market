// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {SubLoop} from "../../src/SubLoop.sol";
import {Harvester} from "../../src/Harvester.sol";
import {ExecutionController} from "../../src/ExecutionController.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {MockIntentDispatch} from "../mocks/MockIntentDispatch.sol";
import {DcaDispatch} from "../../src/lib/DcaDispatch.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Artifacts} from "../helpers/Artifacts.t.sol";

// vault and fee callbacks are explicit boundaries; the source and harvester are production contracts.
contract SharedIntentVault {
    SubLoop public immutable source;
    MockERC20 public immutable token;
    uint256 public seenCost;
    uint256 public weight;
    uint256 public compounded;
    uint256 public pulled;
    bool public blocked;

    constructor(SubLoop s, MockERC20 t) { source = s; token = t; }
    function collateral() external view returns (address) { return address(token); }
    function mainDebt() external view returns (address) { return address(this); }
    function serviceBlocked() public view returns (bool) {
        return blocked || seenCost != source.unwindExecutionCost(address(this));
    }
    function acknowledgeCost() external { seenCost = source.unwindExecutionCost(address(this)); }
    function setBlocked(bool b) external { blocked = b; }
    function deposit(uint256 amount) external returns (uint256) {
        MockERC20 h = MockERC20(address(source.hollar()));
        h.mint(address(this), amount);
        h.approve(address(source), amount);
        return source.deposit(amount);
    }
    function request(uint256 shares) external returns (uint256) { return source.requestUnwind(shares); }
    function pull() external returns (uint256 amount) { amount = source.pullFreed(); pulled += amount; }
    function sync() external returns (uint256) {
        uint256 equity = source.totalEquity() * 1e10;
        uint256 target = source.unwindTargetEquity();
        uint256 live = equity > target ? equity - target : 0;
        uint256 basis = live == 0 ? 0 : Math.mulDiv(source.principalOf(address(this)), source.totalShares(), live, Math.Rounding.Up);
        uint256 held = source.sharesOf(address(this));
        weight = serviceBlocked() || basis >= held ? 0 : held - basis;
        return weight;
    }
    function burnYieldShares(uint256 amount) external {
        require(msg.sender == address(source) && !serviceBlocked() && amount <= weight);
        weight -= amount;
    }
    function compound(address, uint256 amount, uint256, bytes calldata) external {
        token.transferFrom(msg.sender, address(this), amount);
        compounded += amount;
    }
}

contract SharedIntentFees {
    function configurationVersion() external pure returns (uint256) { return 0; }
    function validateVault(address, address) external pure {}
}

contract LeanSharedIntentTest is Test {
    MockERC20 hollar;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 hollarDebt;
    MockPool pool;
    SubLoop loop;
    MockIntentDispatch dispatch;
    SharedIntentVault[2] vaults;
    Harvester harvester;
    string trace;
    uint256 steps;
    mapping(uint256 => uint128) ids;

    function setUp() public {
        vm.warp(1_800_000_000);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        hollarDebt = new MockERC20("debtHOLLAR", "dHOLLAR", 18);
        pool = new MockPool();
        pool.initReserve(address(prime), address(aPrime), address(new MockERC20("dPRIME", "dPRIME", 6)), 8800, 8500, 6, 1e18);
        pool.initReserve(address(hollar), address(new MockERC20("aHOLLAR", "aHOLLAR", 18)), address(hollarDebt), 0, 0, 18, 1e18);
        pool.setIsolationMode(address(prime), true);
        loop = SubLoop(Artifacts.proxy(Artifacts.subLoop(), abi.encodeCall(SubLoop.initialize,
            (address(pool), address(hollar), address(prime), address(aPrime), 1.05e18, 1.10e18, address(this)))));
        vm.etch(DcaDispatch.DISPATCH, address(new MockIntentDispatch()).code);
        dispatch = MockIntentDispatch(payable(DcaDispatch.DISPATCH));
        dispatch.configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);
        loop.configureIntents(600, 5);
    }

    function _pending() internal view returns (uint64 nonce, uint64 deadline, uint8 kind, uint256 amount, uint256 minimum) {
        (nonce, deadline, kind,, amount, minimum,,,) = loop.pendingIntent();
    }

    function _callback(uint128 id, uint256 amount) internal {
        MockIntentDispatch.Intent memory p = dispatch.intent(id);
        vm.prank(address(loop), address(loop));
        loop.execute(address(loop), id, p.assetIn == 222 ? address(hollar) : address(aPrime), p.amountIn,
            p.assetOut == 222 ? address(hollar) : address(aPrime), amount, p.data);
    }

    function _init(uint256 seed) internal {
        harvester = Harvester(Artifacts.harvester(address(loop), address(prime), address(this)));
        harvester.setFeeController(address(new SharedIntentFees()));
        ExecutionController control = new ExecutionController(address(this), 300, 20);
        harvester.setExecutionController(address(control));
        control.configureBudget(bytes32(uint256(1)), address(prime), 1e30, 0, type(uint64).max);
        for (uint256 i; i < 2; ++i) {
            vaults[i] = new SharedIntentVault(loop, prime);
            loop.registerVault(address(vaults[i]));
            harvester.addVault(address(vaults[i]));
            control.configureLimit(address(vaults[i]), address(prime), address(prime), bytes32(uint256(1)), 1, 1e30);
        }
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 50e6);
        trace = string.concat("formal/.stateful/shared-intent-", vm.toString(seed), ".jsonl");
        vm.createDir("formal/.stateful", true);
        vm.writeFile(trace, "");
        _record(999, 0, 0, true, 0);
    }

    function _record(uint256 op, uint256 actor, uint256 amount, bool ok, uint256 result) internal {
        uint256[] memory operation = new uint256[](3);
        operation[0] = op; operation[1] = actor; operation[2] = amount;
        uint256 nonce = loop.intentNonce();
        uint256[] memory state = new uint256[](48 + nonce * 5);
        state[0] = hollar.balanceOf(address(loop));
        state[1] = aPrime.balanceOf(address(loop));
        state[2] = hollarDebt.balanceOf(address(loop));
        state[3] = pool.usingAsCollateral(address(loop), address(prime)) ? 1 : 0;
        state[4] = loop.totalShares(); state[5] = loop.principalEquity();
        state[6] = loop.unwindTargetEquity(); state[7] = loop.reservedFreed();
        state[8] = loop.unwindOrderId(); state[9] = nonce;
        state[10] = prime.balanceOf(address(harvester)); state[11] = block.timestamp;
        state[12] = harvester.lastHarvestAt(); state[13] = loop.totalEquity();
        state[14] = loop.harvestCapacity(); state[15] = loop.healthFactor();
        (uint64 n, uint64 deadline, uint8 kind,, uint128 input, uint128 minimum, uint128 fair, uint128 inBase, uint128 outBase) = loop.pendingIntent();
        state[16] = n; state[17] = deadline; state[18] = kind; state[19] = input;
        state[20] = minimum; state[21] = fair; state[22] = inBase; state[23] = outBase;
        for (uint256 i; i < 2; ++i) {
            SharedIntentVault v = vaults[i];
            uint256 j = 24 + 11 * i;
            state[j] = loop.sharesOf(address(v)); state[j + 1] = loop.principalOf(address(v));
            state[j + 2] = loop.unwindRequested(address(v)); state[j + 3] = loop.freedOf(address(v));
            state[j + 4] = loop.unwindYieldAllowance(address(v)); state[j + 5] = loop.unwindExecutionCost(address(v));
            state[j + 6] = v.seenCost(); state[j + 7] = v.weight();
            state[j + 8] = v.compounded(); state[j + 9] = v.pulled(); state[j + 10] = v.blocked() ? 1 : 0;
        }
        state[46] = harvester.parkedGiftOf(address(vaults[0]));
        state[47] = harvester.parkedGiftOf(address(vaults[1]));
        for (uint256 i = 1; i <= nonce; ++i) {
            MockIntentDispatch.Intent memory p = dispatch.intent(ids[i]);
            uint256 j = 48 + (i - 1) * 5;
            state[j] = p.assetIn == 222 ? 1 : 2; state[j + 1] = p.amountIn;
            state[j + 2] = p.amountOut; state[j + 3] = p.deadline; state[j + 4] = p.state;
        }
        vm.serializeUint("shared", "action", operation);
        vm.serializeBool("shared", "ok", ok);
        vm.serializeUint("shared", "result", result);
        vm.writeLine(trace, vm.serializeUint("shared", "state", state));
    }

    function action(uint256 op, uint256 actor, uint256 amount) external returns (uint256 result) {
        require(msg.sender == address(this));
        if (op == 0) return vaults[actor].deposit(amount);
        if (op == 1) return loop.pokeBorrow();
        if (op == 2) dispatch.fill(ids[actor], amount);
        else if (op == 3) dispatch.cleanup(ids[actor]);
        else if (op == 4) return loop.reconcile();
        else if (op == 5) { aPrime.mint(address(loop), amount); prime.mint(address(pool), amount); }
        else if (op == 6) hollar.mint(address(loop), amount);
        else if (op == 7) return vaults[actor].request(amount);
        else if (op == 8) return loop.pokeRepay();
        else if (op == 9) vm.warp(block.timestamp + amount);
        else if (op == 10) return harvester.harvest(new uint256[](2));
        else if (op == 11) prime.mint(address(harvester), amount);
        else if (op == 12) return vaults[actor].pull();
        else if (op == 13) _callback(ids[actor], amount);
        else if (op == 14) vaults[actor].acknowledgeCost();
        else if (op == 15) vaults[actor].setBlocked(amount != 0);
        else revert("unknown operation");
    }

    function _step(uint256 op, uint256 actor, uint256 amount) internal returns (bool ok) {
        bytes memory data;
        (ok, data) = address(this).call(abi.encodeCall(this.action, (op, actor, amount)));
        uint256 nonce = loop.intentNonce();
        if (nonce != 0) ids[nonce] = dispatch.lastId();
        ++steps;
        _record(op, actor, amount, ok, ok ? abi.decode(data, (uint256)) : 0);
    }

    function _land(uint256 bps, bool callback_) internal {
        (uint64 nonce,, uint8 kind,,) = _pending();
        if (kind == 0) return;
        uint256 out = dispatch.quote(ids[nonce], uint16(bps));
        _step(2, nonce, out);
        if (callback_) _step(13, nonce, out);
    }

    function _history(uint256 seed) internal {
        _init(seed);
        assertTrue(_step(0, 0, 1_000e18));
        assertTrue(_step(0, 1, 2_000e18));
        for (uint256 i; i < 12; ++i) { _step(1, 0, 0); _land(1, true); }
        _step(5, 0, aPrime.balanceOf(address(loop)) / 20);
        _step(7, 1, loop.sharesOf(address(vaults[1])) / 3);
        _step(8, 0, 0);
        _land(100, false);
        uint256 before_ = loop.unwindExecutionCost(address(vaults[1]));
        assertTrue(_step(10, 0, 0));
        assertGt(loop.unwindExecutionCost(address(vaults[1])), before_);
        assertEq(vaults[1].weight(), 0, "cost is reconciled before sync");
        _step(14, 1, 0);
        for (uint256 i; i < 240; ++i) {
            uint256 choice = uint256(keccak256(abi.encode(seed, i))) % 16;
            (uint64 nonce,, uint8 kind,, uint256 minimum) = _pending();
            uint256 actor = (seed + i) % 2;
            if (choice == 0) _step(0, actor, (i + 1) * 1e18);
            else if (choice == 1) _step(1, 0, 0);
            else if (choice == 2 && kind != 0) _step(2, nonce, minimum);
            else if (choice == 3 && kind != 0) { _step(9, 0, 601); _step(3, nonce, 0); }
            else if (choice == 5) _step(5, 0, (i + 1) * 1e5);
            else if (choice == 6) _step(6, 0, (i + 1) * 1e15);
            else if (choice == 7) _step(7, actor, loop.sharesOf(address(vaults[actor])) / 100);
            else if (choice == 8) _step(8, 0, 0);
            else if (choice == 10) _step(10, 0, 0);
            else if (choice == 11) _step(11, 0, (i + 1) * 1e6);
            else if (choice == 12) _step(12, actor, 0);
            else if (choice == 13 && nonce != 0) _step(13, nonce, 0);
            else if (choice == 14) _step(14, actor, 0);
            else if (choice == 15) _step(15, actor, i % 3);
            else _step(4, 0, 0);
        }
        _record(998, 0, steps, true, 0);
    }

    function test_sharedIntentHistory1() public { _history(1); }
    function test_sharedIntentHistory2() public { _history(2); }
    function test_sharedIntentHistory3() public { _history(3); }
    function test_sharedIntentHistory4() public { _history(4); }

    function test_sharedIntentGiftBeforeRealFill() public {
        _init(5);
        _step(0, 0, 1_000e18);
        _step(1, 0, 0);
        (uint64 nonce,, , , uint256 minimum) = _pending();
        _step(5, 0, minimum - minimum / 100);
        assertTrue(_step(4, 0, 0));
        (,, uint8 kind,,) = _pending();
        assertEq(kind, 0);
        assertEq(dispatch.intent(ids[nonce]).state, 1, "pallet input is still open");
        _step(0, 1, 10_000e18);
        _step(2, nonce, 1_000e6);
        _step(13, nonce, 1_000e6);
        _step(10, 0, 0);
        _record(998, 0, steps, true, 0);
    }

    function test_sharedIntentParkedGift() public {
        _init(6);
        _step(0, 0, 1_000e18);
        _step(0, 1, 1_000e18);
        _step(11, 0, 1_000e6);
        _step(15, 0, 1);
        for (uint256 i; i < 5; ++i) assertTrue(_step(10, 0, 0));
        assertEq(vaults[0].compounded(), 0);
        assertEq(vaults[1].compounded(), 500_000_000);
        assertEq(prime.balanceOf(address(harvester)), 500_000_000);
        assertEq(harvester.parkedGiftOf(address(vaults[0])), 500_000_000);
        assertEq(harvester.parkedGiftOf(address(vaults[1])), 0);
        _record(998, 0, steps, true, 0);
    }
}
