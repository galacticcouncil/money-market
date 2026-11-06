// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {IUiGhoDataProvider} from "./interfaces/IUiGhoDataProvider.sol";

interface IERC20BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IGhoPool {
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);
}

interface IGhoToken {
    function getFacilitatorBucket(address facilitator) external view returns (uint256, uint256);
}

interface IGhoVariableDebtToken {
    function getDiscountRateStrategy() external view returns (address);

    function getDiscountToken() external view returns (address);

    function getDiscountPercent(address user) external view returns (uint256);

    function getPreviousIndex(address user) external view returns (uint256);

    function scaledBalanceOf(address user) external view returns (uint256);
}

interface ILegacyGhoDiscountRateStrategy {
    function GHO_DISCOUNTED_PER_DISCOUNT_TOKEN() external view returns (uint256);

    function DISCOUNT_RATE() external view returns (uint256);

    function MIN_DISCOUNT_TOKEN_BALANCE() external view returns (uint256);

    function MIN_DEBT_TOKEN_BALANCE() external view returns (uint256);
}

/**
 * @title UiGhoDataProviderCompat
 * @notice Drop-in UiGhoDataProvider for discount strategies that implement the
 *         required calculateDiscountRate surface but not Aave's four legacy
 *         public metadata getters.
 * @dev Required market reads retain the original fail-closed behavior. Only
 *      optional, strategy-specific metadata falls back to zero when absent or
 *      malformed. Zero matches the previous Hydration strategy values and
 *      does not affect the debt token's discount accounting.
 */
contract UiGhoDataProviderCompat is IUiGhoDataProvider {
    IGhoPool public immutable POOL;
    IGhoToken public immutable GHO;

    constructor(IGhoPool pool, IGhoToken ghoToken) {
        POOL = pool;
        GHO = ghoToken;
    }

    function getGhoReserveData() public view override returns (GhoReserveData memory) {
        DataTypes.ReserveData memory baseData = POOL.getReserveData(address(GHO));
        IGhoVariableDebtToken debtToken = IGhoVariableDebtToken(baseData.variableDebtTokenAddress);
        address strategy = debtToken.getDiscountRateStrategy();

        (uint256 bucketCapacity, uint256 bucketLevel) = GHO.getFacilitatorBucket(baseData.aTokenAddress);

        return GhoReserveData({
            ghoBaseVariableBorrowRate: baseData.currentVariableBorrowRate,
            ghoDiscountedPerToken: _readOptionalUint256(
                strategy, ILegacyGhoDiscountRateStrategy.GHO_DISCOUNTED_PER_DISCOUNT_TOKEN.selector
            ),
            ghoDiscountRate: _readOptionalUint256(strategy, ILegacyGhoDiscountRateStrategy.DISCOUNT_RATE.selector),
            ghoMinDebtTokenBalanceForDiscount: _readOptionalUint256(
                strategy, ILegacyGhoDiscountRateStrategy.MIN_DEBT_TOKEN_BALANCE.selector
            ),
            ghoMinDiscountTokenBalanceForDiscount: _readOptionalUint256(
                strategy, ILegacyGhoDiscountRateStrategy.MIN_DISCOUNT_TOKEN_BALANCE.selector
            ),
            ghoReserveLastUpdateTimestamp: baseData.lastUpdateTimestamp,
            ghoCurrentBorrowIndex: baseData.variableBorrowIndex,
            aaveFacilitatorBucketLevel: bucketLevel,
            aaveFacilitatorBucketMaxCapacity: bucketCapacity
        });
    }

    function getGhoUserData(address user) public view override returns (GhoUserData memory) {
        DataTypes.ReserveData memory baseData = POOL.getReserveData(address(GHO));
        IGhoVariableDebtToken debtToken = IGhoVariableDebtToken(baseData.variableDebtTokenAddress);
        address discountToken = debtToken.getDiscountToken();

        return GhoUserData({
            userGhoDiscountPercent: debtToken.getDiscountPercent(user),
            userDiscountTokenBalance: IERC20BalanceOf(discountToken).balanceOf(user),
            userPreviousGhoBorrowIndex: debtToken.getPreviousIndex(user),
            userGhoScaledBorrowBalance: debtToken.scaledBalanceOf(user)
        });
    }

    function _readOptionalUint256(address target, bytes4 selector) internal view returns (uint256) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || result.length < 32) return 0;
        return abi.decode(result, (uint256));
    }
}
