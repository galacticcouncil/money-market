// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerDiscount} from "../src/JuicerDiscount.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {
    MockDiscountAToken, MockDiscountDebtToken, MockDiscountLoop, MockDiscountVault
} from "./mocks/MockDiscount.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Artifacts} from "./helpers/Artifacts.t.sol";

contract JuicerDiscountTest is Test {
    address constant POOL = address(0xAA0E);
    address constant COMMITTEE = address(0xC011);
    address constant OUTSIDER = address(0xBAD);
    address constant HOLLAR = address(0x4011A);
    SyntheticToken synth;
    MockDiscountAToken aSynth;
    MockDiscountDebtToken debt;
    JuicerDiscount discount;
    MockDiscountVault vault;

    function setUp() public {
        synth = SyntheticToken(Artifacts.syntheticToken("Synthetic", "jsHOLLAR", address(this)));
        aSynth = new MockDiscountAToken(POOL, address(synth));
        debt = new MockDiscountDebtToken(POOL);
        discount = new JuicerDiscount(address(debt), address(synth), address(aSynth), address(this), COMMITTEE);
        debt.setPolicy(address(discount));
        vault = _newVault();
    }

    function _newVault() internal returns (MockDiscountVault v) {
        v = new MockDiscountVault(POOL, address(synth), address(debt), address(discount));
        synth.grantRole(synth.MINTER_ROLE(), address(v));
    }

    function _newLoop() internal returns (MockDiscountLoop l) {
        debt.setUnderlying(HOLLAR);
        l = new MockDiscountLoop(POOL, HOLLAR);
        vault.setYieldSource(address(l));
    }

    function _enrollLoop(uint256 cap) internal returns (MockDiscountLoop l) {
        l = _newLoop();
        _fundAndRegister(vault);
        discount.registerLoop(address(l), cap);
        debt.mint(address(l), 1_000e18);
    }

    function _fundAndRegister(MockDiscountVault v) internal {
        discount.registerVault(address(v));
        aSynth.mint(address(v), 1_100e18);
        debt.mint(address(v), 1_000e18);
    }

    function test_startsAtZeroWithoutDeployerPrivileges() public {
        assertEq(discount.discountBps(), 0);
        vm.prank(OUTSIDER);
        JuicerDiscount other =
            new JuicerDiscount(address(debt), address(synth), address(aSynth), address(this), COMMITTEE);
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
        vm.expectRevert(JuicerDiscount.InvalidDiscount.selector);
        discount.setDiscountBps(10_001);
        debt.setPolicy(address(0));
        vm.expectRevert(JuicerDiscount.NotInstalled.selector);
        discount.setDiscountBps(8_000);
        vm.expectRevert(JuicerDiscount.NotInstalled.selector);
        discount.registerVault(address(vault));
    }

    function test_constructorTakesAPredictedATokenAndRejectsNoMarketOrAuthority() public {
        address predicted = address(0xA70C3);
        JuicerDiscount early = new JuicerDiscount(address(debt), address(synth), predicted, address(this), COMMITTEE);
        assertEq(address(early.aSynthetic()), predicted);
        MockDiscountDebtToken poolless = new MockDiscountDebtToken(address(0));
        vm.expectRevert(JuicerDiscount.InvalidMarket.selector);
        new JuicerDiscount(address(poolless), address(synth), predicted, address(this), COMMITTEE);
        vm.expectRevert(JuicerDiscount.ZeroAddress.selector);
        new JuicerDiscount(address(debt), address(synth), address(0), address(this), COMMITTEE);
        vm.expectRevert(JuicerDiscount.ZeroAddress.selector);
        new JuicerDiscount(address(debt), address(synth), address(aSynth), address(this), address(0));
    }

    function test_constructorRejectsWrongSyntheticDecimals() public {
        MockERC20 wrongSynth = new MockERC20("Wrong", "WRONG", 6);
        vm.expectRevert(JuicerDiscount.InvalidMarket.selector);
        new JuicerDiscount(address(debt), address(wrongSynth), address(aSynth), address(this), COMMITTEE);
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
        vm.expectRevert(JuicerDiscount.InvalidVault.selector);
        discount.registerVault(address(wrong));
        vault.setController(address(0));
        vm.expectRevert(JuicerDiscount.InvalidVault.selector);
        discount.registerVault(address(vault));
        wrong = new MockDiscountVault(address(0x123), address(synth), address(debt), address(discount));
        synth.grantRole(synth.MINTER_ROLE(), address(wrong));
        vm.expectRevert(JuicerDiscount.InvalidVault.selector);
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
        backing = bound(backing, 0, discount.LOOP_TAG() - 1);
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
        vm.expectRevert(JuicerDiscount.NotRegistered.selector);
        discount.unregisterVault(address(vault));
    }

    function test_registryIsBoundedAndCanReuseRemovedSlots() public {
        discount.registerVault(address(vault));
        vm.expectRevert(JuicerDiscount.AlreadyRegistered.selector);
        discount.registerVault(address(vault));
        for (uint256 i = 1; i < discount.MAX_VAULTS(); ++i) {
            discount.registerVault(address(_newVault()));
        }
        MockDiscountVault extra = _newVault();
        vm.expectRevert(JuicerDiscount.TooManyVaults.selector);
        discount.registerVault(address(extra));
        discount.unregisterVault(address(vault));
        discount.registerVault(address(extra));
        vm.prank(COMMITTEE);
        discount.setDiscountBps(8_000);
        assertEq(discount.vaults().length, discount.MAX_VAULTS());
    }

    function test_loopEnrollmentIsGovernanceOnly() public {
        MockDiscountLoop l = _newLoop();
        discount.registerVault(address(vault));
        vm.prank(COMMITTEE);
        vm.expectRevert();
        discount.registerLoop(address(l), 500e18);
        vm.prank(OUTSIDER);
        vm.expectRevert();
        discount.registerLoop(address(l), 500e18);
        uint256 before = debt.refreshCount(address(l));
        vm.expectEmit(true, false, false, true, address(discount));
        emit JuicerDiscount.LoopRegistered(address(l), 500e18);
        discount.registerLoop(address(l), 500e18);
        assertEq(discount.loop(), address(l));
        assertEq(discount.loopCap(), 500e18);
        assertEq(discount.loopDiscountBps(), 0);
        assertEq(debt.refreshCount(address(l)), before + 1);
        vm.expectRevert(JuicerDiscount.AlreadyRegistered.selector);
        discount.registerLoop(address(l), 500e18);
    }

    function test_loopEnrollmentValidatesMarketCapAndFunding() public {
        MockDiscountLoop l = _newLoop();
        vm.expectRevert(JuicerDiscount.InvalidLoop.selector);
        discount.registerLoop(address(l), 500e18);
        discount.registerVault(address(vault));
        uint256 tag = discount.LOOP_TAG();
        vm.expectRevert(JuicerDiscount.InvalidCap.selector);
        discount.registerLoop(address(l), 0);
        vm.expectRevert(JuicerDiscount.InvalidCap.selector);
        discount.registerLoop(address(l), tag);
        vm.expectRevert(JuicerDiscount.InvalidLoop.selector);
        discount.registerLoop(address(0x5100), 500e18);
        MockDiscountLoop wrongPool = new MockDiscountLoop(address(0x123), HOLLAR);
        vault.setYieldSource(address(wrongPool));
        vm.expectRevert(JuicerDiscount.InvalidLoop.selector);
        discount.registerLoop(address(wrongPool), 500e18);
        MockDiscountLoop wrongAsset = new MockDiscountLoop(POOL, address(0x4011B));
        vault.setYieldSource(address(wrongAsset));
        vm.expectRevert(JuicerDiscount.InvalidLoop.selector);
        discount.registerLoop(address(wrongAsset), 500e18);
        vault.setYieldSource(address(l));
        debt.setPolicy(address(0));
        vm.expectRevert(JuicerDiscount.NotInstalled.selector);
        discount.registerLoop(address(l), 500e18);
        debt.setPolicy(address(discount));
        discount.registerLoop(address(l), tag - 1);
        assertEq(discount.loopCap(), tag - 1);
    }

    function test_loopRateIsSeparateFromMainAndCapped() public {
        MockDiscountLoop l = _enrollLoop(500e18);
        discount.setDiscountBps(8_000);
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
        assertEq(debt.getDiscountPercent(address(l)), 0, "loop rate starts at zero");
        vm.expectEmit(false, false, false, true, address(discount));
        emit JuicerDiscount.LoopDiscountBpsUpdated(0, 6_000);
        vm.prank(COMMITTEE);
        discount.setLoopDiscountBps(6_000);
        assertEq(debt.getDiscountPercent(address(l)), 3_000, "half the debt is under the cap");
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
        vm.prank(COMMITTEE);
        discount.setDiscountBps(2_000);
        assertEq(debt.getDiscountPercent(address(vault)), 2_000);
        assertEq(debt.getDiscountPercent(address(l)), 3_000);
        debt.burn(address(l), 600e18);
        assertEq(debt.getDiscountPercent(address(l)), 6_000, "debt under the cap is fully discounted");
        vm.prank(COMMITTEE);
        discount.setDiscountBps(0);
        assertEq(debt.getDiscountPercent(address(l)), 6_000, "main shutdown leaves the loop alone");
        vm.prank(COMMITTEE);
        discount.setLoopDiscountBps(0);
        assertEq(debt.getDiscountPercent(address(l)), 0);
    }

    function test_loopEligibilityIsTaggedFromStorageOnly() public {
        MockDiscountLoop l = _enrollLoop(500e18);
        assertEq(discount.balanceOf(address(l)), 0, "zero rate reads zero");
        discount.setLoopDiscountBps(6_000);
        uint256 tagged = discount.LOOP_TAG() | 500e18;
        assertEq(discount.balanceOf(address(l)), tagged);
        assertEq(discount.calculateDiscountRate(1_000e18, tagged), 3_000);
        assertEq(discount.calculateDiscountRate(1_000e18, 500e18), 0, "untagged takes the main rate");
        vm.etch(address(synth), hex"fe");
        vm.etch(address(aSynth), hex"fe");
        vm.etch(address(l), hex"fe");
        assertEq(discount.balanceOf(address(l)), tagged);
        assertEq(discount.balanceOf(OUTSIDER), 0);
    }

    function test_loopCapIsGovernanceOnlyAndBounded() public {
        MockDiscountLoop l = _enrollLoop(500e18);
        discount.setLoopDiscountBps(6_000);
        vm.prank(COMMITTEE);
        vm.expectRevert();
        discount.setLoopCap(1_000e18);
        uint256 tag = discount.LOOP_TAG();
        vm.expectRevert(JuicerDiscount.InvalidCap.selector);
        discount.setLoopCap(0);
        vm.expectRevert(JuicerDiscount.InvalidCap.selector);
        discount.setLoopCap(tag);
        vm.expectEmit(false, false, false, true, address(discount));
        emit JuicerDiscount.LoopCapUpdated(500e18, 250e18);
        discount.setLoopCap(250e18);
        assertEq(debt.getDiscountPercent(address(l)), 1_500);
        discount.setLoopCap(2_000e18);
        assertEq(debt.getDiscountPercent(address(l)), 6_000);
    }

    function test_unregisterLoopSettlesAndStopsDiscount() public {
        MockDiscountLoop l = _enrollLoop(500e18);
        discount.setLoopDiscountBps(6_000);
        uint256 before = debt.refreshCount(address(l));
        vm.prank(COMMITTEE);
        vm.expectRevert();
        discount.unregisterLoop();
        vm.expectEmit(true, false, false, false, address(discount));
        emit JuicerDiscount.LoopUnregistered(address(l));
        discount.unregisterLoop();
        assertEq(debt.refreshCount(address(l)), before + 1);
        assertEq(debt.getDiscountPercent(address(l)), 0);
        assertEq(discount.loop(), address(0));
        assertEq(discount.loopCap(), 0);
        assertEq(discount.balanceOf(address(l)), 0);
        assertEq(discount.balanceOf(address(0)), 0);
        vm.expectRevert(JuicerDiscount.NotRegistered.selector);
        discount.unregisterLoop();
        vm.expectRevert(JuicerDiscount.NotRegistered.selector);
        discount.setLoopCap(500e18);
        discount.registerLoop(address(l), 400e18);
        assertEq(debt.getDiscountPercent(address(l)), 2_400, "the rate outlives enrollment");
    }

    function test_loopRateBoundsRolesAndRollback() public {
        vm.expectRevert(JuicerDiscount.InvalidDiscount.selector);
        discount.setLoopDiscountBps(10_001);
        vm.prank(OUTSIDER);
        vm.expectRevert();
        discount.setLoopDiscountBps(1_000);
        discount.setLoopDiscountBps(1_000);
        assertEq(discount.loopDiscountBps(), 1_000, "settable before a loop is enrolled");
        MockDiscountLoop l = _enrollLoop(2_000e18);
        assertEq(debt.getDiscountPercent(address(l)), 1_000);
        debt.setFailingBorrower(address(l));
        vm.prank(COMMITTEE);
        vm.expectRevert("refresh failed");
        discount.setLoopDiscountBps(5_000);
        assertEq(discount.loopDiscountBps(), 1_000);
        vm.prank(COMMITTEE);
        vm.expectRevert("refresh failed");
        discount.setDiscountBps(5_000);
        assertEq(discount.discountBps(), 0, "main refresh covers the loop too");
        debt.setPolicy(address(0));
        vm.expectRevert(JuicerDiscount.NotInstalled.selector);
        discount.setLoopDiscountBps(5_000);
    }

    function test_refreshAllIncludesTheLoop() public {
        MockDiscountLoop l = _enrollLoop(500e18);
        uint256 before = debt.refreshCount(address(l));
        vm.prank(OUTSIDER);
        discount.refreshAll();
        discount.setDiscountBps(8_000);
        assertEq(debt.refreshCount(address(l)), before + 2);
    }

    function testFuzz_loopRateNeverExceedsItsOwnRate(
        uint256 debtBalance,
        uint256 cap,
        uint256 eligible,
        uint16 loopBps,
        uint16 mainBps
    ) public {
        loopBps = uint16(bound(loopBps, 0, 10_000));
        mainBps = uint16(bound(mainBps, 0, 10_000));
        cap = bound(cap, 1, discount.LOOP_TAG() - 1);
        eligible = bound(eligible, 0, discount.LOOP_TAG() - 1);
        discount.setLoopDiscountBps(loopBps);
        discount.setDiscountBps(mainBps);
        uint256 loopRate = discount.calculateDiscountRate(debtBalance, discount.LOOP_TAG() | cap);
        assertLe(loopRate, loopBps);
        if (debtBalance != 0 && cap >= debtBalance) assertEq(loopRate, loopBps);
        if (debtBalance == 0) assertEq(loopRate, 0);
        uint256 mainRate = discount.calculateDiscountRate(debtBalance, eligible);
        assertLe(mainRate, mainBps);
        if (debtBalance != 0 && eligible >= debtBalance) assertEq(mainRate, mainBps);
    }
}
