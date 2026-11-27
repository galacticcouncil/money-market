// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
// keeps the proxy artifact in sparse test builds
// forge-lint: disable-next-line(unused-import)
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev deploys system contracts from their artifacts so test contracts don't embed (and re-optimize)
/// their creation code; caller, nonce and pranks behave as with `new`. the .t.sol suffix keeps it and
/// its imports out of production builds (--skip test), whose ast ids they would shift
library Artifacts {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function compoundLogic() internal returns (address) {
        return VM.deployCode("CompoundLogic.sol:CompoundLogic");
    }

    function collateralVault() internal returns (address) {
        return VM.deployCode("CollateralVault.sol:CollateralVault", abi.encode(compoundLogic()));
    }

    function subLoopLogic() internal returns (address) {
        return VM.deployCode("SubLoopLogic.sol:SubLoopLogic");
    }

    function subLoop(address logic) internal returns (address) {
        return VM.deployCode("SubLoop.sol:SubLoop", abi.encode(logic));
    }

    function subLoop() internal returns (address) {
        return subLoop(subLoopLogic());
    }

    function proxy(address implementation, bytes memory data) internal returns (address) {
        return VM.deployCode("ERC1967Proxy.sol:ERC1967Proxy", abi.encode(implementation, data));
    }

    function syntheticToken(string memory name, string memory symbol, address admin) internal returns (address) {
        return VM.deployCode("SyntheticToken.sol:SyntheticToken", abi.encode(name, symbol, admin));
    }

    function harvester(address loop, address prime, address admin) internal returns (address) {
        return VM.deployCode("Harvester.sol:Harvester", abi.encode(loop, prime, admin));
    }

    function feeController(address governance, address recipient) internal returns (address) {
        return VM.deployCode("JuicerFeeController.sol:JuicerFeeController", abi.encode(governance, recipient));
    }

    function mainDebt(address vault) internal returns (address) {
        return VM.deployCode("JuicerMainDebt.sol:JuicerMainDebt", abi.encode(vault));
    }

    function yieldAccounting(address vault) internal returns (address) {
        return VM.deployCode("JuicerYieldAccounting.sol:JuicerYieldAccounting", abi.encode(vault));
    }

    function executionController(address admin, uint64 age, uint64 blocks) internal returns (address) {
        return VM.deployCode("ExecutionController.sol:ExecutionController", abi.encode(admin, age, blocks));
    }

    function discount(address debtToken, address synthetic, address aSynthetic, address governance, address committee)
        internal
        returns (address)
    {
        return VM.deployCode(
            "JuicerDiscount.sol:JuicerDiscount", abi.encode(debtToken, synthetic, aSynthetic, governance, committee)
        );
    }
}
