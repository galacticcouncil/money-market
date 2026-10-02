// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    IHollarDiscountDebtToken,
    IPropellerDiscount,
    IDiscountVault,
    ISyntheticAToken
} from "./interfaces/IPropellerDiscount.sol";

/// @notice Main-vault-only HOLLAR discount. Install this contract as BOTH the
///         debt token's discount token (balanceOf adapter) and rate strategy.
///         No transferable eligibility token is issued. SubLoop is not enrolled.
contract PropellerDiscount is AccessControl, ReentrancyGuard, IPropellerDiscount {
    bytes32 public constant RATE_ADMIN_ROLE = keccak256("RATE_ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_VAULTS = 16;

    IHollarDiscountDebtToken public immutable override debtToken;
    address public immutable override synthetic;
    ISyntheticAToken public immutable aSynthetic;
    address public immutable pool;
    uint16 public discountBps;

    // Enrollment bounds the complete set of possible cached-discount recipients.
    // Without it, a rate change could miss a borrower whose eligibility changed.
    address[] private _vaults;
    mapping(address => bool) public isRegistered;

    event DiscountBpsUpdated(uint16 previousBps, uint16 newBps);
    event VaultRegistered(address indexed vault);
    event VaultUnregistered(address indexed vault);

    error ZeroAddress();
    error InvalidMarket();
    error InvalidVault();
    error AlreadyRegistered();
    error NotRegistered();
    error TooManyVaults();
    error InvalidDiscount();
    error NotInstalled();

    constructor(address debtToken_, address synthetic_, address aSynthetic_, address governance, address committee) {
        if (
            debtToken_ == address(0) || synthetic_ == address(0) || aSynthetic_ == address(0)
                || governance == address(0) || committee == address(0)
        ) revert ZeroAddress();
        debtToken = IHollarDiscountDebtToken(debtToken_);
        synthetic = synthetic_;
        aSynthetic = ISyntheticAToken(aSynthetic_);
        pool = debtToken.POOL();
        if (
            pool == address(0) || aSynthetic.POOL() != pool || aSynthetic.UNDERLYING_ASSET_ADDRESS() != synthetic_
                || IERC20Metadata(synthetic_).decimals() != 18 || IERC20Metadata(aSynthetic_).decimals() != 18
                || IERC20Metadata(debtToken_).decimals() != 18
        ) {
            revert InvalidMarket();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(RATE_ADMIN_ROLE, governance);
        _grantRole(RATE_ADMIN_ROLE, committee);
        // Starts at zero. Installation and enrollment precede an explicit rate decision.
    }

    /// @notice Governance enrolls an approved, hook-enabled Main vault, even
    ///         before its first deposit. Neither MINTER_ROLE nor aPSYNTH alone
    ///         lets a borrower opt itself into this subsidy.
    function registerVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        if (isRegistered[vault]) revert AlreadyRegistered();
        if (_vaults.length == MAX_VAULTS) revert TooManyVaults();
        if (vault.code.length == 0 || !IAccessControl(synthetic).hasRole(MINTER_ROLE, vault)) {
            revert InvalidVault();
        }
        IDiscountVault v = IDiscountVault(vault);
        if (
            v.pool() != pool || v.synthetic() != synthetic || v.hollarDebtToken() != address(debtToken)
                || v.discountController() != address(this)
        ) revert InvalidVault();
        isRegistered[vault] = true;
        _vaults.push(vault);
        debtToken.rebalanceUserDiscountPercent(vault);
        emit VaultRegistered(vault);
    }

    /// @notice Revoke the subsidy without revoking synthetic minting or exit access.
    function unregisterVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        if (!isRegistered[vault]) revert NotRegistered();
        isRegistered[vault] = false;
        uint256 n = _vaults.length;
        for (uint256 i; i < n; ++i) {
            if (_vaults[i] == vault) {
                _vaults[i] = _vaults[n - 1];
                _vaults.pop();
                break;
            }
        }
        // The debt token first settles accrued interest at the OLD cached rate.
        // It then reads our now-zero eligibility for all future accrual.
        debtToken.rebalanceUserDiscountPercent(vault);
        emit VaultUnregistered(vault);
    }

    /// @notice Committee or governance can set 0..100% off Main borrowing interest.
    ///         The complete bounded recipient set is refreshed atomically. A
    ///         failed refresh rolls back the rate change, not just that borrower.
    function setDiscountBps(uint16 newBps) external onlyRole(RATE_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        if (newBps > BPS) revert InvalidDiscount();
        uint16 previous = discountBps;
        discountBps = newBps;
        _refreshAll();
        emit DiscountBpsUpdated(previous, newBps);
    }

    function refreshAll() external nonReentrant {
        _requireInstalled();
        _refreshAll();
    }

    /// @dev This is the balanceOf surface consumed by GHO, not an ERC20 token.
    ///      Never read HOLLAR debt here: doing so would risk recursive debt reads.
    function balanceOf(address borrower) external view override returns (uint256) {
        // Disabling must not depend on a vault or collateral getter still working.
        if (
            discountBps == 0 || !isRegistered[borrower] || !IAccessControl(synthetic).hasRole(MINTER_ROLE, borrower)
                || IDiscountVault(borrower).discountController() != address(this)
        ) return 0;
        return aSynthetic.balanceOf(borrower);
    }

    /// @notice Synthetic and HOLLAR both use 18 decimals and the same $1 unit.
    ///         Dust backing cannot unlock the full discount on a large debt.
    /// @dev Like native GHO discounts, this fraction is cached between actions;
    ///      it is NOT a continuously enforced notional cap or subsidy budget.
    function calculateDiscountRate(uint256 debtBalance, uint256 eligibleBalance)
        external
        view
        override
        returns (uint256)
    {
        if (debtBalance == 0 || eligibleBalance == 0) return 0;
        return Math.mulDiv(Math.min(debtBalance, eligibleBalance), discountBps, debtBalance);
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function _refreshAll() internal {
        for (uint256 i; i < _vaults.length; ++i) {
            debtToken.rebalanceUserDiscountPercent(_vaults[i]);
        }
    }

    function _requireInstalled() internal view {
        if (debtToken.getDiscountToken() != address(this) || debtToken.getDiscountRateStrategy() != address(this)) {
            revert NotInstalled();
        }
    }
}
