// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ILeveragedLoop} from "./IYieldSource.sol";

/// @title ISubLoop
/// @notice The shared PRIME/HOLLAR leveraged loop (Aave isolation mode, HF target
///         ~1.05) — **one implementation** of `IYieldSource`, not the vault's only
///         option. Funded by every CollateralVault's borrowed HOLLAR; tracks each
///         vault's equity as internal shares.
///
/// @dev    Every method lives on `IYieldSource` / `ILeveragedLoop`; this interface
///         adds nothing. It exists so call sites can name the concrete strategy
///         where that reads better, while `CollateralVault` binds only to the
///         generic seam. To plug in a different yield source (an ERC-4626/7540
///         wrapper such as BIL, which is not an Aave reserve and has no health
///         factor), implement `IYieldSource` directly — the vault needs no change.
///
///         Deploy and unwind are gradual and async, driven by keeper pokes: each
///         poke does an Aave debt leg (borrow on deploy, repay on unwind) plus a
///         synchronous HF-capped router sell (HOLLAR↔aPRIME). No flash loans. A
///         vault requests an unwind, the deleveraging spiral frees equity HOLLAR
///         over blocks, and the vault pulls it as it accrues.
///
///         With intents configured, entries go out as ICE intents that settle a block or two
///         later: the lazy executor calls `execute`, or anyone calls `reconcile`.
interface ISubLoop is ILeveragedLoop {
    /// @notice `pokeBorrow` with the keeper's router dry-run rate: output units per 1e18 input
    ///         units. Less the solver's 1 bp haircut and the drift allowance it may only raise
    ///         the oracle floor. Returns the HOLLAR sent in an intent (router mode: borrowed).
    function pokeBorrowQuoted(uint256 keeperQuote) external returns (uint256);

    /// @notice Settle the in-flight intent from balance deltas.
    /// @return outcome 0 nothing in flight, 1 waiting, 2 filled, 3 input returned
    function reconcile() external returns (uint8 outcome);

    /// @notice ICE lazy-executor receiver. Accepts only the loop's own intents, called as the loop.
    function execute(
        address owner,
        uint256 intentId,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        bytes calldata data
    ) external returns (bytes4);
}
