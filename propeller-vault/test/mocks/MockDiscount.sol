// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPropellerDiscount} from "../../src/interfaces/IPropellerDiscount.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockDiscountAToken is MockERC20 {
    address public immutable POOL;
    address public immutable UNDERLYING_ASSET_ADDRESS;

    constructor(address pool, address underlying) MockERC20("aPSYNTH", "aPSYNTH", 18) {
        POOL = pool;
        UNDERLYING_ASSET_ADDRESS = underlying;
    }
}

/// @dev Models the discount cache and action ordering, NOT interest arithmetic.
///      Interest arithmetic is exercised against the deployed GHO token in fork tests.
contract MockDiscountDebtToken is ERC20 {
    address public immutable POOL;
    address public policy;
    address public failingBorrower;
    mapping(address => uint256) public getDiscountPercent;
    mapping(address => uint256) public refreshCount;
    mapping(address => uint256) public lastEligibleBalance;

    constructor(address pool) ERC20("HOLLAR debt", "vdHOLLAR") {
        POOL = pool;
    }

    function setPolicy(address value) external {
        policy = value;
    }

    function setFailingBorrower(address value) external {
        failingBorrower = value;
    }

    function getDiscountToken() external view returns (address) {
        return policy;
    }

    function getDiscountRateStrategy() external view returns (address) {
        return policy;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
        rebalanceUserDiscountPercent(to);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
        rebalanceUserDiscountPercent(from);
    }

    function rebalanceUserDiscountPercent(address borrower) public {
        require(borrower != failingBorrower, "refresh failed");
        ++refreshCount[borrower];
        lastEligibleBalance[borrower] = policy == address(0) ? 0 : IPropellerDiscount(policy).balanceOf(borrower);
        getDiscountPercent[borrower] = policy == address(0)
            ? 0
            : IPropellerDiscount(policy).calculateDiscountRate(balanceOf(borrower), lastEligibleBalance[borrower]);
    }
}

contract MockDiscountVault {
    address public immutable pool;
    address public immutable synthetic;
    address public immutable hollarDebtToken;
    address public discountController;

    constructor(address pool_, address synthetic_, address debt_, address controller_) {
        pool = pool_;
        synthetic = synthetic_;
        hollarDebtToken = debt_;
        discountController = controller_;
    }

    function setController(address value) external {
        discountController = value;
    }
}
