// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IceIntentsTest} from "./IceIntents.t.sol";
import {SubLoop} from "../src/SubLoop.sol";

contract AuditPr46IntentsTest is IceIntentsTest {
    address constant STRANGER = address(0xBEEF);

    function _aboveTarget() internal {
        _rampToTarget();
        pool.setPrice(address(prime), 1.01e18);
        assertGt(loop.effectiveHealthFactor(), TARGET_HF);
    }

    function test_pr46_landedExitFillDoesNotInviteASafetyDelever() public {
        _aboveTarget();
        loop.requestUnwind(loop.sharesOf(address(this)) / 2);
        loop.pokeRepayQuoted(EXIT_RATE);
        uint128 id = dispatch.lastId();
        dispatch.fill(id, dispatch.quote(id, 1));

        assertLt(loop.healthFactor(), TARGET_HF, "aave sees the aPRIME gone and the debt unpaid");
        assertGe(loop.effectiveHealthFactor(), TARGET_HF, "the landed cash still backs the debt");
        vm.prank(STRANGER);
        vm.expectRevert(SubLoop.HealthyEnough.selector);
        loop.deLever();

        loop.pokeRepayQuoted(EXIT_RATE);
        assertEq(loop.deleverDebtTarget(), 0);
        assertGe(loop.effectiveHealthFactor(), TARGET_HF, "the split keeps the position at target");
    }

    function test_pr46_idleEntryCashNoLongerMasksALoopBelowTarget() public {
        _rampToTarget();
        (, uint256 debt8,,,,) = pool.getUserAccountData(address(loop));
        _deposit(debt8 * 1e10 / 20);
        assertGt(loop.pokeBorrowQuoted(ENTRY_RATE), 0);
        (,, uint8 kind,,) = _pending();
        assertEq(kind, ENTRY);

        pool.setPrice(address(prime), 0.955e18);
        uint256 hf = loop.healthFactor();
        assertLt(hf, 1.01e18, "the live position is near liquidation");
        assertLt(loop.effectiveHealthFactor(), TARGET_HF);
        assertGt(loop.effectiveHealthFactor(), hf);
        vm.prank(STRANGER);
        loop.deLever();
        assertGt(loop.deleverDebtTarget(), 0);
    }

    function test_pr46_unwindSaleCountsIdleCashInTheSplitBase() public {
        _rampToTarget();
        loop.requestUnwind(loop.sharesOf(address(this)) / 100);
        _deposit(50e18);
        assertEq(loop.pokeBorrowQuoted(ENTRY_RATE), 0);

        (uint256 coll8, uint256 debt8,,,,) = pool.getUserAccountData(address(loop));
        uint256 idle8 = hollar.balanceOf(address(loop)) / 1e10;
        uint256 target8 = Math.ceilDiv(loop.unwindTargetEquity(), 1e10);
        uint256 gross8 = coll8 + idle8;
        uint256 exact = Math.mulDiv(Math.mulDiv(target8, gross8, gross8 - debt8, Math.Rounding.Up) - idle8,
            1e12, 1e8 * 990_000, Math.Rounding.Up);
        uint256 collOnly = Math.mulDiv(Math.mulDiv(target8, coll8, coll8 - debt8, Math.Rounding.Up) - idle8,
            1e12, 1e8 * 990_000, Math.Rounding.Up);

        loop.pokeRepayQuoted(EXIT_RATE);
        (,, uint8 kind, uint256 amountIn,) = _pending();
        assertEq(kind, EXIT);
        assertEq(amountIn, exact, "need against collateral plus idle cash");
        assertLt(amountIn, collOnly * 9 / 10, "the collateral-only base oversold by over 10%");

        _resolve();
        loop.pokeRepayQuoted(EXIT_RATE);
        assertEq(loop.unwindTargetEquity(), 0, "the request is freed");
        uint256 left = hollar.balanceOf(address(loop)) - loop.reservedFreed();
        assertLt(left, 0.1e18, "no oversold cash left idle");
    }

    function test_pr46_safetyStepSellsOnlyWhatTheTargetNeeds() public {
        _rampToTarget();
        pool.setPrice(address(prime), 0.998e18);
        loop.deLever();
        uint256 target = loop.deleverDebtTarget();
        assertGt(target, 0);
        uint256 idle = hollar.balanceOf(address(loop)) - loop.reservedFreed();

        uint256 collateral = aPrime.balanceOf(address(loop));
        loop.pokeRepayQuoted(EXIT_RATE * 998 / 1000);
        uint256 sold = collateral - aPrime.balanceOf(address(loop));
        uint256 need = Math.mulDiv(target - idle, 1e8 * 1e6, 0.998e8 * 1e12 * 990_000, Math.Rounding.Up);
        assertEq(sold, need, "bounded by the target");
        assertEq(loop.deleverDebtTarget(), 0, "one step meets it");
        assertApproxEqRel(loop.healthFactor(), TARGET_HF, 0.002e18);
    }

    function test_pr46_aHalfGiftNoLongerSettlesALiveIntent() public {
        _deposit(SEED);
        _rampSteps(2);
        loop.pokeBorrowQuoted(ENTRY_RATE);
        (uint64 nonce,,,, uint256 minOut) = _pending();
        uint256 equity = loop.totalEquity();
        aPrime.mint(address(loop), minOut / 2);

        vm.prank(STRANGER);
        assertEq(loop.reconcile(), WAITING);
        (uint64 still,,,,) = _pending();
        assertEq(still, nonce, "the intent stays in flight");
        assertApproxEqAbs(loop.totalEquity(), equity + minOut / 2 * 1e2, 1, "the input still counts beside the gift");

        _resolve();
        (,, uint8 kind,,) = _pending();
        assertEq(kind, 0, "the real fill settles it");
    }
}

