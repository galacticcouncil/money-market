// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MockERC20} from "./MockERC20.sol";

/// @notice Stand-in for Pool-Proxy-BIL or the GIGAHDX pool: an Aave pool in `EVMAccounts.ApprovedContract` with a
/// HOLLAR reserve. HOLLAR honours the unlimited HDX allowance such a contract reads, so `repay` pulls with no approve.
contract MockApprovedPool {
    function repay(address asset, uint256 amount, uint256, address) external returns (uint256) {
        MockERC20(asset).move(msg.sender, address(this), amount);
        return amount;
    }
}
