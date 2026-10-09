// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MultiVaultFlowTest} from "./MultiVaultFlow.t.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";
import {JuicerYieldAccounting} from "../src/JuicerYieldAccounting.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {Deficit} from "./helpers/Deficit.sol";

/// @dev test-only append-only upgrade, not strategy rotation
contract SubLoopUpgradeProbe is SubLoop {
    uint256 public compatibilityMarker;

    function initializeProbe(uint256 marker) external reinitializer(2) onlyRole(UPGRADER_ROLE) {
        compatibilityMarker = marker;
    }
}

/// @dev deliberately unsafe test candidate; never deploy
contract SubLoopBrokenCounterProbe is SubLoopUpgradeProbe {
    function overwriteCostForTest(address vault, uint256 value) external onlyRole(UPGRADER_ROLE) {
        _unwindExecutionCost[vault] = value;
    }
}

contract SourceUpgradeCompatibilityTest is MultiVaultFlowTest {
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _ledger(CollateralVault vault) internal view returns (JuicerMainDebt) {
        return JuicerMainDebt(address(vault.mainDebt()));
    }

    function _openPositions() internal {
        this.seedPosition(false);
        this.seedPosition(true);
        for (uint256 i; i < 40; ++i) loop.pokeBorrow();
        // earned prime, not a sponsored hollar balance
        aPrime.mint(address(loop), 1_000e6);
        prime.mint(address(pool), 1_000e6);
        loop.configureDca(222, 43, 1043, 143, 1_000);
        harvester.harvest(new uint256[](0));
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(10);
    }

    // Keep deposit setup outside the large optimizer-inlined test bodies.
    function seedPosition(bool btc) external {
        if (btc) {
            tbtc.mint(BTC_USER, 1e17);
            vm.startPrank(BTC_USER);
            tbtc.approve(address(tbtcVault), 1e17);
            tbtcVault.deposit(1e17, BTC_USER);
            tbtcVault.rebalance();
        } else {
            eth.mint(ETH_USER, 1e18);
            vm.startPrank(ETH_USER);
            eth.approve(address(ethVault), 1e18);
            ethVault.deposit(1e18, ETH_USER);
            ethVault.rebalance();
        }
        vm.stopPrank();
    }

    function _preparePartialExit() internal {
        _openPositions();
        uint256 shares = ethVault.balanceOf(ETH_USER) / 2;
        vm.prank(ETH_USER);
        ethVault.requestRedeem(shares, ETH_USER);
        vm.warp(vm.getBlockTimestamp() + ethVault.withdrawalDelay());
        ethVault.startUnwinds(64);
        // A second vault has a waiting, not-yet-started withdrawal.
        shares = tbtcVault.balanceOf(BTC_USER) / 2;
        vm.prank(BTC_USER);
        tbtcVault.requestRedeem(shares, BTC_USER);
        loop.pokeRepay();
        ethVault.pokeSettle();
        assertGt(_ledger(ethVault).sourceCostCheckpoint(), 0);
        assertGt(ethVault.totalQueuedDebt(), 0);
        loop.pokeRepay();
        assertGt(loop.freedOf(address(ethVault)), 0);
        assertGt(loop.unwindExecutionCost(address(ethVault)), _ledger(ethVault).sourceCostCheckpoint());
    }

    function _upgrade() internal {
        bytes32 before_ = _fingerprint();
        SubLoopUpgradeProbe next = new SubLoopUpgradeProbe();
        loop.upgradeToAndCall(address(next), abi.encodeCall(next.initializeProbe, (7)));
        assertEq(address(uint160(uint256(vm.load(address(loop), IMPLEMENTATION_SLOT)))), address(next));
        assertEq(SubLoopUpgradeProbe(address(loop)).compatibilityMarker(), 7);
        assertEq(_fingerprint(), before_, "upgrade preserves existing positions and policy");
        assertTrue(loop.hasRole(loop.UPGRADER_ROLE(), address(this)));
        assertTrue(loop.hasRole(loop.GUARDIAN_ROLE(), address(this)));
        assertTrue(loop.hasRole(loop.VAULT_ROLE(), address(ethVault)));
        assertTrue(loop.hasRole(loop.VAULT_ROLE(), address(tbtcVault)));
        fees.validateVault(address(ethVault), address(harvester));
        fees.validateVault(address(tbtcVault), address(harvester));
    }

    function _read(address target, bytes memory query) internal view returns (bytes memory result) {
        bool ok;
        (ok, result) = target.staticcall(query);
        require(ok, "snapshot read failed");
    }

    function _sourceVaultState(CollateralVault vault) internal view returns (bytes32) {
        address v = address(vault);
        return keccak256(abi.encode(loop.sharesOf(v), loop.equityOf(v), loop.pendingUnwindOf(v),
            loop.freedOf(v), loop.unwindYieldAllowance(v), loop.unwindExecutionCost(v), loop.principalOf(v)));
    }

    function _sourceState() internal view returns (bytes32) {
        bytes32 accounting = keccak256(abi.encode(loop.totalShares(), loop.principalEquity(),
            loop.totalEquity(), loop.unwindTargetEquity(), loop.reservedFreed(),
            loop.deleverDebtTarget(), loop.unwindOrderId()));
        bytes32 assets = keccak256(abi.encode(address(loop.pool()), address(loop.hollar()),
            address(loop.prime()), address(loop.primeAToken()), loop.harvester(),
            aPrime.balanceOf(address(loop)), hollar.balanceOf(address(loop)),
            hollarDebt.balanceOf(address(loop))));
        bytes32 policy = keccak256(abi.encode(loop.targetHf(), loop.deployHfFloor(),
            loop.deLeverTrigger(), loop.harvestThreshold(), loop.deployTranche(), loop.unwindTranche(),
            loop.dcaSlippagePpm(), loop.paused(), loop.emergencyPaused()));
        bytes32 route = keccak256(abi.encode(loop.hollarAssetId(), loop.primeAssetId(),
            loop.aPrimeAssetId(), loop.primePoolId()));
        return keccak256(abi.encode(accounting, assets, policy, route,
            _sourceVaultState(ethVault), _sourceVaultState(tbtcVault)));
    }

    function _ledgerState(CollateralVault vault) internal view returns (bytes32) {
        JuicerMainDebt ledger = _ledger(vault);
        bytes32 totals = keccak256(abi.encode(ledger.totalUnits(), ledger.ownedCash(),
            ledger.sourceOutstanding(), ledger.activeSourceRemaining(), ledger.sourceHead(), ledger.sourceTail()));
        bytes32 allocation = keccak256(abi.encode(ledger.sourceCostCheckpoint(),
            ledger.unallocatedSource(), ledger.unallocatedCost(), hollar.balanceOf(address(ledger)),
            ledger.sourceFeeReserve(), ledger.activeFunds(),
            _read(address(ledger), abi.encodeWithSignature("sourceFees(uint256)", 0)),
            _read(address(ledger), abi.encodeWithSignature("sourceFees(uint256)", 1))));
        return keccak256(abi.encode(totals, allocation,
            _read(address(ledger), abi.encodeWithSignature("positions(uint256)", 0)),
            _read(address(ledger), abi.encodeWithSignature("positions(uint256)", 1))));
    }

    function _yieldState(CollateralVault vault) internal view returns (bytes32) {
        JuicerYieldAccounting y = vault.yieldAccounting();
        bytes32 totals = keccak256(abi.encode(y.sourceShares(), y.protocolShares(),
            y.totalUnits(), y.totalAssets(), y.rewardIndex(), y.requestIndex(0)));
        bytes32 owners = keccak256(abi.encode(y.balanceOf(ETH_USER), y.balanceOf(BTC_USER),
            vault.balanceOf(address(y)), vault.reinvestAssets()));
        bytes32 vested = keccak256(abi.encode(y.requestUnits(0), y.fundedOf(ETH_USER), y.fundedOf(BTC_USER),
            y.epoch(), y.unitScale()));
        return keccak256(abi.encode(address(y), totals, owners, vested));
    }

    function _vaultState(CollateralVault vault) internal view returns (bytes32) {
        bytes32 accounting = keccak256(abi.encode(vault.totalAssets(), vault.totalSupply(),
            vault.loopShares(), vault.syntheticSupplied(), vault.roundingReserve(),
            hollarDebt.balanceOf(address(vault)), hollar.balanceOf(address(vault))));
        bytes32 queue = keccak256(abi.encode(vault.queueHead(), vault.queueTail(), vault.queueUnwind(),
            vault.pendingWithdrawalShares(), vault.totalQueuedShares(), vault.totalQueuedDebt(),
            vault.totalQueuedCollateral(), vault.unwindEligibleAt(0), vault.claimedCollateral(0)));
        bytes32 holders = keccak256(abi.encode(vault.balanceOf(ETH_USER), vault.balanceOf(BTC_USER),
            vault.balanceOf(address(vault)), vault.paused(), vault.depositsPaused(), vault.withdrawalDelay(),
            address(vault.yieldSource()), address(vault.mainDebt()), address(vault.feeController())));
        return keccak256(abi.encode(accounting, queue, holders, _yieldState(vault),
            _read(address(vault), abi.encodeWithSignature("redemptions(uint256)", 0)), _ledgerState(vault)));
    }

    function _fingerprint() internal view returns (bytes32) {
        return keccak256(abi.encode(_sourceState(), _vaultState(ethVault), _vaultState(tbtcVault),
            fees.claimableProtocolFees(address(eth)), fees.claimableProtocolFees(address(tbtc)),
            eth.balanceOf(ETH_USER), tbtc.balanceOf(BTC_USER),
            hollar.balanceOf(ETH_USER), hollar.balanceOf(BTC_USER)));
    }

    function _claimEthExit() internal {
        (,,uint256 promised,,,,,,) = ethVault.redemptions(0);
        vm.prank(ETH_USER);
        uint256 paid = ethVault.claim(0, ETH_USER);
        assertEq(paid, promised, "exact collateral promise, no haircut");
        assertGe(paid, 1e18 / 2, "deposited-token principal");
    }

    function _finishEthExit() internal returns (bytes32) {
        for (uint256 i; i < 1500 && ethVault.totalQueuedDebt() != 0; ++i) {
            loop.pokeRepay();
            ethVault.pokeSettle();
        }
        assertEq(ethVault.totalQueuedDebt(), 0);
        _claimEthExit();
        assertEq(tbtcVault.queueUnwind(), 0, "waiting request is not silently started");
        hollarDebt.mint(address(tbtcVault), 1e18);
        tbtcVault.maintainPeg();
        aPrime.mint(address(loop), 1_000e6);
        prime.mint(address(pool), 1_000e6);
        harvester.harvest(new uint256[](0));
        assertEq(_ledger(tbtcVault).interestOf(0), 0, "fresh yield still services Main interest");
        return _fingerprint();
    }

    function test_upgradeLiveSourcePreservesPartialExitAndWaitingRequest() public {
        _preparePartialExit();
        uint256 snapshot = vm.snapshotState();
        bytes32 expected = _finishEthExit();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        _upgrade();
        assertEq(_finishEthExit(), expected, "identical continuation with and without upgrade");
    }

    function test_upgradePreservesEmergencyAndLocalPauses() public {
        _preparePartialExit();
        ethVault.pause();
        loop.pauseEmergency();
        _upgrade();
        vm.prank(ETH_USER);
        vm.expectRevert("Pausable: paused");
        ethVault.claim(0, ETH_USER);
        JuicerMainDebt ledger = _ledger(ethVault);
        vm.expectRevert(JuicerMainDebt.Paused.selector);
        ledger.claimSurplus(0);
        loop.unpauseEmergency();
        assertTrue(ethVault.paused());
        assertFalse(tbtcVault.paused());
        ethVault.unpause();
        _finishEthExit();
    }

    function test_upgradePendingCostsAndReceiptsAreCreditedExactlyOnce() public {
        _preparePartialExit();
        _upgrade();
        ethVault.pokeSettle();
        JuicerMainDebt ledger = _ledger(ethVault);
        assertEq(ledger.sourceCostCheckpoint(), loop.unwindExecutionCost(address(ethVault)));
        assertEq(ledger.sourceOutstanding(), loop.pendingUnwindOf(address(ethVault)));
        assertEq(ledger.unallocatedCost(), 0);
        bytes32 after_ = _fingerprint();
        ethVault.pokeSettle();
        assertEq(_fingerprint(), after_, "neither receipt nor old expense is replayed");
    }

    function test_upgradeLateRecoveryStillPaysOriginalExitOwner() public {
        _preparePartialExit();
        JuicerMainDebt ledger = _ledger(ethVault);
        uint256 debt = ledger.debtOf(1);
        hollar.mint(address(this), debt);
        hollar.approve(address(ledger), debt);
        ledger.fundPosition(1, debt); // explicit recovery, not a principal write-off
        ethVault.pokeSettle();
        _claimEthExit();
        ledger.claimSurplus(0);
        assertGt(loop.pendingUnwindOf(address(ethVault)), 0);
        _upgrade();
        for (uint256 i; i < 20 && loop.pendingUnwindOf(address(ethVault)) != 0; ++i) {
            loop.pokeRepay();
            ethVault.pokeSettle();
        }
        uint256 ownerCash = hollar.balanceOf(ETH_USER);
        uint256 strangerCash = hollar.balanceOf(BTC_USER);
        vm.prank(BTC_USER);
        uint256 paid = ledger.claimSurplus(0);
        assertGt(paid, 0);
        assertEq(hollar.balanceOf(ETH_USER), ownerCash + paid);
        assertEq(hollar.balanceOf(BTC_USER), strangerCash);
        assertEq(ledger.debtOf(1), 0);
        assertEq(ledger.sourceOutstanding(), loop.pendingUnwindOf(address(ethVault)));
    }

    function test_upgradeCannotHideAnUnderfundedOldPosition() public {
        _preparePartialExit();
        ethVault.pokeSettle();
        aPrime.burn(address(loop), aPrime.balanceOf(address(loop)) / 2);
        assertTrue(Deficit.underfunded(ethVault));
        uint256 assets = ethVault.totalAssets();
        uint256 claim = loop.pendingUnwindOf(address(ethVault));
        _upgrade();
        assertTrue(Deficit.underfunded(ethVault));
        assertFalse(Deficit.ready(_ledger(ethVault)));
        assertEq(ethVault.totalAssets(), assets);
        assertEq(loop.pendingUnwindOf(address(ethVault)), claim);
    }

    function test_upgradeRequiresAuthorityAndCannotReinitializeExistingState() public {
        SubLoopUpgradeProbe next = new SubLoopUpgradeProbe();
        bytes32 oldImplementation = vm.load(address(loop), IMPLEMENTATION_SLOT);
        vm.prank(ETH_USER);
        vm.expectRevert();
        loop.upgradeTo(address(next));
        assertEq(vm.load(address(loop), IMPLEMENTATION_SLOT), oldImplementation);
        _upgrade();
        vm.expectRevert("Initializable: contract is already initialized");
        loop.initialize(address(pool), address(hollar), address(prime), address(aPrime),
            1.05e18, 1.10e18, address(this));
        vm.expectRevert("Initializable: contract is already initialized");
        SubLoopUpgradeProbe(address(loop)).initializeProbe(8);
        vm.expectRevert("Initializable: contract is already initialized");
        next.initializeProbe(8);
    }

    function test_upgradeResettingCostCounterBreaksSettlementWithoutErasingClaims() public {
        _preparePartialExit();
        uint256 cost = loop.unwindExecutionCost(address(ethVault));
        bytes32 before_ = _fingerprint();
        SubLoopBrokenCounterProbe bad = new SubLoopBrokenCounterProbe();
        loop.upgradeToAndCall(address(bad),
            abi.encodeCall(bad.overwriteCostForTest, (address(ethVault), 0)));
        bytes32 ledgerBefore = _ledgerState(ethVault);
        uint256 pending = loop.pendingUnwindOf(address(ethVault));
        // upgrade auth doesn't check semantics: this installs but must fail compatibility tests
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        ethVault.pokeSettle();
        assertEq(_ledgerState(ethVault), ledgerBefore);
        assertEq(loop.pendingUnwindOf(address(ethVault)), pending);
        SubLoopBrokenCounterProbe(address(loop)).overwriteCostForTest(address(ethVault), cost);
        assertEq(_fingerprint(), before_);
        ethVault.pokeSettle();
        assertEq(_ledger(ethVault).sourceCostCheckpoint(), cost);
    }
}
