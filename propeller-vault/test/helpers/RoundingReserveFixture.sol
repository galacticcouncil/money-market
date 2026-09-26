// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CollateralVault} from "../../src/CollateralVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

library RoundingReserveFixture {
    function fund(CollateralVault vault) internal {
        MockERC20 token = MockERC20(address(vault.collateral()));
        token.mint(address(this), 1e9);
        token.approve(address(vault), 1e9);
        vault.fundRoundingReserve(1e9);
    }
}
