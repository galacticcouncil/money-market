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
import {MockYieldSource} from "./mocks/MockYieldSource.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice `setYieldSource` is a wiring lever: allowed only while the current source
///         owes the vault nothing; there is no force-unwind admin path.
contract AdminSourceControlTest is Test {
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

    address stranger = address(0xBAD);

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
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
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
        vault.rebalance();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    /// a fresh vault has never routed hollar into a source, so repointing is safe.
    function test_setYieldSourceOnFreshVault() public {
        MockYieldSource next = new MockYieldSource(address(hollar));
        vault.setYieldSource(address(next));
        assertEq(address(vault.yieldSource()), address(next), "source repointed");
    }

    /// once funded, repointing must refuse: it would strand the old source's shares.
    function test_setYieldSourceRevertsWhileFunded() public {
        _depositAndRamp();
        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setYieldSource(address(next));
    }

    /// an in-flight unwind still owes the vault hollar; refuse until `pendingUnwindOf` is zero.
    function test_setYieldSourceGuardsInFlightUnwind() public {
        _depositAndRamp();
        vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        assertGt(loop.pendingUnwindOf(address(vault)), 0, "source still owes the vault in-flight");

        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setYieldSource(address(next));
    }

    /// a funded vault can never be repointed: the dead shares' loop slice never unwinds,
    /// so `loopShares` never returns to 0. migration means a new vault.
    function test_setYieldSourceUnreachableOnceFunded() public {
        _depositAndRamp();
        uint256 id = vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        for (uint256 i = 0; i < 2_000; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
            vault.pokeSettle();
        }
        // recover rounding deficits without discarding either layer's claims
        hollar.mint(address(loop), 1e18);
        loop.pokeRepay();
        hollar.mint(address(vault), 1e18);
        vault.pokeSettle();
        vault.claim(id, address(this));

        assertEq(vault.balanceOf(address(this)), 0, "holder fully exited");
        assertEq(loop.pendingUnwindOf(address(vault)), 0, "source owes nothing in flight");
        assertGt(vault.loopShares(), 0, "but the DEAD_SHARES slice remains, forever");

        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setYieldSource(address(next));
    }

    function test_onlyAdminControls() public {
        MockYieldSource next = new MockYieldSource(address(hollar));

        vm.prank(stranger);
        vm.expectRevert();
        vault.setYieldSource(address(next));

        vm.prank(stranger);
        vm.expectRevert();
        vault.setTvlCap(1);

        vm.prank(stranger);
        vm.expectRevert();
        vault.setCompoundSlippageBps(100);
    }
}
