// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IMainDebt {
    function quoteCollateral(uint256 hollar) external view returns (uint256);
    function quoteHollar(uint256 collateral) external view returns (uint256);
    function yieldAccounting() external view returns (address);
    function activePosition() external view returns (uint256 debt, uint256 principal, uint256 cash);
    function activeFunds() external view returns (uint256);
    function sourceFeeReserve() external view returns (uint256);
    function pendingSourceAccounting() external view returns (bool);
    function serviceBlocked() external view returns (bool);
    function vault() external view returns (address);
    function ownedCash() external view returns (uint256);
    function activeSourceRemaining() external view returns (uint256);
    function activeUnderfunded() external view returns (bool);
    function protocolReserve() external view returns (uint256);
    function beforeDeposit() external returns (uint256 debtBefore);
    function borrowed(uint256 debtBefore) external;
    function startExit(uint256 id, address owner, uint256 shares, uint256 supply,
        uint256 sourceClaim, uint256 sourcePrincipal, uint256 sourceFee)
        external returns (uint256 debt);
    function expectDelever(uint256 amount, uint256 sourcePrincipal) external;
    function creditSource(uint256 amount) external returns (uint256 activeExecutionCost);
    function repay(uint256 key, uint256 principalLimit, uint256 recovery)
        external returns (uint256 cashSpent, uint256 principalPaid, uint256 debtReduced);
    function harvest(uint256 collateralAmount) external returns (uint256 collateralRemaining);
}
