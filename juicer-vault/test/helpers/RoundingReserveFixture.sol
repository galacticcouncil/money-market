// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CollateralVault} from "../../src/CollateralVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {JuicerMainDebt} from "../../src/JuicerMainDebt.sol";

// --skip test builds compile this file, so it stays off the .t.sol deploy helper and its proxy import
interface IDeployCode {
    function deployCode(string calldata artifactPath, bytes calldata constructorArgs) external returns (address);
}

library RoundingReserveFixture {
    IDeployCode private constant VM = IDeployCode(address(uint160(uint256(keccak256("hevm cheat code")))));

    function fund(CollateralVault vault) internal {
        if (address(vault.mainDebt()) == address(0)) {
            JuicerMainDebt buffer =
                JuicerMainDebt(VM.deployCode("JuicerMainDebt.sol:JuicerMainDebt", abi.encode(address(vault))));
            vault.setMainDebt(address(buffer));
        }
        MockERC20 token = MockERC20(address(vault.collateral()));
        token.mint(address(this), 1e9);
        token.approve(address(vault), 1e9);
        vault.fundRoundingReserve(1e9);
    }
}
