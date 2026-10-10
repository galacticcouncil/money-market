// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";

/// @notice minimal non-leveraged `IYieldSource`: custodies hollar 1:1 and frees it
/// synchronously on request, no yield modelled
contract MockYieldSource is IYieldSource {
    IERC20 public immutable hollar;
    bool public emergencyPaused;

    function setEmergencyPaused(bool value) external {
        emergencyPaused = value;
    }

    mapping(address => uint256) internal _shares;
    mapping(address => uint256) public principalOf;
    mapping(address => uint256) internal _freed;
    uint256 internal _totalShares;
    uint256 public pullBps = 10_000;
    function unwindExecutionCost(address) external pure returns (uint256) { return 0; }

    function setPullBps(uint256 bps) external { require(bps <= 10_000); pullBps = bps; }

    constructor(address _hollar) {
        hollar = IERC20(_hollar);
    }

    function admissionCapacity() external pure returns (uint256) { return type(uint256).max; }
    function previewHarvest(uint256) external pure returns (uint256) { return 0; }

    function deposit(uint256 hollarAmount) external returns (uint256 shares) {
        hollar.transferFrom(msg.sender, address(this), hollarAmount);
        shares = hollarAmount; // 1:1
        _shares[msg.sender] += shares;
        principalOf[msg.sender] += shares;
        _totalShares += shares;
    }

    function requestUnwind(uint256 shares) public returns (uint256 unwindId) {
        uint256 basis = principalOf[msg.sender] * shares / _shares[msg.sender];
        principalOf[msg.sender] -= basis;
        return _unwind(shares);
    }

    function _unwind(uint256 shares) private returns (uint256) {
        require(_shares[msg.sender] >= shares, "insufficient shares");
        _shares[msg.sender] -= shares;
        _totalShares -= shares;
        _freed[msg.sender] += shares; // 1:1, freed synchronously
        return 0;
    }

    function requestUnwindProtected(uint256 shares, uint256 basis) external returns (uint256) {
        principalOf[msg.sender] -= basis;
        return _unwind(shares);
    }

    function releasePrincipal(address vault, uint256 amount) external { principalOf[vault] -= amount; }

    function accountingLocked() external pure returns (bool) { return false; }

    function harvestCapacity() external pure returns (uint256) { return 0; }
    function harvestFor(address, uint256) external pure returns (uint256, uint256) { return (0, 0); }

    function pullFreed() external returns (uint256 hollarSent) {
        hollarSent = _freed[msg.sender] * pullBps / 10_000;
        if (hollarSent == 0) return 0;
        _freed[msg.sender] -= hollarSent;
        hollar.transfer(msg.sender, hollarSent);
    }

    function freedOf(address vault) external view returns (uint256) {
        return _freed[vault];
    }

    function pendingUnwindOf(address vault) external view returns (uint256) {
        // frees synchronously into _freed, so anything still owed is unpulled-freed
        return _freed[vault];
    }

    function equityOf(address vault) external view returns (uint256) {
        // equity in USD8; HOLLAR is 18dp $1, shares 1:1 → /1e10
        return _shares[vault] / 1e10;
    }

    function sharesOf(address vault) external view returns (uint256) {
        return _shares[vault];
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    function totalEquity() external view returns (uint256) {
        return _totalShares / 1e10;
    }

    function negativeCarryBps() external pure returns (uint256) {
        return 0; // 1:1 custody, no yield/loss modelled → never underwater
    }

    function harvest() external returns (uint256 surplus) {
        return 0; // no yield modelled
    }
}
