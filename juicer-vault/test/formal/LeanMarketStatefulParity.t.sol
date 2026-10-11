// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LeanStatefulParityTest} from "./LeanStatefulParity.t.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StatefulYieldSource} from "../mocks/StatefulYieldSource.sol";
import {MockSwapper} from "../mocks/MockSwapper.sol";
import {Harvester} from "../../src/Harvester.sol";
import {JuicerFeeController} from "../../src/JuicerFeeController.sol";
import {JuicerMainDebt} from "../../src/JuicerMainDebt.sol";

contract LeanMarketStatefulParityTest is LeanStatefulParityTest {
    StatefulYieldSource internal market;
    MockSwapper internal swapper;
    Harvester internal harvester;
    JuicerFeeController internal fees;

    function _configure() internal override {
        super._configure();
        market = new StatefulYieldSource(address(hollar));
        vault.setYieldSource(address(market));
        source = MockYieldSource(address(market));
        swapper = new MockSwapper(address(pool));
        vault.setSwapper(address(swapper));
        vault.setCompoundSlippageBps(100);
        harvester = new Harvester(address(market), address(hollar), address(this));
        market.setHarvester(address(harvester));
        fees = new JuicerFeeController(address(this), actors[3]);
        vault.setFeeController(address(fees));
        harvester.setFeeController(address(fees));
        fees.registerVault(address(vault), address(harvester));
        fees.setProtocolFeeBps(address(vault), 1000);
        harvester.addVault(address(vault));
    }

    function _checkFixture() internal view override {
        JuicerMainDebt m = JuicerMainDebt(address(vault.mainDebt()));
        assertEq(market.sharesOf(address(vault)), vault.loopShares());
        assertEq(hollar.balanceOf(address(m)), m.ownedCash() + m.protocolReserve());
        assertEq(aSynth.balanceOf(address(vault)), vault.syntheticSupplied());
        assertEq(hollar.balanceOf(address(fees)), fees.claimableProtocolFees(address(hollar)));
        assertEq(eth.balanceOf(address(fees)), fees.claimableProtocolFees(address(eth)));
        assertEq(hollar.balanceOf(address(harvester)), 0);
        assertEq(vault.availableHollar(), 0);
        assertEq(vault.yieldAccounting().harvestUnits(), 0);
    }

    function _snapshot() internal view override returns (uint256[] memory out) {
        uint256[] memory base = super._snapshot();
        JuicerMainDebt m = JuicerMainDebt(address(vault.mainDebt()));
        out = new uint256[](base.length + 26 + m.sourceTail() * 2);
        uint256 k;
        for (; k < base.length; ++k) out[k] = base[k];
        out[k++] = market.rate(); out[k++] = hollar.balanceOf(address(market));
        out[k++] = fees.protocolFeeBps(address(vault)); out[k++] = market.costBps();
        (uint256 price,) = pool.assetPrice(address(eth)); out[k++] = price;
        out[k++] = pool.debtIndex(); out[k++] = pool.borrowRoundingLoss(); out[k++] = pool.repayRoundingLoss();
        out[k++] = m.activeSourceRemaining(); out[k++] = m.unallocatedCost();
        out[k++] = market.unwindExecutionCost(address(vault)); out[k++] = m.protocolReserve();
        out[k++] = m.sourceFeeReserve(); out[k++] = fees.claimableProtocolFees(address(hollar));
        out[k++] = fees.claimableProtocolFees(address(eth)); out[k++] = swapper.haircutBps();
        out[k++] = vault.deleverTarget(); out[k++] = harvester.lastHarvestAt();
        out[k++] = hollar.balanceOf(actors[3]);
        for (uint256 slot = 13; slot <= 18; ++slot) out[k++] = uint256(vm.load(address(m), bytes32(slot)));
        out[k++] = pool.repayCalls();
        for (uint256 i; i < m.sourceTail(); ++i) {
            (uint256 yield, uint256 fee) = m.sourceFees(i);
            out[k++] = yield; out[k++] = fee;
        }
        assertEq(k, out.length);
    }

    function perform(uint256 op, uint256 caller, uint256 a, uint256 b, uint256 n) public override {
        require(msg.sender == address(this));
        if (op <= 16) { super.perform(op, caller, a, b, n); return; }
        address target;
        bytes memory data;
        if (op == 17) { target = address(market); data = abi.encodeCall(market.reprice, (n)); }
        else if (op == 18) { target = address(fees); data = abi.encodeCall(fees.setProtocolFeeBps, (address(vault), uint16(n))); }
        else if (op == 19) { target = address(market); data = abi.encodeCall(market.setCostBps, (n)); }
        else if (op == 20) { target = address(pool); data = abi.encodeCall(pool.accrueInterest, (address(hollar), address(vault), n)); }
        else if (op == 21) { target = address(pool); data = abi.encodeCall(pool.setPrice, (address(eth), n)); }
        else if (op == 22) { target = address(vault); data = abi.encodeCall(vault.maintainPeg, ()); }
        else if (op == 23) {
            uint256[] memory minima = new uint256[](1); minima[0] = n;
            target = address(harvester); data = abi.encodeCall(harvester.harvest, (minima));
        } else if (op == 24) {
            target = address(vault); data = abi.encodeCall(vault.compound, (address(eth), n, b, ""));
        } else if (op == 25) { target = address(pool); data = abi.encodeCall(pool.setDebtRounding, (a, n)); }
        else if (op == 26 || op == 30) {
            hollar.mint(actors[caller], n);
            vm.prank(actors[caller]); hollar.approve(address(vault.mainDebt()), n);
            JuicerMainDebt m = JuicerMainDebt(address(vault.mainDebt()));
            target = address(m);
            data = op == 26 ? abi.encodeCall(m.fundReserve, (n)) : abi.encodeCall(m.fundPosition, (0, n));
        } else if (op == 27) {
            target = address(fees); data = abi.encodeCall(fees.claimProtocolFees, (a == 0 ? address(eth) : address(hollar)));
        } else if (op == 28) { target = address(swapper); data = abi.encodeCall(swapper.setHaircut, (n)); }
        else revert("unknown market action");
        vm.prank(actors[caller]);
        (bool ok, bytes memory result) = target.call(data);
        uint256 code = ok ? 0 : _error(result);
        uint256 value = ok && result.length == 32 ? abi.decode(result, (uint256)) : 0;
        _record([op, caller, a, b, n], code, value);
    }

    function _error(bytes memory result) internal pure override returns (uint256) {
        bytes4 selector = bytes4(result);
        if (selector == bytes4(keccak256("PrincipalNotFloored()"))) return 23;
        if (selector == bytes4(keccak256("DeleverPending()"))) return 24;
        if (selector == bytes4(keccak256("TransferMismatch()"))) return 25;
        if (keccak256(result) == keccak256(abi.encodeWithSignature("Error(string)", "MockSwapper: minOut"))) return 26;
        if (selector == bytes4(keccak256("InvalidHarvest()"))) return 27;
        if (selector == bytes4(keccak256("PrincipalShortfall()"))) return 28;
        return super._error(result);
    }

    function _campaign(uint256 seed, uint256 depth, bool wide) internal override {
        tracePath = string.concat("formal/.stateful/market-", vm.toString(seed), ".jsonl");
        vm.writeFile(tracePath, ""); random = seed; step = 0;
        _record([uint256(999), 0, 0, 0, 1], 0, 0);
        _act(0, 0, 0, 0, 30e18);
        for (uint256 i = 1; i < 4; ++i) _act(0, i, 0, i, 20e18);
        _act(26, 0, 0, 0, 100e18);
        _act(9, 0, 0, 0, 0);
        _act(17, 0, 0, 0, 125e16);
        _act(23, 0, 0, 0, 0);
        _act(20, 0, 0, 0, 100);
        _act(0, 0, 0, 0, 1e15);
        _act(22, 0, 0, 0, 0);
        _act(25, 0, 0, 0, 1);
        _act(24, 1, 0, 0, 2e18);
        _act(20, 0, 0, 0, 1);
        _act(30, 0, 0, 0, 1e18);
        _act(6, 0, 0, 0, 0);
        _act(17, 0, 0, 0, 135e16);
        _act(19, 0, 0, 0, 50);
        _act(21, 0, 0, 0, 70e16);
        _act(9, 0, 0, 0, 0);
        _act(0, 1, 0, 1, 1e15);
        _act(12, 0, 0, 0, 4000);
        _act(14, 0, 0, 0, 1);
        _act(6, 0, 0, 0, 0);
        _act(14, 0, 0, 0, 0);
        _act(12, 0, 0, 0, 10000);
        _act(6, 0, 0, 0, 0);
        _act(17, 0, 0, 0, 110e16);
        _act(8, 0, 0, 0, 0);
        _act(17, 0, 0, 0, 140e16);
        _act(23, 2, 0, 0, type(uint128).max);
        _act(23, 2, 0, 0, 0);
        _act(4, 0, 0, 0, 1e18);
        if (wide) for (uint256 i; i < 70; ++i) _act(4, 1, 1, 0, 1e15 + i);
        _act(10, 0, 0, 0, 10);
        _act(5, 0, 0, 0, 100);
        _act(12, 0, 0, 0, 4000);
        _act(13, 0, 0, 0, 1e17);
        _act(6, 0, 0, 0, 0);
        _act(7, 3, 0, 2, 0);
        for (uint256 i; i < depth; ++i) {
            uint256 r = _next(); uint256 op = (r >> 16) % 31;
            uint256 a = r % 4; uint256 b = (r >> 8) % 4;
            if (op == 0) _act(0, a, 0, b, ((r >> 32) % 10 + 1) * 1e15);
            else if (op == 1) _act(1, a, 0, b, type(uint256).max);
            else if (op == 2 || op == 3) _act(op, op == 2 ? a : b, a, b, vault.balanceOf(actors[a]) / 20);
            else if (op == 4) _act(4, a, a, 0, vault.walletOf(actors[a]) / 100);
            else if (op == 5) _act(5, a, 0, 0, 5);
            else if (op == 6 || op == 8 || op == 9 || op == 22) _act(op, a, 0, 0, 0);
            else if (op == 7) _act(7, a, 0, b, (r >> 32) % (vault.queueTail() + 1));
            else if (op == 10) _act(10, 0, 0, 0, 15);
            else if (op == 11) _act(11, 0, 0, 0, 1e14);
            else if (op == 12) _act(12, 0, 0, 0, (r % 4 + 1) * 2500);
            else if (op == 13) _act(13, 0, 0, 0, r % 2 == 0 ? type(uint256).max : 1e17);
            else if (op == 14 || op == 15 || op == 16) _act(op, 0, 0, 0, (r >> 32) % 2);
            else if (op == 17) _act(17, 0, 0, 0, (110 + (r >> 32) % 50) * 1e16);
            else if (op == 18) _act(18, 0, 0, 0, (r >> 32) % 4 * 500);
            else if (op == 19) _act(19, 0, 0, 0, (r >> 32) % 4 * 25);
            else if (op == 20) _act(20, 0, 0, 0, (r >> 32) % 30 + 1);
            else if (op == 21) _act(21, 0, 0, 0, (70 + (r >> 32) % 61) * 1e16);
            else if (op == 23) _act(23, a, 0, 0, 0);
            else if (op == 24) _act(24, a, 0, 0, ((r >> 32) % 10 + 1) * 1e16);
            else if (op == 25) _act(25, 0, r % 2, 0, (r >> 32) % 3);
            else if (op == 26 || op == 30) _act(op, 0, 0, 0, 1e17);
            else if (op == 27) _act(27, a, (r >> 32) % 2, 0, 0);
            else if (op == 28) _act(28, 0, 0, 0, (r >> 32) % 3 * 50);
            else _act(2, a, 0, 6, vault.walletOf(actors[a]) / 100);
        }
        _act(16, 0, 0, 0, 0); _act(14, 0, 0, 0, 0); _act(15, 0, 0, 0, 0);
        _act(22, 0, 0, 0, 0); _act(10, 0, 0, 0, 20);
        _act(12, 0, 0, 0, 10000); _act(13, 0, 0, 0, type(uint256).max);
        for (uint256 i; i < 6; ++i) { _act(6, 0, 0, 0, 0); _act(5, 0, 0, 0, 100); }
        for (uint256 id; id < vault.queueTail(); ++id) _act(7, 3, 0, 2, id);
        _act(27, 0, 0, 0, 0); _act(27, 0, 1, 0, 0);
        _record([uint256(998), seed, depth, 1, step - 1], 0, 0);
    }
}
