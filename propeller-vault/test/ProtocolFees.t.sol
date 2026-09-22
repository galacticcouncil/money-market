// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HarvestTest} from "./Harvest.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerFeeController} from "../src/PropellerFeeController.sol";
import {PropellerDiscount} from "../src/PropellerDiscount.sol";
import {MockDiscountAToken, MockDiscountDebtToken} from "./mocks/MockDiscount.sol";
import {MockFeeSwapper, MockFeeCallbackToken} from "./mocks/MockFeeAttack.sol";

contract ProtocolFeesTest is HarvestTest {
    address constant TREASURY = address(0xFEE);
    address constant STRANGER = address(0xABCD);

    function _park(uint256 amount) internal {
        _depositAndRamp();
        prime.mint(address(harvester), amount);
    }

    function _harvest() internal {
        harvester.harvest(new uint256[](0));
    }

    function _accrue() internal returns (uint256) {
        _park(3_000e6);
        _harvest();
        return fees.claimableProtocolFees(address(eth));
    }

    function _secondVault() internal returns (CollateralVault v) {
        v = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Second ETH",
                            "pETH2",
                            address(eth),
                            address(pool),
                            address(loop),
                            address(swapper),
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
        v.setCompoundSlippageBps(100);
        v.setFeeController(address(fees));
        synth.grantRole(synth.MINTER_ROLE(), address(v));
        RoundingReserveFixture.fund(v);
        loop.registerVault(address(v));
        fees.registerVault(address(v), address(harvester));
        harvester.addVault(address(v));
        eth.mint(address(this), 1e18);
        eth.approve(address(v), 1e18);
        v.deposit(1e18, address(this));
    }

    function test_initialFivePercentAndIdleCollateralExcluded() public {
        _park(3_000e6);
        eth.mint(address(vault), 7e18);
        uint256 beforeAssets = vault.totalAssets();
        uint256 beforeDebt = hollarDebt.balanceOf(address(vault));
        _harvest();
        assertEq(fees.protocolFeeBps(address(vault)), 500);
        assertEq(fees.claimableProtocolFees(address(eth)), 0.05e18);
        assertEq(eth.balanceOf(address(fees)), 0.05e18);
        assertEq(vault.totalAssets(), beforeAssets + 0.95e18);
        assertEq(eth.balanceOf(address(vault)), 7e18 + vault.roundingReserve());
        assertEq(aEth.balanceOf(address(fees)), 0);
        assertEq(prime.balanceOf(address(fees)), 0);
        assertEq(hollarDebt.balanceOf(address(vault)), beforeDebt);
        assertEq(prime.allowance(address(vault), address(swapper)), 0);
        assertEq(prime.allowance(address(harvester), address(vault)), 0);
        assertEq(eth.allowance(address(vault), address(fees)), 0);
        assertEq(eth.allowance(address(vault), address(pool)), 0);
    }

    function test_zeroFeeSuppliesAllHarvest() public {
        fees.setProtocolFeeBps(address(vault), 0);
        _park(3_000e6);
        _harvest();
        assertEq(aEth.balanceOf(address(vault)), 2e18);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
    }

    function test_fullFeeDoesNotCallZeroSupply() public {
        fees.setProtocolFeeBps(address(vault), 10_000);
        _park(3_000e6);
        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(eth), 0, address(vault), uint16(0)
            ),
            "zero supply"
        );
        _harvest();
        assertEq(aEth.balanceOf(address(vault)), 1e18);
        assertEq(fees.claimableProtocolFees(address(eth)), 1e18);
    }

    function testFuzz_feeConservesGross(uint16 rate, uint96 grossSeed) public {
        uint16 bps = uint16(bound(rate, 0, 10_000));
        uint256 gross = bound(grossSeed, 1, type(uint96).max);
        fees.setProtocolFeeBps(address(vault), bps);
        eth.mint(address(vault), gross);
        vm.startPrank(address(vault));
        eth.approve(address(fees), gross);
        uint256 fee = fees.collectFee(gross, address(harvester));
        vm.stopPrank();
        assertEq(fee, gross * bps / 10_000);
        assertEq(eth.balanceOf(address(vault)) + eth.balanceOf(address(fees)), gross + vault.roundingReserve());
        assertEq(fees.claimableProtocolFees(address(eth)), fee);
    }

    function test_feeBoundsAndUnknownVault() public {
        fees.setProtocolFeeBps(address(vault), 9_999);
        fees.setProtocolFeeBps(address(vault), 10_000);
        vm.expectRevert(PropellerFeeController.InvalidFee.selector);
        fees.setProtocolFeeBps(address(vault), 10_001);
        vm.expectRevert(PropellerFeeController.NotRegistered.selector);
        fees.setProtocolFeeBps(STRANGER, 0);
        vm.expectRevert(PropellerFeeController.NotRegistered.selector);
        fees.protocolFeeBps(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(PropellerFeeController.NotRegistered.selector);
        fees.collectFee(1e18, address(harvester));
    }

    function test_governanceControlsAllPolicy() public {
        vm.startPrank(STRANGER);
        vm.expectRevert();
        fees.setProtocolFeeBps(address(vault), 0);
        vm.expectRevert();
        fees.setFeeRecipient(STRANGER);
        vm.expectRevert();
        fees.registerVault(address(vault), address(harvester));
        vm.expectRevert();
        fees.grantRole(bytes32(0), STRANGER);
        vm.expectRevert();
        vault.setFeeController(STRANGER);
        vm.expectRevert();
        harvester.setFeeController(STRANGER);
        vm.stopPrank();
        fees.grantRole(bytes32(0), STRANGER);
        vm.prank(STRANGER);
        fees.setProtocolFeeBps(address(vault), 700);
        fees.revokeRole(bytes32(0), STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert();
        fees.setProtocolFeeBps(address(vault), 0);
    }

    function test_rebindingPreservesExplicitZeroRate() public {
        fees.setProtocolFeeBps(address(vault), 0);
        fees.registerVault(address(vault), address(harvester));
        assertEq(fees.protocolFeeBps(address(vault)), 0);
    }

    function test_permissionlessClaimPaysOnlyCurrentRecipient() public {
        uint256 amount = _accrue();
        eth.mint(address(fees), 1e18); // Uncredited donation is not claimable.
        fees.setFeeRecipient(address(0xCAFE));
        fees.setProtocolFeeBps(address(vault), 0);
        vm.prank(STRANGER);
        fees.claimProtocolFees(address(eth));
        assertEq(eth.balanceOf(address(0xCAFE)), amount);
        assertEq(eth.balanceOf(TREASURY), 0);
        assertEq(eth.balanceOf(STRANGER), 0);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
        assertEq(eth.balanceOf(address(fees)), 1e18);
        fees.claimProtocolFees(address(eth));
        fees.claimProtocolFees(address(0)); // Empty claims do not call the token.
    }

    function test_paidFeesUnaffectedByRecipientRotation() public {
        uint256 amount = _accrue();
        fees.claimProtocolFees(address(eth));
        fees.setFeeRecipient(STRANGER);
        fees.claimProtocolFees(address(eth));
        assertEq(eth.balanceOf(TREASURY), amount);
        assertEq(eth.balanceOf(STRANGER), 0);
    }

    function test_rejectsZeroAndKnownCustodyRecipients() public {
        address[7] memory invalid = [
            address(0), address(fees), address(vault), address(harvester), address(loop), address(pool), address(aEth)
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(PropellerFeeController.InvalidAddress.selector);
            fees.setFeeRecipient(invalid[i]);
        }
    }

    function test_failedClaimRetainsLedgerAndRecipientCanRecover() public {
        uint256 amount = _accrue();
        vm.mockCall(address(eth), abi.encodeCall(IERC20.transfer, (TREASURY, amount)), abi.encode(false));
        vm.expectRevert();
        fees.claimProtocolFees(address(eth));
        assertEq(fees.claimableProtocolFees(address(eth)), amount);
        assertEq(eth.balanceOf(address(fees)), amount);
        fees.setFeeRecipient(STRANGER);
        fees.claimProtocolFees(address(eth));
        assertEq(eth.balanceOf(STRANGER), amount);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
    }

    function test_claimCannotReenterOrChangeRecipientDuringTransfer() public {
        uint256 amount = _accrue();
        vm.etch(address(eth), address(new MockFeeCallbackToken()).code);
        MockFeeCallbackToken token = MockFeeCallbackToken(address(eth));
        fees.grantRole(bytes32(0), address(eth));
        token.setCallback(address(fees), abi.encodeCall(fees.setFeeRecipient, (STRANGER)));
        fees.claimProtocolFees(address(eth));
        assertFalse(token.callbackSucceeded());
        assertEq(fees.feeRecipient(), TREASURY);
        assertEq(eth.balanceOf(TREASURY), amount);
        token.setCallback(address(0), "");
        prime.mint(address(harvester), 3_000e6);
        _harvest();
        token.setCallback(address(fees), abi.encodeCall(fees.claimProtocolFees, (address(eth))));
        fees.claimProtocolFees(address(eth));
        assertFalse(token.callbackSucceeded());
        assertEq(eth.balanceOf(TREASURY), 2 * amount);
    }

    function test_directDonationNotTaxedAndSameTokenSkipsSwap() public {
        prime.mint(address(this), 3_000e6);
        prime.approve(address(vault), 3_000e6);
        vault.compound(address(prime), 3_000e6, 1e18, "");
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.compound(address(eth), 1e18, 1e18, "");
        assertEq(aEth.balanceOf(address(vault)), 2e18);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
    }

    function test_grossMinOutAppliedBeforeFee() public {
        _park(3_000e6);
        uint256[] memory minimum = new uint256[](1);
        minimum[0] = 1e18;
        harvester.harvest(minimum);
        assertEq(aEth.balanceOf(address(vault)), 1.95e18);
    }

    function test_minOutFailureRollsBackHarvestAndAccrual() public {
        _park(3_000e6);
        uint256[] memory minimum = new uint256[](1);
        minimum[0] = 1e18 + 1;
        vm.expectRevert();
        harvester.harvest(minimum);
        assertEq(prime.balanceOf(address(harvester)), 3_000e6);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
        assertEq(aEth.balanceOf(address(vault)), 1e18);
    }

    function test_actualOutputUsedInsteadOfSwapperReturn() public {
        _park(3_000e6);
        MockFeeSwapper lying = new MockFeeSwapper();
        lying.configure(1e18, type(uint256).max, 10_000);
        vault.setSwapper(address(lying));
        _harvest();
        assertEq(fees.claimableProtocolFees(address(eth)), 0.05e18);
    }

    function test_lyingSwapperCannotSpendIdleCollateral() public {
        _park(3_000e6);
        eth.mint(address(vault), 10e18);
        MockFeeSwapper lying = new MockFeeSwapper();
        lying.configure(0, 1e18, 10_000);
        vault.setSwapper(address(lying));
        vm.expectRevert(CollateralVault.PrincipalShortfall.selector);
        _harvest();
        assertEq(eth.balanceOf(address(vault)), 10e18 + vault.roundingReserve());
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
    }

    function test_zeroActualOutputRejectedEvenWhenFloorRoundsZero() public {
        fees.setProtocolFeeBps(address(vault), 10_000);
        _park(1);
        pool.setPrice(address(eth), 1e36);
        MockFeeSwapper lying = new MockFeeSwapper();
        lying.configure(0, 1, 10_000);
        vault.setSwapper(address(lying));
        vm.expectRevert(CollateralVault.PrincipalShortfall.selector);
        _harvest();
    }

    function test_partialInputConsumptionRejected() public {
        _park(3_000e6);
        MockFeeSwapper lying = new MockFeeSwapper();
        lying.configure(1e18, 1e18, 5_000);
        vault.setSwapper(address(lying));
        vm.expectRevert(CollateralVault.PrincipalShortfall.selector);
        _harvest();
        assertEq(prime.balanceOf(address(harvester)), 3_000e6);
    }

    function test_missingOrMismatchedWiringFailsClosed() public {
        _park(3_000e6);
        vault.setFeeController(address(1));
        vm.expectRevert(PropellerFeeController.InvalidBinding.selector);
        _harvest();
        assertEq(prime.balanceOf(address(harvester)), 3_000e6);
        Harvester unwired = new Harvester(address(loop), address(prime), address(this));
        vm.expectRevert(Harvester.FeeControllerUnset.selector);
        unwired.harvest(new uint256[](0));
    }

    function test_sharedAssetDifferentRatesUseOneClaimLedger() public {
        _park(6_000e6);
        CollateralVault second = _secondVault();
        fees.setProtocolFeeBps(address(second), 1_000);
        uint256 grossFirst = (6_000e6 * loop.sharesOf(address(vault)) / loop.totalShares()) * 1e12 / 3_000;
        uint256 grossSecond = (6_000e6 * loop.sharesOf(address(second)) / loop.totalShares()) * 1e12 / 3_000;
        uint256 feeFirst = grossFirst * 500 / 10_000;
        uint256 feeSecond = grossSecond * 1_000 / 10_000;
        _harvest();
        assertEq(fees.protocolFeeBps(address(vault)), 500);
        assertEq(fees.protocolFeeBps(address(second)), 1_000);
        assertEq(aEth.balanceOf(address(vault)), 1e18 + grossFirst - feeFirst);
        assertEq(aEth.balanceOf(address(second)), 1e18 + grossSecond - feeSecond);
        assertEq(fees.claimableProtocolFees(address(eth)), feeFirst + feeSecond);
        fees.claimProtocolFees(address(eth));
        assertEq(eth.balanceOf(TREASURY), feeFirst + feeSecond);
    }

    function test_laterVaultRateChangeDuringSwapRollsBackBatch() public {
        _park(6_000e6);
        CollateralVault second = _secondVault();
        MockFeeSwapper callback = new MockFeeSwapper();
        callback.configure(1e18, 1e18, 10_000);
        fees.grantRole(bytes32(0), address(callback));
        callback.setCallback(address(fees), abi.encodeCall(fees.setProtocolFeeBps, (address(second), uint16(9_000))));
        vault.setSwapper(address(callback));
        vm.expectRevert(Harvester.HarvestConfigurationChanged.selector);
        _harvest();
        assertEq(fees.protocolFeeBps(address(second)), 500);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
        assertEq(prime.balanceOf(address(harvester)), 6_000e6);
        assertEq(aEth.balanceOf(address(vault)), 1e18);
    }

    function test_policyChangeAndRestorationStillReverts() public {
        _park(3_000e6);
        MockFeeSwapper callback = new MockFeeSwapper();
        callback.configure(1e18, 1e18, 10_000);
        callback.setCallback(address(this), abi.encodeCall(this.changeRateAndRestore, ()));
        vault.setSwapper(address(callback));
        vm.expectRevert(Harvester.HarvestConfigurationChanged.selector);
        _harvest();
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
    }

    function changeRateAndRestore() external {
        fees.setProtocolFeeBps(address(vault), 9_000);
        fees.setProtocolFeeBps(address(vault), 500);
    }

    function test_feeTransferMismatchRollsBackHarvest() public {
        _park(3_000e6);
        vm.mockCall(
            address(eth),
            abi.encodeCall(IERC20.transferFrom, (address(vault), address(fees), 0.05e18)),
            abi.encode(true)
        );
        vm.expectRevert(PropellerFeeController.TransferMismatch.selector);
        _harvest();
        assertEq(prime.balanceOf(address(harvester)), 3_000e6);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
        assertEq(eth.balanceOf(address(fees)), 0);
    }

    function test_claimTransferMismatchRetainsLedger() public {
        uint256 amount = _accrue();
        vm.mockCall(address(eth), abi.encodeCall(IERC20.transfer, (TREASURY, amount)), abi.encode(true));
        vm.expectRevert(PropellerFeeController.TransferMismatch.selector);
        fees.claimProtocolFees(address(eth));
        assertEq(fees.claimableProtocolFees(address(eth)), amount);
    }

    function test_directSourceHarvestStillPaysFeeOnLaterDistribution() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vm.prank(STRANGER);
        loop.harvest();
        uint256 parked = prime.balanceOf(address(harvester));
        assertGt(parked, 0);
        assertEq(prime.balanceOf(STRANGER), 0);
        _harvest();
        uint256 gross = parked * 1e12 / 3_000;
        assertEq(fees.claimableProtocolFees(address(eth)), gross * 500 / 10_000);
    }

    function test_settledWithdrawalIsNotUsedForFee() public {
        uint256 shares = _depositAndRamp();
        uint256 request = vault.requestRedeem(shares / 2, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) {
            loop.pokeRepay();
        }
        vault.pokeSettle();
        uint256 idle = eth.balanceOf(address(vault));
        uint256 reserve = vault.roundingReserve();
        (, , , , , , uint256 settled, , ) = vault.redemptions(request);
        assertGt(settled, 0);
        prime.mint(address(harvester), 3_000e6);
        _harvest();
        assertEq(eth.balanceOf(address(vault)), idle);
        assertEq(vault.roundingReserve(), reserve);
        assertEq(fees.claimableProtocolFees(address(eth)), 0.05e18);
        assertEq(vault.claim(request, address(this)), settled);
        assertEq(eth.balanceOf(address(vault)), idle - settled);
        assertGe(eth.balanceOf(address(vault)), reserve);
    }

    function test_treasuryMayDepositPaidCollateralNormally() public {
        uint256 amount = _accrue();
        fees.claimProtocolFees(address(eth));
        // A treasury deposit is subject to the same backing gate as any user.
        hollar.mint(address(loop), 1e18);
        assertFalse(vault.isUnderfunded());
        vm.startPrank(TREASURY);
        eth.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, TREASURY);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(vault.balanceOf(TREASURY), shares);
        assertEq(fees.claimableProtocolFees(address(eth)), 0);
    }

    function test_runtimeSizesRemainDeployable() public {
        assertLe(address(new CollateralVault()).code.length, 24_576);
        assertLe(address(fees).code.length, 24_576);
        assertLe(address(harvester).code.length, 24_576);
    }

    function testFuzz_accrualClaimAndRotationConserveFees(uint256 seed) public {
        uint256 collected;
        uint256 paid;
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint16 bps = uint16(seed % 10_001);
            uint256 gross = (seed >> 32) % 1e24;
            fees.setProtocolFeeBps(address(vault), bps);
            eth.mint(address(vault), gross);
            vm.startPrank(address(vault));
            eth.approve(address(fees), gross);
            uint256 fee = fees.collectFee(gross, address(harvester));
            vm.stopPrank();
            collected += fee;
            assertEq(fee, gross * bps / 10_000);
            if (seed % 3 == 0) fees.setFeeRecipient(i % 2 == 0 ? TREASURY : STRANGER);
            if (seed % 2 == 0) {
                paid += fees.claimableProtocolFees(address(eth));
                fees.claimProtocolFees(address(eth));
            }
            assertEq(fees.claimableProtocolFees(address(eth)), collected - paid);
            assertEq(eth.balanceOf(address(fees)), collected - paid);
            assertEq(eth.balanceOf(TREASURY) + eth.balanceOf(STRANGER), paid);
        }
    }

    function test_feeWithZeroBorrowingDiscount() public {
        _feeWithDiscount(0);
    }

    function test_feeWithPartialBorrowingDiscount() public {
        _feeWithDiscount(8_000);
    }

    function test_feeWithFullBorrowingDiscount() public {
        _feeWithDiscount(10_000);
    }

    function _feeWithDiscount(uint16 bps) internal {
        // Preserve the fixture's reserve addresses while installing the cache-aware
        // debt/aToken mocks. Interest arithmetic is covered by the pinned fork suite.
        vm.etch(address(hollarDebt), address(new MockDiscountDebtToken(address(pool))).code);
        vm.etch(address(aSynth), address(new MockDiscountAToken(address(pool), address(synth))).code);
        MockDiscountDebtToken debt = MockDiscountDebtToken(address(hollarDebt));
        PropellerDiscount discount =
            new PropellerDiscount(address(debt), address(synth), address(aSynth), address(this), STRANGER);
        debt.setPolicy(address(discount));
        vault.setDiscountController(address(discount));
        discount.registerVault(address(vault));
        vm.prank(STRANGER);
        discount.setDiscountBps(bps);
        _accrue();
        assertEq(debt.getDiscountPercent(address(vault)), bps);
        assertEq(debt.getDiscountPercent(address(loop)), 0);
        assertEq(fees.claimableProtocolFees(address(eth)), 0.05e18);
        vm.prank(STRANGER);
        vm.expectRevert();
        fees.setProtocolFeeBps(address(vault), 0);
    }
}
