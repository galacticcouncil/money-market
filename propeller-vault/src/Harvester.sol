// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISubLoop} from "./interfaces/ISubLoop.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPropellerFeeController} from "./interfaces/IPropellerFeeController.sol";

interface ICompoundable {
    function prepareHarvest() external returns (uint256);
    function compound(address tokenIn, uint256 amountIn, uint256 minOut, bytes calldata route) external;
}

/// @title Harvester
/// @notice Keeper entrypoint orchestrating harvest / de-lever across the shared
///         SubLoop and the registered CollateralVaults. `harvest` skims the loop
///         carry (surplus PRIME), splits it by each vault's eligible owned units,
///         and compounds each cut into that vault's collateral (in-kind yield).
contract Harvester is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // KEEPER_ROLE removed: harvest/deLever are permissionless. DEFAULT_ADMIN_ROLE
    // is retained for addVault (registry management).

    ISubLoop public immutable subLoop;
    IERC20 public immutable prime; // the token SubLoop.harvest returns
    address[] public vaults;
    mapping(address => bool) public isRegistered;
    IPropellerFeeController public feeController;

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

    constructor(address _subLoop, address _prime, address admin) {
        if (_subLoop == address(0) || _prime == address(0) || admin == address(0)) revert ZeroAddress();
        subLoop = ISubLoop(_subLoop);
        prime = IERC20(_prime);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Register a vault to receive its pro-rata cut of the loop carry.
    /// @dev    Duplicate registration is REJECTED, not tolerated: `harvest` sums
    ///         `sharesOf(v)` per entry and hard-requires the total to equal
    ///         `subLoop.totalShares()`, so a vault listed twice double-counts, fails
    ///         that check, and reverts every harvest. This contract is not
    ///         upgradeable, so recovery would mean redeploying it and re-running a
    ///         governance `SubLoop.setHarvester`.
    function addVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (vault == address(0)) revert ZeroAddress();
        if (isRegistered[vault]) revert AlreadyRegistered();
        isRegistered[vault] = true;
        vaults.push(vault);
        emit VaultAdded(vault);
    }

    /// @notice Deregister a vault. Needed because the registry-completeness check
    ///         is strict: a vault that still holds loop shares but must be excluded
    ///         (retired, or paused for long enough to block the shared harvest)
    ///         would otherwise wedge harvesting for every healthy vault with no way
    ///         out short of redeploying this contract.
    /// @dev    Removing a vault that still holds loop shares will make
    ///         `registeredShares < totalShares` and revert `harvest` until its
    ///         shares are unwound — deliberate, so carry is never silently
    ///         redistributed away from a vault that is still entitled to it.
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
        feeController = IPropellerFeeController(controller);
        emit FeeControllerUpdated(controller);
    }

    /// @notice Realize each vault's owned loop carry → distribute PRIME →
    ///         compound each vault's cut into its collateral.
    /// @param minOuts per-vault min collateral out (slippage bound); pass 0s in tests.
    function harvest(uint256[] calldata minOuts) external nonReentrant {
        IPropellerFeeController controller = feeController;
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
            weights[i] = ICompoundable(vaults[i]).prepareHarvest();
            totalWeight += weights[i];
        }
        require(registeredShares == total, "vault set incomplete");
        uint256 capacity = Math.min(totalWeight, subLoop.harvestCapacity());
        uint256 donated = prime.balanceOf(address(this));
        uint256 surplus;
        uint256 totalBurned;
        for (uint256 i; i < n; ++i) {
            address v = vaults[i];
            uint256 amount;
            if (capacity != 0 && weights[i] != 0) {
                (amount, burned[i]) = subLoop.harvestFor(v, Math.mulDiv(capacity, weights[i], totalWeight));
                totalBurned += burned[i];
                surplus += amount;
            }
            uint256 gift = total == 0 ? 0 : Math.mulDiv(donated, beforeShares[i], total);
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
        emit HarvestRun(surplus);
    }

    /// @notice Trigger loop de-lever when HF is at/below the trigger.
    function deLever() external nonReentrant {
        subLoop.deLever();
        emit DeLeverRun();
    }
}
