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

/// @notice `pokeSettle` settles a long funded queue in bounded passes.
contract SettleBatchTest is Test {
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

    address small = makeAddr("small");
    address user = makeAddr("user");

    uint256 constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 constant SMALL_REQUESTS = 400;
    uint256 constant MAX_SETTLE_PER_CALL = 32; // mirrors the internal vault constant

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

    function test_singleRequestSettles() public {
        _bootstrap();
        _depositAs(user, 1e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();

        uint256 shares = vault.balanceOf(user);
        uint256 reqId = _requestAs(user, shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        _unwindEverything();
        // cover unwind rounding dust so the debt slice repays in full
        hollar.mint(address(vault), 1e18);

        uint256 g = gasleft();
        vault.pokeSettle();
        uint256 used = g - gasleft();

        emit log_named_uint("gas to settle 1 request", used);
        assertLt(used, BLOCK_GAS_LIMIT, "settles within block gas");
        assertEq(vault.queueHead(), reqId + 1, "request fully settled");
    }

    function test_longQueueSettlesInBoundedPasses() public {
        _bootstrap();
        _depositAs(user, 1e18);
        _depositAs(small, 0.4e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();

        uint256 part = vault.balanceOf(small) / SMALL_REQUESTS;
        assertGt(vault.convertToAssets(part), 0, "request is non-zero");
        for (uint256 i = 0; i < SMALL_REQUESTS; i++) {
            _requestAs(small, part);
        }
        uint256 userReq = _requestAs(user, vault.balanceOf(user));
        assertEq(userReq, SMALL_REQUESTS, "user request is last in the queue");

        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(type(uint256).max);
        assertEq(vault.queueUnwind(), userReq + 1, "all requests started");
        _unwindEverything();

        // fund the whole queue so no pass stops early on a shortfall
        uint256 shortfall = vault.totalQueuedDebt() - hollar.balanceOf(address(vault)) - loop.freedOf(address(vault));
        hollar.mint(address(vault), shortfall + 1e18);

        uint256 calls;
        uint256 maxPassGas;
        while (vault.queueHead() < vault.queueUnwind()) {
            uint256 headBefore = vault.queueHead();
            uint256 g = gasleft();
            (bool ok,) = address(vault).call{gas: BLOCK_GAS_LIMIT}(abi.encodeCall(CollateralVault.pokeSettle, ()));
            uint256 used = g - gasleft();
            assertTrue(ok, "pass fits the block budget");
            uint256 progressed = vault.queueHead() - headBefore;
            assertGt(progressed, 0, "every pass makes progress");
            assertLe(progressed, MAX_SETTLE_PER_CALL, "pass is capped");
            if (used > maxPassGas) maxPassGas = used;
            calls++;
        }
        emit log_named_uint("settle calls to drain the queue", calls);
        emit log_named_uint("max gas for one settle pass", maxPassGas);
        uint256 n = SMALL_REQUESTS + 1;
        assertEq(calls, (n + MAX_SETTLE_PER_CALL - 1) / MAX_SETTLE_PER_CALL, "queue drains in ceil(n/cap) calls");

        (, , , uint256 debtShare, , uint256 repaid, uint256 settled, , ) = vault.redemptions(userReq);
        assertEq(repaid, debtShare, "user debt fully repaid");
        assertGt(settled, 0, "user collateral settled");
        uint256 balBefore = eth.balanceOf(user);
        vm.prank(user);
        vault.claim(userReq, user);
        assertEq(eth.balanceOf(user) - balBefore, settled, "user receives the settled collateral");
    }
}
