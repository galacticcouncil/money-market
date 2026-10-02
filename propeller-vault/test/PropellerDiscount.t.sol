// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {PropellerDiscount} from "../src/PropellerDiscount.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockDiscountAToken, MockDiscountDebtToken, MockDiscountVault} from "./mocks/MockDiscount.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PropellerDiscountTest is Test {
    address constant POOL = address(0xAA0E);
    address constant COMMITTEE = address(0xC011);
    address constant OUTSIDER = address(0xBAD);
    SyntheticToken synth;
    MockDiscountAToken aSynth;
    MockDiscountDebtToken debt;
    PropellerDiscount discount;
    MockDiscountVault vault;

    function setUp() public {
        synth = new SyntheticToken("Synthetic", "psHOLLAR", address(this));
        aSynth = new MockDiscountAToken(POOL, address(synth));
        debt = new MockDiscountDebtToken(POOL);
        discount = new PropellerDiscount(address(debt), address(synth), address(aSynth), address(this), COMMITTEE);
        debt.setPolicy(address(discount));
        vault = _newVault();
    }

    function _newVault() internal returns (MockDiscountVault v) {
        v = new MockDiscountVault(POOL, address(synth), address(debt), address(discount));
        synth.grantRole(synth.MINTER_ROLE(), address(v));
    }

    function _fundAndRegister(MockDiscountVault v) internal {
        discount.registerVault(address(v));
        aSynth.mint(address(v), 1_100e18);
        debt.mint(address(v), 1_000e18);
    }

    function test_startsAtZeroWithoutDeployerPrivileges() public {
        assertEq(discount.discountBps(), 0);
        vm.prank(OUTSIDER);
        PropellerDiscount other =
            new PropellerDiscount(address(debt), address(synth), address(aSynth), address(this), COMMITTEE);
        assertFalse(other.hasRole(other.DEFAULT_ADMIN_ROLE(), OUTSIDER));
        assertFalse(other.hasRole(other.RATE_ADMIN_ROLE(), OUTSIDER));
        assertTrue(other.hasRole(other.RATE_ADMIN_ROLE(), COMMITTEE));
        assertFalse(other.hasRole(other.DEFAULT_ADMIN_ROLE(), COMMITTEE));
    }

    function test_committeeCanIncreaseReduceDisableAndRestore() public {
        _fundAndRegister(vault);
        uint16[5] memory rates = [uint16(8_000), 10_000, 5_000, 0, 8_000];
        for (uint256 i; i < rates.length; ++i) {
            vm.prank(COMMITTEE);
            discount.setDiscountBps(rates[i]);
            assertEq(discount.discountBps(), rates[i]);
            assertEq(debt.getDiscountPercent(address(vault)), rates[i]);
        }
    }

    function test_committeeCannotEnrollBorrowersOrGrantRoles() public {
        bytes32 adminRole = discount.DEFAULT_ADMIN_ROLE();
        vm.startPrank(COMMITTEE);
        vm.expectRevert();
        discount.registerVault(address(vault));
        vm.expectRevert();
        discount.grantRole(adminRole, COMMITTEE);
        vm.stopPrank();
    }

    function test_outsiderCannotSetRateButCanRefresh() public {
        _fundAndRegister(vault);
        discount.setDiscountBps(8_000);
        vm.startPrank(OUTSIDER);
        vm.expectRevert();
        discount.setDiscountBps(10_000);
        discount.refreshAll();
        vm.stopPrank();
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
    }

    function test_governanceCanRevokeCommitteeRateAuthority() public {
        discount.revokeRole(discount.RATE_ADMIN_ROLE(), COMMITTEE);
        vm.prank(COMMITTEE);
        vm.expectRevert();
        discount.setDiscountBps(8_000);
        discount.setDiscountBps(5_000);
        assertEq(discount.discountBps(), 5_000);
    }

    function test_invalidRateAndUninstalledPolicyRevert() public {
        vm.expectRevert(PropellerDiscount.InvalidDiscount.selector);
        discount.setDiscountBps(10_001);
        debt.setPolicy(address(0));
        vm.expectRevert(PropellerDiscount.NotInstalled.selector);
        discount.setDiscountBps(8_000);
        vm.expectRevert(PropellerDiscount.NotInstalled.selector);
        discount.registerVault(address(vault));
    }

    function test_constructorRejectsWrongMarketAndZeroAuthority() public {
        MockDiscountAToken wrong = new MockDiscountAToken(address(0x123), address(synth));
        vm.expectRevert(PropellerDiscount.InvalidMarket.selector);
        new PropellerDiscount(address(debt), address(synth), address(wrong), address(this), COMMITTEE);
        vm.expectRevert(PropellerDiscount.ZeroAddress.selector);
        new PropellerDiscount(address(debt), address(synth), address(aSynth), address(this), address(0));
    }

    function test_constructorRejectsWrongSyntheticDecimals() public {
        MockERC20 wrongSynth = new MockERC20("Wrong", "WRONG", 6);
        MockDiscountAToken wrongReceipt = new MockDiscountAToken(POOL, address(wrongSynth));
        vm.expectRevert(PropellerDiscount.InvalidMarket.selector);
        new PropellerDiscount(address(debt), address(wrongSynth), address(wrongReceipt), address(this), COMMITTEE);
    }

    function test_rawSyntheticIsNotEligibility() public {
        discount.registerVault(address(vault));
        discount.setDiscountBps(8_000);
        vm.prank(address(vault));
        synth.mint(address(vault), 1_100e18);
        debt.mint(address(vault), 1_000e18);
        assertEq(discount.balanceOf(address(vault)), 0);
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        aSynth.mint(address(vault), 1_100e18);
        discount.refreshAll();
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
    }

    function test_receiptOrMinterRoleAloneCannotUnlockDiscount() public {
        discount.setDiscountBps(8_000);
        aSynth.mint(OUTSIDER, 1_100e18);
        debt.mint(OUTSIDER, 1_000e18);
        assertEq(debt.getDiscountPercent(OUTSIDER), 0);
        // Even a minter with backing must be explicitly enrolled by governance.
        aSynth.mint(address(vault), 1_100e18);
        debt.mint(address(vault), 1_000e18);
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        assertEq(discount.balanceOf(address(0x5100)), 0, "SubLoop not eligible");
    }

    function test_registrationRequiresMinterCorrectMarketAndRefreshHook() public {
        MockDiscountVault wrong = new MockDiscountVault(POOL, address(synth), address(debt), address(discount));
        vm.expectRevert(PropellerDiscount.InvalidVault.selector);
        discount.registerVault(address(wrong));
        vault.setController(address(0));
        vm.expectRevert(PropellerDiscount.InvalidVault.selector);
        discount.registerVault(address(vault));
        wrong = new MockDiscountVault(address(0x123), address(synth), address(debt), address(discount));
        synth.grantRole(synth.MINTER_ROLE(), address(wrong));
        vm.expectRevert(PropellerDiscount.InvalidVault.selector);
        discount.registerVault(address(wrong));
    }

    function test_dustBackingOnlyDiscountsProportionalDebt() public {
        discount.setDiscountBps(8_000);
        assertEq(discount.calculateDiscountRate(1_000e18, 500e18), 4_000);
        assertEq(discount.calculateDiscountRate(1_000e18, 1), 0);
        assertEq(discount.calculateDiscountRate(0, 1_000e18), 0);
        assertEq(discount.calculateDiscountRate(1_000e18, 0), 0);
    }

    function testFuzz_discountNeverExceedsConfiguredRate(uint256 debtBalance, uint256 backing) public {
        discount.setDiscountBps(8_000);
        uint256 result = discount.calculateDiscountRate(debtBalance, backing);
        assertLe(result, 8_000);
        if (debtBalance != 0 && backing >= debtBalance) assertEq(result, 8_000);
        if (debtBalance == 0 || backing == 0) assertEq(result, 0);
    }

    function test_rateChangeRefreshesAllIncludingLostEligibility() public {
        MockDiscountVault second = _newVault();
        MockDiscountVault third = _newVault();
        _fundAndRegister(vault);
        _fundAndRegister(second);
        _fundAndRegister(third);
        discount.setDiscountBps(8_000);
        synth.revokeRole(synth.MINTER_ROLE(), address(second));
        third.setController(address(0));
        vm.prank(COMMITTEE);
        discount.setDiscountBps(5_000);
        assertEq(debt.getDiscountPercent(address(vault)), 5_000);
        assertEq(debt.getDiscountPercent(address(second)), 0);
        assertEq(debt.getDiscountPercent(address(third)), 0);
    }

    function test_refreshFailureRollsBackRateAndEveryBorrower() public {
        MockDiscountVault second = _newVault();
        _fundAndRegister(vault);
        _fundAndRegister(second);
        discount.setDiscountBps(8_000);
        uint256 firstCount = debt.refreshCount(address(vault));
        debt.setFailingBorrower(address(second));
        vm.prank(COMMITTEE);
        vm.expectRevert("refresh failed");
        discount.setDiscountBps(0);
        assertEq(discount.discountBps(), 8_000);
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
        assertEq(debt.getDiscountPercent(address(second)), 8_000);
        assertEq(debt.refreshCount(address(vault)), firstCount);
    }

    function test_committeeCanDisableEvenWithBrokenVaultGetter() public {
        _fundAndRegister(vault);
        discount.setDiscountBps(8_000);
        vm.etch(address(vault), hex"00");
        vm.prank(COMMITTEE);
        discount.setDiscountBps(0);
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        discount.unregisterVault(address(vault));
        assertEq(discount.vaults().length, 0);
    }

    function test_unregisterClearsCacheWithoutRevokingMintPermission() public {
        _fundAndRegister(vault);
        discount.setDiscountBps(8_000);
        discount.unregisterVault(address(vault));
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        assertEq(discount.vaults().length, 0);
        assertTrue(synth.hasRole(synth.MINTER_ROLE(), address(vault)));
        vm.expectRevert(PropellerDiscount.NotRegistered.selector);
        discount.unregisterVault(address(vault));
    }

    function test_registryIsBoundedAndCanReuseRemovedSlots() public {
        discount.registerVault(address(vault));
        vm.expectRevert(PropellerDiscount.AlreadyRegistered.selector);
        discount.registerVault(address(vault));
        for (uint256 i = 1; i < discount.MAX_VAULTS(); ++i) {
            discount.registerVault(address(_newVault()));
        }
        MockDiscountVault extra = _newVault();
        vm.expectRevert(PropellerDiscount.TooManyVaults.selector);
        discount.registerVault(address(extra));
        discount.unregisterVault(address(vault));
        discount.registerVault(address(extra));
        vm.prank(COMMITTEE);
        discount.setDiscountBps(8_000);
        assertEq(discount.vaults().length, discount.MAX_VAULTS());
    }
}
