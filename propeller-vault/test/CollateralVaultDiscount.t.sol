// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {PropellerDiscount} from "../src/PropellerDiscount.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";
import {MockDiscountAToken, MockDiscountDebtToken} from "./mocks/MockDiscount.sol";

contract CollateralVaultDiscountTest is Test {
    address constant COMMITTEE = address(0xC011);
    MockERC20 collateral;
    MockERC20 hollar;
    MockPool pool;
    SyntheticToken synth;
    MockDiscountAToken aSynth;
    MockDiscountDebtToken debt;
    PropellerDiscount discount;
    CollateralVault vault;

    function setUp() public {
        pool = new MockPool();
        collateral = new MockERC20("tBTC", "tBTC", 18);
        MockERC20 aCollateral = new MockERC20("atBTC", "atBTC", 18);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        debt = new MockDiscountDebtToken(address(pool));
        synth = new SyntheticToken("Synthetic", "psHOLLAR", address(this));
        aSynth = new MockDiscountAToken(address(pool), address(synth));
        pool.initReserve(
            address(collateral),
            address(aCollateral),
            address(new MockERC20("dBTC", "dBTC", 18)),
            8_500,
            8_000,
            18,
            100_000e18
        );
        pool.initReserve(address(hollar), address(new MockERC20("aH", "aH", 18)), address(debt), 0, 0, 18, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(new MockERC20("dS", "dS", 18)), 9_800, 100, 18, 1e18);
        MockYieldSource source = new MockYieldSource(address(hollar));
        vault = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Propeller tBTC",
                            "ptBTC",
                            address(collateral),
                            address(pool),
                            address(source),
                            address(0),
                            address(hollar),
                            address(synth),
                            address(aCollateral),
                            address(debt),
                            100e18,
                            address(this)
                        )
                    )
                )
            )
        );
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        discount = new PropellerDiscount(address(debt), address(synth), address(aSynth), address(this), COMMITTEE);
        debt.setPolicy(address(discount));
        collateral.mint(address(this), 10e18);
        collateral.approve(address(vault), type(uint256).max);
    }

    function _enable() internal {
        vault.setDiscountController(address(discount));
        discount.registerVault(address(vault));
        vm.prank(COMMITTEE);
        discount.setDiscountBps(8_000);
    }

    function test_firstDepositRefreshesAfterSynthSupply() public {
        _enable();
        assertEq(debt.getDiscountPercent(address(vault)), 0, "no position yet");
        vault.deposit(1e18, address(this));
        assertEq(synth.balanceOf(address(vault)), 0);
        assertGt(aSynth.balanceOf(address(vault)), 0);
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
        assertEq(debt.lastEligibleBalance(address(vault)), aSynth.balanceOf(address(vault)));
    }

    function test_incrementalDepositAndPegMaintenanceRefreshBacking() public {
        _enable();
        vault.deposit(1e18, address(this));
        vault.deposit(1e18, address(this));
        assertEq(debt.lastEligibleBalance(address(vault)), aSynth.balanceOf(address(vault)));
        debt.mint(address(vault), 10_000e18); // simulated accrued debt exceeding the old backing
        vault.maintainPeg();
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
        assertEq(debt.lastEligibleBalance(address(vault)), aSynth.balanceOf(address(vault)));
    }

    function test_upRebalanceRefreshesAfterNewSynthetic() public {
        _enable();
        vault.deposit(1e18, address(this));
        uint256 oldDebt = debt.balanceOf(address(vault));
        pool.setPrice(address(collateral), 200_000e18);
        vault.rebalance();
        assertGt(debt.balanceOf(address(vault)), oldDebt);
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
        assertEq(debt.lastEligibleBalance(address(vault)), aSynth.balanceOf(address(vault)));
    }

    function test_settleRefreshesAfterSyntheticWithdrawal() public {
        _enable();
        uint256 shares = vault.deposit(1e18, address(this));
        uint256 beforeSynth = aSynth.balanceOf(address(vault));
        uint256 request = vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        assertLt(aSynth.balanceOf(address(vault)), beforeSynth);
        assertEq(debt.lastEligibleBalance(address(vault)), aSynth.balanceOf(address(vault)));
        assertGt(vault.claim(request, address(this)), 0);
    }

    function test_detachImmediatelyClearsDiscountAndExitsStillWork() public {
        _enable();
        uint256 shares = vault.deposit(1e18, address(this));
        vault.setDiscountController(address(0));
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        assertTrue(synth.hasRole(synth.MINTER_ROLE(), address(vault)));
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        assertGt(vault.claim(request, address(this)), 0);
    }

    function test_unregisterLeavesRepaymentAndPegMaintenanceAvailable() public {
        _enable();
        uint256 shares = vault.deposit(1e18, address(this));
        discount.unregisterVault(address(vault));
        vault.maintainPeg();
        uint256 request = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        assertGt(vault.claim(request, address(this)), 0);
    }

    function test_committeeCannotChangeVaultControllerOrEligibility() public {
        _enable();
        vm.startPrank(COMMITTEE);
        vm.expectRevert();
        vault.setDiscountController(address(0));
        vm.expectRevert();
        discount.unregisterVault(address(vault));
        vm.stopPrank();
    }

    function test_legacyVaultWithoutControllerRemainsUndiscounted() public {
        discount.setDiscountBps(8_000);
        vault.deposit(1e18, address(this));
        assertEq(vault.discountController(), address(0));
        assertEq(debt.getDiscountPercent(address(vault)), 0);
    }
}
