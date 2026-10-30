// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IReservePool {
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

    function getReserveData(address asset) external view returns (ReserveData memory);
}

/// @notice governance creates the JuicerDiscount in the proposal that lists the synthetic, whose aToken its
///         constructor checks. the code is pinned and the aToken read at creation, so the address, this
///         contract's first creation, is known before the proposal runs
/// @dev outside src/: production builds keep their sources, and bytecode, unchanged
contract DiscountDeployment {
    address public immutable governance;
    address public immutable pool;
    address public immutable debtToken;
    address public immutable synthetic;
    address public immutable committee;
    bytes32 public immutable codeHash;
    address public discount;

    error ZeroAddress();
    error Unauthorized();
    error AlreadyDeployed();
    error InvalidCode();
    error NotListed();
    error CreateFailed();

    event DiscountDeployed(address indexed discount, address indexed aSynthetic);

    constructor(
        address governance_,
        address pool_,
        address debtToken_,
        address synthetic_,
        address committee_,
        bytes32 codeHash_
    ) {
        if (
            governance_ == address(0) || pool_ == address(0) || debtToken_ == address(0)
                || synthetic_ == address(0) || committee_ == address(0) || codeHash_ == bytes32(0)
        ) revert ZeroAddress();
        governance = governance_;
        pool = pool_;
        debtToken = debtToken_;
        synthetic = synthetic_;
        committee = committee_;
        codeHash = codeHash_;
    }

    function deploy(bytes calldata creationCode) external returns (address created) {
        if (msg.sender != governance) revert Unauthorized();
        if (discount != address(0)) revert AlreadyDeployed();
        if (keccak256(creationCode) != codeHash) revert InvalidCode();
        address aSynthetic = IReservePool(pool).getReserveData(synthetic).aTokenAddress;
        if (aSynthetic == address(0)) revert NotListed();
        bytes memory initcode =
            abi.encodePacked(creationCode, abi.encode(debtToken, synthetic, aSynthetic, governance, committee));
        assembly ("memory-safe") {
            created := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (created == address(0)) revert CreateFailed();
        discount = created;
        emit DiscountDeployed(created, aSynthetic);
    }
}
