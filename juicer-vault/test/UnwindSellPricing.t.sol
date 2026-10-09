// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice the unwind sell is sized at the oracle prime price, so loop hf stays
///         >= STEP_HF_FLOOR after a sell even when prime trades above $1.
contract UnwindSellPricingTest is Test {
    // mirrors SubLoop.STEP_HF_FLOOR (internal)
    uint256 constant STEP_HF_FLOOR = 1.02e18;

    MockERC20 eth;
    MockERC20 aEth;
    MockERC20 ethDebt;
    MockERC20 hollar;
    MockERC20 aHollar;
    MockERC20 hollarDebt;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt;
    MockERC20 aSynth;
    MockERC20 synthDebt;

    MockPool pool;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;

    function setUp() public {
        eth = new MockERC20("ETH", "ETH", 18);
        aEth = new MockERC20("aETH", "aETH", 18);
        ethDebt = new MockERC20("dETH", "dETH", 18);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);
        hollarDebt = new MockERC20("dHOLLAR", "dHOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("dPRIME", "dPRIME", 6);
        synth = new SyntheticToken("Juicer Synthetic", "jsHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool),
                            address(hollar),
                            address(prime),
                            address(aPrime),
                            1.05e18,
                            1.10e18,
                            address(this)
                        )
                    )
                )
            )
        );

        vault = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Juicer ETH",
                            "jETH",
                            address(eth),
                            address(pool),
                            address(loop),
                            address(0),
                            address(hollar),
                            address(synth),
                            address(aEth),
                            address(hollarDebt),
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function test_unwindSellSurvivesPrimeAppreciation() public {
        // deposit 1 eth and ramp the loop to target hf (~1.05) at prime = $1
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
        assertApproxEqRel(loop.healthFactor(), 1.05e18, 0.03e18, "loop ramped to target");

        // prime appreciates +30%; the loop is more collateralised, nothing should be unsafe
        pool.setPrice(address(prime), 1.30e18);

        // open a redemption so the unwind spiral has work to do
        vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        assertGt(loop.unwindTargetEquity(), 0, "unwind is open");

        uint256 aPrimeBefore = aPrime.balanceOf(address(loop));
        uint256 targetBefore = loop.unwindTargetEquity();

        // a $1-sized sell at $1.30 would oversell ~30% and revert the in-route withdraw
        bool reverted;
        try loop.pokeRepay() {
            // ok
        } catch {
            reverted = true;
        }
        assertFalse(reverted, "pokeRepay reverted: unwind sell oversized at PRIME>$1 breached Aave HF");

        // the step must actually sell and progress, not pass by selling nothing
        assertLt(aPrime.balanceOf(address(loop)), aPrimeBefore, "an actual aPRIME sell occurred");
        assertLt(loop.unwindTargetEquity(), targetBefore, "unwind made progress (equity freed)");

        // the repay leg lifts hf back up after the safe-sized sell
        assertGe(loop.healthFactor(), STEP_HF_FLOOR, "loop left healthy after the unwind step");
    }
}
