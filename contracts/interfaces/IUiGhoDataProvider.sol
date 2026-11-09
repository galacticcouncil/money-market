// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title IUiGhoDataProvider
 * @notice ABI consumed by the Aave GHO/HOLLAR UI integration.
 */
interface IUiGhoDataProvider {
    struct GhoReserveData {
        uint256 ghoBaseVariableBorrowRate;
        uint256 ghoDiscountedPerToken;
        uint256 ghoDiscountRate;
        uint256 ghoMinDebtTokenBalanceForDiscount;
        uint256 ghoMinDiscountTokenBalanceForDiscount;
        uint40 ghoReserveLastUpdateTimestamp;
        uint128 ghoCurrentBorrowIndex;
        uint256 aaveFacilitatorBucketLevel;
        uint256 aaveFacilitatorBucketMaxCapacity;
    }

    struct GhoUserData {
        uint256 userGhoDiscountPercent;
        uint256 userDiscountTokenBalance;
        uint256 userPreviousGhoBorrowIndex;
        uint256 userGhoScaledBorrowBalance;
    }

    function getGhoReserveData() external view returns (GhoReserveData memory);

    function getGhoUserData(address user) external view returns (GhoUserData memory);
}
