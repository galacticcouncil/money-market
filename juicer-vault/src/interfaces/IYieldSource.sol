// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IYieldSource
/// @notice the pluggable boundary between a CollateralVault and a yield strategy: HOLLAR in, NAV-priced shares out.
/// @dev async by contract: deposit only credits shares and requestUnwind only records a target the vault later pulls.
interface IYieldSource {
    /// @notice Source-wide freeze of user flows and new risk, not safety repayment.
    function emergencyPaused() external view returns (bool);
    function accountingLocked() external view returns (bool);
    function principalOf(address vault) external view returns (uint256);
    function releasePrincipal(address vault, uint256 amount) external;

    // vault → source: deposit
    function admissionCapacity() external view returns (uint256);
    function previewHarvest(uint256 shares) external view returns (uint256);
    /// @notice credit the calling vault shares at current NAV; the HOLLAR may deploy later.
    function deposit(uint256 hollarAmount) external returns (uint256 shares);

    // vault → source: withdraw (async)

    /// @notice burn `shares` of the calling vault and grow the release target; HOLLAR frees over blocks.
    function requestUnwind(uint256 shares) external returns (uint256 unwindId);
    function requestUnwindProtected(uint256 shares, uint256 basis) external returns (uint256 unwindId);

    /// @notice Pull whatever HOLLAR has been freed for the calling vault so far
    ///         (≤ its outstanding request). Returns the amount actually sent.
    function pullFreed() external returns (uint256 hollarSent);

    /// @notice Freed-but-unpulled HOLLAR owed to `vault`.
    function freedOf(address vault) external view returns (uint256);

    /// @notice HOLLAR still owed to `vault` from requested unwinds (requested minus pulled, incl. freedOf).
    function pendingUnwindOf(address vault) external view returns (uint256);

    /// @notice Cumulative realized swap costs charged only to un-compounded
    /// yield earmarked for this vault's unwinds, never to source cost basis.
    function unwindExecutionCost(address vault) external view returns (uint256);

    // pricing

    /// @notice `vault`'s LIVE-share equity in USD8 (8 decimals), excluding
    /// outstanding withdrawal liabilities. Not HOLLAR's 18-decimal units.
    function equityOf(address vault) external view returns (uint256);

    /// @notice `vault`'s share balance in this source.
    function sharesOf(address vault) external view returns (uint256);

    function totalShares() external view returns (uint256);

    /// @notice Gross equity in USD8, including uncredited withdrawal backing
    /// and unreserved cash, excluding freed cash already reserved for claims.
    function totalEquity() external view returns (uint256);

    // monitoring

    /// @notice equity shortfall below cost basis in bps (0 at or above basis); monitoring only.
    function negativeCarryBps() external view returns (uint256);

    // yield realisation

    /// @notice realise carry to the harvester; only the harvester calls this.
    /// @return surplus amount skimmed, in the source's yield asset
    function harvest() external returns (uint256 surplus);
    function harvestCapacity() external view returns (uint256 sourceShares);
    function harvestFor(address vault, uint256 shares) external returns (uint256 amount, uint256 burned);
}

/// @title ILeveragedLoop
/// @notice a levered yield source with a health factor; kept out of IYieldSource so unlevered sources needn't fake one.
interface ILeveragedLoop is IYieldSource {
    /// @notice deploy step: borrow and lever one bounded tranche in; permissionless.
    function pokeBorrow() external returns (uint256 borrowed);

    /// @notice Unwind step: repay debt with freed proceeds (raising HF) and
    ///         credit freed equity to unwinding vaults pro-rata. Permissionless.
    function pokeRepay() external returns (uint256 work);

    /// @notice Safety de-lever toward the target HF — the same spiral as an
    ///         unwind, but the freed HOLLAR repays debt with no payout.
    function deLever() external;

    function healthFactor() external view returns (uint256);
}
