// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice ICE `on_resolved` forward target for Juicer deposits.
/// @dev When a swap intent with `OnResolved::Forward { contract: this, data }` is
///      resolved, pallet-lazy-executor transfers the intent's net `amountOut` from
///      the owner to this contract, then calls `execute` with `msg.sender` set to the
///      owner's EVM address. The whole forward rolls back unless `execute` returns
///      its own selector, leaving the output in the owner's wallet.
///      `data` = abi.encode(address vault, uint256 minShares).
///      direct calls remain possible; unsolicited balances have no owner accounting.
contract JuicerIceDepositAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error CallerMismatch(address caller, address user);
    error ZeroAmount();
    error AssetMismatch(address vaultAsset, address assetOut);
    error InsufficientBalance(uint256 balance, uint256 amountOut);
    error BalanceMismatch(uint256 expected, uint256 actual);
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
    ) external nonReentrant returns (bytes4) {
        if (msg.sender != user) revert CallerMismatch(msg.sender, user);
        if (amountOut == 0) revert ZeroAmount();
        (address vault, uint256 minShares) = abi.decode(data, (address, uint256));
        uint256 shares = _deposit(vault, user, assetOut, amountOut, minShares);
        emit IceDeposit(user, intentId, vault, assetIn, amountIn, amountOut, shares);
        return this.execute.selector;
    }

    function _deposit(address vault, address user, address assetOut, uint256 amountOut, uint256 minShares)
        private
        returns (uint256 shares)
    {
        address vaultAsset = IERC4626(vault).asset();
        if (vaultAsset != assetOut) revert AssetMismatch(vaultAsset, assetOut);
        IERC20 token = IERC20(assetOut);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amountOut) revert InsufficientBalance(balance, amountOut);
        token.forceApprove(vault, amountOut);
        shares = IERC4626(vault).deposit(amountOut, user);
        token.forceApprove(vault, 0);
        uint256 remaining = token.balanceOf(address(this));
        if (remaining != balance - amountOut) revert BalanceMismatch(balance - amountOut, remaining);
        if (shares < minShares) revert Slippage(shares, minShares);
    }
}
