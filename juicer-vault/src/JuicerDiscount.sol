// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    IHollarDiscountDebtToken,
    IJuicerDiscount,
    IDiscountLoop,
    IDiscountVault,
    ISyntheticAToken
} from "./interfaces/IJuicerDiscount.sol";

/// @notice HOLLAR discount for enrolled Main vaults and, at its own rate, the shared
///         loop. Install this contract as BOTH the debt token's discount token
///         (balanceOf adapter) and rate strategy. No transferable eligibility token is issued.
contract JuicerDiscount is AccessControl, ReentrancyGuard, IJuicerDiscount {
    bytes32 public constant RATE_ADMIN_ROLE = keccak256("RATE_ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_VAULTS = 16;
    // the strategy never sees the borrower, so the loop's eligibility carries this bit
    uint256 public constant LOOP_TAG = 1 << 255;

    IHollarDiscountDebtToken public immutable override debtToken;
    address public immutable override synthetic;
    ISyntheticAToken public immutable aSynthetic;
    address public immutable pool;
    uint16 public discountBps;
    uint16 public loopDiscountBps;
    address public loop;
    /// @notice discounted HOLLAR notional of the loop's debt
    uint256 public loopCap;

    // Enrollment bounds the complete set of possible cached-discount recipients.
    // Without it, a rate change could miss a borrower whose eligibility changed.
    address[] private _vaults;
    mapping(address => bool) public isRegistered;

    event DiscountBpsUpdated(uint16 previousBps, uint16 newBps);
    event VaultRegistered(address indexed vault);
    event VaultUnregistered(address indexed vault);
    event LoopRegistered(address indexed loop, uint256 cap);
    event LoopUnregistered(address indexed loop);
    event LoopCapUpdated(uint256 previousCap, uint256 newCap);
    event LoopDiscountBpsUpdated(uint16 previousBps, uint16 newBps);

    error ZeroAddress();
    error InvalidMarket();
    error InvalidVault();
    error AlreadyRegistered();
    error NotRegistered();
    error TooManyVaults();
    error InvalidDiscount();
    error NotInstalled();
    error InvalidLoop();
    error InvalidCap();

    constructor(address debtToken_, address synthetic_, address aSynthetic_, address governance, address committee) {
        if (
            debtToken_ == address(0) || synthetic_ == address(0) || aSynthetic_ == address(0)
                || governance == address(0) || committee == address(0)
        ) revert ZeroAddress();
        debtToken = IHollarDiscountDebtToken(debtToken_);
        synthetic = synthetic_;
        aSynthetic = ISyntheticAToken(aSynthetic_);
        pool = debtToken.POOL();
        // the aToken is read only once a vault is enrolled: it can be predicted before its reserve is listed
        if (pool == address(0) || IERC20Metadata(synthetic_).decimals() != 18 || IERC20Metadata(debtToken_).decimals() != 18) {
            revert InvalidMarket();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(RATE_ADMIN_ROLE, governance);
        _grantRole(RATE_ADMIN_ROLE, committee);
        // Starts at zero. Installation and enrollment precede an explicit rate decision.
    }

    /// @notice Governance enrolls an approved, hook-enabled Main vault, even
    ///         before its first deposit. Neither MINTER_ROLE nor aJSYNTH alone
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

    /// @notice Governance enrolls the loop that funds a registered vault. Only
    ///         min(debt, cap) is discounted, at loopDiscountBps, which starts at zero.
    function registerLoop(address loop_, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        if (loop != address(0)) revert AlreadyRegistered();
        if (cap == 0 || cap >= LOOP_TAG) revert InvalidCap();
        if (loop_.code.length == 0) revert InvalidLoop();
        IDiscountLoop l = IDiscountLoop(loop_);
        if (l.pool() != pool || l.hollar() != debtToken.UNDERLYING_ASSET_ADDRESS() || !_funds(loop_)) {
            revert InvalidLoop();
        }
        loop = loop_;
        loopCap = cap;
        debtToken.rebalanceUserDiscountPercent(loop_);
        emit LoopRegistered(loop_, cap);
    }

    function unregisterLoop() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        address l = loop;
        if (l == address(0)) revert NotRegistered();
        loop = address(0);
        loopCap = 0;
        // as for a vault: accrued interest settles at the old cached rate first
        debtToken.rebalanceUserDiscountPercent(l);
        emit LoopUnregistered(l);
    }

    function setLoopCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        address l = loop;
        if (l == address(0)) revert NotRegistered();
        if (cap == 0 || cap >= LOOP_TAG) revert InvalidCap();
        uint256 previous = loopCap;
        loopCap = cap;
        debtToken.rebalanceUserDiscountPercent(l);
        emit LoopCapUpdated(previous, cap);
    }

    /// @notice Committee or governance can set 0..100% off the loop's capped borrowing interest.
    function setLoopDiscountBps(uint16 newBps) external onlyRole(RATE_ADMIN_ROLE) nonReentrant {
        _requireInstalled();
        if (newBps > BPS) revert InvalidDiscount();
        uint16 previous = loopDiscountBps;
        loopDiscountBps = newBps;
        if (loop != address(0)) debtToken.rebalanceUserDiscountPercent(loop);
        emit LoopDiscountBpsUpdated(previous, newBps);
    }

    function refreshAll() external nonReentrant {
        _requireInstalled();
        _refreshAll();
    }

    /// @dev This is the balanceOf surface consumed by GHO, not an ERC20 token.
    ///      Never read HOLLAR debt here: doing so would risk recursive debt reads.
    function balanceOf(address borrower) external view override returns (uint256) {
        if (borrower == loop) {
            // storage only: this runs inside every HOLLAR mint and burn
            uint256 cap = loopCap;
            return loopDiscountBps == 0 || cap == 0 ? 0 : LOOP_TAG | cap;
        }
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
        uint256 bps = discountBps;
        if (eligibleBalance & LOOP_TAG != 0) {
            eligibleBalance ^= LOOP_TAG;
            bps = loopDiscountBps;
        }
        return Math.mulDiv(Math.min(debtBalance, eligibleBalance), bps, debtBalance);
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function _refreshAll() internal {
        for (uint256 i; i < _vaults.length; ++i) {
            debtToken.rebalanceUserDiscountPercent(_vaults[i]);
        }
        if (loop != address(0)) debtToken.rebalanceUserDiscountPercent(loop);
    }

    function _funds(address loop_) internal view returns (bool) {
        for (uint256 i; i < _vaults.length; ++i) {
            if (IDiscountVault(_vaults[i]).yieldSource() == loop_) return true;
        }
        return false;
    }

    function _requireInstalled() internal view {
        if (debtToken.getDiscountToken() != address(this) || debtToken.getDiscountRateStrategy() != address(this)) {
            revert NotInstalled();
        }
    }
}
