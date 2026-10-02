// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerFeeController} from "../src/PropellerFeeController.sol";

/// @notice Fresh deployment only. Deploys the controller and prints, but does
/// not execute, the governance wiring. Every new vault starts at 500 bps.
contract DeployFees is Script {
    function run() external returns (PropellerFeeController fees) {
        address governance = vm.envAddress("FEE_GOVERNANCE");
        address recipient = vm.envAddress("FEE_RECIPIENT");
        address harvester = vm.envAddress("HARVESTER");
        address[] memory vaults = vm.envAddress("FEE_VAULTS", ",");
        require(harvester != address(0) && vaults.length > 0, "fee wiring");

        vm.startBroadcast();
        fees = new PropellerFeeController(governance, recipient);
        vm.stopBroadcast();

        console.log("PropellerFeeController:", address(fees));
        console.log("Governance:", governance);
        console.log("Treasury recipient:", recipient);
        console.log("Initial rate per registered vault: 500 bps");
        console.log("First wire SubLoop.harvester and the complete Harvester vault registry.");
        console.log("Execute these governance calls atomically before accepting deposits:");
        _print(harvester, abi.encodeCall(Harvester.setFeeController, (address(fees))));
        for (uint256 i; i < vaults.length; ++i) {
            _print(vaults[i], abi.encodeCall(CollateralVault.setFeeController, (address(fees))));
            _print(address(fees), abi.encodeCall(PropellerFeeController.registerVault, (vaults[i], harvester)));
        }
    }

    function _print(address target, bytes memory data) internal pure {
        console.log("target:", target);
        console.logBytes(data);
    }
}
