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

/// @notice Deposits are priced against source carry that is accrued but not
///         yet harvested, and the source skims only through the Harvester.
contract DepositCarryPricingTest is Test {
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
    PropellerFeeController fees;

    address holder = makeAddr("holder");
    address late = makeAddr("late");

    /// simulated PRIME yield accruing to the loop (USD, 6dp aPRIME)
    uint256 constant CARRY = 60e6; // $60 on a ~$2.2k seed

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
        synth = new SyntheticToken("Propeller Synthetic", "psHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
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
                        (address(pool), address(hollar), address(prime), address(aPrime), 1.05e18, 1.10e18, address(this))
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
                            "Propeller ETH", "pETH", address(eth), address(pool), address(loop),
                            address(swapper), address(hollar), address(synth), address(aEth),
                            address(hollarDebt), 1_000e18, address(this)
                        )
                    )
                )
            )
        );
        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.setCompoundSlippageBps(100);
        harvester.addVault(address(vault));
        fees = new PropellerFeeController(address(this), address(0xFEE));
        harvester.setFeeController(address(fees));
        vault.setFeeController(address(fees));
        fees.registerVault(address(vault), address(harvester));
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        eth.mint(who, amount);
        vm.startPrank(who);
        eth.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _valueOf(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    function _seedWithCarry() internal {
        // bootstrap (governance-only first deposit), then the existing holder
        eth.mint(address(this), 0.01e18);
        eth.approve(address(vault), 0.01e18);
        vault.deposit(0.01e18, address(this));
        _depositAs(holder, 1e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();
        // carry accrues to the loop while only the existing holders are in
        aPrime.mint(address(loop), CARRY);
    }

    /// A deposit made while carry is pending buys in at the value existing
    /// shares already accrued, so the next harvest does not re-split it.
    function test_lateDepositDoesNotShareAccruedCarry() public {
        _seedWithCarry();
        uint256 holderBefore = _valueOf(holder);
        uint256[] memory minOuts = new uint256[](1);

        uint256 snap = vm.snapshotState();
        harvester.harvest(minOuts);
        uint256 holderGainAlone = _valueOf(holder) - holderBefore;
        assertGt(holderGainAlone, 0, "carry reaches the holder");
        vm.revertToState(snap);

        assertGt(fees.pendingCarry(address(vault)), 0, "carry pending before harvest");
        _depositAs(late, 9e18);
        harvester.harvest(minOuts);

        uint256 holderGain = _valueOf(holder) - holderBefore;
        uint256 lateValue = _valueOf(late);
        emit log_named_decimal_uint("holder gain, harvested alone (ETH)", holderGainAlone, 18);
        emit log_named_decimal_uint("holder gain, late deposit first (ETH)", holderGain, 18);
        emit log_named_decimal_uint("late depositor value (ETH)", lateValue, 18);

        assertApproxEqRel(holderGain, holderGainAlone, 0.02e18, "holder keeps the carry it accrued");
        assertLe(lateValue, 9e18 + holderGainAlone / 50, "late deposit gains no accrued carry");
    }

    /// Only the Harvester can skim, so realised carry is always distributed in
    /// the same call and never sits outside the vaults' pricing.
    function test_sourceHarvestOnlyThroughHarvester() public {
        _seedWithCarry();
        uint256 equityBefore = loop.totalEquity();

        vm.prank(late);
        vm.expectRevert(SubLoop.NotHarvester.selector);
        loop.harvest();

        assertEq(prime.balanceOf(address(harvester)), 0, "nothing parked");
        assertEq(loop.totalEquity(), equityBefore, "carry stays in the loop");
    }

    function test_pendingCarryClearsOnHarvest() public {
        _seedWithCarry();
        uint256 pending = fees.pendingCarry(address(vault));
        // $60 carry at $3k ETH, net of the 5% fee
        assertApproxEqRel(pending, uint256(60e18) / 3_000 * 95 / 100, 0.01e18);
        harvester.harvest(new uint256[](1));
        assertLt(fees.pendingCarry(address(vault)), pending / 100, "harvest realises the carry");
    }
}
