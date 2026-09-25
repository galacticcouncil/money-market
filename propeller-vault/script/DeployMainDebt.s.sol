// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";

/// @notice Deploy one settlement ledger per fresh vault; no sponsored capital.
contract DeployMainDebt is Script {
    function run() external returns (PropellerMainDebt buffer) {
        CollateralVault vault = CollateralVault(vm.envAddress("MAIN_DEBT_VAULT"));
        require(vault.totalSupply() == 0 && address(vault.mainDebt()) == address(0), "fresh vault only");
        vm.startBroadcast();
        buffer = new PropellerMainDebt(address(vault));
        vm.stopBroadcast();
        console.log("Main debt ledger:", address(buffer));
        console.log("Dust-whitelist this custody account before use. Execute as vault governance:");
        _print(address(vault), abi.encodeCall(vault.setMainDebt, (address(buffer))));
        console.log("Wire BEFORE fee registration; no operating bootstrap required.");
    }

    function _print(address target, bytes memory data) internal pure {
        console.log("target:", target);
        console.logBytes(data);
    }
}
