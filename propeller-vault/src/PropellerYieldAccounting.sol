// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {IPropellerFeeController} from "./interfaces/IPropellerFeeController.sol";
import {IMainDebt} from "./interfaces/IMainDebt.sol";

interface IYieldVault is IERC20 {
    function yieldSource() external view returns (IYieldSource);
    function mainDebt() external view returns (IMainDebt);
    function feeController() external view returns (IPropellerFeeController);
    function hollar() external view returns (IERC20);
    function totalQueuedShares() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
}

/// @notice Separately owned, unencumbered source units and funded reward shares.
/// Collateral shares never include receivables. A lazy index allocates reward
/// fund units before collateral balances change; no operation scans holders.
/// The fund's collateral shares keep earning while rewards remain unclaimed.
contract PropellerYieldAccounting {
    uint256 private constant RAY = 1e27;
    uint256 private constant BPS = 10_000;
    address public immutable vault;
    uint256 public sourceShares;
    uint256 public protocolShares;
    uint256 public totalUnits;
    uint256 public rewardIndex;
    mapping(address => uint256) private units;
    mapping(address => uint256) public accountIndex;
    mapping(uint256 => uint256) public requestIndex;
    uint256 public harvestUnits;
    uint256 public harvestRewardUnits;
    uint256 public harvestProtocolUnits;
    uint256 public totalVestedShares;
    mapping(address => uint256) public vestedShares;
    uint256 public epoch;
    mapping(address => uint256) public accountEpoch;
    mapping(uint256 => uint256) public requestEpoch;
    uint256 public unitScale;
    mapping(address => uint256) public accountScale;
    mapping(uint256 => uint256) public requestScale;

    error Unauthorized();
    error InvalidHarvest();
    event YieldCheckpoint(uint256 sourceShares, uint256 rewardUnits);
    event RewardClaimed(address indexed owner, uint256 units, uint256 collateralShares);
    event RewardsVested(address indexed owner, uint256 collateralShares);
    event YieldWrittenOff(uint256 indexed epoch);

    constructor(address vault_) { vault = vault_; }
    modifier onlyVault() { if (msg.sender != vault) revert Unauthorized(); _; }

    function _supply() private view returns (uint256) {
        IYieldVault v = IYieldVault(vault);
        return v.totalSupply() - v.totalQueuedShares();
    }

    function _fee() private view returns (uint256) {
        IPropellerFeeController f = IYieldVault(vault).feeController();
        return address(f) == address(0) ? 0 : f.protocolFeeBps(vault);
    }

    function reservedShares() public view returns (uint256) {
        return sourceShares + protocolShares;
    }

    function requiredSourceBacking() public view returns (uint256 required) {
        IMainDebt ledger = IYieldVault(vault).mainDebt();
        (uint256 debt, uint256 principal,) = ledger.activePosition();
        uint256 cash = ledger.activeFunds();
        required = debt > cash ? debt - cash : 0;
        uint256 interest = debt > principal + cash ? debt - principal - cash : 0;
        uint256 fee = _fee();
        if (fee < BPS) required += Math.mulDiv(interest, fee, BPS - fee, Math.Rounding.Up);
    }

    function _required() private view returns (uint256 required) {
        required = requiredSourceBacking();
        // Allocation retains two USD8 quote quanta; entry need not fund an
        // additional buffer when principal is already exactly covered.
        if (required != 0) required += 2e10;
    }

    /// @dev Unrealized earnings are junior to the Main obligation. A recovery
    /// of borrowed capital must not resurrect yield ahead of collateral exits.
    function _retained() private view returns (uint256 retained) {
        IYieldSource s = IYieldVault(vault).yieldSource();
        uint256 equity = s.equityOf(vault) * 1e10;
        uint256 required = _required();
        if (equity > required) {
            retained = Math.min(reservedShares(), Math.mulDiv(equity - required, s.sharesOf(vault), equity));
        }
    }

    function _value(uint256 shares) private view returns (uint256) {
        if (shares == 0) return 0;
        IYieldVault v = IYieldVault(vault);
        IYieldSource s = v.yieldSource();
        uint256 held = s.sharesOf(vault);
        if (held == 0) return 0;
        return Math.mulDiv(s.equityOf(vault) * 1e10, shares, held);
    }

    /// @notice Combined user/protocol source value excluded from Main backing.
    function sourceValue() public view returns (uint256) {
        IYieldSource s = IYieldVault(vault).yieldSource();
        uint256 held = s.sharesOf(vault);
        return held == 0 ? 0 : Math.mulDiv(s.equityOf(vault) * 1e10, _retained(), held);
    }

    function totalAssets() public view returns (uint256) {
        return IYieldVault(vault).mainDebt().quoteCollateral(_assets());
    }

    // Price reward units in HOLLAR precision, including for 8-decimal BTC.
    // Rounding each small accrual to a collateral unit could erase ownership.
    function _assets() private view returns (uint256) {
        IYieldVault v = IYieldVault(vault);
        uint256 reserved = reservedShares();
        uint256 retained = reserved == 0 ? 0 : Math.mulDiv(_retained(), sourceShares, reserved);
        return _value(retained) + v.mainDebt().quoteHollar(v.convertToAssets(_funded()));
    }

    function _funded() private view returns (uint256) {
        return IERC20(vault).balanceOf(address(this)) - totalVestedShares;
    }

    function _weight(address owner) private view returns (uint256) {
        return IERC20(vault).balanceOf(owner) + vestedShares[owner];
    }

    function balanceOf(address owner) public view returns (uint256) {
        if (owner == vault || owner == address(this) || owner == address(0)) return units[owner];
        uint256 shift = unitScale - (accountEpoch[owner] == epoch ? accountScale[owner] : unitScale);
        uint256 previous = accountEpoch[owner] == epoch ? accountIndex[owner] >> shift : 0;
        uint256 owned = accountEpoch[owner] == epoch ? units[owner] >> shift : 0;
        return Math.min(totalUnits, owned + Math.mulDiv(_weight(owner), rewardIndex - previous, RAY));
    }

    function _settle(address owner) private {
        if (owner == address(0) || owner == vault || owner == address(this)) return;
        units[owner] = balanceOf(owner);
        accountIndex[owner] = rewardIndex;
        accountEpoch[owner] = epoch;
        accountScale[owner] = unitScale;
    }

    /// @dev Ownership and its fee vest together, before collateral balances
    /// change. The protocol receives its reserved source units only on actual
    /// realization. A later rate change cannot reassign earlier earnings.
    function checkpoint(address from, address to) external onlyVault {
        IYieldVault v = IYieldVault(vault);
        IYieldSource s = v.yieldSource();
        if (harvestUnits != 0 || s.accountingLocked() || v.mainDebt().pendingSourceAccounting()) revert InvalidHarvest();
        uint256 reserved = reservedShares();
        uint256 retained = _retained();
        if (retained < reserved) {
            sourceShares = Math.mulDiv(sourceShares, retained, reserved);
            protocolShares = retained - sourceShares;
        }
        if (totalUnits != 0 && _assets() == 0) {
            totalUnits = 0;
            rewardIndex = 0;
            unitScale = 0;
            emit YieldWrittenOff(++epoch);
        }
        uint256 held = s.sharesOf(vault);
        uint256 supply = _supply();
        if (held != 0 && supply != 0) {
            uint256 equity = s.equityOf(vault) * 1e10;
            uint256 required = _required();
            uint256 available = equity > required ? Math.mulDiv(equity - required, held, equity) : 0;
            uint256 added = available > retained ? available - retained : 0;
            if (added != 0) {
                uint256 before_ = _assets();
                // Main recovery cash or an outside repayment can release source
                // capital. That capital is a gift, not fee-bearing earned yield.
                uint256 basis = s.principalOf(vault);
                uint256 released = Math.min(Math.mulDiv(added, equity, held), basis > required ? basis - required : 0);
                if (released != 0) s.releasePrincipal(vault, released);
                uint256 untaxed = Math.mulDiv(released, held, equity);
                uint256 feeShares = Math.mulDiv(added - untaxed, _fee(), BPS);
                uint256 rewardShares = added - feeShares;
                uint256 value = _value(rewardShares);
                uint256 selfValue = Math.mulDiv(value, _funded(), supply);
                uint256 outsideSupply = supply - _funded();
                uint256 outsideValue = value - selfValue;
                uint256 denominator = before_ + selfValue + 1;
                // Loss followed by refilling must not exponentially inflate
                // units. Rescale lazily, preserving far more precision than a
                // collateral/source base unit and without visiting holders.
                uint256 limit = Math.mulDiv(uint256(1) << 160, denominator, Math.max(denominator, outsideValue));
                while (totalUnits > limit) {
                    totalUnits >>= 64;
                    rewardIndex >>= 64;
                    unitScale += 64;
                }
                uint256 minted = Math.mulDiv(outsideValue, totalUnits + 1, denominator);
                sourceShares += rewardShares;
                protocolShares += feeShares;
                totalUnits += minted;
                if (outsideSupply != 0) rewardIndex += Math.mulDiv(minted, RAY, outsideSupply);
                emit YieldCheckpoint(rewardShares, minted);
            }
        }
        _settle(from);
        if (to != from) _settle(to);
    }

    function escrow(uint256 id) external onlyVault {
        requestIndex[id] = rewardIndex;
        requestEpoch[id] = epoch;
        requestScale[id] = unitScale;
    }

    function startExit(uint256 id, address owner, uint256 shares) external onlyVault
        returns (uint256 rewardShares, uint256 feeShares)
    {
        _settle(owner);
        uint256 previous = requestEpoch[id] == epoch ? requestIndex[id] >> (unitScale - requestScale[id]) : 0;
        units[owner] = Math.min(totalUnits, units[owner] + Math.mulDiv(shares, rewardIndex - previous, RAY));
        delete requestIndex[id];
        delete requestEpoch[id];
        delete requestScale[id];
        // The owner's unharvested portion follows the exit and supplies its own
        // execution allowance. Funded reward shares stay independently claimable.
        // Exit surplus keeps #60's original-owner HOLLAR recovery semantics.
        if (totalUnits != 0 && units[owner] != 0) {
            uint256 burned = Math.mulDiv(units[owner], shares, _weight(owner) + shares);
            rewardShares = Math.mulDiv(sourceShares, burned, totalUnits);
            feeShares = sourceShares == 0 ? 0 : Math.mulDiv(protocolShares, rewardShares, sourceShares);
            uint256 funded = Math.mulDiv(_funded(), burned, totalUnits);
            // Split both assets pro rata. Removing only source units from a
            // mixed fund would change the next holder's execution allowance.
            vestedShares[owner] += funded;
            totalVestedShares += funded;
            units[owner] -= burned;
            totalUnits -= burned;
            sourceShares -= rewardShares;
            protocolShares -= feeShares;
            emit RewardsVested(owner, funded);
        }
    }

    function harvestableShares() public view returns (uint256) {
        IYieldVault v = IYieldVault(vault);
        IYieldSource s = v.yieldSource();
        uint256 held = s.sharesOf(vault);
        uint256 equity = s.equityOf(vault) * 1e10;
        if (held == 0 || equity == 0) return 0;
        uint256 protected = s.principalOf(vault);
        uint256 reserved = reservedShares();
        uint256 active = equity - Math.mulDiv(equity, reserved, held);
        return reserved + (active > protected ? Math.mulDiv(active - protected, held, equity) : 0);
    }

    function beginHarvest(uint256 burned) external onlyVault {
        uint256 available = harvestableShares();
        if (harvestUnits != 0 || burned == 0 || burned > available) revert InvalidHarvest();
        harvestUnits = burned;
        uint256 reserved = reservedShares();
        uint256 service = available - reserved;
        uint256 realized = burned > service ? burned - service : 0;
        harvestRewardUnits = reserved == 0 ? 0 : Math.mulDiv(realized, sourceShares, reserved);
        harvestProtocolUnits = realized - harvestRewardUnits;
        sourceShares -= harvestRewardUnits;
        protocolShares -= harvestProtocolUnits;
    }

    function splitHarvest(uint256 collateral) external onlyVault
        returns (uint256 reward, uint256 service, uint256 fee)
    {
        if (harvestUnits == 0) revert InvalidHarvest();
        reward = Math.mulDiv(collateral, harvestRewardUnits, harvestUnits);
        fee = Math.mulDiv(collateral, harvestProtocolUnits, harvestUnits);
        service = collateral - reward - fee;
        uint256 serviceFee = Math.mulDiv(service, _fee(), BPS);
        fee += serviceFee;
        service -= serviceFee;
        harvestUnits = 0;
        harvestRewardUnits = 0;
        harvestProtocolUnits = 0;
    }

    /// @notice Extra cash from servicing funded by the reward fund releases an
    /// equal source claim back to that fund. Keep the existing unit owners;
    /// allocating this release at the next checkpoint would enrich newcomers.
    function retainServicingSurplus(uint256 value) external onlyVault {
        if (value == 0) return;
        IYieldVault v = IYieldVault(vault);
        IYieldSource s = v.yieldSource();
        uint256 held = s.sharesOf(vault);
        uint256 equity = s.equityOf(vault) * 1e10;
        uint256 required = _required();
        if (held == 0 || equity <= required) return;
        uint256 available = Math.mulDiv(equity - required, held, equity);
        uint256 reserved = reservedShares();
        if (available <= reserved) return;
        uint256 added = Math.min(available - reserved, Math.mulDiv(value, held, equity));
        sourceShares += added;
        uint256 basis = s.principalOf(vault);
        uint256 released = Math.min(Math.mulDiv(added, equity, held), basis > required ? basis - required : 0);
        if (released != 0) s.releasePrincipal(vault, released);
    }

    /// @notice Materialize funded collateral shares only. Unconverted reward
    /// units remain owned; a partial claim cannot erase them.
    function claim(address owner, address receiver) external onlyVault returns (uint256 shares) {
        _settle(owner);
        _settle(receiver);
        shares = vestedShares[owner];
        uint256 extra = _claimable(owner);
        uint256 assets = _assets();
        uint256 owned = units[owner];
        IYieldVault v = IYieldVault(vault);
        uint256 burned = extra == 0 ? 0 : Math.min(owned,
            Math.mulDiv(v.mainDebt().quoteHollar(v.convertToAssets(extra)), totalUnits, assets, Math.Rounding.Up));
        units[owner] -= burned;
        totalUnits -= burned;
        totalVestedShares -= shares;
        vestedShares[owner] = 0;
        shares += extra;
        emit RewardClaimed(owner, burned, shares);
    }

    function _claimable(address owner) private view returns (uint256) {
        uint256 owned = balanceOf(owner);
        if (owned == 0 || totalUnits == 0) return 0;
        IYieldVault v = IYieldVault(vault);
        return Math.min(_funded(), v.convertToShares(v.mainDebt().quoteCollateral(Math.mulDiv(_assets(), owned, totalUnits))));
    }

    function claimableShares(address owner) external view returns (uint256) {
        return vestedShares[owner] + _claimable(owner);
    }

    function earnedAssets(address owner) external view returns (uint256) {
        IYieldVault v = IYieldVault(vault);
        return v.convertToAssets(vestedShares[owner]) + (totalUnits == 0 ? 0
            : v.mainDebt().quoteCollateral(Math.mulDiv(_assets(), balanceOf(owner), totalUnits)));
    }
}
