// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The slice of the Aave v3.0/3.1 pool Looper uses, with v3.0 struct layouts.
interface IAavePool {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    struct EModeCategory {
        uint16 ltv;
        uint16 liquidationThreshold;
        uint16 liquidationBonus;
        address priceSource;
        string label;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function setUserEMode(uint8 categoryId) external;

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function getConfiguration(address asset) external view returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
    function getReservesList() external view returns (address[] memory);
    function getReserveAddressById(uint16 id) external view returns (address);
    function getUserConfiguration(address user) external view returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getEModeCategoryData(uint8 id) external view returns (EModeCategory memory);
    function getUserEMode(address user) external view returns (uint256);
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IPoolAddressesProvider {
    function getPriceOracle() external view returns (address);
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IAToken is IERC20 {
    function scaledBalanceOf(address user) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
