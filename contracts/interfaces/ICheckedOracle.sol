// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

interface ICheckedOracle {
    error InvalidFeed();
    error InvalidBps();
    error InvalidPrice();
    error NotPriceSetter();
    error CheckPriceUnavailable();
    error PriceDeviationTooLarge(
        int256 price,
        int256 checkPrice,
        uint256 deviationBps,
        uint256 maxDiffBps
    );

    event CheckOracleUpdated(address indexed checkOracle, uint8 checkDecimals);
    event MaxDiffBpsUpdated(uint256 maxDiffBps);
    event PusherUpdated(
        address indexed previousPusher,
        address indexed newPusher
    );
    /// @notice Emitted when the owner pushes a price without the deviation
    /// check. `checkPrice` is 0 when the check oracle was unavailable.
    event PriceSetUnchecked(
        uint80 indexed roundId,
        int256 price,
        int256 checkPrice
    );

    function checkOracle() external view returns (address);

    function checkDecimals() external view returns (uint8);

    function maxDiffBps() external view returns (uint256);

    function pusher() external view returns (address);

    function checkPrice() external view returns (bool ok, int256 price);

    function previewSetPrice(
        int256 price
    ) external view returns (bool ok, uint256 deviationBps);

    function setPriceUnchecked(int256 price) external;

    function setCheckOracle(address checkOracle_) external;

    function setMaxDiffBps(uint256 maxDiffBps_) external;

    function setPusher(address pusher_) external;
}
