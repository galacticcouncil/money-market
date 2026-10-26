// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {SubLoop} from "../../src/SubLoop.sol";
import {JuicerDiscount} from "../../src/JuicerDiscount.sol";
import {SyntheticToken} from "../../src/SyntheticToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {
    MockDiscountAToken, MockDiscountDebtToken, MockDiscountLoop, MockDiscountVault
} from "../mocks/MockDiscount.sol";
import {Artifacts} from "../helpers/Artifacts.t.sol";

contract LeanConfigParityTest is Test {
    string internal vectors = vm.readFile("formal/config-vectors.json");
    address constant POOL = address(0xAA0E);
    address constant COMMITTEE = address(0xC011);
    address constant HOLLAR = address(0x4011A);

    function _count(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(vectors, string.concat(".", key, "Count"));
    }

    function _row(string memory key, uint256 i) internal view returns (uint256[] memory) {
        return vm.parseJsonUintArray(vectors, string.concat(".", key, "[", vm.toString(i), "]"));
    }

    function test_leanBandRegistryOnSubLoop() public {
        MockPool pool = new MockPool();
        MockERC20 hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        MockERC20 prime = new MockERC20("PRIME", "PRIME", 6);
        MockERC20 aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        SubLoop loop = SubLoop(Artifacts.proxy(Artifacts.subLoop(), abi.encodeCall(SubLoop.initialize,
            (address(pool), address(hollar), address(prime), address(aPrime), 1.05e18, 1.10e18, address(this)))));
        address[3] memory vaults = [address(0xA11), address(0xB22), address(0xC33)];
        loop.registerVault(vaults[0]);
        loop.registerVault(vaults[1]);
        uint256 n = _count("band");
        for (uint256 i; i < n; ++i) {
            uint256[] memory r = _row("band", i);
            bytes memory data = r[0] == 0
                ? abi.encodeCall(loop.setRebalanceBand, (vaults[r[1]], uint16(r[2]), uint16(r[3]), uint16(r[4])))
                : abi.encodeCall(loop.setAdmissionMaxDeficitBps, (uint16(r[4])));
            (bool ok, bytes memory reason) = address(loop).call(data);
            assertEq(ok ? 1 : 0, r[5], "setter outcome");
            if (!ok) assertEq(bytes4(reason), SubLoop.InvalidParameters.selector);
            for (uint256 v; v < 3; ++v) {
                (uint16 target, uint16 relever, uint16 delever) = loop.rebalanceBand(vaults[v]);
                assertEq(target, r[6 + 3 * v], "target gap");
                assertEq(relever, r[7 + 3 * v], "relever gap");
                assertEq(delever, r[8 + 3 * v], "delever gap");
            }
            assertEq(loop.admissionMaxDeficitBps(), r[15], "admission bound");
        }
    }

    function _discount() internal returns (JuicerDiscount discount, MockDiscountLoop loop) {
        SyntheticToken synth = SyntheticToken(Artifacts.syntheticToken("Synthetic", "jsHOLLAR", address(this)));
        MockDiscountAToken aSynth = new MockDiscountAToken(POOL, address(synth));
        MockDiscountDebtToken debt = new MockDiscountDebtToken(POOL);
        discount = new JuicerDiscount(address(debt), address(synth), address(aSynth), address(this), COMMITTEE);
        debt.setPolicy(address(discount));
        debt.setUnderlying(HOLLAR);
        MockDiscountVault vault = new MockDiscountVault(POOL, address(synth), address(debt), address(discount));
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop = new MockDiscountLoop(POOL, HOLLAR);
        vault.setYieldSource(address(loop));
        discount.registerVault(address(vault));
    }

    function test_leanDiscountRates() public {
        (JuicerDiscount discount, MockDiscountLoop loop) = _discount();
        uint256 n = _count("discount");
        for (uint256 i; i < n; ++i) {
            uint256[] memory r = _row("discount", i);
            discount.setDiscountBps(uint16(r[0]));
            discount.setLoopDiscountBps(uint16(r[1]));
            if (r[2] == 0) {
                if (discount.loop() != address(0)) discount.unregisterLoop();
            } else if (discount.loop() == address(0)) {
                discount.registerLoop(address(loop), r[2]);
            } else {
                discount.setLoopCap(r[2]);
            }
            assertEq(discount.calculateDiscountRate(r[3], r[4]), r[5], "discount rate");
            assertEq(discount.balanceOf(address(loop)), r[6], "loop eligibility");
        }
    }

    function test_leanDiscountSetters() public {
        (JuicerDiscount discount, MockDiscountLoop loop) = _discount();
        discount.registerLoop(address(loop), 1);
        uint256 n = _count("setter");
        for (uint256 i; i < n; ++i) {
            uint256[] memory r = _row("setter", i);
            bytes memory data = r[0] == 0 ? abi.encodeCall(discount.setDiscountBps, (uint16(r[1])))
                : r[0] == 1 ? abi.encodeCall(discount.setLoopDiscountBps, (uint16(r[1])))
                : abi.encodeCall(discount.setLoopCap, (r[1]));
            (bool ok,) = address(discount).call(data);
            assertEq(ok ? 1 : 0, r[2], "setter outcome");
            assertEq(discount.discountBps(), r[3], "Main rate");
            assertEq(discount.loopDiscountBps(), r[4], "loop rate");
            assertEq(discount.loopCap(), r[5], "loop cap");
        }
    }
}
