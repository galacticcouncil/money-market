// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Harvester} from "../src/Harvester.sol";
import {JuicerFeeController} from "../src/JuicerFeeController.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";
import {SubLoopLogic} from "../src/lib/SubLoopLogic.sol";

/// @notice harvest skims prime carry above cost basis and compounds it into the
///         eth vault's collateral; loop equity returns to its basis.
contract HarvestTest is Test {
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
    MockSwapper swapper;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;
    Harvester harvester;
    JuicerFeeController fees;

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
        // synth: lt 98%, small non-zero ltv so it can be enabled as collateral
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        swapper = new MockSwapper(address(pool));

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop(address(new SubLoopLogic()))),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool), address(hollar), address(prime),
                            address(aPrime), 1.05e18, 1.10e18, address(this)
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
                            "Juicer ETH", "jETH", address(eth), address(pool), address(loop),
                            address(swapper), address(hollar), address(synth), address(aEth),
                            address(hollarDebt), 1_000e18, address(this)
                        )
                    )
                )
            )
        );
        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        // compound needs a slippage tolerance set
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.setCompoundSlippageBps(100); // 1% vs oracle-fair
        harvester.addVault(address(vault));
        fees = new JuicerFeeController(address(this), address(0xFEE));
        harvester.setFeeController(address(fees));
        vault.setFeeController(address(fees));
        fees.registerVault(address(vault), address(harvester));
    }

    function _depositAndRamp() internal returns (uint256 shares) {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        shares = vault.deposit(1e18, address(this));
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    function test_harvestCompoundsYieldIntoSharePrice() public {
        _depositAndRamp();

        uint256 aEthBefore = aEth.balanceOf(address(vault)); // 1e18
        uint256 equityBasis = loop.totalEquity();

        // simulate PRIME yield: aPRIME accrues +5% in the loop's position
        uint256 yieldPrime = aPrime.balanceOf(address(loop)) * 5 / 100;
        aPrime.mint(address(loop), yieldPrime);
        assertGt(loop.totalEquity(), equityBasis, "yield raised equity");
        uint256 retained = loop.executionCostReserve();

        // harvest → compound into ETH collateral
        uint256[] memory minOuts = new uint256[](1);
        harvester.harvest(minOuts);

        // share price rose: vault's ETH collateral grew (yield compounded in)
        assertGt(aEth.balanceOf(address(vault)), aEthBefore, "yield compounded into jETH");
        assertApproxEqAbs(loop.totalEquity() * 1e10, loop.principalEquity() + retained, 1e12,
            "earned execution allowance stays in PRIME");
    }

    /// prime appreciation is carry: harvest skims it at the oracle price and
    /// compounds it into the deposit without dipping loop hf.
    function test_primePriceAppreciationCompoundsToDeposit() public {
        _depositAndRamp();
        uint256 hfBefore = loop.healthFactor();

        pool.setPrice(address(prime), 1.06e18); // PRIME +6%
        uint256 retained = loop.executionCostReserve();
        uint256 harvestable = loop.totalEquity() * 1e10 - loop.principalEquity() - retained;
        uint256 assetsBefore = vault.totalAssets();

        uint256[] memory minOuts = new uint256[](1);
        harvester.harvest(minOuts);

        assertApproxEqAbs(vault.totalAssets() - assetsBefore, harvestable * 95 / 100 / 3000, 1e9,
            "only net carry above earned cost allowance compounds");
        assertApproxEqAbs(loop.totalEquity() * 1e10, loop.principalEquity() + retained, 2e12,
            "oracle-priced cost allowance retained");
        // loop hf did not dip below where it started
        assertGe(loop.healthFactor() + 0.005e18, hfBefore, "harvest left HF at target");
    }

    /// harvest during an open redemption skims only carry above basis + in-flight
    /// unwinds, never the exiter's equity.
    function test_harvestSkipsInFlightUnwindEquity() public {
        uint256 shares = _depositAndRamp();
        uint256 equity0 = loop.totalEquity(); // ~2250e8

        // redeem half the position → ~half the equity in flight
        uint256 reqId = vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        uint256 inFlight = loop.unwindTargetEquity();
        assertApproxEqRel(inFlight, uint256(equity0) * 1e10 / 2, 0.01e18, "half equity in flight");

        // accrue enough carry for both the retained allowance and a harvest
        uint256 yieldPrime = aPrime.balanceOf(address(loop)) / 50;
        aPrime.mint(address(loop), yieldPrime);
        uint256 retained = loop.executionCostReserve();
        uint256 expected = (loop.totalEquity() * 1e10 - loop.principalEquity() - inFlight - retained) / 1e12;

        // harvest mid-redemption skims only the yield
        uint256 beforePrime = aPrime.balanceOf(address(loop));
        harvester.harvest(new uint256[](1));
        uint256 surplusPrime = beforePrime - aPrime.balanceOf(address(loop));
        assertApproxEqAbs(surplusPrime, expected, 1, "skim only carry above cost allowance");
        assertEq(loop.unwindTargetEquity(), inFlight, "in-flight equity untouched");

        // the exiter still settles to ~their full half ETH
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
        uint256 got = vault.claim(reqId, address(this));
        assertApproxEqRel(got, 0.5e18, 0.02e18, "exiter principal intact");
    }
}
