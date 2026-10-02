// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerDiscount} from "../src/PropellerDiscount.sol";
import {IHollarDiscountDebtToken} from "../src/interfaces/IPropellerDiscount.sol";

/// @notice Deploy at zero discount and print, but DO NOT execute, governance calls.
///         Requires already-listed synthetic collateral and hook-enabled vaults.
contract DeployDiscount is Script {
    function run() external returns (PropellerDiscount discount) {
        address debt = vm.envAddress("HOLLAR_VDEBT");
        address synth = vm.envAddress("SYNTH");
        address aSynth = vm.envAddress("ASYNTH");
        address governance = vm.envAddress("DISCOUNT_GOVERNANCE");
        address committee = vm.envAddress("DISCOUNT_COMMITTEE");
        address[] memory vaults = vm.envAddress("DISCOUNT_VAULTS", ",");
        uint256 bps = vm.envOr("DISCOUNT_BPS", uint256(0));
        require(bps <= 10_000, "discount bps");
        require(vaults.length > 0 && vaults.length <= 16, "vault count");

        vm.startBroadcast();
        discount = new PropellerDiscount(debt, synth, aSynth, governance, committee);
        vm.stopBroadcast();

        console.log("PropellerDiscount (initial rate = 0):", address(discount));
        console.log("Governance:", governance);
        console.log("Rate admin (committee):", committee);
        console.log("Governance calls below must execute atomically, in order.");
        _print(debt, abi.encodeCall(IHollarDiscountDebtToken.updateDiscountToken, (address(discount))));
        _print(debt, abi.encodeCall(IHollarDiscountDebtToken.updateDiscountRateStrategy, (address(discount))));
        for (uint256 i; i < vaults.length; ++i) {
            _print(vaults[i], abi.encodeCall(CollateralVault.setDiscountController, (address(discount))));
            _print(address(discount), abi.encodeCall(PropellerDiscount.registerVault, (vaults[i])));
        }
        _print(address(discount), abi.encodeCall(PropellerDiscount.setDiscountBps, (uint16(bps))));
    }

    function _print(address target, bytes memory data) internal pure {
        console.log("target:", target);
        console.logBytes(data);
    }
}
