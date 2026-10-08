// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerFeeController} from "../src/PropellerFeeController.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @notice two vaults (eth 75% ltv, tbtc 80%) share one subloop and harvester;
///         each earns carry in its own collateral and an eth exit leaves tbtc untouched.
contract MultiVaultFlowTest is Test {
    MockERC20 eth; MockERC20 aEth; MockERC20 ethDebt;
    MockERC20 tbtc; MockERC20 aTbtc; MockERC20 tbtcDebt;
    MockERC20 hollar; MockERC20 aHollar; MockERC20 hollarDebt;
    MockERC20 prime; MockERC20 aPrime; MockERC20 primeDebt;
    MockERC20 aSynth; MockERC20 synthDebt;

    MockPool pool;
    MockSwapper swapper;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault ethVault;
    CollateralVault tbtcVault;
    Harvester harvester;
    PropellerFeeController fees;

    address constant ETH_USER = address(0xE0);
    address constant BTC_USER = address(0xB0);

    function setUp() public {
        eth = new MockERC20("ETH", "ETH", 18);
        aEth = new MockERC20("aETH", "aETH", 18);
        ethDebt = new MockERC20("dETH", "dETH", 18);
        tbtc = new MockERC20("tBTC", "tBTC", 18);
        aTbtc = new MockERC20("atBTC", "atBTC", 18);
        tbtcDebt = new MockERC20("dtBTC", "dtBTC", 18);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);
        hollarDebt = new MockERC20("dHOLLAR", "dHOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("dPRIME", "dPRIME", 6);
        synth = new SyntheticToken("Propeller Synthetic", "psHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        // lark-2 reserve configs: ETH LT85/LTV75 @$3000, tBTC LT85/LTV80 @$60000
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(tbtc), address(aTbtc), address(tbtcDebt), 8500, 8000, 18, 60_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        swapper = new MockSwapper(address(pool));

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
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
        ethVault = _deployVault("Propeller ETH", "pETH", address(eth), address(aEth));
        tbtcVault = _deployVault("Propeller tBTC", "ptBTC", address(tbtc), address(aTbtc));
        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(ethVault));
        synth.grantRole(synth.MINTER_ROLE(), address(tbtcVault));
        RoundingReserveFixture.fund(ethVault);
        RoundingReserveFixture.fund(tbtcVault);
        loop.registerVault(address(ethVault));
        loop.registerVault(address(tbtcVault));
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        ethVault.setCompoundSlippageBps(100);
        tbtcVault.setCompoundSlippageBps(100);
        harvester.addVault(address(ethVault));
        harvester.addVault(address(tbtcVault));
        fees = new PropellerFeeController(address(this), address(0xFEE));
        harvester.setFeeController(address(fees));
        ethVault.setFeeController(address(fees));
        tbtcVault.setFeeController(address(fees));
        fees.registerVault(address(ethVault), address(harvester));
        fees.registerVault(address(tbtcVault), address(harvester));
        _bootstrapVaults();
    }

    function _bootstrapVaults() internal virtual {
        // Governance, not the first public depositor, funds the locked shares.
        eth.mint(address(this), 1e12);
        eth.approve(address(ethVault), 1e12);
        ethVault.deposit(1e12, address(this));
        ethVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        tbtc.mint(address(this), 1e12);
        tbtc.approve(address(tbtcVault), 1e12);
        tbtcVault.deposit(1e12, address(this));
        tbtcVault.rebalance(); // Explicit keeper deployment before exercising a live position.
    }

    function _deployVault(string memory n, string memory s, address coll, address aTok)
        internal
        returns (CollateralVault v)
    {
        v = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            n, s, coll, address(pool), address(loop), address(swapper),
                            address(hollar), address(synth), aTok, address(hollarDebt),
                            1_000e18, address(this)
                        )
                    )
                )
            )
        );
    }

    function test_sourceEmergencyFreezesBothVaultsAndPreservesLocalPause() public {
        ethVault.pause();
        loop.pauseEmergency();
        assertTrue(ethVault.paused());
        assertTrue(tbtcVault.paused());
        vm.expectRevert("Pausable: paused");
        tbtcVault.requestRedeem(1, address(this));
        vm.expectRevert("Pausable: paused");
        tbtcVault.claim(0, address(this));
        loop.unpauseEmergency();
        assertTrue(ethVault.paused(), "local pause remains in force");
        assertFalse(tbtcVault.paused());
        ethVault.unpause();
        assertFalse(ethVault.paused());
    }

    function test_fullFlowTwoVaultsYieldInKind() public {
        // supply: 1 eth ($3000 → $2250 @75%) + 0.1 tbtc ($6000 → $4800 @80%)
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        uint256 ethShares = ethVault.deposit(1e18, ETH_USER);
        ethVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        vm.stopPrank();

        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        tbtcVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        vm.stopPrank();

        // loop seeded with both Main borrows: $2250 + $4800 = $7050
        assertApproxEqRel(loop.totalEquity(), 7_050e8, 0.01e18, "shared loop seeded by both");

        // ramp the shared loop to target hf
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
        assertApproxEqRel(loop.healthFactor(), 1.05e18, 0.03e18, "shared loop at target HF");
        uint256 basis = loop.principalEquity() / 1e10;

        // +5% prime yield on the levered position (~$2177)
        uint256 yieldPrime = aPrime.balanceOf(address(loop)) * 5 / 100;
        aPrime.mint(address(loop), yieldPrime);
        uint256 retained8 = loop.executionCostReserve() / 1e10;

        // one harvest splits carry by loop shares into each vault's own collateral
        uint256[] memory minOuts = new uint256[](2);
        harvester.harvest(minOuts);

        uint256 ethGain = aEth.balanceOf(address(ethVault)) - 1e18 - 1e12; // excludes governance seed
        uint256 tbtcGain = aTbtc.balanceOf(address(tbtcVault)) - 0.1e18 - 1e12;
        assertGt(ethGain, 0, "ETH vault earned ETH");
        assertGt(tbtcGain, 0, "tBTC vault earned tBTC");

        // in-kind: nothing cross-contaminated
        assertEq(aTbtc.balanceOf(address(ethVault)), 0, "no tBTC in the ETH vault");
        assertEq(aEth.balanceOf(address(tbtcVault)), 0, "no ETH in the tBTC vault");

        uint256 ethFee = fees.claimableProtocolFees(address(eth));
        uint256 tbtcFee = fees.claimableProtocolFees(address(tbtc));
        assertGt(ethFee, 0);
        assertGt(tbtcFee, 0);
        fees.claimProtocolFees(address(eth));
        assertEq(eth.balanceOf(address(0xFEE)), ethFee);
        assertEq(fees.claimableProtocolFees(address(tbtc)), tbtcFee);
        fees.claimProtocolFees(address(tbtc));
        assertEq(tbtc.balanceOf(address(0xFEE)), tbtcFee);

        // pro-rata by loop shares: USD gains split 2250 : 4800
        uint256 ethGainUsd = ethGain * 3_000 / 1e10; // 8dp USD
        uint256 tbtcGainUsd = tbtcGain * 60_000 / 1e10; // 8dp USD
        assertApproxEqRel(
            ethGainUsd * 4_800, tbtcGainUsd * 2_250, 0.01e18, "carry split pro-rata by loop shares"
        );
        assertApproxEqAbs(loop.totalEquity(), basis + retained8, 200,
            "un-compounded execution yield remains above basis");

        // yield tracks each vault's max ltv: tbtc (80%) beats eth (75%)
        assertGt(tbtcGain * 10, ethGain, "tBTC %-yield > ETH %-yield (higher LTV)");
        vm.prank(ETH_USER);
        ethShares += ethVault.claimYield(ETH_USER);
        vm.prank(BTC_USER);
        assertGt(tbtcVault.claimYield(BTC_USER), 0, "BTC earnings become funded receipt shares");

        // eth user redeems everything
        uint256 tbtcVaultCollBefore = aTbtc.balanceOf(address(tbtcVault));
        uint256 tbtcLoopSharesBefore = tbtcVault.loopShares();

        vm.prank(ETH_USER);
        uint256 reqId = ethVault.requestRedeem(ethShares, ETH_USER);
        vm.warp(vm.getBlockTimestamp() + ethVault.withdrawalDelay());
        ethVault.startUnwinds(100);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        ethVault.pokeSettle();
        vm.prank(ETH_USER);
        uint256 got = ethVault.claim(reqId, ETH_USER);

        // principal + ~23% compounded carry
        assertGt(got, 1e18, "exit returns principal + yield, in ETH");
        assertApproxEqRel(got, 1e18 + ethGain, 0.02e18, "exit ~ principal + compounded gain");

        // cross-vault isolation: the tBTC position is untouched by the ETH exit
        assertEq(aTbtc.balanceOf(address(tbtcVault)), tbtcVaultCollBefore, "tBTC collateral untouched");
        assertEq(tbtcVault.loopShares(), tbtcLoopSharesBefore, "tBTC loop shares untouched");
        assertGt(loop.totalEquity(), 0, "tBTC slice still in the loop");
    }

    /// one year at 6.5% prime supply vs 4.4% hollar borrow on every debt leg;
    /// net per deposit must match (1 - fee) * loopCarry - main interest.
    function test_netCarryAfterHollarBorrowCost() public {
        uint256 PRIME_APY_BPS = 650; // 6.5% PRIME supply
        uint256 BORROW_APY_BPS = 440; // 4.4% HOLLAR variable borrow

        // supply + ramp (same as the flow test)
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        ethVault.deposit(1e18, ETH_USER);
        ethVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        vm.stopPrank();
        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        tbtcVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        vm.stopPrank();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        (uint256 loopColl8, uint256 loopDebt8,,,,) = pool.getUserAccountData(address(loop));
        uint256 loopLevWad = (loopColl8 * 1e18) / (loopColl8 - loopDebt8); // ~6.17e18

        // one year: yield on the prime leg, interest on every debt leg
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) * PRIME_APY_BPS / 10_000);
        hollarDebt.mint(address(loop), hollarDebt.balanceOf(address(loop)) * BORROW_APY_BPS / 10_000);
        uint256 ethMainInt = hollarDebt.balanceOf(address(ethVault)) * BORROW_APY_BPS / 10_000;
        uint256 tbtcMainInt = hollarDebt.balanceOf(address(tbtcVault)) * BORROW_APY_BPS / 10_000;
        hollarDebt.mint(address(ethVault), ethMainInt);
        hollarDebt.mint(address(tbtcVault), tbtcMainInt);

        // peg upkeep: synth re-tops to cover the accrued Main debt (INV-1)
        ethVault.maintainPeg();
        tbtcVault.maintainPeg();
        assertGe(
            aSynth.balanceOf(address(ethVault)) * 9800 / 1e4,
            hollarDebt.balanceOf(address(ethVault)),
            "synth covers accrued ETH Main debt"
        );

        // harvest skims gross prime yield minus the loop's borrow cost
        uint256 retained8 = loop.executionCostReserve() / 1e10;
        uint256 expectedLoopNet8 =
            (loopColl8 * PRIME_APY_BPS - loopDebt8 * BORROW_APY_BPS) / 10_000 - retained8;
        uint256 primeBefore = aPrime.balanceOf(address(loop));
        harvester.harvest(new uint256[](2));
        uint256 surplusPrime = primeBefore - aPrime.balanceOf(address(loop)); // PRIME 6dp
        assertApproxEqRel(surplusPrime * 100, expectedLoopNet8, 0.01e18,
            "skim = gross - loop borrow cost - retained execution yield");

        // net per deposit applies the protocol fee before subtracting main interest
        uint256 spreadBps = PRIME_APY_BPS - BORROW_APY_BPS; // 210
        // ETH: deposit $3000 at 75%
        uint256 ethGainUsd8 = (aEth.balanceOf(address(ethVault)) - 1e18) * 3_000 / 1e10;
        // main interest is paid before compounding; don't deduct it twice
        uint256 ethNetUsd8 = ethGainUsd8;
        uint256 ethModel8 = (3_000e8 * 7_500 / 10_000) * loopLevWad / 1e18 * spreadBps / 10_000;
        ethModel8 = (ethModel8 + ethMainInt / 1e10 - retained8 * 2250 / 7050)
            * 9_500 / 10_000 - ethMainInt / 1e10;
        assertApproxEqRel(ethNetUsd8, ethModel8, 0.02e18, "ETH net after harvest fee and Main interest");
        // tBTC: deposit $6000 at 80%
        uint256 tbtcGainUsd8 = (aTbtc.balanceOf(address(tbtcVault)) - 0.1e18) * 60_000 / 1e10;
        uint256 tbtcNetUsd8 = tbtcGainUsd8;
        uint256 tbtcModel8 = (6_000e8 * 8_000 / 10_000) * loopLevWad / 1e18 * spreadBps / 10_000;
        tbtcModel8 = (tbtcModel8 + tbtcMainInt / 1e10 - retained8 * 4800 / 7050)
            * 9_500 / 10_000 - tbtcMainInt / 1e10;
        assertApproxEqRel(tbtcNetUsd8, tbtcModel8, 0.02e18, "tBTC net after harvest fee and Main interest");

        // tbtc ~10.4% vs eth ~9.7% at these rates
        assertGt(tbtcNetUsd8 * 3_000e8 / 6_000e8, ethNetUsd8, "tBTC net %-yield > ETH net %-yield");
    }

    /// swap costs (5 bps loop legs, 50 bps compound) dent the ramp equity, the
    /// realized gain and the exit, but principal + yield survive.
    function test_swapCostsReduceRealizedYield() public {
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(5); // measured: 4 bps + impact
        swapper.setHaircut(50); // measured: 46-51 bps (< the 100 bps oracle floor)

        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        uint256 ethShares = ethVault.deposit(1e18, ETH_USER);
        ethVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        vm.stopPrank();
        // The first entry's execution deficit must recover before new entry.
        assertTrue(tbtcVault.isUnderfunded());
        hollar.mint(address(loop), 2e18);
        assertFalse(tbtcVault.isUnderfunded());
        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        tbtcVault.rebalance(); // Explicit keeper deployment before exercising a live position.
        vm.stopPrank();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        // ramp cost: 5 bps over ~$43.5k swapped ≈ $22 → equity < $7050 seed
        uint256 equity = loop.totalEquity();
        assertLt(equity, 7_050e8, "ramp fees dent the equity");
        assertGt(equity, 7_010e8, "...by roughly fee x levered volume (~$22)");

        // below cost basis harvest is a no-op until carry refills the fee hole
        vm.prank(address(harvester));
        assertEq(loop.harvest(), 0, "no skim below cost basis");

        // 5% prime yield, then harvest + compound
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) * 5 / 100);
        uint256 harvestable8 = loop.totalEquity() - loop.principalEquity() / 1e10
            - loop.executionCostReserve() / 1e10;
        uint256 ethWeight = ethVault.prepareHarvest();
        uint256 btcWeight = tbtcVault.prepareHarvest();
        uint256 expectedGrossEth = harvestable8 * ethWeight
            / (ethWeight + btcWeight) * 9950 / 10_000 * 1e10 / 3000;
        uint256[] memory minOuts = new uint256[](2);
        harvester.harvest(minOuts);

        uint256 ethGain = aEth.balanceOf(address(ethVault)) - 1e18 - 1e12;
        // frictionless gain is ~0.2316 eth
        assertLt(ethGain, 0.2316e18, "swap costs reduce the realized gain");
        uint256 grossEthGain = ethGain + fees.claimableProtocolFees(address(eth));
        assertApproxEqAbs(grossEthGain, expectedGrossEth, 2e10,
            "compound only carry above the execution holdback, after modeled swap costs");
        // protocol source units and servicing fees round independently
        assertApproxEqAbs(fees.claimableProtocolFees(address(eth)), grossEthGain / 20, 1,
            "five-percent fee, allowing one unit of source/receipt rounding");

        // an incomplete exit is a partial payment, never a finalized haircut
        vm.prank(ETH_USER);
        ethShares += ethVault.claimYield(ETH_USER);
        vm.prank(ETH_USER);
        uint256 reqId = ethVault.requestRedeem(ethShares, ETH_USER);
        vm.warp(vm.getBlockTimestamp() + ethVault.withdrawalDelay());
        ethVault.startUnwinds(100);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        ethVault.pokeSettle();
        vm.prank(ETH_USER);
        uint256 got = ethVault.claim(reqId, ETH_USER);
        assertGt(got, 1e18, "principal + yield survive the round-trip costs");
        assertGt(got, ((1e18 + ethGain) * 99) / 100, "unwind fee ~6bps x leverage");
        (, , uint256 promised, , , , , , bool active) = ethVault.redemptions(reqId);
        assertEq(got, promised, "earned execution yield covers the full recorded promise");
        assertFalse(active, "only fully paid requests close");
        assertEq(ethVault.totalQueuedCollateral(), 0);
    }
}
