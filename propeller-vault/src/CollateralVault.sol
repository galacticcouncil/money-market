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
import {IMainDebt} from "./interfaces/IMainDebt.sol";
import {PropellerYieldAccounting} from "./PropellerYieldAccounting.sol";
import {ExecutionController} from "./ExecutionController.sol";
import {CompoundLogic, SyntheticFloor} from "./lib/CompoundLogic.sol";

/// @title CollateralVault
/// @notice per-collateral vault: rebalance borrows HOLLAR into the shared loop while a synthetic floor
/// keeps the principal un-liquidatable. realized yield mints separately owned reward shares.
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
    uint256 private constant DEAD_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(0xdead);
    /// @dev Bounds one settle pass so a long funded queue can't exceed block gas.
    uint256 internal constant MAX_SETTLE_PER_CALL = 32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // config
    IERC20 public collateral; // the deposited asset (ETH/tBTC/…)
    IAavePool public pool;
    IYieldSource public yieldSource;
    ISwapper public swapper;
    IERC20 public hollar;
    ISyntheticToken public synthetic;
    IERC20 public collateralAToken; // Aave aToken for the collateral (Main position)
    IERC20 public hollarDebtToken; // Aave variable-debt token for HOLLAR (Main debt)

    // policy params. max LTV and the synthetic LT are read live off the pool: a stored
    // copy would drift from governance and could let a stale INV-1 check pass
    /// @notice max slippage (bps) `compound` tolerates vs the oracle-fair output; 0 fails closed
    uint16 public compoundSlippageBps;
    uint256 public tvlCap; // deposit-side cap (collateral units)
    bool public depositsPaused;

    // accounting
    /// @notice Loop shares this vault holds in the shared SubLoop.
    uint256 public loopShares;
    /// @notice Total synthetic this vault has minted+supplied (tracks Main debt).
    uint256 public syntheticSupplied;
    /// @notice HOLLAR pulled from the loop, not yet applied to settle requests.
    uint256 public availableHollar;
    /// @notice Main HOLLAR debt still to repay from a down-rebalance de-lever
    ///         (settled ahead of the redemption queue as the loop frees HOLLAR).
    uint256 public deleverTarget;

    // async redemption queue
    /// @dev amounts are snapshotted when the unwind starts, so settlement is deterministic
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

    /// @notice Σ(debtShare − repaid) over started redemptions
    uint256 public totalQueuedDebt;

    /// @notice optional Main-debt discount adapter; zero disables it
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
    IMainDebt public mainDebt;
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
        // the admin can pause from block 0; governance may delegate it later
        _grantRole(GUARDIAN_ROLE, _admin);
    }

    /// @notice collateral backing the shares: the Main aToken balance plus settled but unclaimed
    /// collateral (its escrowed shares stay in supply until claim), minus the rounding reserve.
    function totalAssets() public view returns (uint256) {
        // loop equity offsets the Main HOLLAR debt; the synthetic is a non-cash HF prop
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
        return CompoundLogic(compoundLogic).isUnderfunded(address(this));
    }

    function asset() external view returns (address) {
        return address(collateral);
    }

    /// @notice A source emergency freezes every attached vault in one transaction.
    function paused() public view override returns (bool) {
        return super.paused() || yieldSource.emergencyPaused();
    }

    /// @notice Capability marker: deposits mint funded shares without swaps.
    function deferredDeployment() external pure returns (bool) { return true; }

    /// @notice Supply collateral and mint funded shares. No borrowing or swaps
    /// occur here; keepers deploy available collateral through quoted rebalances.
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        if (depositsPaused) revert DepositsArePaused();
        if (assets == 0) revert ZeroAmount();
        if (address(mainDebt) == address(0)) revert ZeroAddress();
        if (deleverTarget != 0) revert Underfunded();
        mainDebt.beforeDeposit();
        yieldAccounting.checkpoint(address(0), receiver);
        if (isUnderfunded()) revert Underfunded();
        // Governance funds the locked initial shares, never the first public user.
        if (totalSupply() == 0 && !hasRole(ADMIN_ROLE, _depositCaller())) revert BootstrapRequired();
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

        Address.functionDelegateCall(compoundLogic, abi.encodeCall(CompoundLogic.deposit, (assets)));
        reinvestAssets += assets;
        _refreshDiscount();
        if (syntheticSupplied * synthLtBps() / BPS < hollarDebtToken.balanceOf(address(this))) revert PrincipalNotFloored();
        _coverRounding(minimumAssets);
        emit Deposited(receiver, assets, shares);
    }

    /// @notice escrow shares for withdrawal; after the cooldown `startUnwinds` quotes and unwinds
    /// them, and `claim` pays the collateral once settled.
    function requestRedeem(uint256 shares, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0 || convertToAssets(shares) == 0) revert ZeroAmount();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        yieldAccounting.checkpoint(owner, address(0));
        _transfer(owner, address(this), shares);
        requestId = queueTail++;
        yieldAccounting.escrow(requestId);
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
        if (deleverTarget != 0 || mainDebt.activeSourceRemaining() != 0) return;
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
        yieldAccounting.checkpoint(address(0), address(0));
        Redemption storage r = redemptions[requestId];
        uint256 shares = r.shares;
        uint256 supply = totalSupply() - totalQueuedShares;

        // Undeployed borrowing capacity follows the exiting funded shares too.
        reinvestAssets -= Math.mulDiv(reinvestAssets, shares, supply);

        // Waiting shares earned yield and incurred debt until this start.
        // The resulting collateral promise stays fixed through settlement.
        uint256 assetsBefore = totalAssets();
        uint256 numerator = (assetsBefore - totalQueuedCollateral) * shares;
        uint256 collateralOwed = Math.ceilDiv(numerator, supply);
        if (collateralOwed == 0) revert ZeroAmount();
        uint256 debt = hollarDebtToken.balanceOf(address(this));
        uint256 debtShare;
        (loopShares, debtShare) = abi.decode(Address.functionDelegateCall(compoundLogic,
            abi.encodeCall(CompoundLogic.startExit, (requestId, r.owner, shares, supply))), (uint256, uint256));
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

    /// @notice pull HOLLAR the loop has freed, then settle started requests FIFO: repay each
    /// Main debt slice, burn its synthetic and make its collateral claimable.
    function pokeSettle() external nonReentrant returns (uint256 work) {
        uint256 debtBefore = hollarDebtToken.balanceOf(address(this));
        uint256 headBefore = queueHead;
        bool accounting = mainDebt.pendingSourceAccounting();
        uint256 assetsBefore = totalAssets();
        uint256 freed = yieldSource.pullFreed();
        hollar.forceApprove(address(mainDebt), freed);
        uint256 executionCost = mainDebt.creditSource(freed);
        // A resize target is expected net source proceeds, not a user debt claim.
        deleverTarget -= Math.min(deleverTarget, executionCost);
        hollar.forceApprove(address(mainDebt), 0);
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
        uint256 end = queueUnwind;
        if (end - head > MAX_SETTLE_PER_CALL) end = head + MAX_SETTLE_PER_CALL;
        while (!paused() && head < end && deleverTarget == 0) {
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
        work = freed + (debtBefore - Math.min(debtBefore, hollarDebtToken.balanceOf(address(this))))
            + head - headBefore + (accounting ? 1 : 0);
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

    /// @notice claim the collateral settled so far, burning only the escrowed shares matching the
    /// payout; the request closes once settlement completes.
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

        // a fully repaid debt slice accrues no more collateral, so this claim is the last
        bool complete = r.repaid >= r.debtShare;

        // burn pro rata to collateral paid on the fixed basis; the final claim burns the rounding dust
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

    /// @notice swap `tokenIn` into collateral rewards after servicing Main interest;
    /// the Harvester calls this with each vault's PRIME cut.
    function compound(address tokenIn, uint256 amountIn, uint256 minCollateralOut, bytes calldata route)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 activeAssets = _activeAssets();
        uint256 supply = totalSupply() - totalQueuedShares;
        (uint256 reward, uint256 serviceRemainder) = abi.decode(Address.functionDelegateCall(compoundLogic,
            abi.encodeCall(CompoundLogic.compound, (tokenIn, amountIn, minCollateralOut, route))), (uint256, uint256));
        if (reward != 0) _mint(address(yieldAccounting), Math.mulDiv(reward, supply, activeAssets + serviceRemainder));
        reinvestAssets += reward + serviceRemainder;
    }

    function prepareHarvest() external nonReentrant whenNotPaused returns (uint256) {
        yieldAccounting.checkpoint(address(0), address(0));
        return yieldAccounting.harvestableShares();
    }

    /// @dev Source calls before burning owned units, inside the atomic harvest.
    function burnYieldShares(uint256 shares) external nonReentrant whenNotPaused {
        if (msg.sender != address(yieldSource)) revert ZeroAddress();
        yieldAccounting.beginHarvest(shares);
        loopShares -= shares;
    }

    function claimYield(address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        yieldAccounting.checkpoint(msg.sender, receiver);
        shares = yieldAccounting.claim(msg.sender, receiver);
        if (shares != 0) _transfer(address(yieldAccounting), receiver, shares);
    }

    /// @notice resize the Main position to the reserve's max LTV after a price move,
    /// growing or shrinking the loop and the synthetic in lockstep.
    function rebalance() external nonReentrant whenNotPaused returns (uint256 work) {
        yieldAccounting.checkpoint(address(0), address(0));
        // not a safety de-lever (the synthetic floors HF). a committed de-lever settles first;
        // waiting or unsettled exits pause price resizing only
        if (deleverTarget != 0) return 0;
        bool exiting = pendingWithdrawalShares != 0 || queueHead != queueUnwind
            || yieldSource.pendingUnwindOf(address(this)) != 0;
        uint256 before_ = loopShares;
        (loopShares, syntheticSupplied, deleverTarget, reinvestAssets) = abi.decode(
            Address.functionDelegateCall(compoundLogic, abi.encodeCall(CompoundLogic.rebalance, (exiting))),
            (uint256, uint256, uint256, uint256));
        _refreshDiscount();
        work = before_ > loopShares ? before_ - loopShares : loopShares - before_;
    }

    /// @notice Keep `synth·LT ≥ Main debt` as the HOLLAR debt accrues interest —
    ///         re-tops the synthetic so the principal stays un-liquidatable.
    function maintainPeg() external nonReentrant returns (uint256 add) {
        uint256 debt = hollarDebtToken.balanceOf(address(this));
        uint256 lt = synthLtBps();
        uint256 required = SyntheticFloor.buffered(debt, lt);
        // refill the 50bp buffer only once half of it is used, not on every wei of interest
        if (syntheticSupplied >= Math.mulDiv(debt, BPS * 10025, lt * 10000, Math.Rounding.Up)) {
            emit SyntheticPegMaintained(0);
            return 0;
        }
        add = required - syntheticSupplied;
        _supplySynth(add);
        emit SyntheticPegMaintained(int256(add));
    }

    /// @dev mint + supply synthetic, explicitly enabled as collateral so the HF floor counts it
    function _supplySynth(uint256 amt) internal {
        syntheticSupplied += amt;
        SyntheticFloor.supply(pool, synthetic, amt);
        // The first borrow precedes synth supply, so GHO initially caches zero.
        _refreshDiscount();
    }

    function _refreshDiscount() internal {
        if (discountController != address(0)) {
            IHollarDiscountDebtToken(address(hollarDebtToken)).rebalanceUserDiscountPercent(address(this));
        }
    }

    /// @notice synthetic reserve liquidation threshold (bps), read live from config bits 16-31.
    /// @dev reverts with SynthReserveNotListed rather than a division panic before listing.
    function synthLtBps() public view returns (uint256 lt) {
        lt = (pool.getConfiguration(address(synthetic)) >> 16) & 0xFFFF;
        if (lt == 0) revert SynthReserveNotListed();
    }

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
        if (from != address(0) && to != address(0) && from != address(this) && to != address(this)
            && from != address(yieldAccounting)) {
            if (_reentrancyGuardEntered()) revert Underfunded();
            yieldAccounting.checkpoint(from, to);
        }
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

    /// @notice Deployment-only wiring; a live settlement ledger cannot be replaced.
    function setMainDebt(address buffer) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (totalSupply() != 0 || address(mainDebt) != address(0)) revert SourceNotEmpty();
        if (buffer == address(0) || IMainDebt(buffer).vault() != address(this)) revert ZeroAddress();
        mainDebt = IMainDebt(buffer);
        yieldAccounting = PropellerYieldAccounting(IMainDebt(buffer).yieldAccounting());
    }

    /// @notice repoint to a new yield source, only while the current one owes this vault nothing.
    /// @dev deploy-time wiring only: dead shares keep loopShares non-zero once funded; live vaults migrate.
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

    /// @notice repoint the swap venue `compound` uses.
    /// @dev safe anytime: the swapper holds no funds across calls and output is checked against an oracle floor.
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

    function _depositCaller() internal view returns (address) {
        return msg.sender == address(executionController) ? executionController.caller() : msg.sender;
    }

    function setExecutionController(address controller) external onlyRole(ADMIN_ROLE) {
        if (controller.code.length == 0 || address(executionController) != address(0)) revert ZeroAddress();
        executionController = ExecutionController(controller);
        emit ExecutionControllerSet(controller);
    }

    event ExecutionControllerSet(address indexed controller);
    uint256[29] private __gap;
    PropellerYieldAccounting public yieldAccounting;
    uint256 public reinvestAssets;
    ExecutionController public executionController;
}
