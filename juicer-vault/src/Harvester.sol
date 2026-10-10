// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISubLoop} from "./interfaces/ISubLoop.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IJuicerFeeController} from "./interfaces/IJuicerFeeController.sol";
import {ExecutionController} from "./ExecutionController.sol";
import {IMainDebt} from "./interfaces/IMainDebt.sol";

interface ICompoundable {
    function collateral() external view returns (address);
    function mainDebt() external view returns (IMainDebt);
    function sync() external returns (uint256);
    function compound(address tokenIn, uint256 amountIn, uint256 minOut, bytes calldata route) external;
}

/// @title Harvester
/// @notice permissionless harvest / de-lever for the shared SubLoop. splits loop carry by each
/// registered vault's owned units and compounds each cut into that vault's collateral.
contract Harvester is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISubLoop public immutable subLoop;
    IERC20 public immutable prime; // the token SubLoop.harvest returns
    address[] public vaults;
    mapping(address => bool) public isRegistered;
    IJuicerFeeController public feeController;
    ExecutionController public executionController;
    uint256 public lastHarvestAt;

    event HarvestRun(uint256 surplusPrime);
    event DeLeverRun();
    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event FeeControllerUpdated(address indexed controller);

    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error FeeControllerUnset();
    error HarvestConfigurationChanged();
    event ExecutionControllerSet(address indexed controller);

    constructor(address _subLoop, address _prime, address admin) {
        if (_subLoop == address(0) || _prime == address(0) || admin == address(0)) revert ZeroAddress();
        lastHarvestAt = block.timestamp;
        subLoop = ISubLoop(_subLoop);
        prime = IERC20(_prime);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice register a vault for its pro-rata cut of the loop carry.
    /// @dev duplicates are rejected: a double-counted vault would fail harvest's share-sum check forever.
    function addVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (vault == address(0)) revert ZeroAddress();
        if (isRegistered[vault]) revert AlreadyRegistered();
        isRegistered[vault] = true;
        vaults.push(vault);
        emit VaultAdded(vault);
    }

    /// @notice deregister a vault that would otherwise wedge the shared harvest.
    /// @dev harvest reverts until its loop shares are unwound, so its carry is never redistributed.
    function removeVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!isRegistered[vault]) revert NotRegistered();
        isRegistered[vault] = false;
        uint256 n = vaults.length;
        for (uint256 i = 0; i < n; i++) {
            if (vaults[i] == vault) {
                vaults[i] = vaults[n - 1];
                vaults.pop();
                break;
            }
        }
        emit VaultRemoved(vault);
    }

    /// @notice Number of registered vaults (the array is not otherwise enumerable).
    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function harvestable() external view returns (bool) {
        return prime.balanceOf(address(this)) != 0 || subLoop.harvestCapacity() != 0;
    }

    function setFeeController(address controller) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (controller == address(0)) revert ZeroAddress();
        feeController = IJuicerFeeController(controller);
        emit FeeControllerUpdated(controller);
    }

    function setExecutionController(address controller) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (controller.code.length == 0 || address(executionController) != address(0)) revert ZeroAddress();
        executionController = ExecutionController(controller);
        emit ExecutionControllerSet(controller);
    }

    function _fit(address vault, uint256 amount) private view returns (uint256) {
        if (address(executionController) == address(0)) return amount;
        return executionController.fit(vault, address(prime), ICompoundable(vault).collateral(), amount);
    }

    /// @notice realize each vault's owned loop carry and compound its cut into its collateral.
    /// @param minOuts per-vault min collateral out (slippage bound)
    function harvest(uint256[] calldata minOuts) external nonReentrant returns (uint256 surplus) {
        IJuicerFeeController controller = feeController;
        if (address(controller) == address(0)) revert FeeControllerUnset();
        uint256 version = controller.configurationVersion();
        uint256 total = subLoop.totalShares();
        uint256 n = vaults.length;
        uint256[] memory beforeShares = new uint256[](n);
        uint256[] memory weights = new uint256[](n);
        uint256[] memory burned = new uint256[](n);
        uint256 registeredShares;
        uint256 totalWeight;
        for (uint256 i; i < n; ++i) {
            controller.validateVault(vaults[i], address(this));
            beforeShares[i] = subLoop.sharesOf(vaults[i]);
            registeredShares += beforeShares[i];
            weights[i] = ICompoundable(vaults[i]).sync();
            totalWeight += weights[i];
        }
        require(registeredShares == total, "vault set incomplete");
        uint256 capacity = Math.min(totalWeight, subLoop.harvestCapacity());
        uint256 donated = prime.balanceOf(address(this));
        uint256 totalBurned;
        for (uint256 i; i < n; ++i) {
            address v = vaults[i];
            uint256 amount;
            if (capacity != 0 && weights[i] != 0) {
                uint256 shares = Math.mulDiv(capacity, weights[i], totalWeight);
                if (address(executionController) != address(0)) {
                    uint256 expected = subLoop.previewHarvest(shares);
                    uint256 bounded = _fit(v, expected);
                    shares = expected == 0 ? 0 : Math.mulDiv(shares, bounded, expected);
                    // shares round down from the bounded input; sub-minimum tails stay in the source
                    if (_fit(v, subLoop.previewHarvest(shares)) == 0) shares = 0;
                }
                (amount, burned[i]) = subLoop.harvestFor(v, shares);
                totalBurned += burned[i];
                surplus += amount;
            }
            uint256 gift = total == 0 ? 0 : Math.mulDiv(donated, beforeShares[i], total);
            if (address(executionController) != address(0)) {
                // owned carry first: no second dust trade on the route, and parked donations
                // never bypass the limits or a skipped vault's blocked interest sale
                gift = amount == 0 && !ICompoundable(v).mainDebt().serviceBlocked() ? _fit(v, gift) : 0;
            }
            uint256 minimum = i < minOuts.length ? minOuts[i] : 0;
            uint256 yieldMinimum = amount == 0 ? 0 : Math.mulDiv(minimum, amount, amount + gift, Math.Rounding.Up);
            controller.validateVault(v, address(this));
            if (amount != 0) {
                prime.forceApprove(v, amount);
                ICompoundable(v).compound(address(prime), amount, yieldMinimum, "");
                prime.forceApprove(v, 0);
            }
            if (gift != 0) {
                prime.forceApprove(v, gift);
                ICompoundable(v).compound(address(prime), gift, minimum - yieldMinimum, "");
                prime.forceApprove(v, 0);
                surplus += gift;
            }
        }
        if (controller.configurationVersion() != version || subLoop.totalShares() + totalBurned != total) {
            revert HarvestConfigurationChanged();
        }
        for (uint256 i; i < n; ++i) {
            controller.validateVault(vaults[i], address(this));
            if (subLoop.sharesOf(vaults[i]) + burned[i] != beforeShares[i]) revert HarvestConfigurationChanged();
        }
        if (surplus != 0) lastHarvestAt = block.timestamp;
        emit HarvestRun(surplus);
    }

    /// @notice Trigger loop de-lever when HF is at/below the trigger.
    function deLever() external nonReentrant {
        subLoop.deLever();
        emit DeLeverRun();
    }
}
