// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {Artifacts} from "./helpers/Artifacts.t.sol";
import {CollateralStub} from "./mocks/CollateralStub.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";

/// @notice keeper ops: rebalance toward the live max ltv, and maintainPeg re-topping
///         the synthetic as main debt accrues.
contract KeeperOpsTest is Test {
    MockERC20 eth; MockERC20 aEth; MockERC20 ethDebt;
    MockERC20 hollar; MockERC20 aHollar; MockERC20 hollarDebt;
    MockERC20 prime; MockERC20 aPrime; MockERC20 primeDebt;
    MockERC20 aSynth; MockERC20 synthDebt;
    MockPool pool; SyntheticToken synth;
    SubLoop loop; CollateralVault vault;

    uint16 constant SYNTH_LT = 9800;

    function setUp() public {
        eth = new MockERC20("ETH","ETH",18); aEth = new MockERC20("aETH","aETH",18); ethDebt = new MockERC20("dETH","dETH",18);
        hollar = new MockERC20("HOLLAR","HOLLAR",18); aHollar = new MockERC20("aHOLLAR","aHOLLAR",18); hollarDebt = new MockERC20("dHOLLAR","dHOLLAR",18);
        prime = new MockERC20("PRIME","PRIME",6); aPrime = new MockERC20("aPRIME","aPRIME",6); primeDebt = new MockERC20("dPRIME","dPRIME",6);
        synth = SyntheticToken(Artifacts.syntheticToken("Juicer Synthetic","jsHOLLAR",address(this)));
        aSynth = new MockERC20("aSYNTH","aSYNTH",18); synthDebt = new MockERC20("dSYNTH","dSYNTH",18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        // synth: small non-zero LTV so it can be enabled as collateral
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), SYNTH_LT, 100, 18, 1e18);

        loop = SubLoop(Artifacts.proxy(Artifacts.subLoop(), abi.encodeCall(SubLoop.initialize,
            (address(pool),address(hollar),address(prime),address(aPrime),1.05e18,1.10e18,address(this)))));
        vault = CollateralVault(Artifacts.proxy(Artifacts.collateralVault(), abi.encodeCall(CollateralVault.initialize,
            ("Juicer ETH","jETH",address(eth),address(pool),address(loop),address(0),address(hollar),address(synth),address(aEth),address(hollarDebt),1_000e18,address(this)))));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        // permissionless: pokeBorrow/pokeRepay/rebalance/maintainPeg need no grant
        loop.setTranches(10_000_000e18, 10_000_000e6);

        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        vault.rebalance();
    }

    function _ramp() internal {
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    function test_rebalanceDownOnDrop() public {
        _ramp();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // ~2250 (75% of $3000)
        uint256 loopBefore = vault.loopShares();

        // ETH −50% → LTV blows past the band → de-lever to the max LTV
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0, "de-lever scheduled");
        assertLt(vault.loopShares(), loopBefore, "loop slice queued to unwind");

        // run the unwind spiral, then settle the de-lever repay
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // Main debt repaid toward the max LTV (ethValue 1500 × 75% = 1125)
        uint256 debtAfter = hollarDebt.balanceOf(address(vault));
        assertLt(debtAfter, debtBefore, "debt reduced");
        assertApproxEqRel(debtAfter, 1_125e18, 0.05e18, "debt ~ max LTV after de-lever");
        // INV-1 still holds
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, debtAfter, "synth still covers debt");
    }

    function test_rebalanceUpOnAppreciation() public {
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        uint256 loopBefore = vault.loopShares();

        // ETH +50% → LTV drifts below the band → borrow more, deploy more
        pool.setPrice(address(eth), 4_500e18);
        vault.rebalance();

        assertGt(hollarDebt.balanceOf(address(vault)), debtBefore, "borrowed more on appreciation");
        assertGt(vault.loopShares(), loopBefore, "extra deployed into loop");
        // INV-1 preserved: synth still floors Main debt
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, hollarDebt.balanceOf(address(vault)), "synth still covers debt");
    }

    function test_rebalanceFollowsGovernanceLtvChange() public {
        // governance raises max ltv 75% → 80% and the vault follows on the next rebalance;
        // the small price drift crosses the band (2250/3030 ≈ 74.3% < 75%)
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // 2250 @ 75%
        pool.setLtv(address(eth), 8000);
        pool.setPrice(address(eth), 3_030e18);
        vault.rebalance();
        // target debt = 80% × $3030 = $2424
        assertApproxEqRel(
            hollarDebt.balanceOf(address(vault)), 2_424e18, 0.01e18, "debt re-levered to the new 80% max"
        );
        assertGt(hollarDebt.balanceOf(address(vault)), debtBefore, "borrowed the LTV delta");
    }

    function test_maintainPegOnInterestAccrual() public {
        // simulate HOLLAR debt accruing interest: +3% debt token
        uint256 extra = hollarDebt.balanceOf(address(vault)) * 3 / 100;
        hollarDebt.mint(address(vault), extra);

        // peg now broken: synth*LT < debt
        uint256 synthLtVal = aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4;
        assertLt(synthLtVal, hollarDebt.balanceOf(address(vault)), "peg broken by interest");

        vault.maintainPeg();

        // peg restored: synth*LT >= debt again
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, hollarDebt.balanceOf(address(vault)), "peg restored");
    }

    /// @notice hammering rebalance must not inflate the de-lever target, over-unwind
    ///         or freeze settlement.
    function test_rebalanceDeLeverIdempotent_noRedemptionDoS() public {
        _ramp();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // ~2250 (75% of $3000)
        uint256 loopBefore = vault.loopShares();

        // eth −50% → over-levered → de-lever branch fires
        pool.setPrice(address(eth), 1_500e18);

        // the first rebalance queues exactly the needed de-lever
        vault.rebalance();
        uint256 targetAfterOne = vault.deleverTarget();
        uint256 loopAfterOne = vault.loopShares();
        assertGt(targetAfterOne, 0, "de-lever scheduled");
        assertLt(loopAfterOne, loopBefore, "only the needed slice queued");

        // hammer rebalance before pokeSettle runs
        for (uint256 i = 0; i < 25; i++) vault.rebalance();

        // repeated calls add nothing and never over-unwind
        assertEq(vault.deleverTarget(), targetAfterOne, "deleverTarget not inflated by repeated calls");
        assertEq(vault.loopShares(), loopAfterOne, "loop not over-unwound by repeated calls");
        assertLe(vault.deleverTarget(), debtBefore, "target never exceeds real Main debt");

        // settlement completes and de-levers to ~max ltv
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle(); // must not revert

        uint256 debtAfter = hollarDebt.balanceOf(address(vault));
        assertLt(debtAfter, debtBefore, "debt reduced");
        assertApproxEqRel(debtAfter, 1_125e18, 0.05e18, "debt ~ max LTV (not driven to zero)");
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, debtAfter, "INV-1 still holds");
    }

    function _studyBand(CollateralVault v) internal {
        loop.setRebalanceBand(address(v), 0, 1_000, 800);
    }

    function _settleDelever() internal {
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
    }

    function test_bandDefaultsToTheOriginalHysteresis() public view {
        (uint16 target, uint16 relever, uint16 delever) = loop.rebalanceBand(address(vault));
        assertEq(target, 0);
        assertEq(relever, 500);
        assertEq(delever, 300);
    }

    function test_bandSetterIsAdminOnlyBoundedAndPerVault() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        loop.setRebalanceBand(address(vault), 0, 1_000, 800);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setRebalanceBand(address(0xBEEF), 0, 1_000, 800);
        uint16[3][6] memory invalid = [
            [uint16(0), 0, 800], [uint16(0), 1_000, 0], [uint16(5_001), 1_000, 800],
            [uint16(0), 5_001, 800], [uint16(0), 1_000, 2_501], [uint16(1), 0, 0]
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(SubLoop.InvalidParameters.selector);
            loop.setRebalanceBand(address(vault), invalid[i][0], invalid[i][1], invalid[i][2]);
        }
        address other = address(new CollateralStub(address(eth)));
        loop.registerVault(other);
        vm.expectEmit(true, false, false, true, address(loop));
        emit SubLoop.RebalanceBandSet(other, 500, 1_000, 800);
        loop.setRebalanceBand(other, 500, 1_000, 800);
        (uint16 target, uint16 relever, uint16 delever) = loop.rebalanceBand(other);
        assertEq(target, 500);
        assertEq(relever, 1_000);
        assertEq(delever, 800);
        (, relever,) = loop.rebalanceBand(address(vault));
        assertEq(relever, 500, "other vaults keep theirs");
        loop.setRebalanceBand(other, 5_000, 5_000, 2_500);
        loop.setRebalanceBand(other, 0, 0, 0);
        (target, relever, delever) = loop.rebalanceBand(other);
        assertEq(target, 0);
        assertEq(relever, 500);
        assertEq(delever, 300);
    }

    function test_wideReleverSideWaitsBelowSixtyFive() public {
        _studyBand(vault);
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        pool.setPrice(address(eth), 3_309e18);
        vault.rebalance();
        assertEq(hollarDebt.balanceOf(address(vault)), debtBefore, "68% is inside 65-83");
        pool.setPrice(address(eth), 3_500e18);
        vault.rebalance();
        assertApproxEqRel(hollarDebt.balanceOf(address(vault)), 2_625e18, 0.01e18, "64% relevers to 75%");
    }

    function test_defaultBandReleversWhereTheWideOneWaits() public {
        pool.setPrice(address(eth), 3_309e18);
        vault.rebalance();
        assertApproxEqRel(hollarDebt.balanceOf(address(vault)), 2_481.75e18, 0.01e18, "68% is under 70%");
    }

    function test_wideDeleverSideWaitsAboveEightyThree() public {
        _ramp();
        _studyBand(vault);
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        pool.setPrice(address(eth), 2_744e18);
        vault.rebalance();
        assertEq(vault.deleverTarget(), 0, "82% is inside 65-83");
        assertEq(hollarDebt.balanceOf(address(vault)), debtBefore);
        pool.setPrice(address(eth), 2_700e18);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0, "83.3% delevers");
        _settleDelever();
        assertApproxEqRel(hollarDebt.balanceOf(address(vault)), 2_025e18, 0.05e18, "back to 75%");
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, hollarDebt.balanceOf(address(vault)));
    }

    function test_bandTargetFollowsAGovernanceLtvRaise() public {
        loop.setRebalanceBand(address(vault), 500, 500, 300);
        pool.setLtv(address(eth), 8500);
        pool.setPrice(address(eth), 3_030e18);
        vault.rebalance();
        assertApproxEqRel(hollarDebt.balanceOf(address(vault)), 2_424e18, 0.01e18, "80% under an 85% max");
    }

    function test_bandTargetFollowsAGovernanceLtvCut() public {
        _ramp();
        loop.setRebalanceBand(address(vault), 500, 1_000, 800);
        vault.rebalance();
        assertEq(vault.deleverTarget(), 0, "75% is inside 60-78");
        pool.setLtv(address(eth), 7000);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0, "75% is over 65+8");
        _settleDelever();
        assertApproxEqRel(hollarDebt.balanceOf(address(vault)), 1_950e18, 0.05e18, "65% under a 70% max");
    }

    function test_creditDeploysToTheTargetInsideAWideBand() public {
        _studyBand(vault);
        pool.setPrice(address(eth), 3_309e18);
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        eth.mint(address(this), 0.01e18);
        eth.approve(address(vault), 0.01e18);
        vault.deposit(0.01e18, address(this));
        vault.rebalance();
        assertApproxEqRel(
            hollarDebt.balanceOf(address(vault)) - debtBefore, 24.8175e18, 0.02e18, "the deposit levers to 75%, the drift waits"
        );
    }

    function test_bandsArePerVault() public {
        CollateralVault other = CollateralVault(Artifacts.proxy(Artifacts.collateralVault(), abi.encodeCall(CollateralVault.initialize,
            ("Juicer ETH 2","jETH2",address(eth),address(pool),address(loop),address(0),address(hollar),address(synth),address(aEth),address(hollarDebt),1_000e18,address(this)))));
        synth.grantRole(synth.MINTER_ROLE(), address(other));
        RoundingReserveFixture.fund(other);
        loop.registerVault(address(other));
        eth.mint(address(this), 1e18);
        eth.approve(address(other), 1e18);
        other.deposit(1e18, address(this));
        other.rebalance();
        _studyBand(vault);
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        pool.setPrice(address(eth), 3_309e18);
        vault.rebalance();
        other.rebalance();
        assertEq(hollarDebt.balanceOf(address(vault)), debtBefore, "wide band waits");
        assertApproxEqRel(hollarDebt.balanceOf(address(other)), 2_481.75e18, 0.01e18, "default band relevers");
    }

    function test_exitsStillHoldPriceResizingInsideABand() public {
        _studyBand(vault);
        vault.requestRedeem(vault.balanceOf(address(this)) / 10, address(this));
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        pool.setPrice(address(eth), 3_500e18);
        vault.rebalance();
        assertEq(hollarDebt.balanceOf(address(vault)), debtBefore, "64% waits for the exit");
    }

    function _exitNinetyPercentSettled(bool claimIt) internal {
        loop.setRebalanceBand(address(vault), 0, 1000, 800);
        uint256 id = vault.requestRedeem(vault.balanceOf(address(this)) * 9 / 10, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        assertEq(vault.queueHead(), vault.queueUnwind());
        assertGt(vault.totalQueuedCollateral(), 0);
        if (claimIt) vault.claim(id, address(this), type(uint256).max);
    }

    function _thirtyDollarDepositDeploysAtTarget() internal {
        uint256 beforeDebt = hollarDebt.balanceOf(address(vault));
        eth.mint(address(this), 0.01e18);
        eth.approve(address(vault), 0.01e18);
        vault.deposit(0.01e18, address(this));
        vault.rebalance();
        uint256 afterDebt = hollarDebt.balanceOf(address(vault));
        vault.rebalance();
        assertEq(hollarDebt.balanceOf(address(vault)), afterDebt, "nothing left for a second pass");
        assertApproxEqAbs(afterDebt - beforeDebt, 22.5e18, 1e12, "the deposit deploys at the 75% target");
    }

    function test_unclaimedExitDoesNotShrinkNewDepositCredit() public {
        _exitNinetyPercentSettled(false);
        _thirtyDollarDepositDeploysAtTarget();
    }

    function test_claimedExitNewDepositCredit() public {
        _exitNinetyPercentSettled(true);
        _thirtyDollarDepositDeploysAtTarget();
    }

    function test_unclaimedExitDefaultBandNewDepositCredit() public {
        _exitNinetyPercentSettled(false);
        loop.setRebalanceBand(address(vault), 0, 0, 0);
        _thirtyDollarDepositDeploysAtTarget();
    }

    function test_bandDeleverStaysUnderTheLiquidationThreshold() public {
        // eth: max ltv 75%, liquidation threshold 85%
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setRebalanceBand(address(vault), 0, 1_000, 1_000);
        loop.setRebalanceBand(address(vault), 0, 1_000, 999);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setRebalanceBand(address(vault), 500, 1_000, 1_500);
        loop.setRebalanceBand(address(vault), 500, 1_000, 1_499);
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 7_600, 7_500, 18, 3_000e18);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setRebalanceBand(address(vault), 0, 1_000, 100);
        loop.setRebalanceBand(address(vault), 0, 0, 0);
    }

    function test_aLoopWithoutBandsKeepsTheDefaultBand() public {
        _studyBand(vault);
        vm.mockCallRevert(address(loop), abi.encodeWithSelector(SubLoop.rebalanceBand.selector), "");
        pool.setPrice(address(eth), 3_309e18);
        vault.rebalance();
        assertApproxEqRel(hollarDebt.balanceOf(address(vault)), 2_481.75e18, 0.01e18, "the default band relevers at 68%");
    }

    // headroom exits: collateral leaves from the vault's LTV room and the loop stays whole

    function _requestTenth(uint256 primePrice) internal returns (uint256 id) {
        _ramp();
        pool.setPrice(address(eth), 3_600e18); // 62.5% ltv, under the 75% max
        pool.setPrice(address(prime), primePrice);
        id = vault.requestRedeem(vault.balanceOf(address(this)) / 10, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
    }

    function _fundReserve(uint256 amount) internal returns (JuicerMainDebt ledger) {
        ledger = JuicerMainDebt(address(vault.mainDebt()));
        hollar.mint(address(this), amount);
        hollar.approve(address(ledger), amount);
        ledger.fundReserve(amount);
    }

    /// loop equity net of the active Main position, per active vault share (1e18)
    function _netPerShare() internal view returns (uint256) {
        (uint256 debt,, uint256 cash) = vault.mainDebt().activePosition();
        uint256 equity = loop.equityOf(address(vault)) * 1e10 + cash;
        uint256 active = vault.totalSupply() - vault.totalQueuedShares();
        return equity > debt ? (equity - debt) * 1e18 / active : 0;
    }

    function _redemption(uint256 id) internal view returns (uint256 owed, uint256 debtShare, uint256 settled, bool active) {
        (,, owed, debtShare,,, settled,, active) = vault.redemptions(id);
    }

    function test_headroomExitPaysCollateralWithoutSellingTheLoop() public {
        uint256 id = _requestTenth(0.99e18); // the loop is under its debt: a shortfall
        loop.setExitHeadroom(address(vault), true, 0);
        JuicerMainDebt ledger = _fundReserve(100e18);
        uint256 loopShares = vault.loopShares();
        uint256 primeHeld = aPrime.balanceOf(address(loop));
        uint256 net = _netPerShare();

        vault.startUnwinds(1);
        assertEq(loop.unwindTargetEquity(), 0, "nothing to sell");
        assertEq(vault.loopShares(), loopShares, "the holders who stay keep the slice");
        (uint256 owed, uint256 debtShare,,) = _redemption(id);
        assertGt(debtShare, 0, "the exit keeps only its shortfall");
        assertLt(debtShare, 30e18);
        // equityOf has 8 decimals
        assertGe(_netPerShare() + 1e11, net, "the holders who stay are not worse off");

        uint256 reserve = ledger.protocolReserve();
        vault.pokeSettle();
        assertEq(vault.queueHead(), id + 1, "settled at once");
        (,, uint256 settled,) = _redemption(id);
        assertEq(settled, owed);
        assertApproxEqAbs(reserve - ledger.protocolReserve(), debtShare, 1e12, "the reserve covers the shortfall");
        uint256 before_ = eth.balanceOf(address(this));
        vault.claim(id, address(this), type(uint256).max);
        assertEq(eth.balanceOf(address(this)) - before_, owed, "the full collateral promise");
        assertEq(aPrime.balanceOf(address(loop)), primeHeld, "no prime sold");
    }

    function test_headroomExitUnwindsOnlyTheSurplus() public {
        uint256 id = _requestTenth(1.01e18); // the loop is over its debt: a surplus
        loop.setExitHeadroom(address(vault), true, 0);
        uint256 loopShares = vault.loopShares();
        uint256 net = _netPerShare();

        vault.startUnwinds(1);
        (uint256 owed, uint256 debtShare,,) = _redemption(id);
        assertEq(debtShare, 0, "the debt stays with the holders who stay");
        uint256 unwound = loopShares - vault.loopShares();
        assertGt(unwound, 0);
        assertLt(unwound, loopShares / 50, "only the surplus leaves the loop");
        // equityOf has 8 decimals
        assertGe(_netPerShare() + 1e11, net, "the holders who stay are not worse off");

        vault.pokeSettle();
        (,, uint256 settled,) = _redemption(id);
        assertEq(settled, owed, "collateral first, the surplus after");
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        JuicerMainDebt ledger = JuicerMainDebt(address(vault.mainDebt()));
        uint256 surplus = ledger.surplusOf(id);
        assertGt(surplus, 0);
        uint256 before_ = hollar.balanceOf(address(this));
        ledger.claimSurplus(id);
        assertEq(hollar.balanceOf(address(this)) - before_, surplus, "the surplus pays the owner in HOLLAR");
    }

    function test_headroomIsOffUntilEnabled() public {
        uint256 id = _requestTenth(0.99e18);
        _fundReserve(100e18);
        vault.startUnwinds(1);
        (, uint256 debtShare,,) = _redemption(id);
        assertGt(loop.unwindTargetEquity(), 100e18, "the slice unwinds as before");
        assertGt(debtShare, 200e18, "with its whole debt share");
    }

    function test_headroomStaysUnderTheCap() public {
        uint256 id = _requestTenth(0.99e18);
        pool.setPrice(address(eth), 3_000e18); // back at the 75% max
        loop.setExitHeadroom(address(vault), true, 0);
        _fundReserve(100e18);
        vault.startUnwinds(1);
        (, uint256 debtShare,,) = _redemption(id);
        assertGt(debtShare, 200e18, "no room under the cap: the queue");
    }

    function test_aShortfallWithoutReserveQueues() public {
        uint256 id = _requestTenth(0.99e18);
        loop.setExitHeadroom(address(vault), true, 0);
        vault.startUnwinds(1);
        (, uint256 debtShare,,) = _redemption(id);
        assertGt(debtShare, 200e18, "the reserve cannot cover the shortfall: the queue");
    }

    function test_headroomGapLowersTheCap() public {
        _ramp();
        pool.setPrice(address(eth), 3_600e18);
        pool.setPrice(address(prime), 1.01e18);
        loop.setExitHeadroom(address(vault), true, 1_000); // cap 65%
        uint256 tenth = vault.requestRedeem(vault.balanceOf(address(this)) / 10, address(this));
        uint256 small = vault.requestRedeem(vault.balanceOf(address(this)) / 100, address(this));
        vm.warp(block.timestamp + vault.withdrawalDelay());
        vault.startUnwinds(1);
        (, uint256 debtShare,,) = _redemption(tenth);
        assertGt(debtShare, 0, "69% after a tenth leaves: the queue");
        for (uint256 i; i < 400 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        vault.pokeSettle();
        vault.startUnwinds(1);
        (, debtShare,,) = _redemption(small);
        assertEq(debtShare, 0, "a small exit fits under 65%");
    }

    function test_setExitHeadroomIsAdminOnlyBoundedAndPerVault() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        loop.setExitHeadroom(address(vault), true, 0);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setExitHeadroom(address(0xBEEF), true, 0);
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.setExitHeadroom(address(vault), true, 10_001);
        (bool enabled, uint16 gap) = loop.exitHeadroom(address(vault));
        assertFalse(enabled, "off until governance turns it on");
        vm.expectEmit(true, false, false, true, address(loop));
        emit SubLoop.ExitHeadroomSet(address(vault), true, 500);
        loop.setExitHeadroom(address(vault), true, 500);
        (enabled, gap) = loop.exitHeadroom(address(vault));
        assertTrue(enabled);
        assertEq(gap, 500);
        loop.setExitHeadroom(address(vault), false, 0);
        (enabled,) = loop.exitHeadroom(address(vault));
        assertFalse(enabled);
    }
}
