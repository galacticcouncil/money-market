// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice The call Hydration's lazy executor makes on an ICE forward, as the intent owner. Named here because
/// the position also has ERC-6551's `execute`, so `LooperPosition.execute.selector` alone is ambiguous.
interface IIntentForward {
    function execute(
        address owner_,
        uint256 intentId,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        bytes calldata data
    ) external returns (bytes4);
}
