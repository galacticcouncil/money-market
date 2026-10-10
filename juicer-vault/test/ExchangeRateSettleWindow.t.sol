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
import {Deficit} from "./helpers/Deficit.sol";
import {SubLoopLogic} from "../src/lib/SubLoopLogic.sol";

/// @notice settled-but-unclaimed collateral still backs shares: settling leaves the
///         share price unchanged and a deposit in the settle→claim window mints fairly.
contract ExchangeRateSettleWindowTest is Test {
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

    address bob = address(0xB0B);

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
                    address(new SubLoop(address(new SubLoopLogic()))),
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

    /// unwind a redemption; callers settle it but never claim.
    function _settleWithoutClaiming(uint256 sharesToRedeem) internal {
        vault.requestRedeem(sharesToRedeem, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        // no claim: shares stay escrowed
    }

    function test_settleDoesNotDepressSharePrice() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 aliceShares = vault.deposit(1e18, address(this));
        vault.rebalance();

        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        _settleWithoutClaiming(aliceShares / 2);

        // measured immediately before the settling withdraw
        uint256 rateBefore = vault.exchangeRate();
        assertGt(rateBefore, 0, "sanity: rate positive");

        // settle moves the redeemer's collateral into the vault but burns no shares
        vault.pokeSettle();
        assertGt(eth.balanceOf(address(vault)), 0, "sanity: collateral now sits in the vault");

        // the collateral only moved location, so per-share value is unchanged
        uint256 rateAfter = vault.exchangeRate();
        assertEq(rateAfter, rateBefore, "settle must not change the share price");
    }

    function test_depositInSettleWindowIsNotMisMinted() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 aliceShares = vault.deposit(1e18, address(this));
        vault.rebalance();

        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        _settleWithoutClaiming(aliceShares / 2);

        // fair quote for a fresh 1 eth deposit, taken before the settle
        uint256 fairShares = vault.convertToShares(1e18);

        vault.pokeSettle(); // enter the settle→claim window (collateral in vault, unclaimed)

        // bob deposits inside the window and must get the pre-settle quote
        eth.mint(bob, 1e18);
        // cover source conversion dust independently, never from bob's deposit
        hollar.mint(address(loop), 1e18);
        hollar.mint(address(vault), 1e18);
        assertFalse(Deficit.underfunded(vault));
        vm.startPrank(bob);
        eth.approve(address(vault), 1e18);
        uint256 bobShares = vault.deposit(1e18, bob);
        vm.stopPrank();

        assertEq(bobShares, fairShares, "deposit in settle window must mint at the un-depressed rate");
    }
}
