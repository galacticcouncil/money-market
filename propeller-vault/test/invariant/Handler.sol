// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {SubLoop} from "../../src/SubLoop.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {PropellerOperatingBuffer} from "../../src/PropellerOperatingBuffer.sol";

/// @notice Randomized driver for the Propeller invariant suite. A single actor
///         (this handler) deposits, drives the deploy/unwind DCA + keeper pokes,
///         requests redemptions, settles and claims — in whatever order the
///         fuzzer picks. Ghost vars track quantities the invariants compare to.
contract Handler is Test {
    CollateralVault public vault;
    SubLoop public loop;
    MockPool public pool;
    MockERC20 public eth;
    MockERC20 public prime;

    uint256 public ghostEscrowed; // pShares escrowed in open redemptions
    uint256 public successfulDeposits;
    uint256 public ghostRequested;
    uint256 public ghostClaimed;
    uint256[] public reqIds;

    constructor(
        CollateralVault _vault,
        SubLoop _loop,
        MockPool _pool,
        MockERC20 _eth,
        MockERC20 _prime
    ) {
        vault = _vault;
        loop = _loop;
        pool = _pool;
        eth = _eth;
        prime = _prime;
    }

    // ── user: deposit ───────────────────────────────────────────────────────
    function deposit(uint256 amt) external {
        uint256 cap = vault.tvlCap();
        uint256 used = vault.totalAssets();
        if (used >= cap) return;
        amt = bound(amt, 1e15, cap - used);
        eth.mint(address(this), amt);
        eth.approve(address(vault), amt);
        vault.deposit(amt, address(this));
        successfulDeposits++;
    }

    // ── keeper: ramp the loop (each poke borrows + levers a tranche) ─────────
    function ramp(uint256 n) external {
        n = bound(n, 1, 8);
        for (uint256 i = 0; i < n; i++) {
            loop.pokeBorrow();
        }
    }

    // ── user: request redemption ──────────────────────────────────────────────
    function requestRedeem(uint256 seed) external {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        uint256 id = vault.requestRedeem(shares, address(this));
        reqIds.push(id);
        ghostEscrowed += shares;
    }

    function advanceAndStart(uint256 secondsForward, uint256 count) external {
        vm.warp(block.timestamp + bound(secondsForward, 0, 24 hours));
        uint256 before = vault.queueUnwind();
        vault.startUnwinds(bound(count, 1, 8));
        for (uint256 id = before; id < vault.queueUnwind(); ++id) {
            (, , uint256 owed, , , , , , ) = vault.redemptions(id);
            ghostRequested += owed;
        }
    }

    // ── keeper: deleveraging spiral (pokeRepay sells + repays per call) ───────
    function churnUnwind(uint256 n) external {
        if (loop.unwindTargetEquity() == 0) return;
        n = bound(n, 1, 12);
        for (uint256 i = 0; i < n; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
    }

    // ── keeper: settle queued redemptions ─────────────────────────────────────
    function settle() external {
        vault.pokeSettle();
    }

    function accrueMainInterest(uint256 seed) external {
        MockERC20 debt = MockERC20(address(vault.hollarDebtToken()));
        uint256 balance = debt.balanceOf(address(vault));
        if (balance == 0) return;
        debt.mint(address(vault), bound(seed, 1, balance / 100_000 + 1));
        vault.maintainPeg();
    }

    function externalRepayment(uint256 seed) external {
        uint256 balance = vault.hollarDebtToken().balanceOf(address(vault));
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        MockERC20 cash = MockERC20(address(vault.hollar()));
        cash.mint(address(this), amount);
        cash.approve(address(pool), amount);
        pool.repay(address(cash), amount, 2, address(vault));
    }

    function claimOperatingBuffer(uint256 seed) external {
        if (vault.queueUnwind() == 0) return;
        PropellerOperatingBuffer(address(vault.operatingBuffer())).claimBuffer(seed % vault.queueUnwind());
    }

    // ── user: claim a settled request ─────────────────────────────────────────
    function claim(uint256 seed) external {
        uint256 len = reqIds.length;
        if (len == 0) return;
        uint256 id = reqIds[bound(seed, 0, len - 1)];
        (
            , // owner
            , // shares
            , // collateralOwed
            , // debtShare
            , // synthShare
            , // repaid
            uint256 settled,
            , // sharesBurned
            bool active
        ) = vault.redemptions(id);
        if (!active || settled == 0) return;
        // claim may be partial: shares are burned only in proportion to the
        // collateral paid, so track the ACTUAL burn (escrow balance delta)
        // rather than assuming the whole request closes.
        uint256 escrowBefore = vault.balanceOf(address(vault));
        ghostClaimed += vault.claim(id, address(this));
        ghostEscrowed -= (escrowBefore - vault.balanceOf(address(vault)));
    }
}
