// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";

/// @notice the vault runs a full deposit → redeem → claim against a non-leveraged
/// `IYieldSource`, so the source is pluggable
contract PluggableYieldSourceTest is Test {
    MockERC20 eth;
    MockERC20 aEth;
    MockERC20 ethDebt;
    MockERC20 hollar;
    MockERC20 aHollar;
    MockERC20 hollarDebt;
    MockERC20 aSynth;
    MockERC20 synthDebt;

    MockPool pool;
    SyntheticToken synth;
    MockYieldSource source; // the non-leveraged plug
    CollateralVault vault;

    function setUp() public {
        eth = new MockERC20("ETH", "ETH", 18);
        aEth = new MockERC20("aETH", "aETH", 18);
        ethDebt = new MockERC20("dETH", "dETH", 18);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);
        hollarDebt = new MockERC20("dHOLLAR", "dHOLLAR", 18);
        synth = new SyntheticToken("Juicer Synthetic", "jsHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        source = new MockYieldSource(address(hollar));

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
                            address(source), // non-leveraged source
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

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
    }

    function test_depositRedeemClaimThroughNonLeveragedSource() public {
        // fund collateral, then deploy hollar into the generic source
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));
        assertGt(shares, 0, "shares minted");
        assertEq(vault.loopShares(), 0, "deposit waits for deployment");
        vault.rebalance();

        assertGt(vault.loopShares(), 0, "vault holds shares in the generic source");
        assertGt(source.equityOf(address(vault)), 0, "source reports the vault's equity");
        assertEq(
            hollar.balanceOf(address(source)),
            hollarDebt.balanceOf(address(vault)),
            "borrowed HOLLAR is custodied by the source"
        );

        // no ramp or pokes: requestUnwind frees synchronously and pokeSettle pulls it back
        uint256 reqId = vault.requestRedeem(shares, address(this));
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(100);
        vault.pokeSettle();
        uint256 got = vault.claim(reqId, address(this));

        // only DEAD_SHARES (1000 wei) may be lost, so keep the band tight
        assertApproxEqAbs(got, 1e18, 1e6, "principal returned via the generic seam");
        assertApproxEqAbs(hollarDebt.balanceOf(address(vault)), 0, 1e12, "Main debt repaid");
    }
}
