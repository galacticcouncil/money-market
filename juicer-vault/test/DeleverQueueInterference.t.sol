// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice interference between the permissionless `rebalance()` de-lever and the
///         fifo redemption queue.
contract DeleverQueueInterferenceTest is Test {
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
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;

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
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);
        // isolation-mode prime is never auto-enabled as collateral; pokeBorrow enables it
        pool.setIsolationMode(address(prime), true);

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
                            "Juicer ETH",
                            "jETH",
                            address(eth),
                            address(pool),
                            address(loop),
                            address(0),
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

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function _depositAndRamp() internal {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        vault.rebalance(); // Explicit keeper deployment before exercising a live position.
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    /// @dev returns the spiral rounds consumed; the tail converges geometrically.
    function _grind(uint256 budget) internal returns (uint256 rounds) {
        for (rounds = 0; rounds < budget; rounds++) {
            if (loop.unwindTargetEquity() == 0 && loop.deleverDebtTarget() == 0) break;
            try loop.pokeRepay() {}
            catch (bytes memory err) {
                console2.log("pokeRepay REVERTED at round", rounds);
                console2.logBytes(err);
                break;
            }
            try vault.pokeSettle() {}
            catch (bytes memory err) {
                console2.log("pokeSettle REVERTED at round", rounds);
                console2.logBytes(err);
                break;
            }
        }
        try vault.pokeSettle() {} catch {}
    }

    function _req(uint256 id)
        internal
        view
        returns (uint256 shares, uint256 collateralOwed, uint256 debtShare, uint256 repaid, bool active)
    {
        (, shares, collateralOwed, debtShare,, repaid,,, active) = vault.redemptions(id);
    }

    /// rebalance waits for a queued exit instead of repaying the redeemer's own
    /// debt slice out from under them.
    function test_rebalanceWaitsForQueuedExit() public {
        _depositAndRamp();

        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        uint256 synthBefore = vault.syntheticSupplied();
        assertGt(debtBefore, 0, "position open");

        // redeem 90% of the supply; the snapshot claims 90% of main debt
        uint256 shares = (vault.balanceOf(address(this)) * 90) / 100;
        uint256 id = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        (, , uint256 debtShare, , ) = _req(id);
        uint256 queuedDebt = vault.totalQueuedDebt();
        assertEq(debtShare, queuedDebt, "queue holds the whole snapshot");

        // collateral halves → over-levered, so the de-lever branch fires
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();

        uint256 target = vault.deleverTarget();
        uint256 nonQueuedDebt = debtBefore > queuedDebt ? debtBefore - queuedDebt : 0;
        console2.log("live debt       ", debtBefore);
        console2.log("queued debt     ", queuedDebt);
        console2.log("non-queued debt ", nonQueuedDebt);
        console2.log("deleverTarget   ", target);

        assertLe(target, nonQueuedDebt, "de-lever must never exceed the NON-queued Main debt");
        assertEq(target, 0, "Main resizing waits; source safety de-lever remains independent");

        // capping the repaid debt caps the synthetic burn, so synthShare stays covered
        _grind(600);
        assertLe(
            target,
            synthBefore,
            "sanity: burn basis bounded"
        );
        (, , uint256 ds, uint256 repaid, ) = _req(id);
        assertGe(repaid * 10_000 / ds, 9_999, "redeemer settles to >=99.99% of its snapshot");
    }

    /// the spiral tail can stall on 8dp/6dp truncation; it must stay claimable and
    /// a recovery donation must let the queue head advance.
    function test_unwindSpiralTailRemainsClaimableUntilRecovery() public {
        _depositAndRamp();
        uint256 shares = vault.balanceOf(address(this));
        uint256 id = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);

        uint256 rounds = _grind(2_000);
        (, , uint256 ds, uint256 repaid, bool active) = _req(id);

        console2.log("spiral rounds      ", rounds);
        console2.log("repaid / debtShare ", repaid, ds);
        console2.log("pendingUnwindOf    ", loop.pendingUnwindOf(address(vault)));
        console2.log("loop aPRIME left   ", aPrime.balanceOf(address(loop)));
        console2.log("unwindTargetEquity ", loop.unwindTargetEquity());
        console2.log("queueHead / tail   ", vault.queueHead(), vault.queueTail());

        assertGt(loop.pendingUnwindOf(address(vault)), 0, "unpaid source claim survives dust stall");
        assertLt(repaid, ds, "no sponsored cash silently pays the source tail");
        assertEq(vault.queueHead(), id, "unpaid Main debt keeps the claim open");
        assertTrue(active, "still claimable until fully paid");
        uint256 paid = vault.claim(id, address(this));
        (, , uint256 originalDebt, , bool partiallyActive) = _req(id);
        assertEq(originalDebt, ds);
        assertTrue(partiallyActive, "unfunded collateral remains owed");

        // a recovery donation funds the missing tail, never a new user's deposit
        hollar.mint(address(loop), 1e18);
        _grind(100);
        vault.pokeSettle();
        assertEq(loop.pendingUnwindOf(address(vault)), 0, "source recovery pays its full quote");
        // funding the loop can't credit the cohort more than the 8dp source quote
        JuicerMainDebt ledger = JuicerMainDebt(address(vault.mainDebt()));
        uint256 missing = ledger.debtOf(id + 1);
        assertGt(missing, 0, "Main rounding deficit remains a real obligation");
        hollar.mint(address(this), missing);
        hollar.approve(address(ledger), missing);
        ledger.fundPosition(id + 1, missing);
        vault.pokeSettle();
        paid += vault.claim(id, address(this));
        assertEq(paid, 1e18 - 1000, "all principal apart from governance bootstrap is returned");
        assertEq(vault.queueHead(), vault.queueTail());
        (, , , , bool stillActive) = _req(id);
        assertFalse(stillActive, "request closed on final claim");
    }

    /// a redeem before the loop ramps must still register a non-zero unwind target.
    function test_requestRedeemBeforeRampHasRecognizedBacking() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this)); // no pokeBorrow ramp
        vault.rebalance(); // Explicit keeper deployment before exercising a live position.

        assertGt(vault.loopShares(), 0, "vault holds loop shares");
        assertGt(loop.totalEquity(), 0, "deposit enables PRIME collateral immediately");

        uint256 shares = vault.balanceOf(address(this)) / 2;

        uint256 id = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        (, , uint256 debtShare, , bool active) = _req(id);
        assertGt(debtShare, 0, "vault enqueued a real debt slice");
        assertTrue(active, "request is live");
        assertGt(
            loop.pendingUnwindOf(address(vault)),
            0,
            "SubLoop records a non-zero unwind target for a live request"
        );
    }

    /// Zero backing must not destroy source shares in exchange for a zero claim.
    function test_subLoopPreservesSharesAtZeroEquity() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        vault.rebalance(); // Explicit keeper deployment before exercising a live position.
        pool.setPrice(address(prime), 0);

        assertEq(loop.totalEquity(), 0, "un-ramped loop reports zero equity");
        assertGt(loop.sharesOf(address(vault)), 0, "but the vault holds loop shares");

        uint256 held = loop.sharesOf(address(vault));
        vm.expectRevert(SubLoop.Underfunded.selector);
        vm.prank(address(vault));
        loop.requestUnwind(held);
        assertEq(loop.sharesOf(address(vault)), held, "source shares survive for recovery");
    }
}
