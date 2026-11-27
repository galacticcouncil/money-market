// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {Artifacts} from "./helpers/Artifacts.t.sol";
import {JuicerMainDebt} from "../src/JuicerMainDebt.sol";

/// @notice a partially settled redemption survives `claim()`: only the paid slice's
///         shares burn and the unsettled remainder stays claimable.
contract PartialClaimTest is Test {
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
        synth = SyntheticToken(Artifacts.syntheticToken("Juicer Synthetic", "jsHOLLAR", address(this)));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        loop = SubLoop(
            Artifacts.proxy(
                Artifacts.subLoop(),
                abi.encodeCall(
                    SubLoop.initialize,
                    (
                        address(pool),
                        address(hollar),
                        address(prime),
                        address(aPrime),
                        1.05e18,
                        1.10e18,
                        address(this)
                    )
                )
            )
        );

        vault = CollateralVault(
            Artifacts.proxy(
                Artifacts.collateralVault(),
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

    function test_partialClaimKeepsRequestActiveAndReturnsRemainder() public {
        // deposit 1 eth and ramp the loop to target hf
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));
        vault.rebalance();

        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        // request full redemption
        uint256 reqId = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);

        // throttle the sell sliver so the request ends up partially filled
        loop.setTranches(10_000_000e18, 100e6); // ~$100 of aPRIME per pokeRepay
        for (uint256 i = 0; i < 6; i++) {
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // sanity: the queue head has not advanced past the request
        assertEq(vault.queueHead(), reqId, "request only partially settled");

        // claim the ready slice
        uint256 balBefore = eth.balanceOf(address(this));
        uint256 got1 = vault.claim(reqId, address(this), type(uint256).max);
        assertGt(got1, 0, "partial claim pays something");
        assertLt(got1, 1e18, "partial claim is less than full principal");
        assertEq(eth.balanceOf(address(this)) - balBefore, got1, "ETH received == claimed");

        // escrowed shares burn only in proportion to what was paid
        assertGt(vault.balanceOf(address(vault)), 0, "escrow not destroyed by partial claim");

        // finish unwinding and settle the rest
        loop.setTranches(10_000_000e18, 10_000_000e6);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // claim the remainder
        uint256 got2 = vault.claim(reqId, address(this), type(uint256).max);
        assertGt(got2, 0, "remainder is claimable");

        // total across both claims ≈ the full 1 eth principal
        assertApproxEqRel(got1 + got2, 1e18, 0.02e18, "full principal returned across partial claims");

        // proportional-settlement dust may remain in escrow, backed by matching collateral
        assertApproxEqAbs(vault.balanceOf(address(vault)), 0, 1e15, "escrow burned to dust once complete");
    }

    function _partiallySettled() internal returns (uint256 reqId) {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
        reqId = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        loop.setTranches(10_000_000e18, 100e6);
        for (uint256 i = 0; i < 6; i++) {
            loop.pokeRepay();
        }
        vault.pokeSettle();
    }

    function _settleRest() internal {
        loop.setTranches(10_000_000e18, 10_000_000e6);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
    }

    function _settled(uint256 reqId) internal view returns (uint256 settled, bool active) {
        (,,,,,, settled,, active) = vault.redemptions(reqId);
    }

    function test_exactClaimPaysTheAmountAndKeepsTheRest() public {
        uint256 reqId = _partiallySettled();
        (uint256 settled,) = _settled(reqId);
        assertGt(settled, 0);

        uint256 balBefore = eth.balanceOf(address(this));
        uint256 got = vault.claim(reqId, address(this), settled / 3);
        assertEq(got, settled / 3, "pays exactly the amount");
        assertEq(eth.balanceOf(address(this)) - balBefore, settled / 3);
        (uint256 left, bool active) = _settled(reqId);
        assertEq(left, settled - settled / 3, "the rest stays claimable");
        assertTrue(active);

        assertEq(vault.claim(reqId, address(this), type(uint256).max), left, "the max amount takes what is left");
    }

    function test_exactClaimAboveSettledReverts() public {
        uint256 reqId = _partiallySettled();
        (uint256 settled,) = _settled(reqId);
        vm.expectRevert(CollateralVault.NothingToClaim.selector);
        vault.claim(reqId, address(this), settled + 1);
        vm.expectRevert(CollateralVault.NothingToClaim.selector);
        vault.claim(reqId, address(this), 0);
    }

    function test_repaidRequestStaysActiveUntilEmptied() public {
        uint256 reqId = _partiallySettled();
        _settleRest();
        // fund the exit's round-trip shortfall so its debt slice is fully repaid
        JuicerMainDebt ledger = JuicerMainDebt(address(vault.mainDebt()));
        hollar.mint(address(this), 1e18);
        hollar.approve(address(ledger), 1e18);
        ledger.fundPosition(reqId + 1, 1e18);
        vault.pokeSettle();
        (uint256 settled,) = _settled(reqId);
        (,,, uint256 debtShare,, uint256 repaid,,,) = vault.redemptions(reqId);
        assertGe(repaid, debtShare, "fully repaid");

        vault.claim(reqId, address(this), settled / 2);
        (uint256 left, bool active) = _settled(reqId);
        assertTrue(active, "a partial claim of a repaid request is not the last");
        assertGt(vault.balanceOf(address(vault)), 0, "escrow burns pro rata, not all at once");

        vault.claim(reqId, address(this), left);
        (, active) = _settled(reqId);
        assertFalse(active, "emptying a repaid request completes it");
        assertApproxEqAbs(vault.balanceOf(address(vault)), 0, 1e15, "escrow burned to dust once complete");
        assertApproxEqRel(settled, 1e18, 0.02e18, "full principal across the claims");
    }

    function test_thirdPartyExactClaimStillPaysTheOwner() public {
        uint256 reqId = _partiallySettled();
        (uint256 settled,) = _settled(reqId);
        address keeper = address(0xBEEF);
        uint256 balBefore = eth.balanceOf(address(this));
        vm.prank(keeper);
        vault.claim(reqId, keeper, settled / 2);
        assertEq(eth.balanceOf(keeper), 0, "a third party cannot redirect");
        assertEq(eth.balanceOf(address(this)) - balBefore, settled / 2);
    }
}
