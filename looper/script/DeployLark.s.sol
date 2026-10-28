// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ERC6551Registry} from "erc6551/ERC6551Registry.sol";
import {IERC6551Registry} from "erc6551/interfaces/IERC6551Registry.sol";

import {LooperFactory} from "../src/LooperFactory.sol";
import {LooperPosition} from "../src/LooperPosition.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

/// @notice Deploys the logic library, the position implementation and the factory on the lark testnet.
/// The broadcaster must be a whitelisted contract deployer; nothing is administered afterwards. Forge
/// deploys and links `LooperLogic` first.
///
///   forge script script/DeployLark.s.sol --rpc-url https://3.lark.hydration.cloud \
///     --evm-version london --legacy --slow --gas-estimate-multiplier 300 --private-key $PK --broadcast
///
/// Dry run against live state, no key needed: drop `--private-key`/`--broadcast`, add
/// `--sender <deployer>`. `--evm-version london` is only for forge's fork simulation: Frontier block
/// headers carry no prevrandao, which the post-merge spec requires. `--gas-estimate-multiplier 300`
/// because Hydration charges `GasLimitStorageGrowthRatio = 366` gas per byte of new storage: a code
/// deposit of 24 KB needs ~9 M gas, far above forge's local estimate (`eth_estimateGas` on the chain
/// knows, forge's simulation does not). `--slow` waits for each receipt so a failed create stops the
/// run instead of sending the dependent calls to an empty address.
///
/// Hydration has no deterministic deployer, so the ERC-6551 registry cannot sit at its canonical address:
/// the first run deploys one, later runs reuse it with `REGISTRY=<address>`.
contract DeployLark is Script {
    address constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address constant PRIME = 0x000000000000000000000000000000010000002B;

    function run() external {
        address registry = vm.envOr("REGISTRY", address(0));
        vm.startBroadcast();
        if (registry == address(0)) registry = address(new ERC6551Registry());
        LooperPosition impl = new LooperPosition(IAavePool(POOL));
        LooperFactory factory = new LooperFactory(IAavePool(POOL), address(impl), IERC6551Registry(registry));
        vm.stopBroadcast();

        console2.log("registry       ", registry);
        console2.log("factory        ", address(factory));
        console2.log("implementation ", address(impl));
        console2.log("first position ", factory.predict(1));
        console2.log("PRIME/HOLLAR L_max at minHf 1.15", factory.maxLeverage(PRIME, 0, 1.15e18));
    }
}
