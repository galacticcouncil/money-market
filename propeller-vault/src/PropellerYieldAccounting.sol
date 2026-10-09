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
    function walletOf(address) external view returns (uint256);
}

/// @notice reward units, allocated by a lazy index at equity events, own the fund pro rata: its
/// funded vault shares and its reserved source shares. nobody claims; a holder's funded slice is
/// part of their vault balance and exits fold it in. no operation scans holders.
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
    uint256 public epoch;
    mapping(address => uint256) public accountEpoch;
    mapping(uint256 => uint256) public requestEpoch;
    uint256 public unitScale;
    mapping(address => uint256) public accountScale;
    mapping(uint256 => uint256) public requestScale;
    /// @notice units a redemption took beyond its escrowed shares, burned when it starts
    mapping(uint256 => uint256) public requestUnits;

    error Unauthorized();
    error InvalidHarvest();
    error ExceedsBalance();
    event YieldCheckpoint(uint256 sourceShares, uint256 rewardUnits);
    event RewardsFolded(address indexed owner, uint256 collateralShares);
    event YieldWrittenOff(uint256 indexed epoch);
    event Allocated();

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
        return IYieldVault(vault).walletOf(address(this));
    }

    function _weight(address owner) private view returns (uint256) {
        return IYieldVault(vault).walletOf(owner);
    }

    /// @notice the fund's vault shares attributable to `owner`; part of their vault balance
    function fundedOf(address owner) public view returns (uint256) {
        uint256 total = totalUnits;
        return total == 0 ? 0 : Math.mulDiv(_funded(), balanceOf(owner), total);
    }

    /// @notice the fund's vault shares attributable to unit holders
    function attributed() external view returns (uint256) {
        return totalUnits == 0 ? 0 : _funded();
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

    /// @dev ownership and its fee vest before collateral balances change; a later rate change
    /// can't reassign earlier earnings, though the interest servicing reserve follows it.
    function checkpoint(address from, address to) external onlyVault {
        IYieldVault v = IYieldVault(vault);
        IYieldSource s = v.yieldSource();
        if (harvestUnits != 0 || s.accountingLocked()) revert InvalidHarvest();
        // unallocated source cash or costs leave active cash stale. accounts settle
        // at the current index; allocation waits for pokeSettle.
        if (!v.mainDebt().pendingSourceAccounting()) {
            _allocate(v, s);
            emit Allocated();
        }
        _settle(from);
        if (to != from) _settle(to);
    }

    /// @dev a transfer settles its two holders at the stored index; yield accrued since the last
    /// allocation follows the balances at the next one. a transfer beyond the sender's wallet
    /// moves the units whose funded slice covers the rest, so no third party's balance changes
    function settle(address from, address to, uint256 excess) external onlyVault {
        _settle(from);
        if (to != from) _settle(to);
        if (excess != 0) {
            if (to == address(this) || to == address(0)) revert Unauthorized();
            units[to] += _take(from, excess);
        }
    }

    /// @dev units whose funded slice covers `shares`; they keep their source claim. the owner is settled
    function _take(address owner, uint256 shares) private returns (uint256 taken) {
        uint256 owned = units[owner];
        uint256 slice = owned == 0 ? 0 : Math.mulDiv(_funded(), owned, totalUnits);
        if (shares > slice) revert ExceedsBalance();
        taken = Math.min(owned, Math.mulDiv(owned, shares, slice, Math.Rounding.Up));
        units[owner] = owned - taken;
    }

    /// @dev reads equity, backing and fund value once; nothing below changes them
    function _allocate(IYieldVault v, IYieldSource s) private {
        uint256 held = s.sharesOf(vault);
        uint256 equity = s.equityOf(vault) * 1e10;
        uint256 required = _required();
        uint256 available = equity > required ? Math.mulDiv(equity - required, held, equity) : 0;
        uint256 reserved = reservedShares();
        if (available < reserved) {
            sourceShares = Math.mulDiv(sourceShares, available, reserved);
            protocolShares = available - sourceShares;
            reserved = available;
        }
        uint256 added = available - reserved;
        uint256 supply = _supply();
        bool allocating = held != 0 && supply != 0 && added != 0;
        if (totalUnits == 0 && !allocating) return;
        uint256 funded = _funded();
        uint256 before_ = (held == 0 ? 0 : Math.mulDiv(equity, sourceShares, held))
            + v.mainDebt().quoteHollar(v.convertToAssets(funded));
        if (totalUnits != 0 && before_ == 0) {
            totalUnits = 0;
            rewardIndex = 0;
            unitScale = 0;
            emit YieldWrittenOff(++epoch);
        }
        if (!allocating) return;
        // Main recovery cash or an outside repayment can release source
        // capital. That capital is a gift, not fee-bearing earned yield.
        uint256 basis = s.principalOf(vault);
        uint256 released = Math.min(Math.mulDiv(added, equity, held), basis > required ? basis - required : 0);
        if (released != 0) s.releasePrincipal(vault, released);
        uint256 untaxed = Math.mulDiv(released, held, equity);
        uint256 feeShares = Math.mulDiv(added - untaxed, _fee(), BPS);
        uint256 rewardShares = added - feeShares;
        uint256 value = Math.mulDiv(equity, rewardShares, held);
        uint256 selfValue = Math.mulDiv(value, funded, supply);
        uint256 outsideSupply = supply - funded;
        uint256 outsideValue = value - selfValue;
        uint256 denominator = before_ + selfValue + 1;
        // rescale lazily so loss-then-refill can't inflate units exponentially;
        // precision stays far finer than a base unit and no holder is visited
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

    /// @dev `excess` is what the request takes beyond the escrowed wallet shares, out of the
    /// owner's funded slice; the owner is settled
    function escrow(uint256 id, address owner, uint256 excess) external onlyVault {
        requestIndex[id] = rewardIndex;
        requestEpoch[id] = epoch;
        requestScale[id] = unitScale;
        if (excess != 0) requestUnits[id] = _take(owner, excess);
    }

    function startExit(uint256 id, address owner, uint256 shares) external onlyVault
        returns (uint256 rewardShares, uint256 feeShares, uint256 folded)
    {
        _settle(owner);
        bool current = requestEpoch[id] == epoch;
        uint256 shift = current ? unitScale - requestScale[id] : 0;
        uint256 previous = current ? requestIndex[id] >> shift : 0;
        uint256 burned = current ? requestUnits[id] >> shift : 0;
        units[owner] = Math.min(totalUnits, units[owner] + Math.mulDiv(shares, rewardIndex - previous, RAY));
        delete requestIndex[id];
        delete requestEpoch[id];
        delete requestScale[id];
        delete requestUnits[id];
        if (totalUnits == 0) return (0, 0, 0);
        // the exiting share of the owner's weight takes its units along
        uint256 owned = units[owner];
        uint256 exiting = owned == 0 || shares == 0 ? 0 : Math.mulDiv(owned, shares, _weight(owner) + shares);
        units[owner] = owned - exiting;
        burned = Math.min(totalUnits, burned + exiting);
        if (burned == 0) return (0, 0, 0);
        // split both assets pro rata: the source part funds the exit's own unwind, the funded
        // shares join its escrow before the vault quotes it
        rewardShares = Math.mulDiv(sourceShares, burned, totalUnits);
        feeShares = sourceShares == 0 ? 0 : Math.mulDiv(protocolShares, rewardShares, sourceShares);
        folded = Math.mulDiv(_funded(), burned, totalUnits);
        totalUnits -= burned;
        sourceShares -= rewardShares;
        protocolShares -= feeShares;
        if (folded != 0) IERC20(vault).transfer(vault, folded);
        emit RewardsFolded(owner, folded);
    }

    function harvestableShares() public view returns (uint256) {
        IYieldVault v = IYieldVault(vault);
        // unallocated accounting or an untradeable interest sale: this vault sits
        // the round out instead of harvesting stale units or reverting the batch
        IMainDebt ledger = v.mainDebt();
        if (ledger.pendingSourceAccounting() || ledger.serviceBlocked()) return 0;
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

    /// @notice return a reward-funded servicing surplus to the fund's existing unit owners,
    /// not to whoever joins before the next checkpoint.
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

    /// @notice collateral value of everything `owner`'s units own: the funded slice already in
    /// their balance plus the pending source part
    function earnedAssets(address owner) external view returns (uint256) {
        return totalUnits == 0 ? 0
            : IYieldVault(vault).mainDebt().quoteCollateral(Math.mulDiv(_assets(), balanceOf(owner), totalUnits));
    }
}
