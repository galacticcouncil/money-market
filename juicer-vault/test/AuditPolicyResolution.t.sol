// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HarvestTest} from "./Harvest.t.sol";
import {MultiVaultFlowTest} from "./MultiVaultFlow.t.sol";
import {IceIntentsTest} from "./IceIntents.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ExecutionController} from "../src/ExecutionController.sol";
import {Harvester} from "../src/Harvester.sol";
import {JuicerYieldAccounting} from "../src/JuicerYieldAccounting.sol";
import {SubLoop} from "../src/SubLoop.sol";

contract AdmissionBackstopTest is HarvestTest {
    address internal constant NEWCOMER = address(0xA2);

    function _attemptDeposit() internal returns (uint256 shares) {
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        shares = vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
    }

    function test_subFiftyBpsDeficitRemainsAdmissible() public {
        _depositAndRamp();
        pool.setPrice(address(prime), 0.9994e18);
        assertGt(_attemptDeposit(), 0);
    }

    function test_largeExistingDeficitCannotDiluteIntoNewDeposit() public {
        _depositAndRamp();
        pool.setPrice(address(prime), 0.99e18);
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.PrincipalShortfall.selector);
        vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
    }

    function test_adminRaisesTheAdmissibleDeficit() public {
        _depositAndRamp();
        pool.setPrice(address(prime), 0.99e18);
        loop.setAdmissionMaxDeficitBps(10_000);
        assertEq(loop.admissionMaxDeficitBps(), 10_000);
        assertGt(_attemptDeposit(), 0);
    }

    function test_unsetAdmissionClosesOnAnyShortfall() public {
        _depositAndRamp();
        pool.setPrice(address(prime), 0.9994e18);
        loop.setAdmissionMaxDeficitBps(0);
        eth.mint(NEWCOMER, 1e18);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVault.PrincipalShortfall.selector);
        vault.deposit(1e18, NEWCOMER);
        vm.stopPrank();
    }

    function test_onlyAdminSetsTheAdmissibleDeficit() public {
        vm.prank(NEWCOMER);
        vm.expectRevert();
        loop.setAdmissionMaxDeficitBps(300);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setAdmissionMaxDeficitBps(10_001);
        assertEq(loop.admissionMaxDeficitBps(), 50);
    }
}

contract RecoveryHighWaterTest is HarvestTest {
    address internal constant NEWCOMER = address(0xB0B);

    function _newcomerDeposits(uint256 amount) internal {
        eth.mint(NEWCOMER, amount);
        vm.startPrank(NEWCOMER);
        eth.approve(address(vault), amount);
        vault.deposit(amount, NEWCOMER);
        vm.stopPrank();
    }

    function test_partialLossRecoveryRestoresIncumbentBeforeNewWeight() public {
        _depositAndRamp();
        hollar.mint(address(loop), loop.principalEquity() - loop.totalEquity() * 1e10);
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        vault.sync();
        JuicerYieldAccounting accounting = vault.yieldAccounting();
        uint256 earnedBefore = accounting.earnedAssets(address(this));
        uint256 reservedBefore = accounting.reservedShares();

        pool.setPrice(address(prime), 0.999e18);
        vault.sync();
        assertLt(accounting.reservedShares(), reservedBefore, "the price dip writes down prior yield");
        assertGt(accounting.sourceLossCarry(), 0, "the incumbent loss is remembered");
        assertGt(accounting.totalUnits(), 0, "the write-down remains in the same epoch");

        _newcomerDeposits(1e18);
        pool.setPrice(address(prime), 1e18);
        vault.sync();

        assertApproxEqRel(accounting.earnedAssets(address(this)), earnedBefore, 0.001e18,
            "recovery restores the incumbent high-water claim");
        assertLe(accounting.earnedAssets(NEWCOMER), 1e9,
            "undeployed current weight does not receive the old recovery");
        assertEq(accounting.sourceLossCarry(), 0, "the recovered loss carry is consumed");
    }
}

contract PendingIntentMembershipTest is IceIntentsTest {
    address internal constant SECOND = address(0xB0B);

    function test_pendingIntentFreezesDepositRequestAndPullMembership() public {
        loop.registerVault(SECOND);
        _deposit(SEED);
        assertGt(loop.pokeBorrowQuoted(ENTRY_RATE), 0);

        hollar.mint(SECOND, SEED);
        vm.startPrank(SECOND);
        hollar.approve(address(loop), SEED);
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.deposit(SEED);
        vm.stopPrank();

        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.requestUnwind(1);
        vm.expectRevert(SubLoop.IntentRejected.selector);
        loop.pullFreed();

        _resolve();
        vm.prank(SECOND);
        loop.deposit(SEED);
        assertGt(loop.sharesOf(SECOND), 0, "membership changes resume after reconciliation");
    }
}

