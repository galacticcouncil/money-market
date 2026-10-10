// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PluggableYieldSourceTest} from "../PluggableYieldSource.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {JuicerMainDebt} from "../../src/JuicerMainDebt.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";

contract LeanStatefulParityTest is PluggableYieldSourceTest {
    address[8] internal actors;
    string internal tracePath;
    uint256 internal random;
    uint256 internal step;
    bytes32 internal lastSnapshot;

    function _configure() internal {
        pool.setPrice(address(eth), 1e18);
        vault.setWithdrawalDelay(10);
        vm.warp(1000);
        actors = [address(this), address(0xa11ce), address(0xb0b), address(0xcafe),
            address(0xdead), address(vault), address(vault.yieldAccounting()), address(0)];
        for (uint256 i; i < 4; ++i) {
            eth.mint(actors[i], 1e24);
            vm.prank(actors[i]); eth.approve(address(vault), type(uint256).max);
        }
    }

    function _id(address who) internal view returns (uint256) {
        for (uint256 i; i < actors.length; ++i) if (actors[i] == who) return i;
        revert("untracked actor");
    }

    function _snapshot() internal view returns (uint256[] memory out) {
        JuicerYieldAccounting y = vault.yieldAccounting();
        JuicerMainDebt m = JuicerMainDebt(address(vault.mainDebt()));
        uint256 tail = vault.queueTail();
        uint256 mainTail = m.sourceTail();
        out = new uint256[](114 + tail * 15 + mainTail * 5);
        uint256 k;
        out[k++] = vault.totalSupply(); out[k++] = vault.totalAssets();
        out[k++] = aEth.balanceOf(address(vault)); out[k++] = eth.balanceOf(address(vault));
        out[k++] = vault.roundingReserve(); out[k++] = hollarDebt.balanceOf(address(vault));
        out[k++] = vault.syntheticSupplied(); out[k++] = vault.loopShares();
        out[k++] = source.principalOf(address(vault)); out[k++] = source.freedOf(address(vault));
        out[k++] = vault.reinvestAssets(); out[k++] = vault.pendingWithdrawalShares();
        out[k++] = vault.totalQueuedShares(); out[k++] = vault.totalQueuedCollateral();
        out[k++] = vault.totalQueuedDebt(); out[k++] = vault.queueHead();
        out[k++] = vault.queueUnwind(); out[k++] = tail;
        out[k++] = y.sourceShares(); out[k++] = y.protocolShares(); out[k++] = y.totalUnits();
        out[k++] = y.rewardIndex(); out[k++] = y.epoch(); out[k++] = y.unitScale();
        out[k++] = m.totalUnits(); out[k++] = m.ownedCash(); out[k++] = m.sourceOutstanding();
        out[k++] = m.sourceHead(); out[k++] = mainTail; out[k++] = m.unallocatedSource();
        out[k++] = vault.paused() ? 1 : 0;
        out[k++] = vault.depositsPaused() ? 1 : 0;
        out[k++] = source.emergencyPaused() ? 1 : 0; out[k++] = block.timestamp;
        for (uint256 i; i < 8; ++i) {
            address owner = actors[i];
            out[k++] = vault.walletOf(owner); out[k++] = vault.balanceOf(owner);
            out[k++] = y.balanceOf(owner);
            out[k++] = uint256(vm.load(address(y), keccak256(abi.encode(owner, uint256(4)))));
            out[k++] = y.accountIndex(owner); out[k++] = y.accountEpoch(owner);
            out[k++] = y.accountScale(owner); out[k++] = eth.balanceOf(owner);
        }
        for (uint256 i; i < 4; ++i) for (uint256 j; j < 4; ++j) out[k++] = vault.allowance(actors[i], actors[j]);
        for (uint256 id; id < tail; ++id) {
            (address owner, uint256 shares, uint256 owed, uint256 debt, uint256 synthetic,
                uint256 repaid, uint256 settled, uint256 burned, bool active) = vault.redemptions(id);
            out[k++] = _id(owner); out[k++] = shares; out[k++] = owed; out[k++] = debt;
            out[k++] = synthetic; out[k++] = repaid; out[k++] = settled; out[k++] = burned;
            out[k++] = active ? 1 : 0; out[k++] = vault.claimedCollateral(id);
            out[k++] = vault.unwindEligibleAt(id); out[k++] = y.requestUnits(id);
            out[k++] = y.requestIndex(id); out[k++] = y.requestEpoch(id); out[k++] = y.requestScale(id);
        }
        for (uint256 i; i < mainTail; ++i) {
            (uint256 units_, uint256 principal, uint256 cash, uint256 remaining, address owner) = m.positions(i);
            out[k++] = units_; out[k++] = principal; out[k++] = cash; out[k++] = remaining; out[k++] = _id(owner);
        }
        assertEq(k, out.length);
        assertEq(y.unitScale(), 0, "rescale belongs to its separate investigation");
        assertEq(source.sharesOf(address(vault)), vault.loopShares());
        assertEq(hollar.balanceOf(address(m)), m.ownedCash());
        assertEq(aSynth.balanceOf(address(vault)), vault.syntheticSupplied());
        assertEq(hollar.balanceOf(address(source)), vault.loopShares() + source.freedOf(address(vault)));
        assertEq(vault.availableHollar(), 0);
        assertEq(vault.deleverTarget(), 0);
    }

    function _error(bytes memory reason) internal pure returns (uint256) {
        bytes4 selector = bytes4(reason);
        if (keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "Pausable: paused"))) return 1;
        if (selector == CollateralVault.ZeroAmount.selector) return 2;
        if (selector == CollateralVault.ZeroAddress.selector) return 3;
        if (selector == CollateralVault.DepositsArePaused.selector) return 4;
        if (selector == CollateralVault.BootstrapRequired.selector) return 5;
        if (selector == CollateralVault.ExceedsTvlCap.selector) return 6;
        if (selector == CollateralVault.DepositTooSmall.selector) return 7;
        if (selector == CollateralVault.NoActiveAssets.selector) return 8;
        if (selector == CollateralVault.NotRequestOwner.selector) return 9;
        if (selector == JuicerYieldAccounting.Unauthorized.selector) return 10;
        if (selector == JuicerYieldAccounting.ExceedsBalance.selector) return 11;
        if (selector == bytes4(keccak256("InexactShares()"))) return 12;
        if (keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "ERC20: transfer to the zero address"))) return 13;
        if (selector == CollateralVault.VaultPaused.selector) return 14;
        if (keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "ERC20: transfer amount exceeds balance"))) return 15;
        if (keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "ERC20: insufficient allowance"))) return 16;
        if (selector == CollateralVault.InsufficientRoundingReserve.selector) return 17;
        if (selector == JuicerMainDebt.OutstandingDebt.selector) return 18;
        if (selector == CollateralVault.NoLoopEquity.selector) return 19;
        if (selector == CollateralVault.RequestNotActive.selector) return 20;
        if (selector == CollateralVault.NothingToClaim.selector) return 21;
        if (keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "Pausable: not paused"))) return 22;
        revert(string.concat("unclassified revert: ", vm.toString(reason)));
    }

    function _record(uint256[5] memory action, uint256 code, uint256 value) internal {
        uint256[] memory a = new uint256[](5);
        for (uint256 i; i < 5; ++i) a[i] = action[i];
        uint256[] memory status = new uint256[](2); status[0] = code; status[1] = value;
        vm.serializeUint("step", "action", a);
        vm.serializeUint("step", "status", status);
        uint256[] memory state = _snapshot();
        bytes32 current = keccak256(abi.encode(state));
        if (code != 0) assertEq(current, lastSnapshot, "failed call changed tracked state");
        lastSnapshot = current;
        string memory row = vm.serializeUint("step", "state", state);
        vm.writeLine(tracePath, row);
        ++step;
    }

    function _act(uint256 op, uint256 caller, uint256 a, uint256 b, uint256 n) internal {
        this.perform(op, caller, a, b, n);
    }

    function perform(uint256 op, uint256 caller, uint256 a, uint256 b, uint256 n) external {
        require(msg.sender == address(this));
        bytes memory data;
        address target = address(vault);
        if (op == 0) data = abi.encodeCall(vault.deposit, (n, actors[b]));
        else if (op == 1) data = abi.encodeCall(vault.approve, (actors[b], n));
        else if (op == 2) data = abi.encodeCall(vault.transfer, (actors[b], n));
        else if (op == 3) data = abi.encodeCall(vault.transferFrom, (actors[a], actors[b], n));
        else if (op == 4) data = abi.encodeCall(vault.requestRedeem, (n, actors[a]));
        else if (op == 5) data = abi.encodeCall(vault.startUnwinds, (n));
        else if (op == 6) data = abi.encodeCall(vault.pokeSettle, ());
        else if (op == 7) data = abi.encodeCall(vault.claim, (n, actors[b]));
        else if (op == 8) data = abi.encodeCall(vault.sync, ());
        else if (op == 9) data = abi.encodeCall(vault.rebalance, ());
        else if (op == 10) { vm.warp(block.timestamp + n); _record([op, caller, a, b, n], 0, 0); return; }
        else if (op == 11) {
            hollar.mint(actors[caller], n);
            vm.prank(actors[caller]); hollar.approve(address(pool), n);
            target = address(pool); data = abi.encodeCall(pool.repay, (address(hollar), n, 2, address(vault)));
        } else if (op == 12) { target = address(source); data = abi.encodeCall(source.setPullBps, (n)); }
        else if (op == 13) { target = address(pool); data = abi.encodeCall(pool.setRepayLimit, (n)); }
        else if (op == 14) data = n == 0 ? abi.encodeCall(vault.unpause, ()) : abi.encodeCall(vault.pause, ());
        else if (op == 15) data = n == 0 ? abi.encodeCall(vault.unpauseDeposits, ()) : abi.encodeCall(vault.pauseDeposits, ());
        else if (op == 16) { target = address(source); data = abi.encodeCall(source.setEmergencyPaused, (n != 0)); }
        else revert("unknown action");
        vm.prank(actors[caller]);
        (bool ok, bytes memory result) = target.call(data);
        uint256 code = ok ? 0 : _error(result);
        uint256 value = ok && result.length == 32 ? abi.decode(result, (uint256)) : 0;
        _record([op, caller, a, b, n], code, value);
    }

    function _next() internal returns (uint256) {
        random = uint256(keccak256(abi.encode(random)));
        return random;
    }

    function _campaign(uint256 seed, uint256 depth, bool wide) internal {
        tracePath = string.concat("formal/.stateful/trace-", vm.toString(seed), ".jsonl");
        vm.writeFile(tracePath, ""); random = seed; step = 0;
        _record([uint256(999), 0, 0, 0, 0], 0, 0);
        _act(0, 1, 0, 1, 1e18); // bootstrap guard before any deposit
        _act(0, 0, 0, 0, 20e18);
        for (uint256 i = 1; i < 4; ++i) _act(0, i, 0, i, 10e18);
        _act(9, 0, 0, 0, 0);
        _act(11, 0, 0, 0, 2e18);
        _act(8, 0, 0, 0, 0);
        _act(2, 0, 0, 6, 1e18);
        _act(1, 0, 0, 1, 7);
        _act(3, 1, 0, 2, 8);
        _act(3, 1, 0, 2, 7);
        _act(11, 0, 0, 0, 1e14);
        _act(4, 2, 0, 0, 1e18);
        _act(4, 0, 0, 0, type(uint256).max);
        _act(5, 0, 0, 0, 100);
        _act(10, 0, 0, 0, 10);
        if (wide) {
            for (uint256 i; i < 70; ++i) _act(4, 1, 1, 0, 1e15 + i);
            _act(10, 0, 0, 0, 10);
        }
        _act(5, 0, 0, 0, 100);
        _act(12, 0, 0, 0, 4000);
        _act(13, 0, 0, 0, 1e17);
        _act(6, 0, 0, 0, 0);
        _act(7, 3, 0, 2, 0);
        for (uint256 i; i < depth; ++i) {
            uint256 r = _next();
            uint256 a = r % 4;
            uint256 b = (r >> 8) % 4;
            uint256 op = (r >> 16) % 18;
            if (op == 0) _act(0, a, 0, b, ((r >> 32) % 20 + 1) * 1e15);
            else if (op == 1) _act(1, a, 0, b, r % 2 == 0 ? type(uint256).max : (r >> 32) % 1e18);
            else if (op == 2 || op == 3) {
                uint256 n = vault.balanceOf(actors[a]);
                uint256 mode = (r >> 48) % 5;
                if (mode == 0) n += 1;
                else if (mode != 1) n /= mode + 1;
                _act(op, op == 2 ? a : b, a, (r >> 24) % 8, n);
            } else if (op == 4) {
                uint256 n = (r >> 48) % 3 == 0 ? type(uint256).max : vault.walletOf(actors[a]) / 10;
                _act(4, (r >> 40) % 2 == 0 ? a : b, a, 0, n);
            } else if (op == 5) _act(5, a, 0, 0, (r >> 32) % 7);
            else if (op == 6) _act(6, a, 0, 0, 0);
            else if (op == 7) _act(7, a, 0, (r >> 24) % 8, (r >> 32) % (vault.queueTail() + 2));
            else if (op == 8) _act(8, a, 0, 0, 0);
            else if (op == 9) _act(9, a, 0, 0, 0);
            else if (op == 10) _act(10, 0, 0, 0, (r >> 32) % 30);
            else if (op == 11) _act(11, a, 0, 0, hollarDebt.balanceOf(address(vault)) / 100 + 1);
            else if (op == 12) _act(12, 0, 0, 0, ((r >> 32) % 4 + 1) * 2500);
            else if (op == 13) _act(13, 0, 0, 0, r % 2 == 0 ? type(uint256).max : 1e17);
            else if (op == 14) _act(14, 0, 0, 0, (r >> 32) % 2);
            else if (op == 15) _act(15, 0, 0, 0, (r >> 32) % 2);
            else if (op == 16) _act(16, 0, 0, 0, (r >> 32) % 2);
            else _act(2, a, 0, 6, vault.walletOf(actors[a]) / 100);
        }
        _act(16, 0, 0, 0, 0); _act(14, 0, 0, 0, 0); _act(15, 0, 0, 0, 0);
        _act(10, 0, 0, 0, 20); _act(12, 0, 0, 0, 10000); _act(13, 0, 0, 0, type(uint256).max);
        for (uint256 i; i < 5; ++i) { _act(6, 0, 0, 0, 0); _act(5, 0, 0, 0, 100); }
        for (uint256 id; id < vault.queueTail(); ++id) _act(7, 3, 0, 2, id);
        _record([uint256(998), seed, depth, 0, step - 1], 0, 0);
        emit log_named_uint("trace seed", seed);
        emit log_named_uint("public steps", step - 2);
    }

    function _run(uint256 offset) internal {
        uint256 count = vm.envOr("LEAN_STATEFUL_COUNT", uint256(8));
        if (offset >= count) return;
        require(count <= 8);
        _configure();
        vm.createDir("formal/.stateful", true);
        uint256 first = vm.envOr("LEAN_STATEFUL_SEED", uint256(1));
        uint256 depth = vm.envOr("LEAN_STATEFUL_DEPTH", uint256(192));
        uint256 seed = first + offset;
        _campaign(seed, depth, seed % 4 == 1 || seed % 4 == 2);
    }

    function test_statefulPublicCalls0() public { _run(0); }
    function test_statefulPublicCalls1() public { _run(1); }
    function test_statefulPublicCalls2() public { _run(2); }
    function test_statefulPublicCalls3() public { _run(3); }
    function test_statefulPublicCalls4() public { _run(4); }
    function test_statefulPublicCalls5() public { _run(5); }
    function test_statefulPublicCalls6() public { _run(6); }
    function test_statefulPublicCalls7() public { _run(7); }
}
