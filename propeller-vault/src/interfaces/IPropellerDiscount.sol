// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IHollarDiscountDebtToken {
    function POOL() external view returns (address);
    function getDiscountToken() external view returns (address);
    function getDiscountRateStrategy() external view returns (address);
    function getDiscountPercent(address borrower) external view returns (uint256);
    function rebalanceUserDiscountPercent(address borrower) external;
    function updateDiscountToken(address token) external;
    function updateDiscountRateStrategy(address strategy) external;
}

interface IPropellerDiscount {
    function debtToken() external view returns (IHollarDiscountDebtToken);
    function synthetic() external view returns (address);
    function balanceOf(address borrower) external view returns (uint256);
    function calculateDiscountRate(uint256 debtBalance, uint256 eligibleBalance) external view returns (uint256);
}

interface IDiscountVault {
    function pool() external view returns (address);
    function synthetic() external view returns (address);
    function hollarDebtToken() external view returns (address);
    function discountController() external view returns (address);
}

interface ISyntheticAToken {
    function POOL() external view returns (address);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function balanceOf(address borrower) external view returns (uint256);
}
