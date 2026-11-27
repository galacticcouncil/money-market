// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Hydration's ERC20 precompile for a bound asset: etched at `(1 << 32) | id`, it reports the bound
/// contract's own `totalSupply`. `token` is an immutable, so it survives `vm.etch`.
contract MockAssetPrecompile {
    IERC20 internal immutable token;

    /// @dev Contracts in `EVMAccounts.ApprovedContract`. Written after the etch, so it lives in the etched storage.
    mapping(address => bool) public approvedContract;

    constructor(IERC20 token_) {
        token = token_;
    }

    function totalSupply() external view returns (uint256) {
        return token.totalSupply();
    }

    function setApprovedContract(address c, bool on) external {
        approvedContract[c] = on;
    }

    /// @dev An approved contract reads `Balance::MAX` (multicurrency.rs `allowance`); nothing else has an
    /// allowance here, since the position cannot approve.
    function allowance(address, address spender) external view returns (uint256) {
        return approvedContract[spender] ? type(uint128).max : 0;
    }
}
