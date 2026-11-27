// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LeanMarketStatefulParityTest} from "./LeanMarketStatefulParity.t.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LeanRescaleStatefulParityTest is LeanMarketStatefulParityTest {
    // Selects the large-balance replay fixture; the campaign itself now checks that public
    // loss/recovery histories stay at scale zero under high-water restoration.
    function _allowRescale() internal pure override returns (bool) { return true; }

    function _configure() internal override {
        super._configure();
        for (uint256 i; i < 4; ++i) eth.mint(actors[i], 1e30 - 1e24);
    }

    function _cycle(uint256 high) internal {
        JuicerYieldAccounting y = vault.yieldAccounting();
        uint256 target = vault.yieldAccounting().requiredSourceBacking() + 1e13;
        uint256 low = Math.mulDiv(target, 1e18, market.sharesOf(address(vault)), Math.Rounding.Up);
        _act(17, 0, 0, 0, low);
        _act(8, 0, 0, 0, 0);
        assertGt(y.totalAssets(), 0, "loss retained a nonzero reward denominator");
        assertGt(y.sourceLossCarry() + y.protocolLossCarry(), 0, "loss recorded high-water carry");
        assertEq(y.unitScale(), 0, "loss did not rescale units");
        _act(17, 0, 0, 0, high);
        _act(8, 0, 0, 0, 0);
        assertEq(y.sourceLossCarry() + y.protocolLossCarry(), 0, "recovery restored prior holders");
        assertEq(y.unitScale(), 0, "recovery did not rescale units");
    }

    function _campaign(uint256 seed, uint256 depth, bool) internal override {
        tracePath = string.concat("formal/.stateful/rescale-", vm.toString(seed), ".jsonl");
        vm.writeFile(tracePath, ""); random = seed; step = 0;
        _record([uint256(999), 0, 0, 0, 2], 0, 0);
        _act(18, 0, 0, 0, 0);
        _act(29, 0, 0, 0, type(uint256).max);
        _act(0, 0, 0, 0, 2e27);
        for (uint256 i = 1; i < 4; ++i) _act(0, i, 0, i, 1e27);
        _act(9, 0, 0, 0, 0);
        uint256 high = (125 + seed % 10) * 1e16;
        _act(17, 0, 0, 0, high);
        _act(8, 0, 0, 0, 0);
        _act(2, 0, 0, 0, 1);
        _act(4, 0, 0, 0, 1e27);
        JuicerYieldAccounting y = vault.yieldAccounting();
        for (uint256 round; round < 48; ++round) {
            _cycle(high);
            _act(2, 2, 0, 3, 1e12 + round);
            _act(1, 3, 0, 2, round);
            _act(3, 2, 3, 2, round + 1);
        }
        assertEq(y.unitScale(), 0, "public loss/recovery cycles preserve the original scale");
        assertEq(y.sourceLossCarry() + y.protocolLossCarry(), 0, "all high-water carry restored");
        assertEq(y.accountScale(actors[0]), 0, "holder scale remained current");
        assertEq(y.requestScale(0), 0, "waiting request scale remained current");
        _act(2, 0, 0, 0, 1);
        _act(10, 0, 0, 0, 10);
        _act(5, 0, 0, 0, 1);
        _act(12, 0, 0, 0, 4000);
        _act(13, 0, 0, 0, 1e17);
        _act(6, 0, 0, 0, 0);
        _act(7, 3, 0, 2, 0);
        _act(12, 0, 0, 0, 10000);
        _act(13, 0, 0, 0, type(uint256).max);
        _act(6, 0, 0, 0, 0);
        _act(7, 3, 0, 2, 0);
        _act(17, 0, 0, 0, 1);
        _act(8, 0, 0, 0, 0);
        assertGt(y.epoch(), 0, "full loss wrote off the reward epoch");
        _act(17, 0, 0, 0, high);
        _act(8, 0, 0, 0, 0);
        _act(23, 0, 0, 0, 0);
        for (uint256 i; i < depth; ++i) {
            uint256 r = _next(); uint256 op = (r >> 16) % 12;
            uint256 a = r % 4; uint256 b = (r >> 8) % 4;
            if (op == 0) _act(0, a, 0, b, ((r >> 32) % 10 + 1) * 1e15);
            else if (op == 1) _act(1, a, 0, b, type(uint256).max);
            else if (op == 2 || op == 3) _act(op, op == 2 ? a : b, a, b, vault.balanceOf(actors[a]) / 20);
            else if (op == 4) _act(4, a, a, 0, vault.walletOf(actors[a]) / 100);
            else if (op == 5) _act(5, a, 0, 0, 5);
            else if (op == 6 || op == 8 || op == 9) _act(op, a, 0, 0, 0);
            else if (op == 7) _act(7, a, 0, b, (r >> 32) % (vault.queueTail() + 1));
            else if (op == 10) _act(10, 0, 0, 0, 15);
            else _act(17, 0, 0, 0, (110 + (r >> 32) % 50) * 1e16);
        }
        _act(10, 0, 0, 0, 20);
        for (uint256 i; i < 6; ++i) { _act(6, 0, 0, 0, 0); _act(5, 0, 0, 0, 100); }
        for (uint256 id; id < vault.queueTail(); ++id) _act(7, 3, 0, 2, id);
        _record([uint256(998), seed, depth, 2, step - 1], 0, 0);
    }
}
