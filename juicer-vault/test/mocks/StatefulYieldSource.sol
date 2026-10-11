// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {MockERC20} from "./MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IHarvestVault {
    function burnYieldShares(uint256 shares) external;
}

contract StatefulYieldSource is IYieldSource {
    MockERC20 public immutable prime;
    address public harvester;
    bool public emergencyPaused;
    uint256 public rate = 1e18;
    uint256 public pullBps = 10_000;
    uint256 public costBps;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public principalOf;
    mapping(address => uint256) public freedOf;
    mapping(address => uint256) public unwindExecutionCost;

    constructor(address token) { prime = MockERC20(token); }
    function setHarvester(address value) external { harvester = value; }
    function setEmergencyPaused(bool value) external { emergencyPaused = value; }
    function setPullBps(uint256 value) external { require(value <= 10_000); pullBps = value; }
    function setCostBps(uint256 value) external { require(value <= 10_000); costBps = value; }
    function admissionCapacity() external pure returns (uint256) { return type(uint256).max; }
    function accountingLocked() external pure returns (bool) { return false; }
    function negativeCarryBps() external pure returns (uint256) { return 0; }
    function harvestCapacity() external view returns (uint256) { return totalShares; }
    function previewHarvest(uint256 shares) public view returns (uint256) { return Math.mulDiv(shares, rate, 1e18); }
    function equityOf(address owner) external view returns (uint256) { return previewHarvest(sharesOf[owner]) / 1e10; }
    function totalEquity() external view returns (uint256) { return previewHarvest(totalShares) / 1e10; }
    function pendingUnwindOf(address owner) external view returns (uint256) { return freedOf[owner]; }
    function releasePrincipal(address owner, uint256 amount) external { principalOf[owner] -= amount; }

    function reprice(uint256 value) external {
        require(value != 0);
        uint256 before_ = previewHarvest(totalShares);
        rate = value;
        uint256 after_ = previewHarvest(totalShares);
        if (after_ > before_) prime.mint(address(this), after_ - before_);
        else prime.burn(address(this), before_ - after_);
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        prime.transferFrom(msg.sender, address(this), amount);
        shares = Math.mulDiv(amount, 1e18, rate);
        sharesOf[msg.sender] += shares;
        principalOf[msg.sender] += amount;
        totalShares += shares;
    }

    function requestUnwind(uint256 shares) external returns (uint256) {
        return _unwind(shares, Math.mulDiv(principalOf[msg.sender], shares, sharesOf[msg.sender]));
    }
    function requestUnwindProtected(uint256 shares, uint256 basis) external returns (uint256) {
        return _unwind(shares, basis);
    }
    function _unwind(uint256 shares, uint256 basis) private returns (uint256) {
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        principalOf[msg.sender] -= basis;
        freedOf[msg.sender] += previewHarvest(shares);
        return 0;
    }

    function pullFreed() external returns (uint256 amount) {
        uint256 gross = Math.mulDiv(freedOf[msg.sender], pullBps, 10_000);
        uint256 cost = Math.mulDiv(gross, costBps, 10_000);
        freedOf[msg.sender] -= gross;
        unwindExecutionCost[msg.sender] += cost;
        prime.burn(address(this), cost);
        amount = gross - cost;
        prime.transfer(msg.sender, amount);
    }

    function harvestFor(address owner, uint256 shares) external returns (uint256 amount, uint256 burned) {
        require(msg.sender == harvester);
        if (shares == 0) return (0, 0);
        IHarvestVault(owner).burnYieldShares(shares);
        amount = previewHarvest(shares);
        sharesOf[owner] -= shares;
        totalShares -= shares;
        prime.transfer(msg.sender, amount);
        return (amount, shares);
    }
    function harvest() external pure returns (uint256) { return 0; }
}
