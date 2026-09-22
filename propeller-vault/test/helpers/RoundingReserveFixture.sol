// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CollateralVault} from "../../src/CollateralVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PropellerOperatingBuffer} from "../../src/PropellerOperatingBuffer.sol";

library RoundingReserveFixture {
    function fund(CollateralVault vault) internal {
        if (address(vault.operatingBuffer()) == address(0)) {
            PropellerOperatingBuffer buffer = new PropellerOperatingBuffer(address(vault));
            vault.setOperatingBuffer(address(buffer));
            // Fixture values only. Production has no implicit funding policy.
            buffer.configure(7 days, 10, 5e25);
            MockERC20 hollar = MockERC20(address(vault.hollar()));
            hollar.mint(address(this), 1e30);
            hollar.approve(address(buffer), 1e30);
            buffer.fundBootstrap(1e30);
        }
        MockERC20 token = MockERC20(address(vault.collateral()));
        token.mint(address(this), 1e9);
        token.approve(address(vault), 1e9);
        vault.fundRoundingReserve(1e9);
    }
}
