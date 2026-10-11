// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IJuicerFeeController {
    function collectSourceFee(uint256 amount) external;
    function protocolFeeBps(address vault) external view returns (uint16);
    function configurationVersion() external view returns (uint256);
    function validateVault(address vault, address harvester) external view;
    function quoteCollateral(address vault, address tokenIn, uint256 amountIn) external view returns (uint256);
    function collectFee(uint256 grossCollateral, address compoundCaller) external returns (uint256 fee);
    function collectHarvestFee(uint256 grossCollateral, uint256 fee, address compoundCaller) external;
}
