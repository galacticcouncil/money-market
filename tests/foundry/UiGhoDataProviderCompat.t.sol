// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

import {UiGhoDataProviderCompat, IGhoPool, IGhoToken} from "../../contracts/UiGhoDataProviderCompat.sol";
import {IUiGhoDataProvider} from "../../contracts/interfaces/IUiGhoDataProvider.sol";

contract MockGhoPool {
    DataTypes.ReserveData internal _reserve;

    function setReserve(address aToken, address variableDebtToken) external {
        _reserve.aTokenAddress = aToken;
        _reserve.variableDebtTokenAddress = variableDebtToken;
        _reserve.currentVariableBorrowRate = 7_000;
        _reserve.variableBorrowIndex = 11_000;
        _reserve.lastUpdateTimestamp = 123;
    }

    function getReserveData(address) external view returns (DataTypes.ReserveData memory) {
        return _reserve;
    }
}

contract MockGhoToken {
    uint256 internal _capacity;
    uint256 internal _level;

    function setBucket(uint256 capacity, uint256 level) external {
        _capacity = capacity;
        _level = level;
    }

    function getFacilitatorBucket(address) external view returns (uint256, uint256) {
        return (_capacity, _level);
    }
}

contract MockGhoVariableDebtToken {
    address public strategy;
    address public discountToken;
    mapping(address => uint256) public discountPercent;
    mapping(address => uint256) public previousIndex;
    mapping(address => uint256) public scaledBalance;

    function configure(address strategy_, address discountToken_) external {
        strategy = strategy_;
        discountToken = discountToken_;
    }

    function setUser(address user, uint256 percent, uint256 index, uint256 balance) external {
        discountPercent[user] = percent;
        previousIndex[user] = index;
        scaledBalance[user] = balance;
    }

    function getDiscountRateStrategy() external view returns (address) {
        return strategy;
    }

    function getDiscountToken() external view returns (address) {
        return discountToken;
    }

    function getDiscountPercent(address user) external view returns (uint256) {
        return discountPercent[user];
    }

    function getPreviousIndex(address user) external view returns (uint256) {
        return previousIndex[user];
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return scaledBalance[user];
    }
}

contract LegacyDiscountStrategy {
    uint256 public constant GHO_DISCOUNTED_PER_DISCOUNT_TOKEN = 100e18;
    uint256 public constant DISCOUNT_RATE = 2_000;
    uint256 public constant MIN_DISCOUNT_TOKEN_BALANCE = 3e18;
    uint256 public constant MIN_DEBT_TOKEN_BALANCE = 4e18;
}

contract JuicerDiscountShape {
    mapping(address => uint256) public balanceOf;

    function setBalance(address user, uint256 balance) external {
        balanceOf[user] = balance;
    }

    function calculateDiscountRate(uint256 debtBalance, uint256 eligibleBalance) external pure returns (uint256) {
        if (debtBalance == 0) return 0;
        return eligibleBalance >= debtBalance ? 4_000 : (eligibleBalance * 4_000) / debtBalance;
    }
}

contract MalformedDiscountStrategy {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract RevertingDebtToken {
    fallback() external {
        revert("required read failed");
    }
}

contract UiGhoDataProviderCompatTest is Test {
    MockGhoPool internal pool;
    MockGhoToken internal gho;
    MockGhoVariableDebtToken internal debt;
    UiGhoDataProviderCompat internal provider;

    address internal constant A_TOKEN = address(0xA70C3);
    address internal constant USER = address(0xB0B);

    function setUp() public {
        pool = new MockGhoPool();
        gho = new MockGhoToken();
        debt = new MockGhoVariableDebtToken();
        pool.setReserve(A_TOKEN, address(debt));
        gho.setBucket(900e18, 250e18);
        provider = new UiGhoDataProviderCompat(IGhoPool(address(pool)), IGhoToken(address(gho)));
    }

    function testPreservesTheExistingUiSelectors() public pure {
        assertEq(IUiGhoDataProvider.getGhoReserveData.selector, bytes4(0xf5a5b364));
        assertEq(IUiGhoDataProvider.getGhoUserData.selector, bytes4(0x82d761a9));
    }

    function testReadsLegacyStrategyMetadata() public {
        LegacyDiscountStrategy strategy = new LegacyDiscountStrategy();
        debt.configure(address(strategy), address(strategy));

        IUiGhoDataProvider.GhoReserveData memory data = provider.getGhoReserveData();

        assertEq(data.ghoBaseVariableBorrowRate, 7_000);
        assertEq(data.ghoDiscountedPerToken, 100e18);
        assertEq(data.ghoDiscountRate, 2_000);
        assertEq(data.ghoMinDebtTokenBalanceForDiscount, 4e18);
        assertEq(data.ghoMinDiscountTokenBalanceForDiscount, 3e18);
        assertEq(data.ghoReserveLastUpdateTimestamp, 123);
        assertEq(data.ghoCurrentBorrowIndex, 11_000);
        assertEq(data.aaveFacilitatorBucketLevel, 250e18);
        assertEq(data.aaveFacilitatorBucketMaxCapacity, 900e18);
    }

    function testMissingLegacyGettersReturnZeroWithoutDroppingReserveData() public {
        JuicerDiscountShape strategy = new JuicerDiscountShape();
        debt.configure(address(strategy), address(strategy));

        IUiGhoDataProvider.GhoReserveData memory data = provider.getGhoReserveData();

        assertEq(data.ghoDiscountedPerToken, 0);
        assertEq(data.ghoDiscountRate, 0);
        assertEq(data.ghoMinDebtTokenBalanceForDiscount, 0);
        assertEq(data.ghoMinDiscountTokenBalanceForDiscount, 0);
        assertEq(data.ghoBaseVariableBorrowRate, 7_000);
        assertEq(data.ghoCurrentBorrowIndex, 11_000);
        assertEq(data.aaveFacilitatorBucketLevel, 250e18);
    }

    function testMalformedLegacyGetterResultsReturnZero() public {
        MalformedDiscountStrategy strategy = new MalformedDiscountStrategy();
        debt.configure(address(strategy), address(strategy));

        IUiGhoDataProvider.GhoReserveData memory data = provider.getGhoReserveData();

        assertEq(data.ghoDiscountedPerToken, 0);
        assertEq(data.ghoDiscountRate, 0);
        assertEq(data.ghoMinDebtTokenBalanceForDiscount, 0);
        assertEq(data.ghoMinDiscountTokenBalanceForDiscount, 0);
    }

    function testRequiredMarketReadsRemainFailClosed() public {
        RevertingDebtToken revertingDebt = new RevertingDebtToken();
        pool.setReserve(A_TOKEN, address(revertingDebt));

        vm.expectRevert("required read failed");
        provider.getGhoReserveData();
    }

    function testUserDataStillReadsTheCombinedStrategyAndDiscountToken() public {
        JuicerDiscountShape strategy = new JuicerDiscountShape();
        strategy.setBalance(USER, 765e18);
        debt.configure(address(strategy), address(strategy));
        debt.setUser(USER, 4_000, 123e27, 456e18);

        IUiGhoDataProvider.GhoUserData memory data = provider.getGhoUserData(USER);

        assertEq(data.userGhoDiscountPercent, 4_000);
        assertEq(data.userDiscountTokenBalance, 765e18);
        assertEq(data.userPreviousGhoBorrowIndex, 123e27);
        assertEq(data.userGhoScaledBorrowBalance, 456e18);
    }
}
