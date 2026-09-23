// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPropellerFeeController} from "./interfaces/IPropellerFeeController.sol";
import {IAavePool, IPoolAddressesProvider, IAaveOracle} from "./interfaces/IAavePool.sol";

interface IFeeVault {
    function collateral() external view returns (address);
    function collateralAToken() external view returns (address);
    function pool() external view returns (address);
    function yieldSource() external view returns (address);
    function feeController() external view returns (address);
    function mainDebt() external view returns (address);
}

interface IFeeHarvester {
    function subLoop() external view returns (address);
    function prime() external view returns (address);
    function feeController() external view returns (address);
}

interface IFeeSource {
    function prime() external view returns (address);
    function harvester() external view returns (address);
}

/// @notice Per-vault harvest fees, held as uninvested collateral until anyone
/// triggers a payment to the current treasury. Governance is the trusted admin.
contract PropellerFeeController is AccessControl, ReentrancyGuard, IPropellerFeeController {
    using SafeERC20 for IERC20;

    uint16 public constant INITIAL_FEE_BPS = 500;
    uint16 public constant BPS = 10_000;

    struct Binding {
        address asset;
        address harvester;
        uint16 feeBps;
    }

    mapping(address => Binding) public bindings;
    mapping(address => uint256) public claimableProtocolFees;
    mapping(address => bool) public custodyAddress;
    address public feeRecipient;
    uint256 public override configurationVersion;

    error InvalidAddress();
    error InvalidBinding();
    error NotRegistered();
    error InvalidFee();
    error TransferMismatch();

    event VaultBound(address indexed vault, address indexed asset, address indexed harvester);
    event ProtocolFeeUpdated(address indexed vault, uint16 previousBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event ProtocolFeeAccrued(address indexed vault, address indexed asset, uint256 gross, uint256 fee, uint256 net);
    event ProtocolFeesClaimed(address indexed asset, address indexed recipient, uint256 amount);

    constructor(address governance, address recipient) {
        if (governance == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _setRecipient(recipient);
    }

    /// @notice Register or rebind a reviewed vault. Rebinding preserves its rate.
    function registerVault(address vault, address harvester) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        IFeeVault v = IFeeVault(vault);
        address asset = v.collateral();
        address source = v.yieldSource();
        address pool = v.pool();
        if (asset == address(0) || source == address(0) || pool == address(0)) revert InvalidBinding();
        Binding storage b = bindings[vault];
        if (b.asset == address(0)) {
            b.asset = asset;
            b.feeBps = INITIAL_FEE_BPS;
            emit ProtocolFeeUpdated(vault, 0, INITIAL_FEE_BPS);
        } else if (b.asset != asset) {
            revert InvalidBinding();
        }
        b.harvester = harvester;
        validateVault(vault, harvester);
        _markCustody(vault);
        _markCustody(v.mainDebt());
        _markCustody(harvester);
        _markCustody(source);
        _markCustody(pool);
        _markCustody(v.collateralAToken());
        ++configurationVersion;
        emit VaultBound(vault, asset, harvester);
    }

    function protocolFeeBps(address vault) external view returns (uint16) {
        if (bindings[vault].asset == address(0)) revert NotRegistered();
        return bindings[vault].feeBps;
    }

    function setProtocolFeeBps(address vault, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Binding storage b = bindings[vault];
        if (b.asset == address(0)) revert NotRegistered();
        if (bps > BPS) revert InvalidFee();
        emit ProtocolFeeUpdated(vault, b.feeBps, bps);
        b.feeBps = bps;
        ++configurationVersion;
    }

    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _setRecipient(recipient);
        ++configurationVersion;
    }

    function validateVault(address vault, address harvester) public view override {
        Binding memory b = bindings[vault];
        if (b.asset == address(0)) revert NotRegistered();
        IFeeVault v = IFeeVault(vault);
        IFeeHarvester h = IFeeHarvester(harvester);
        address source = v.yieldSource();
        if (
            harvester != b.harvester || v.collateral() != b.asset || v.feeController() != address(this)
                || h.feeController() != address(this) || h.subLoop() != source
                || h.prime() != IFeeSource(source).prime() || IFeeSource(source).harvester() != harvester
        ) revert InvalidBinding();
    }

    /// @notice Aave-oracle quote in collateral units. Kept outside the vault to
    /// preserve its EIP-170 budget with both fee and borrowing-discount hooks.
    function quoteCollateral(address vault, address tokenIn, uint256 amountIn)
        external
        view
        override
        returns (uint256)
    {
        address asset = bindings[vault].asset;
        if (asset == address(0)) revert NotRegistered();
        if (tokenIn == asset) return amountIn;
        address provider = IAavePool(IFeeVault(vault).pool()).ADDRESSES_PROVIDER();
        IAaveOracle oracle = IAaveOracle(IPoolAddressesProvider(provider).getPriceOracle());
        uint256 pIn = oracle.getAssetPrice(tokenIn);
        uint256 pOut = oracle.getAssetPrice(asset);
        return Math.mulDiv(
            amountIn, pIn * (10 ** IERC20Metadata(asset).decimals()), pOut * (10 ** IERC20Metadata(tokenIn).decimals())
        );
    }

    function collectFee(uint256 grossCollateral, address compoundCaller)
        external
        override
        nonReentrant
        returns (uint256 fee)
    {
        Binding memory b = bindings[msg.sender];
        validateVault(msg.sender, b.harvester);
        // Caller-funded contributions do not access the source's yield.
        if (compoundCaller != b.harvester) return 0;
        fee = Math.mulDiv(grossCollateral, b.feeBps, BPS);
        if (fee != 0) {
            IERC20 token = IERC20(b.asset);
            uint256 beforeBalance = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), fee);
            if (token.balanceOf(address(this)) != beforeBalance + fee) revert TransferMismatch();
            claimableProtocolFees[b.asset] += fee;
        }
        emit ProtocolFeeAccrued(msg.sender, b.asset, grossCollateral, fee, grossCollateral - fee);
    }

    function claimProtocolFees(address asset) external nonReentrant {
        uint256 amount = claimableProtocolFees[asset];
        if (amount == 0) return;
        address recipient = feeRecipient;
        claimableProtocolFees[asset] = 0;
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (
            token.balanceOf(address(this)) != beforeBalance - amount
                || token.balanceOf(recipient) != recipientBefore + amount
        ) revert TransferMismatch();
        emit ProtocolFeesClaimed(asset, recipient, amount);
    }

    function _setRecipient(address recipient) internal {
        if (recipient == address(0) || recipient == address(this) || custodyAddress[recipient]) {
            revert InvalidAddress();
        }
        emit FeeRecipientUpdated(feeRecipient, recipient);
        feeRecipient = recipient;
    }

    function _markCustody(address account) internal {
        if (account == feeRecipient) revert InvalidAddress();
        custodyAddress[account] = true;
    }
}
