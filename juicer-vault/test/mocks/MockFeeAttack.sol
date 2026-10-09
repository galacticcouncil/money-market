// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockFeeSwapper is ISwapper {
    uint256 public actualOut;
    uint256 public reportedOut;
    uint256 public spendBps = 10_000;
    address public callbackTarget;
    bytes public callbackData;

    function configure(uint256 actual, uint256 reported, uint256 spend) external {
        actualOut = actual;
        reportedOut = reported;
        spendBps = spend;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function sell(address tokenIn, address tokenOut, uint256 amountIn, uint256, bytes calldata)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn * spendBps / 10_000);
        MockERC20(tokenOut).mint(msg.sender, actualOut);
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory reason) = callbackTarget.call(callbackData);
            if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
        }
        return reportedOut;
    }

    function buy(address, address, uint256, uint256, bytes calldata) external pure returns (uint256) {
        revert("unused");
    }
}

contract MockFeeCallbackToken is MockERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bool private entered;

    constructor() MockERC20("Callback collateral", "CALL", 18) {}

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (!entered && callbackTarget != address(0)) {
            entered = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
            entered = false;
        }
    }
}
