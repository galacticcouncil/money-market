// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PropellerOperatingBuffer} from "../src/PropellerOperatingBuffer.sol";

/// @notice Deploy one isolated buffer per vault. Print governance configuration
/// and funding calls; do not broadcast them or choose production parameters.
contract DeployOperatingBuffer is Script {
    function run() external returns (PropellerOperatingBuffer buffer) {
        CollateralVault vault = CollateralVault(vm.envAddress("OPERATING_VAULT"));
        uint256 seconds_ = vm.envUint("OPERATING_COVERAGE_SECONDS");
        uint256 cost = vm.envUint("OPERATING_EXIT_COST_BPS");
        uint256 rate = vm.envUint("OPERATING_STRESS_RATE_RAY");
        uint256 bootstrap = vm.envUint("OPERATING_BOOTSTRAP_HOLLAR_WEI");
        require(seconds_ > 0 && seconds_ <= type(uint32).max, "coverage");
        require(cost > 0 && cost < 10_000, "cost");
        require(rate > 0 && rate <= type(uint128).max && bootstrap > 0, "funding policy");
        require(vault.totalSupply() == 0 && address(vault.operatingBuffer()) == address(0), "fresh vault only");
        vm.startBroadcast();
        buffer = new PropellerOperatingBuffer(address(vault));
        vm.stopBroadcast();
        console.log("Operating buffer:", address(buffer));
        console.log("Dust-whitelist this custody account BEFORE funding. Execute as vault governance:");
        _print(address(vault), abi.encodeCall(vault.setOperatingBuffer, (address(buffer))));
        _print(address(buffer), abi.encodeCall(buffer.configure, (uint32(seconds_), uint16(cost), uint128(rate))));
        _print(address(vault.hollar()), abi.encodeCall(IERC20.approve, (address(buffer), 0)));
        _print(address(vault.hollar()), abi.encodeCall(IERC20.approve, (address(buffer), bootstrap)));
        _print(address(buffer), abi.encodeCall(buffer.fundBootstrap, (bootstrap)));
        _print(address(vault.hollar()), abi.encodeCall(IERC20.approve, (address(buffer), 0)));
        console.log("Wire the buffer BEFORE fee registration; verify readiness before opening deposits.");
    }

    function _print(address target, bytes memory data) internal pure {
        console.log("target:", target);
        console.logBytes(data);
    }
}
