// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IMainDebt {
    function vault() external view returns (address);
    function ownedCash() external view returns (uint256);
    function activeSourceRemaining() external view returns (uint256);
    function activeUnderfunded() external view returns (bool);
    function beforeDeposit() external returns (uint256 debtBefore);
    function borrowed(uint256 debtBefore) external;
    function startExit(uint256 id, address owner, uint256 shares, uint256 supply, uint256 sourceClaim)
        external returns (uint256 debt);
    function expectDelever(uint256 amount) external;
    function creditSource(uint256 amount) external returns (uint256 activeExecutionCost);
    function repay(uint256 key, uint256 principalLimit, uint256 recovery)
        external returns (uint256 cashSpent, uint256 principalPaid, uint256 debtReduced);
    function harvest(uint256 collateralAmount) external returns (uint256 collateralRemaining);
}
