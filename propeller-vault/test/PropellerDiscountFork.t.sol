// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PropellerDiscount} from "../src/PropellerDiscount.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {IHollarDiscountDebtToken} from "../src/interfaces/IPropellerDiscount.sol";
import {MockDiscountAToken, MockDiscountVault} from "./mocks/MockDiscount.sol";

interface IGhoDebtActions {
    function mint(address caller, address onBehalfOf, uint256 amount, uint256 index) external returns (bool, uint256);
    function burn(address user, uint256 amount, uint256 index) external returns (uint256);
}

/// @notice Uses the deployed HOLLAR debt-token implementation and accounting.
///         Only the normalized debt index and synthetic backing are test-controlled;
///         this is not an end-to-end fork of Substrate-backed asset transfers.
contract PropellerDiscountForkTest is Test {
    address constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant DEBT = 0x342923782cCaEBf9c38DD9cb40436e82C42c73B5;
    address constant GOVERNANCE = 0xAa7e0000000000000000000000000000000Aa7e0;
    address constant COMMITTEE = address(0xC011);
    uint256 constant RAY = 1e27;
    IHollarDiscountDebtToken debt = IHollarDiscountDebtToken(DEBT);
    PropellerDiscount discount;
    SyntheticToken synth;
    MockDiscountAToken aSynth;
    MockDiscountVault vault;

    function setUp() public {
        string memory rpc = vm.envOr("DISCOUNT_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        uint256 forkBlock = vm.envOr("DISCOUNT_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        _setIndex(RAY);
        synth = new SyntheticToken("Synthetic", "psHOLLAR", address(this));
        aSynth = new MockDiscountAToken(POOL, address(synth));
        discount = new PropellerDiscount(DEBT, address(synth), address(aSynth), address(this), COMMITTEE);
        vm.startPrank(GOVERNANCE);
        debt.updateDiscountToken(address(discount));
        debt.updateDiscountRateStrategy(address(discount));
        vm.stopPrank();
        vault = new MockDiscountVault(POOL, address(synth), DEBT, address(discount));
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        discount.registerVault(address(vault));
        aSynth.mint(address(vault), 2_000e18);
        vm.prank(COMMITTEE);
        discount.setDiscountBps(8_000);
        _borrow(address(vault), 1_000e18, RAY);
        assertEq(debt.getDiscountPercent(address(vault)), 8_000);
    }

    function _setIndex(uint256 index) internal {
        vm.mockCall(
            POOL, abi.encodeWithSignature("getReserveNormalizedVariableDebt(address)", HOLLAR), abi.encode(index)
        );
    }

    function _borrow(address user, uint256 amount, uint256 index) internal {
        vm.prank(POOL);
        IGhoDebtActions(DEBT).mint(user, user, amount, index);
    }

    function testFork_rateChangePreservesOldInterestAndUsesNewRateGoingForward() public {
        _borrow(address(0xB0B), 1_000e18, RAY);
        _setIndex(11 * RAY / 10); // 10% gross index growth; 80% discount leaves 2%
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_020e18, 5);
        vm.prank(COMMITTEE);
        discount.setDiscountBps(5_000);
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_020e18, 5, "no retroactive repricing");
        _setIndex(121 * RAY / 100); // another 10% gross, now 50% off
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_071e18, 5);
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(0xB0B)), 1_210e18, 5, "outsider still pays full rate");
    }

    function testFork_revocationKeepsEarnedDiscountButStopsFutureDiscount() public {
        _setIndex(11 * RAY / 10);
        discount.unregisterVault(address(vault));
        assertEq(debt.getDiscountPercent(address(vault)), 0);
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_020e18, 5);
        _setIndex(121 * RAY / 100);
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_122e18, 5);
    }

    function testFork_fullWaiverPauseRestoreAndRepayment() public {
        vm.prank(COMMITTEE);
        discount.setDiscountBps(10_000);
        _setIndex(11 * RAY / 10);
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_000e18, 5);
        vm.prank(COMMITTEE);
        discount.setDiscountBps(0);
        _setIndex(121 * RAY / 100);
        assertApproxEqAbs(IERC20(DEBT).balanceOf(address(vault)), 1_100e18, 5);
        vm.prank(COMMITTEE);
        discount.setDiscountBps(8_000);
        uint256 repay = IERC20(DEBT).balanceOf(address(vault));
        vm.prank(POOL);
        IGhoDebtActions(DEBT).burn(address(vault), repay, 121 * RAY / 100);
        assertEq(IERC20(DEBT).balanceOf(address(vault)), 0);
        assertEq(debt.getDiscountPercent(address(vault)), 0);
    }

    function testFork_fullRegistryRefreshesEveryAccruedPosition() public {
        for (uint256 i = 1; i < discount.MAX_VAULTS(); ++i) {
            MockDiscountVault next = new MockDiscountVault(POOL, address(synth), DEBT, address(discount));
            synth.grantRole(synth.MINTER_ROLE(), address(next));
            discount.registerVault(address(next));
            aSynth.mint(address(next), 2_000e18);
            _borrow(address(next), 1_000e18, RAY);
        }
        _setIndex(11 * RAY / 10);
        vm.prank(COMMITTEE);
        discount.setDiscountBps(0);
        address[] memory participants = discount.vaults();
        assertEq(participants.length, 16);
        for (uint256 i; i < participants.length; ++i) {
            assertEq(debt.getDiscountPercent(participants[i]), 0);
            assertApproxEqAbs(IERC20(DEBT).balanceOf(participants[i]), 1_020e18, 5);
        }
    }
}
