// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice a registered vault that only reports its collateral, for the band setter
contract CollateralStub {
    address public immutable collateral;

    constructor(address collateral_) {
        collateral = collateral_;
    }
}
