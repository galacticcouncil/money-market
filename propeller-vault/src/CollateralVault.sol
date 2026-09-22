// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IAavePool} from "./interfaces/IAavePool.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {ISyntheticToken} from "./interfaces/ISyntheticToken.sol";
import {IHollarDiscountDebtToken, IPropellerDiscount} from "./interfaces/IPropellerDiscount.sol";
import {IPropellerFeeController} from "./interfaces/IPropellerFeeController.sol";
import {IOperatingBuffer} from "./interfaces/IOperatingBuffer.sol";
import {CompoundLogic} from "./lib/CompoundLogic.sol";

/// @title CollateralVault
/// @notice One per supported volatile collateral (ETH, tBTC, DOT…). An ERC4626
///         vault: "deposit ETH → pETH shares; redeem → ETH + yield". Non-rebasing
///         exchange-rate model (share value = totalAssets / supply, denominated
///         in the collateral), so harvested yield compounded into the Main
///         position lifts the share price — hence "deposit X, earn more X".
///
/// @dev    Architecture A. On deposit the vault:
///           1. supplies collateral to the Aave money market (Main position),
///           2. borrows HOLLAR at the target LTV,
///           3. mints + supplies SyntheticToken (= HOLLAR debt) → Main HF floored
///              → principal un-liquidatable at any collateral price,
///           4. routes the borrowed HOLLAR into the shared SubLoop.
///         Withdraw reverses it (flash-assisted unwind of the loop slice, repay
///         HOLLAR, burn synthetic, withdraw collateral). A target-LTV band keeps
///         the loop sized to the collateral value as price moves.
///
///         Patterned on HDCLVault.
contract CollateralVault is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;
    uint256 internal constant VARIABLE_RATE = 2;
    uint256 private constant DEAD_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(0xdead);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    // KEEPER_ROLE removed: pokeSettle/compound/rebalance/maintainPeg are permissionless
    // (no caller payout; compound enforces an oracle-fair minOut floor).

    // ── config ────────────────────────────────────────────────────────────
    IERC20 public collateral; // the deposited asset (ETH/tBTC/…)
    IAavePool public pool;
    IYieldSource public yieldSource;
    ISwapper public swapper;
    IERC20 public hollar;
    ISyntheticToken public synthetic;
    IERC20 public collateralAToken; // Aave aToken for the collateral (Main position)
    IERC20 public hollarDebtToken; // Aave variable-debt token for HOLLAR (Main debt)

    // ── policy params (→ governance / pallet-parameters analogue) ───────────
    // target LTV is NOT stored: the vault always runs at the reserve's max LTV,
    // read live off the pool (bits 0-15 of the configuration bitmap). There is
    // no reason to run below it — the synthetic floor, not the LTV, is the
    // liquidation guard — and a stored copy drifts from governance changes.
    /// @dev rebalance hysteresis around the reserve max LTV: re-lever up when
    ///      utilization drifts this far below it, de-lever when this far above
    ///      (only a collateral price drop can push LTV past the max).
    uint16 internal constant LTV_BAND_LOW_GAP_BPS = 500;
    uint16 internal constant LTV_BAND_HIGH_GAP_BPS = 300;
    // The synthetic reserve's liquidation threshold is NOT stored either, for the
    // same reason as the collateral's max LTV: it is a governance-controlled Aave
    // parameter, and a copy taken at `initialize` silently drifts when governance
    // retunes the reserve. That drift is not cosmetic — INV-1 (the un-liquidatable
    // principal guard) is checked as `syntheticSupplied · synthLtBps ≥ mainDebt`
    // against vault storage, so a stale-high copy would let the guard pass while
    // the real Aave floor no longer covers the debt. Read live off bits 16-31 of
    // the reserve configuration bitmap instead; see `_synthLtBps`.
    /// @notice Max slippage (bps) permissionless `compound` tolerates vs the
    ///         oracle-fair output. Default 0 ⇒ fails closed until set.
    uint16 public compoundSlippageBps;
    uint256 public tvlCap; // deposit-side cap (collateral units)
    bool public depositsPaused;

    // ── accounting ──────────────────────────────────────────────────────────
    /// @notice Loop shares this vault holds in the shared SubLoop.
    uint256 public loopShares;
    /// @notice Total synthetic this vault has minted+supplied (tracks Main debt).
    uint256 public syntheticSupplied;
    /// @notice HOLLAR pulled from the loop, not yet applied to settle requests.
    uint256 public availableHollar;
    /// @notice Main HOLLAR debt still to repay from a down-rebalance de-lever
    ///         (settled ahead of the redemption queue as the loop frees HOLLAR).
    uint256 public deleverTarget;

    // ── async redemption queue (HDCL pattern; minimal inline form) ───────────
    /// @dev Production: swap for the audited HDCL QueueLib. Inline here to keep
    ///      the scaffold self-contained. Each request snapshots its share of the
    ///      Main position at request time so settlement is deterministic.
    struct Redemption {
        address owner; // who claims the collateral
        uint256 shares; // pVault shares escrowed
        uint256 collateralOwed; // collateral to release on settle
        uint256 debtShare; // Main HOLLAR debt to repay (≈ loop equity freed)
        uint256 synthShare; // synthetic to release+burn
        uint256 repaid; // Main debt repaid so far (proportional settle)
        uint256 collateralSettled; // collateral freed + ready to claim
        uint256 sharesBurned; // escrowed shares burned across partial claims
        bool active;
    }

    mapping(uint256 => Redemption) public redemptions;
    uint256 public queueHead; // first unsettled request
    uint256 public queueTail; // next request id
    uint256 public totalQueuedShares; // started requests only; waiting shares remain invested

    /// @notice Σ of active queued redemptions' still-owed Main debt (debtShare −
    ///         repaid). Lets `rebalance`'s de-lever branch target only the NON-queued
    ///         debt, so it never repays a queued redeemer's own slice out from under
    ///         them (which would leave `repaid` short of `debtShare` forever and pin
    ///         the FIFO head).
    uint256 public totalQueuedDebt;

    /// @notice Optional Main-debt discount adapter. Zero preserves legacy behavior.
    address public discountController;

    event DiscountControllerUpdated(address indexed previousController, address indexed newController);
    IPropellerFeeController public feeController;
    /// @notice Collateral promised to queued users, including unclaimed settlements.
    uint256 public totalQueuedCollateral;
    mapping(uint256 => uint256) public claimedCollateral;

    uint32 public withdrawalDelay;
    uint256 public queueUnwind;
    uint256 public pendingWithdrawalShares;
    mapping(uint256 => uint256) public unwindEligibleAt;
    /// @notice Donated collateral reserved for rounding, excluded from share backing.
    uint256 public roundingReserve;
    IOperatingBuffer public operatingBuffer;
    address public immutable compoundLogic;

    event RoundingReserveFunded(address indexed donor, uint256 assets);
    event RoundingReserveUsed(uint256 assets);

    event WithdrawalDelayUpdated(uint32 delay);
    event UnwindScheduled(uint256 indexed requestId, uint256 eligibleAt);
    event UnwindStarted(uint256 indexed requestId, uint256 collateralOwed, uint256 debtShare);

    event FeeControllerUpdated(address indexed previousController, address indexed newController);

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event RedeemSettled(uint256 indexed requestId, uint256 collateral);
    event Claimed(uint256 indexed requestId, address indexed receiver, uint256 collateral);
    event Harvested(uint256 collateralCompounded);
    event Rebalanced(uint256 ltvBefore, uint256 ltvAfter);
    event SyntheticPegMaintained(int256 delta);

    error ZeroAddress();
    error ZeroAmount();
    error DepositsArePaused();
    error ExceedsTvlCap();
    error DepositTooSmall();
    error PrincipalShortfall(); // withdraw invariant: collateral out >= collateral in
    error NotRequestOwner();
    error RequestNotActive();
    error NothingToClaim();
    error PrincipalNotFloored(); // INV-1: synth*LT must cover Main debt
    error SourceNotEmpty(); // setYieldSource before the old source is drained
    error NoLoopEquity(); // requestRedeem while the source has nothing to unwind
    error SynthReserveNotListed(); // synthetic has no Aave liquidation threshold yet
    error Underfunded();
    error BootstrapRequired();
    error InvalidDiscountController();
    error InvalidSlippage();
    error Unauthorized(address account, bytes32 role);
    error InsufficientRoundingReserve();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        compoundLogic = address(new CompoundLogic());
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address _collateral,
        address _pool,
        address _yieldSource,
        address _swapper,
        address _hollar,
        address _synthetic,
        address _collateralAToken,
        address _hollarDebtToken,
        uint256 _tvlCap,
        address _admin
    ) external initializer {
        if (_collateral == address(0) || _pool == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        collateral = IERC20(_collateral);
        pool = IAavePool(_pool);
        yieldSource = IYieldSource(_yieldSource);
        swapper = ISwapper(_swapper);
        hollar = IERC20(_hollar);
        synthetic = ISyntheticToken(_synthetic);
        collateralAToken = IERC20(_collateralAToken);
        hollarDebtToken = IERC20(_hollarDebtToken);

        tvlCap = _tvlCap;
        withdrawalDelay = 12 hours;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        // Grant GUARDIAN_ROLE (the emergency pause) to the admin so the pause is
        // never wired to a role nobody holds. Governance can then delegate it to
        // a faster-path holder (the technical committee) and, if desired, revoke
        // its own — but a fresh deploy is always pausable from block 0.
        _grantRole(GUARDIAN_ROLE, _admin);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         CORE ACCOUNTING
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Total collateral-denominated assets backing the shares: the
    ///         vault's net Main-position value (collateral supplied, since the
    ///         synthetic exactly offsets the HOLLAR debt) plus its share of the
    ///         loop equity, valued back into the collateral asset.
    /// @dev    TODO(impl): read the Main aToken balance for `collateral`, and
    ///         convert `yieldSource.equityOf(this)` (HOLLAR) into collateral units
    ///         via the oracle. The synthetic↔debt offset nets to ~0 by design.
    function totalAssets() public view returns (uint256) {
        // Net principal in collateral units ≈ the collateral supplied to the
        // Main position: the loop equity offsets the Main HOLLAR debt (the
        // borrowed HOLLAR became the loop seed), and the synthetic is a non-cash
        // HF prop. Harvested yield is supplied as more collateral → aToken grows
        // → share price rises ("deposit X, earn X").
        //
        // Also count collateral settled out of Aave but not yet claimed: pokeSettle
        // withdraws a redeemer's collateral into this vault while their escrowed
        // shares stay in totalSupply until claim. Omitting it would drop totalAssets
        // at settle with supply unchanged, understating the share price for the whole
        // settle→claim window (mis-minting deposits made in it). At rest the raw
        // balance is exactly that settled-but-unclaimed collateral — deposit/compound
        // pull-and-resupply within one nonReentrant call, so nothing else lingers.
        return collateralAToken.balanceOf(address(this)) + collateral.balanceOf(address(this)) - roundingReserve;
    }

    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply() - totalQueuedShares;
        if (supply == 0) return WAD;
        return (_activeAssets() * WAD) / supply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply() - totalQueuedShares;
        uint256 totalA = _activeAssets();
        if (supply == 0 || totalA == 0) return assets;
        return (assets * supply) / totalA;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply() - totalQueuedShares;
        if (supply == 0) return shares;
        return (shares * _activeAssets()) / supply;
    }

    function _activeAssets() internal view returns (uint256) {
        uint256 assets = totalAssets();
        return assets > totalQueuedCollateral ? assets - totalQueuedCollateral : 0;
    }

    /// @notice A deficit freezes entry, never reduces existing principal claims.
    /// The source reports USD8 equity; HOLLAR is the market's $1, 18dp unit.
    function isUnderfunded() public view returns (bool) {
        if (totalAssets() < totalQueuedCollateral) return true;
        uint256 debt = hollarDebtToken.balanceOf(address(this));
        if (debt == 0) return false;
        uint256 backing8 = yieldSource.equityOf(address(this))
            + (yieldSource.pendingUnwindOf(address(this)) + hollar.balanceOf(address(this))) / 1e10;
        if (address(operatingBuffer) != address(0)) {
            if (operatingBuffer.activeUnderfunded()) return true;
            backing8 += operatingBuffer.ownedCash() / 1e10;
        }
        return yieldSource.negativeCarryBps() != 0 || backing8 < debt / 1e10;
    }

    function asset() external view returns (address) {
        return address(collateral);
    }

    /// @notice A source emergency freezes every attached vault in one transaction.
    function paused() public view override returns (bool) {
        return super.paused() || yieldSource.emergencyPaused();
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         USER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    /// @notice ERC4626 deposit. Pulls `assets` collateral, opens/extends the
    ///         leveraged position, mints shares to `receiver`.
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        if (depositsPaused) revert DepositsArePaused();
        if (assets == 0) revert ZeroAmount();
        if (address(operatingBuffer) == address(0)) revert ZeroAddress();
        if (deleverTarget != 0) revert Underfunded();
        uint256 debtBefore = operatingBuffer.beforeDeposit();
        if (isUnderfunded()) revert Underfunded();
        // Governance funds the locked initial shares, never the first public user.
        if (totalSupply() == 0 && !hasRole(ADMIN_ROLE, msg.sender)) revert BootstrapRequired();
        // one aToken balanceOf for both the cap check and share pricing
        uint256 totalA = totalAssets();
        if (totalA + assets > tvlCap) revert ExceedsTvlCap();

        uint256 supply = totalSupply() - totalQueuedShares;
        shares = _previewShares(assets, totalA - totalQueuedCollateral, supply);
        // Round in the depositor's favor without diluting existing holders.
        uint256 minimumAssets = totalA + (supply == 0 ? assets
            : Math.ceilDiv(shares * (totalA - totalQueuedCollateral), supply));
        if (totalSupply() == 0) _mint(DEAD_ADDRESS, DEAD_SHARES);
        _mint(receiver, shares);

        // 1. Supply the collateral to the Main Aave position.
        (uint256 collBefore8,,,,,) = pool.getUserAccountData(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), assets);
        collateral.forceApprove(address(pool), assets);
        pool.supply(address(collateral), assets, address(this), 0);

        // 2. Borrow HOLLAR at the reserve's max LTV against the collateral JUST
        //    supplied — the DELTA in account collateral value, not the total.
        //    Sizing off the total over-borrows on incremental deposits (the
        //    existing position, incl. the synthetic, inflates collBase8) →
        //    Aave error 36 COLLATERAL_CANNOT_COVER_NEW_BORROW.
        //    (collateral USD 8dp → HOLLAR 18dp @ $1.)
        (uint256 collAfter8,,,,,) = pool.getUserAccountData(address(this));
        uint256 borrowHollar = ((collAfter8 - collBefore8) * _maxLtvBps()) / BPS * 1e10;

        pool.borrow(address(hollar), borrowHollar, VARIABLE_RATE, 0, address(this));

        // 3. Mint synthetic sized so synth·LT > debt — floors the Main HF
        //    strictly ABOVE 1 from the synthetic *alone*, so the principal is
        //    un-liquidatable at any collateral price (the +0.5% buffer keeps it
        //    clear of the boundary through rounding/8dp-base truncation).
        uint256 lt = synthLtBps(); // live off the reserve, never a stored copy
        _supplySynth(_bufferedSynthetic(borrowHollar, lt));

        // 4. Route the borrowed HOLLAR into the shared loop.
        hollar.forceApprove(address(yieldSource), borrowHollar);
        loopShares += yieldSource.deposit(borrowHollar);
        operatingBuffer.borrowed(debtBefore, shares, supply);

        // INV-1 (on-chain guard): the synthetic alone must cover the Main debt,
        // so the principal is un-liquidatable at any collateral price.
        if (syntheticSupplied * lt / BPS < hollarDebtToken.balanceOf(address(this))) {
            revert PrincipalNotFloored();
        }
        _coverRounding(minimumAssets);
        emit Deposited(receiver, assets, shares);
    }

    /// @notice Escrow shares until their cooldown expires. A permissionless
    ///         startUnwinds call then snapshots the position and asks the source
    ///         to unwind. Claim collateral via `claim` once settled.
    /// @dev    Async because the loop unwinds gradually via DCA (see SubLoop).
    function requestRedeem(uint256 shares, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0 || convertToAssets(shares) == 0) revert ZeroAmount();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _transfer(owner, address(this), shares);
        requestId = queueTail++;
        Redemption storage r = redemptions[requestId];
        r.owner = owner;
        r.shares = shares;
        r.active = true;
        pendingWithdrawalShares += shares;
        uint256 eligibleAt = block.timestamp + withdrawalDelay;
        unwindEligibleAt[requestId] = eligibleAt;
        emit RedeemRequested(requestId, owner, shares);
        emit UnwindScheduled(requestId, eligibleAt);
    }

    /// @notice Start up to `maxRequests` eligible withdrawals in FIFO order.
    /// Waiting shares remain invested; collateral and debt are quoted at start.
    function startUnwinds(uint256 maxRequests) external nonReentrant whenNotPaused {
        // Complete the active cohort's Main resize before allocating an exit.
        if (deleverTarget != 0 || operatingBuffer.activeSourceRemaining() != 0) return;
        uint256 next = queueUnwind;
        while (next < queueTail && maxRequests != 0) {
            if (block.timestamp < unwindEligibleAt[next]) break;
            _startUnwind(next);
            ++next;
            --maxRequests;
        }
        queueUnwind = next;
    }

    function _startUnwind(uint256 requestId) internal {
        Redemption storage r = redemptions[requestId];
        uint256 shares = r.shares;
        uint256 supply = totalSupply() - totalQueuedShares;

        // Waiting shares earned yield and incurred debt until this start.
        // The resulting collateral promise stays fixed through settlement.
        uint256 assetsBefore = totalAssets();
        uint256 numerator = (assetsBefore - totalQueuedCollateral) * shares;
        uint256 collateralOwed = Math.ceilDiv(numerator, supply);
        if (collateralOwed == 0) revert ZeroAmount();
        uint256 debt = hollarDebtToken.balanceOf(address(this));
        uint256 loopSlice = (loopShares * shares) / supply;
        uint256 pending = yieldSource.pendingUnwindOf(address(this));

        // Ask the shared loop to unwind this vault's proportional equity slice.
        if (loopSlice != 0) {
            loopShares -= loopSlice;
            yieldSource.requestUnwind(loopSlice);
        }
        uint256 debtShare = operatingBuffer.startExit(requestId, r.owner, shares, supply,
            yieldSource.pendingUnwindOf(address(this)) - pending);
        if (loopSlice == 0 && debtShare != 0) revert NoLoopEquity();
        uint256 synthShare = debt == 0 ? 0 : (syntheticSupplied * debtShare) / debt;

        // A split exit must not lose a base unit or charge it to remaining holders.
        _coverRounding(assetsBefore + collateralOwed - numerator / supply);
        r.collateralOwed = collateralOwed;
        r.debtShare = debtShare;
        r.synthShare = synthShare;
        pendingWithdrawalShares -= shares;
        totalQueuedShares += shares;
        totalQueuedDebt += debtShare;
        totalQueuedCollateral += collateralOwed;
        emit UnwindStarted(requestId, collateralOwed, debtShare);
    }

    /// @notice Keeper settlement: pull equity HOLLAR the SubLoop's deleveraging
    ///         spiral has freed, then settle queued requests FIFO. For each
    ///         request, repay its Main debt slice, release+burn its synthetic,
    ///         withdraw its collateral, and mark it claimable.
    function pokeSettle() external nonReentrant {
        uint256 assetsBefore = totalAssets();
        uint256 freed = yieldSource.pullFreed();
        hollar.forceApprove(address(operatingBuffer), freed);
        operatingBuffer.creditSource(freed);
        hollar.forceApprove(address(operatingBuffer), 0);
        // Unsolicited recovery funding is not a deposit and receives no shares.
        availableHollar = hollar.balanceOf(address(this));

        // Already committed de-lever debt is excluded from new request snapshots.
        if (deleverTarget > 0) {
            (,uint256 repaid) = _repayMain(0, deleverTarget, availableHollar);
            deleverTarget -= Math.min(deleverTarget, repaid);
        } else {
            _repayMain(0, 0, queueHead == queueUnwind ? availableHollar : 0);
        }
        if (hollarDebtToken.balanceOf(address(this)) == 0) deleverTarget = 0;

        uint256 head = queueHead;
        while (!paused() && head < queueUnwind && deleverTarget == 0) {
            // A claim closes only after settlement has advanced past this head.
            Redemption storage r = redemptions[head];
            uint256 remainingDebt = r.debtShare - r.repaid;
            if (remainingDebt != 0) {
                (uint256 paid,) = _repayMain(head + 1, remainingDebt, availableHollar);
                if (paid > remainingDebt) paid = remainingDebt;
                r.repaid += paid;
                totalQueuedDebt -= paid;
            }
            uint256 entitled = r.repaid == r.debtShare
                ? r.collateralOwed : (r.collateralOwed * r.repaid) / r.debtShare;
            uint256 collRel = entitled - claimedCollateral[head] - r.collateralSettled;
            if (collRel != 0) {
                uint256 supplied = collateralAToken.balanceOf(address(this));
                uint256 withdraw = collRel < supplied ? collRel : supplied;
                if (withdraw != 0) pool.withdraw(address(collateral), withdraw, address(this));
                r.collateralSettled += collRel;
            }

            emit RedeemSettled(head, collRel);
            if (r.repaid >= r.debtShare) head++;
            else break; // wait for more freed equity
        }
        queueHead = head;
        // Aave's scaled aToken burn can cost an additional collateral base unit.
        _coverRounding(assetsBefore);
        _refreshDiscount();
    }

    /// @dev Use actual repayments and the live synthetic/debt ratio. Frozen
    /// snapshots can over-burn synthetic after another repayment or peg top-up.
    function _repayMain(uint256 key, uint256 amount, uint256 recovery)
        internal returns (uint256 principalPaid, uint256 paid)
    {
        uint256 burn;
        (principalPaid, burn, paid) = abi.decode(Address.functionDelegateCall(compoundLogic,
            abi.encodeCall(CompoundLogic.repay, (key, amount, recovery))), (uint256, uint256, uint256));
        availableHollar -= recovery;
        syntheticSupplied -= burn;
    }

    /// @notice Claim collateral settled so far for a request. Partial-claim
    ///         safe: a request settles proportionally over blocks, so `claim`
    ///         pays whatever is currently ready, burns ONLY the escrowed shares
    ///         matching that payout, and keeps the request active so the
    ///         unsettled remainder stays claimable. The request closes (and any
    ///         rounding-dust shares are burned) only once settlement is complete
    ///         and the last ready slice has been claimed.
    function claim(uint256 requestId, address receiver) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (receiver == address(0)) revert ZeroAddress();
        Redemption storage r = redemptions[requestId];
        if (!r.active) revert RequestNotActive();
        if (msg.sender != r.owner) revert NotRequestOwner();
        amountOut = r.collateralSettled;
        if (amountOut == 0) revert NothingToClaim();

        r.collateralSettled = 0;
        claimedCollateral[requestId] += amountOut;
        totalQueuedCollateral -= amountOut;

        // Settlement is complete once the Main debt slice is fully repaid — no
        // further collateral will ever accrue to this request, so this claim is
        // the last one.
        bool complete = r.repaid >= r.debtShare;

        // Burn escrowed shares in proportion to the collateral paid, against the
        // fixed (shares, collateralOwed) basis: Σ over all claims of
        // shares·amountOut/collateralOwed == shares, so partial claims never
        // over- or under-burn. On the final claim, burn whatever residual
        // remains so floor-rounding dust never strands shares.
        uint256 burnNow;
        uint256 remaining = r.shares - r.sharesBurned;
        if (complete) {
            burnNow = remaining;
            r.active = false;
        } else {
            burnNow = (r.shares * claimedCollateral[requestId]) / r.collateralOwed - r.sharesBurned;
        }
        r.sharesBurned += burnNow;

        totalQueuedShares -= burnNow;
        _burn(address(this), burnNow);
        collateral.safeTransfer(receiver, amountOut);
        emit Claimed(requestId, receiver, amountOut);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         KEEPER OPERATIONS
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Compound this vault's share of harvested loop carry into the
    ///         collateral, lifting the share price ("deposit X, earn X"). The
    ///         Harvester pulls the vault's cut from the loop and calls this with
    ///         the harvested token (PRIME) to swap into collateral and supply.
    function compound(address tokenIn, uint256 amountIn, uint256 minCollateralOut, bytes calldata route)
        external
        nonReentrant
        whenNotPaused
    {
        Address.functionDelegateCall(compoundLogic,
            abi.encodeCall(CompoundLogic.compound, (tokenIn, amountIn, minCollateralOut, route)));
    }

    /// @notice Rebalance the Main position back to the reserve's max LTV after a
    ///         collateral price move: borrow more (price up) or repay (price down),
    ///         growing/shrinking the loop and the synthetic in lockstep.
    function rebalance() external nonReentrant whenNotPaused {
        // Main resizing is not a safety de-lever: the synthetic floors its HF.
        // Finish existing commitments first; SubLoop safety repayment stays live.
        if (pendingWithdrawalShares != 0 || totalQueuedShares != 0 || deleverTarget != 0
            || yieldSource.pendingUnwindOf(address(this)) != 0) return;
        // Isolate the collateral leg's LTV: collBase8 = ETH value + synth value,
        // and synth value = syntheticSupplied (both $1), so ETH value backs out
        // without a separate oracle ref. (Requires the synth to actually count
        // as collateral — i.e. a reserve LTV > 0 and the use-as-collateral flag
        // on; _supplySynth enforces the flag.)
        (uint256 collBase8, uint256 debtBase8,,,,) = pool.getUserAccountData(address(this));
        uint256 synthValue8 = syntheticSupplied / 1e10;
        uint256 ethValue8 = collBase8 > synthValue8 ? collBase8 - synthValue8 : 0;
        if (ethValue8 == 0) return;
        uint256 ltvBefore = (debtBase8 * BPS) / ethValue8;
        uint256 maxLtv = _maxLtvBps();

        if (ltvBefore + LTV_BAND_LOW_GAP_BPS < maxLtv) {
            if (isUnderfunded()) revert Underfunded();
            uint256 debtBefore = operatingBuffer.beforeDeposit();
            // Collateral appreciated → borrow up to the max and deploy the slack,
            // so the yield notional tracks the collateral value.
            uint256 targetDebt8 = (ethValue8 * maxLtv) / BPS;
            uint256 addHollar = (targetDebt8 - debtBase8) * 1e10;
            if (addHollar == 0) return;
            pool.borrow(address(hollar), addHollar, VARIABLE_RATE, 0, address(this));

            uint256 lt = synthLtBps();
            _supplySynth(_bufferedSynthetic(addHollar, lt));

            hollar.forceApprove(address(yieldSource), addHollar);
            loopShares += yieldSource.deposit(addHollar);
            operatingBuffer.borrowed(debtBefore, 0, 0);
        } else if (ltvBefore > maxLtv + LTV_BAND_HIGH_GAP_BPS) {
            // Collateral fell → over-levered on the real ETH. De-lever: unwind the
            // loop slice that frees the excess debt's worth of equity; `pokeSettle`
            // repays Main debt + burns synth from it (ahead of the redeem queue).
            // NOT safety-critical — the synthetic still floors Main HF ≥ 1; this
            // restores the real-collateral backing ratio (and trims yield-side risk).
            uint256 targetDebt8 = (ethValue8 * maxLtv) / BPS;
            uint256 repay8 = debtBase8 - targetDebt8;

            // CAP 2 — never queue more than the loop slice can actually free. The
            // slice is capped at `loopShares`, so an uncapped `repay8` above the
            // vault's whole loop equity leaves a permanently unfundable target that
            // pokeSettle keeps consuming ahead of the FIFO queue.
            uint256 loopEq8 = yieldSource.equityOf(address(this));
            if (repay8 > loopEq8) repay8 = loopEq8;

            uint256 sliceShares = loopEq8 == 0 ? 0 : (loopShares * repay8) / loopEq8;
            if (sliceShares > 0) {
                uint256 pending = yieldSource.pendingUnwindOf(address(this));
                loopShares -= sliceShares;
                yieldSource.requestUnwind(sliceShares);
                // Share and USD rounding can promise less than the nominal quote.
                deleverTarget = yieldSource.pendingUnwindOf(address(this)) - pending;
                operatingBuffer.expectDelever(deleverTarget);
            }
        }
        emit Rebalanced(ltvBefore, (hollarDebtToken.balanceOf(address(this)) / 1e10 * BPS) / ethValue8);
    }

    /// @notice Keep `synth·LT ≥ Main debt` as the HOLLAR debt accrues interest —
    ///         re-tops the synthetic so the principal stays un-liquidatable.
    function maintainPeg() external nonReentrant {
        uint256 debt = hollarDebtToken.balanceOf(address(this));
        uint256 lt = synthLtBps();
        uint256 required = _bufferedSynthetic(debt, lt);
        if (syntheticSupplied >= required) {
            emit SyntheticPegMaintained(0);
            return;
        }
        uint256 add = required - syntheticSupplied;
        _supplySynth(add);
        emit SyntheticPegMaintained(int256(add));
    }

    function _bufferedSynthetic(uint256 debt, uint256 lt) internal pure returns (uint256 amount) {
        amount = Math.ceilDiv(debt * BPS, lt);
        amount += amount / 200;
    }

    /// @dev Mint + supply `amt` synthetic and make sure it COUNTS: Aave only
    ///      auto-enables an asset as collateral on the very first supply (and
    ///      only when its reserve LTV > 0), so without the explicit enable the
    ///      synth sits outside totalCollateralBase and the HF floor is inert.
    ///      A failed enable must revert the entire operation: storage balances
    ///      alone are not proof that Aave counts the synthetic collateral.
    function _supplySynth(uint256 amt) internal {
        syntheticSupplied += amt;
        synthetic.mint(address(this), amt);
        IERC20(address(synthetic)).forceApprove(address(pool), amt);
        pool.supply(address(synthetic), amt, address(this), 0);
        pool.setUserUseReserveAsCollateral(address(synthetic), true);
        // The first borrow precedes synth supply, so GHO initially caches zero.
        _refreshDiscount();
    }

    function _refreshDiscount() internal {
        if (discountController != address(0)) {
            IHollarDiscountDebtToken(address(hollarDebtToken)).rebalanceUserDiscountPercent(address(this));
        }
    }

    /// @dev The collateral reserve's max LTV (bps) — bits 0-15 of the Aave
    ///      reserve configuration bitmap. Read live so the vault auto-follows
    ///      any governance change; never stored.
    function _maxLtvBps() internal view returns (uint256) {
        return pool.getConfiguration(address(collateral)) & 0xFFFF;
    }

    /// @notice The synthetic reserve's liquidation threshold (bps) — bits 16-31 of
    ///         the Aave reserve configuration bitmap, read live.
    /// @dev    Every synthetic sizing (`deposit`, `rebalance`, `maintainPeg`) and
    ///         the INV-1 floor guard divide by this, so a zero would panic. It IS
    ///         zero before the governance proposal lists the synthetic reserve —
    ///         reverting there is correct (the floor cannot be established yet), but
    ///         it should say so rather than panic.
    function synthLtBps() public view returns (uint256 lt) {
        lt = (pool.getConfiguration(address(synthetic)) >> 16) & 0xFFFF;
        if (lt == 0) revert SynthReserveNotListed();
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         INTERNAL / ADMIN
    // ══════════════════════════════════════════════════════════════════════

    function _previewShares(uint256 assets, uint256 totalA, uint256 supply) internal pure returns (uint256 shares) {
        if (supply == 0) {
            if (assets <= DEAD_SHARES) revert DepositTooSmall();
            return assets - DEAD_SHARES;
        }
        if (totalA == 0) revert Underfunded();
        shares = Math.ceilDiv(assets * supply, totalA);
    }

    /// @notice Donate collateral for rounding. No shares or withdrawal rights are minted.
    /// Funding remains available during an emergency freeze.
    function fundRoundingReserve(uint256 assets) external nonReentrant {
        uint256 before = totalAssets();
        collateral.safeTransferFrom(msg.sender, address(this), assets);
        roundingReserve += assets;
        if (totalAssets() != before) revert PrincipalShortfall();
        emit RoundingReserveFunded(msg.sender, assets);
    }

    function _coverRounding(uint256 minimumAssets) internal {
        uint256 current = totalAssets();
        if (current >= minimumAssets) return;
        uint256 shortfall = minimumAssets - current;
        if (shortfall > roundingReserve) revert InsufficientRoundingReserve();
        roundingReserve -= shortfall;
        emit RoundingReserveUsed(shortfall);
    }

    function setTvlCap(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        tvlCap = newCap;
    }

    /// @notice Seconds before new requests may start unwinding. Zero disables the wait.
    function setWithdrawalDelay(uint32 delay) external onlyRole(ADMIN_ROLE) {
        withdrawalDelay = delay;
        emit WithdrawalDelayUpdated(delay);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    /// @notice Opt into an approved adapter, or detach without leaving a cached
    ///         discount behind. Enrollment remains a separate governance action.
    function setDiscountController(address controller) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (controller != address(0)) {
            IPropellerDiscount policy = IPropellerDiscount(controller);
            if (address(policy.debtToken()) != address(hollarDebtToken) || policy.synthetic() != address(synthetic)) {
                revert InvalidDiscountController();
            }
        }
        address previous = discountController;
        discountController = controller;
        if (previous != address(0) || controller != address(0)) {
            IHollarDiscountDebtToken(address(hollarDebtToken)).rebalanceUserDiscountPercent(address(this));
        }
        emit DiscountControllerUpdated(previous, controller);
    }

    function setFeeController(address controller) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (controller == address(0)) revert ZeroAddress();
        emit FeeControllerUpdated(address(feeController), controller);
        feeController = IPropellerFeeController(controller);
    }

    /// @notice Deployment-only wiring; a live buffer cannot be replaced or swept.
    function setOperatingBuffer(address buffer) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (totalSupply() != 0 || address(operatingBuffer) != address(0)) revert SourceNotEmpty();
        if (buffer == address(0) || IOperatingBuffer(buffer).vault() != address(this)) revert ZeroAddress();
        operatingBuffer = IOperatingBuffer(buffer);
    }

    /// @notice Repoint the vault to a new yield source. Allowed only when the
    ///         current source owes this vault NOTHING — no live shares, nothing
    ///         freed-but-unpulled, no in-flight unwind — so no funds can be
    ///         stranded in the abandoned source.
    ///
    /// @dev    This is a DEPLOY-TIME WIRING LEVER, not a migration path. It is
    ///         satisfiable only before any deposit has routed HOLLAR into a source
    ///         — e.g. to correct a vault deployed against a placeholder address.
    ///
    ///         It is NOT reachable again once the vault has been funded, and that is
    ///         deliberate: `DEAD_SHARES` are permanently locked in `totalSupply`, so
    ///         every `requestRedeem` sizes its loop slice as `loopShares · shares /
    ///         supply` and always leaves the dead shares' proportional slice behind.
    ///         `loopShares` therefore never returns to exactly 0 on a funded vault.
    ///
    ///         Deliberately strict — `pending == 0` exactly, no dust tolerance. A
    ///         relative tolerance existed alongside an `adminUnwind()` force-unwind
    ///         path; both were removed. The tolerance scaled with position size
    ///         rather than being true dust (0.1% of notional), so it could abandon
    ///         real HOLLAR that `SubLoop` has no sweep to recover, and the
    ///         force-unwind paused the vault with no bare-collateral exit, locking
    ///         non-redeeming holders behind a guard that realized slippage could
    ///         make unsatisfiable.
    ///
    ///         To change the yield source of a LIVE vault, deploy a new vault
    ///         pointed at the new source and let holders migrate through the normal
    ///         redemption queue. There is no in-place migration.
    function setYieldSource(address newSource) external onlyRole(ADMIN_ROLE) {
        if (newSource == address(0)) revert ZeroAddress();
        // Sweep any last freed HOLLAR out of the old source before abandoning it.
        availableHollar += yieldSource.pullFreed();
        if (
            loopShares != 0 || yieldSource.sharesOf(address(this)) != 0
                || yieldSource.pendingUnwindOf(address(this)) != 0
        ) {
            revert SourceNotEmpty();
        }
        yieldSource = IYieldSource(newSource);
    }

    /// @notice Repoint the swap venue used by `compound` to convert harvested carry
    ///         into this vault's collateral.
    /// @dev    REQ-SWAP (HydraAugustus) is an external dependency in a separate repo
    ///         and is not deployed on Hydration mainnet, so the deploy scripts pass
    ///         the governance precompile as a placeholder. Without this setter the
    ///         only way to point at the real swapper — or to move off a broken or
    ///         superseded one — would be a UUPS upgrade of every CollateralVault.
    ///
    ///         Safe to rotate at any time: the swapper never custodies vault funds
    ///         across calls (`compound` approves, swaps, and re-checks the output
    ///         against an oracle-fair floor within one `nonReentrant` call), so a
    ///         repoint cannot strand anything. A hostile swapper can at worst fail
    ///         the `out < floor` check and revert.
    function setSwapper(address newSwapper) external onlyRole(ADMIN_ROLE) {
        if (newSwapper == address(0)) revert ZeroAddress();
        swapper = ISwapper(newSwapper);
    }

    /// @notice Max slippage (bps) tolerated by permissionless `compound` vs the
    ///         oracle-fair output. Default 0 ⇒ fails closed until set.
    function setCompoundSlippageBps(uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (bps >= BPS) revert InvalidSlippage();
        compoundSlippageBps = bps;
    }

    function pauseDeposits() external onlyRole(GUARDIAN_ROLE) {
        depositsPaused = true;
    }

    function unpauseDeposits() external onlyRole(GUARDIAN_ROLE) {
        depositsPaused = false;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /// @dev Keep role checks without embedding AccessControl's hex-string formatter.
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) revert Unauthorized(account, role);
    }

    uint256[29] private __gap;
}
