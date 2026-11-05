// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

interface IDiscountedCheckedOracle {
    error InvalidCoefficient();

    event CoefficientUpdated(uint256 previousCoefficient, uint256 newCoefficient);

    /// @notice Emitted on every accepted checked push: what the pusher sent,
    /// the coefficient applied, and what was stored.
    event PriceDiscounted(
        uint80 indexed roundId,
        int256 raw,
        uint256 coefficient,
        int256 adjusted
    );

    /// @notice The discount applied to every pushed price, 8 decimals.
    /// `1e8` is neutral (no discount).
    function coefficient() external view returns (uint256);

    /// @notice Bounds `coefficient` is held within, 8 decimals.
    function MIN_COEFFICIENT() external view returns (uint256);

    function MAX_COEFFICIENT() external view returns (uint256);

    /// @notice `raw` after the discount, as `setPrice` would store it.
    function discount(int256 raw) external view returns (int256 adjusted);

    function setCoefficient(uint256 coefficient_) external;
}
