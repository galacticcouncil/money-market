// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {SubLoopLogic} from "../src/lib/SubLoopLogic.sol";

/// @notice pokeRepay sells only what open requests still need, and a de-lever target
/// lapses once hf is back at targetHf
contract SubLoopUnwindSizingTest is Test {
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
    uint16 constant FEE_BPS = 100; // 1% swap fee makes over-selling measurable

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

        SubLoop impl = new SubLoop(address(new SubLoopLogic()));
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

    /// a small unwind sells ~target·leverage, not a full tranche
    function test_unwindSaleSizedToRemainingTarget() public {
        _ramp();

        loop.requestUnwind(loop.sharesOf(address(this)) / 200);
        uint256 target = loop.unwindTargetEquity();
        // freed ≈ 16.2% of each sale at this leverage ⇒ need ≈ target / 0.162
        uint256 need6 = (target / 1e12) * 1000 / 162;
        uint256 apBefore = aPrime.balanceOf(address(loop));
        uint256 equityBefore = loop.totalEquity();

        loop.pokeRepay();

        uint256 sold6 = apBefore - aPrime.balanceOf(address(loop));
        assertLt(sold6, 100e6, "below the tranche");
        assertLe(sold6, need6 * 105 / 100, "within 5% of the need");
        assertLe(loop.unwindTargetEquity(), 0.01e18, "request (all but dust) credited");
        assertLt(hollar.balanceOf(address(loop)) - loop.reservedFreed(), 0.5e18, "no idle surplus");

        // equity out = payout + fee on the needed sale only
        uint256 equityLoss = equityBefore - loop.totalEquity();
        assertLt(equityLoss, target / 1e10 + (need6 * 1e2 * FEE_BPS * 2) / 10_000, "fee on the need, not a tranche");

        // the dust tail finishes without another tranche
        uint256 ap = aPrime.balanceOf(address(loop));
        for (uint256 i = 0; i < 3 && loop.unwindTargetEquity() != 0; i++) loop.pokeRepay();
        assertLt(ap - aPrime.balanceOf(address(loop)), 1e6, "tail sells under 1 aPRIME");
        assertEq(loop.unwindTargetEquity(), 0, "tail is fully funded");
    }

    function test_subUsd8ClaimFinishesWithDebt() public {
        _ramp();
        loop.requestUnwind(1e9);
        uint256 target = loop.unwindTargetEquity();
        assertGt(target, 0);
        assertLt(target, 1e10, "below USD8 precision");
        uint256 before = aPrime.balanceOf(address(loop));
        for (uint256 i; i < 3 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        assertEq(loop.unwindTargetEquity(), 0, "no frozen rounding tail");
        assertEq(loop.freedOf(address(this)), target, "claim is preserved");
        assertLe(before - aPrime.balanceOf(address(loop)), 2, "only rounding-sized sales");
    }

    function test_subPrimeUnitClaimFinishesWithoutDebt() public {
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        loop.deposit(SEED);
        loop.requestUnwind(1e9);
        uint256 target = loop.unwindTargetEquity();
        assertGt(target, 0);
        assertLt(target, 1e12, "below one PRIME base unit");
        uint256 before = aPrime.balanceOf(address(loop));
        loop.pokeRepay();
        assertEq(loop.unwindTargetEquity(), 0);
        assertEq(loop.freedOf(address(this)), target);
        assertEq(before - aPrime.balanceOf(address(loop)), 1);
    }

    function test_reservedHollarIsNotAvailableToAnotherUnwind() public {
        _ramp();
        loop.requestUnwind(loop.sharesOf(address(this)) / 200);
        for (uint256 i; i < 10 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        uint256 reserved = loop.reservedFreed();
        assertGt(reserved, 0);
        loop.requestUnwind(loop.sharesOf(address(this)) / 200);
        for (uint256 i; i < 10 && loop.unwindTargetEquity() != 0; ++i) loop.pokeRepay();
        assertEq(loop.unwindTargetEquity(), 0);
        assertGt(loop.reservedFreed(), reserved);
        assertLe(loop.reservedFreed(), hollar.balanceOf(address(loop)), "all credits funded");
    }

    /// idle HOLLAR counts toward the need before any aPRIME is sold
    function test_idleHollarCoversUnwindBeforeSelling() public {
        _ramp();
        hollar.mint(address(loop), 50e18); // idle equity, e.g. an earlier sale's remainder

        loop.requestUnwind(loop.sharesOf(address(this)) / 500);
        uint256 apBefore = aPrime.balanceOf(address(loop));
        loop.pokeRepay();

        assertEq(aPrime.balanceOf(address(loop)), apBefore, "nothing sold");
        assertEq(loop.unwindTargetEquity(), 0, "credited from idle HOLLAR");
    }

    /// a de-lever target lapses once the price recovers
    function test_deleverTargetLapsesWhenHealthRecovers() public {
        _ramp();

        pool.setPrice(address(prime), 0.98e18);
        loop.deLever();
        assertGt(loop.deleverDebtTarget(), 0, "target set in the dip");

        pool.setPrice(address(prime), 1e18);
        assertGe(loop.healthFactor(), TARGET_HF, "HF back at target");

        uint256 apBefore = aPrime.balanceOf(address(loop));
        loop.pokeRepay();
        assertEq(loop.deleverDebtTarget(), 0, "target dropped");
        assertEq(aPrime.balanceOf(address(loop)), apBefore, "nothing sold");
    }

    /// pokeBorrow resumes the ramp without waiting for a pokeRepay
    function test_pokeBorrowResumesAfterRecovery() public {
        _ramp();

        pool.setPrice(address(prime), 0.98e18);
        loop.deLever();
        pool.setPrice(address(prime), 1.01e18); // recovered with headroom to borrow

        uint256 debtBefore = hollarDebt.balanceOf(address(loop));
        loop.pokeBorrow();
        assertEq(loop.deleverDebtTarget(), 0, "target dropped");
        assertGt(hollarDebt.balanceOf(address(loop)), debtBefore, "ramp resumed");
    }

    /// a real de-lever still runs until HF reaches target, then stops
    function test_deleverStillRunsWhileUnhealthy() public {
        _ramp();

        pool.setPrice(address(prime), 0.98e18);
        loop.deLever();
        uint256 hfDip = loop.healthFactor();
        uint256 apBefore = aPrime.balanceOf(address(loop));
        for (uint256 i = 0; i < 30 && loop.deleverDebtTarget() != 0; i++) loop.pokeRepay();

        assertLt(aPrime.balanceOf(address(loop)), apBefore, "collateral sold");
        assertEq(loop.deleverDebtTarget(), 0, "target cleared");
        // the target is sized fee-free, so the 1% swap fee lands HF just shy of target
        assertGt(loop.healthFactor(), hfDip, "HF raised");
        assertApproxEqRel(loop.healthFactor(), TARGET_HF, 0.005e18, "HF back near target");
    }
}