contract ParkedGiftOwnershipTest is MultiVaultFlowTest {
    bytes32 internal constant HARVEST = keccak256("harvest");
    bytes32 internal constant SERVICE_ETH = keccak256("service-eth");
    bytes32 internal constant SERVICE_BTC = keccak256("service-btc");
    bytes32 internal constant QUOTED_HASH = keccak256("quoted block");
    uint256 internal constant DONATION = 1_000e6;
    address internal constant ATTACKER = address(0xA77AC4);
    ExecutionController internal control;

    function _positions() internal {
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        ethVault.deposit(1e18, ETH_USER);
        vm.stopPrank();
        ethVault.rebalance();

        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        vm.stopPrank();
        tbtcVault.rebalance();
        assertEq(loop.harvestCapacity(), 0);
    }

    function _enableExecutionControl() internal {
        control = new ExecutionController(address(this), 60, 5);
        vm.roll(100);
        vm.setBlockhash(99, QUOTED_HASH);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        control.configureBudget(HARVEST, address(prime), 5_000e6, 1e6, expiry);
        control.configureBudget(SERVICE_ETH, address(eth), 1e18, 1e15, expiry);
        control.configureBudget(SERVICE_BTC, address(tbtc), 1e17, 1e14, expiry);
        control.configureLimit(address(ethVault), address(prime), address(eth), HARVEST, 10_000, 1_000e6);
        control.configureLimit(address(tbtcVault), address(prime), address(tbtc), HARVEST, 10_000, 1_000e6);
        control.configureLimit(address(ethVault.mainDebt()), address(eth), address(hollar), SERVICE_ETH, 1e12, 2e16);
        control.configureLimit(address(tbtcVault.mainDebt()), address(tbtc), address(hollar), SERVICE_BTC, 1e10, 1e15);
        control.configurePrice(control.lane(address(ethVault), address(prime), address(eth)), 10, false);
        control.configurePrice(control.lane(address(tbtcVault), address(prime), address(tbtc)), 10, false);
        control.configureAction(address(harvester), Harvester.harvest.selector, true);
        harvester.setExecutionController(address(control));
        ethVault.setExecutionController(address(control));
        tbtcVault.setExecutionController(address(control));
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.setBlockhash(vm.getBlockNumber() - 1, QUOTED_HASH);
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encodeCall(Harvester.harvest, (new uint256[](2)));
    }

    function _executeWith(bool quoteEth, bool quoteBtc) internal {
        _nextBlock();
        uint256 count = (quoteEth ? 1 : 0) + (quoteBtc ? 1 : 0);
        ExecutionController.Quote[] memory quotes = new ExecutionController.Quote[](count);
        uint256 cursor;
        if (quoteEth) {
            quotes[cursor++] = ExecutionController.Quote(
                control.lane(address(ethVault), address(prime), address(eth)), DONATION, 1
            );
        }
        if (quoteBtc) {
            quotes[cursor] = ExecutionController.Quote(
                control.lane(address(tbtcVault), address(prime), address(tbtc)), DONATION, 1
            );
        }
        vm.prank(ATTACKER);
        control.execute(
            address(harvester), _data(), vm.getBlockNumber() - 1, QUOTED_HASH,
            vm.getBlockTimestamp() + 60, quotes
        );
    }

    function _share(uint256 amount, address vault_) internal view returns (uint256) {
        return Math.mulDiv(amount, loop.sharesOf(vault_), loop.totalShares());
    }

    function test_unquotedVaultKeepsItsAssignedGiftAcrossRounds() public {
        _positions();
        _enableExecutionControl();
        prime.mint(address(harvester), DONATION);
        uint256 ethGift = _share(DONATION, address(ethVault));
        uint256 ethAssets = ethVault.totalAssets();

        for (uint256 i; i < 5; ++i) _executeWith(false, true);

        assertEq(ethVault.totalAssets(), ethAssets, "the unquoted vault has not traded yet");
        assertEq(harvester.parkedGiftOf(address(ethVault)), ethGift,
            "its original gift share remains owned across later rounds");
        assertEq(harvester.totalParkedGifts(), ethGift);
        assertEq(prime.balanceOf(address(harvester)), ethGift);
        vm.expectRevert(Harvester.OutstandingGift.selector);
        harvester.removeVault(address(ethVault));

        _executeWith(true, true);
        assertGt(ethVault.totalAssets(), ethAssets, "an honest quote realizes the owned gift");
        assertEq(harvester.parkedGiftOf(address(ethVault)), 0);
        assertEq(harvester.totalParkedGifts(), 0);
        assertEq(prime.balanceOf(address(harvester)), 0);
    }
}
