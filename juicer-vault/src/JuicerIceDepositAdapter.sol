// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice ICE `on_resolved` forward target for Juicer deposits.
/// @dev When a swap intent with `OnResolved::Forward { contract: this, data }` is
///      resolved, pallet-lazy-executor transfers the intent's net `amountOut` from
///      the owner to this contract, then calls `execute` with `msg.sender` set to the
///      owner's EVM address. The whole forward rolls back unless `execute` returns
///      its own selector, leaving the output in the owner's wallet.
///      `data` = abi.encode(address vault, uint256 minShares).
contract JuicerIceDepositAdapter {
    using SafeERC20 for IERC20;

    error AssetMismatch(address vaultAsset, address assetOut);
    error Slippage(uint256 shares, uint256 minShares);

    event IceDeposit(
        address indexed user,
        uint256 indexed intentId,
        address indexed vault,
        address assetIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 shares
    );

    function execute(
        address user,
        uint256 intentId,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        bytes calldata data
    ) external returns (bytes4) {
        (address vault, uint256 minShares) = abi.decode(data, (address, uint256));
        address vaultAsset = IERC4626(vault).asset();
        if (vaultAsset != assetOut) revert AssetMismatch(vaultAsset, assetOut);
        IERC20(assetOut).forceApprove(vault, amountOut);
        uint256 shares = IERC4626(vault).deposit(amountOut, user);
        if (shares < minShares) revert Slippage(shares, minShares);
        emit IceDeposit(user, intentId, vault, assetIn, amountIn, amountOut, shares);
        return this.execute.selector;
    }
}
