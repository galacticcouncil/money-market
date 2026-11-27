// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAavePool} from "./IAavePool.sol";
import {ILooperPosition} from "./ILooperPosition.sol";

interface ILooperFactory {
    event PositionCreated(uint256 indexed tokenId, address position);

    error NotOwner();
    error LeverageTooHigh();
    error InvalidParams();
    error InvalidImplementation();
    error AssetIdMismatch();

    function pool() external view returns (IAavePool);
    function implementation() external view returns (address);
    function open(ILooperPosition.Params calldata p, uint256 amount, uint256 feeBudget)
        external
        returns (uint256 id, address position);
    function deposit(uint256 id, uint256 amount) external;
    function predict(uint256 id) external view returns (address);
}
