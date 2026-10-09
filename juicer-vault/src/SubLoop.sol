// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {ISubLoop} from "./interfaces/ISubLoop.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IYieldSource, ILeveragedLoop} from "./interfaces/IYieldSource.sol";
import {ExecutionController} from "./ExecutionController.sol";
import {SubLoopStorage, SubLoopLogic} from "./lib/SubLoopLogic.sol";

interface ISourceYieldVault {
    function burnYieldShares(uint256 shares) external;
    function yieldAccounting() external view returns (address);
}

/// @title SubLoop
/// @notice the shared leveraged PRIME/HOLLAR loop (aave isolation mode). `pokeBorrow` ramps it in and
/// `pokeRepay` unwinds it with bounded, oracle-priced router sales; no flash loans.
/// @dev the ramp, the unwind spiral and the de-lever run in `logic` by delegatecall (EIP-170 room).
contract SubLoop is ISubLoop, SubLoopStorage {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Registered CollateralVaults — the only callers of deposit/unwind.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    /// @notice may pass a keeper quote: an unfillable quote would park an intent until it expires
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice delegatecall target for the execution paths, deployed with this implementation
    address public immutable logic;

    event EmergencyPauseUpdated(bool paused);

    modifier whenNotEmergencyPaused() {
        if (_emergencyPaused) revert EmergencyPaused();
        _;
    }

    /// @dev settle a fill or refund that already arrived, then re-measure after the loop's own transfers
    modifier settlesIntents() {
        if (pendingIntent.kind != 0) _delegate(abi.encodeCall(SubLoopLogic.settleArrived, ()));
        _;
        _rebase();
    }

    event LoopDeposited(address indexed vault, uint256 hollarIn, uint256 shares);
    event UnwindRequested(address indexed vault, uint256 shares, uint256 equity, uint256 unwindId);
    event FreedPulled(address indexed vault, uint256 hollar);
    event Harvested(uint256 surplus);

    error ZeroAmount();
    error ZeroAddress();
    error HealthyEnough();
    error InsufficientShares();
    error NotHarvester();
    error Underfunded();
    error InvalidParameters();
    error EmergencyPaused();
    error IntentRejected();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        logic = address(new SubLoopLogic());
        _disableInitializers();
    }

    function initialize(
        address _pool,
        address _hollar,
        address _prime,
        address _primeAToken,
        uint256 _targetHf,
        uint256 _deLeverTrigger,
        address _admin
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        pool = IAavePool(_pool);
        hollar = IERC20(_hollar);
        prime = IERC20(_prime);
        primeAToken = IERC20(_primeAToken);

        targetHf = _targetHf;
        deLeverTrigger = _deLeverTrigger;
        deployHfFloor = _targetHf; // borrow down to target; swap lag keeps actual HF above
        harvestThreshold = 1e15; // 0.1%

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        // the admin can pause from block 0; governance may delegate it later
        _grantRole(GUARDIAN_ROLE, _admin);
    }

    /// @inheritdoc IYieldSource
    function deposit(uint256 hollarAmount)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        whenNotPaused
        whenNotEmergencyPaused
        settlesIntents
        returns (uint256 shares)
    {
        if (hollarAmount == 0) revert ZeroAmount();
        if (deployTranche != 0 && hollarAmount > deployTranche) revert InvalidParameters();
        // Pending withdrawals are liabilities, not backing for live shares.
        // Quote before pulling cash, which is itself included in totalEquity.
        uint256 gross18 = _totalEquity() * 1e10;
        if (gross18 < unwindTargetEquity) revert Underfunded();
        uint256 equityBasis18 = gross18 - unwindTargetEquity;
        if (_totalShares != 0 && equityBasis18 == 0) revert Underfunded();
        shares = (_totalShares == 0 || equityBasis18 == 0)
            ? hollarAmount
            : (hollarAmount * _totalShares) / equityBasis18;
        if (shares == 0) revert ZeroAmount();
        hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
        _sharesOf[msg.sender] += shares;
        _totalShares += shares;
        principalEquity += hollarAmount; // cost basis (seed)
        _principalOf[msg.sender] += hollarAmount;

        // future: match against open unwinds before selling (README, future improvements)
        // with intents the HOLLAR waits as cash for the next ramp step's entry
        if (intentTtl == 0) _delegate(abi.encodeCall(SubLoopLogic.fundDeploy, (hollarAmount)));
        emit LoopDeposited(msg.sender, hollarAmount, shares);
    }

    /// @inheritdoc IYieldSource
    function requestUnwind(uint256 shares)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        whenNotEmergencyPaused
        settlesIntents
        returns (uint256 unwindId)
    {
        return _requestUnwind(shares, Math.mulDiv(_principalOf[msg.sender], shares, _sharesOf[msg.sender]));
    }

    function requestUnwindProtected(uint256 shares, uint256 basis)
        external override onlyRole(VAULT_ROLE) nonReentrant whenNotEmergencyPaused settlesIntents returns (uint256)
    {
        return _requestUnwind(shares, basis);
    }

    function _requestUnwind(uint256 shares, uint256 protectedBasis) private returns (uint256 unwindId) {
        uint256 held = _sharesOf[msg.sender];
        if (shares == 0) revert ZeroAmount();
        if (shares > held) revert InsufficientShares();

        uint256 totalSharesBefore = _totalShares;
        // Equity (8dp USD) of this slice → HOLLAR (18dp, $1) for payout accounting.
        uint256 equityHollar = (_liveEquity18() * shares) / totalSharesBefore;
        if (equityHollar == 0) revert Underfunded();

        uint256 basis = Math.min(_principalOf[msg.sender], protectedBasis);
        _principalOf[msg.sender] -= basis;
        principalEquity -= basis;
        if (equityHollar > basis) unwindYieldAllowance[msg.sender] += equityHollar - basis;
        _sharesOf[msg.sender] = held - shares;
        _totalShares -= shares;

        if (!_isUnwinding[msg.sender]) {
            _isUnwinding[msg.sender] = true;
            _unwinders.push(msg.sender);
        }
        unwindRequested[msg.sender] += equityHollar;
        unwindTargetEquity += equityHollar;

        // only recorded; pokeRepay grinds it down with router sales (pallet-DCA can't price aPRIME)
        unwindId = ++unwindOrderId;
        emit UnwindRequested(msg.sender, shares, equityHollar, unwindId);
    }

    /// @inheritdoc IYieldSource
    function pullFreed()
        external override onlyRole(VAULT_ROLE) nonReentrant settlesIntents returns (uint256 hollarSent)
    {
        hollarSent = freedHollar[msg.sender];
        if (hollarSent == 0) return 0;
        freedHollar[msg.sender] = 0;
        reservedFreed -= hollarSent;
        if (unwindRequested[msg.sender] >= hollarSent) {
            unwindRequested[msg.sender] -= hollarSent;
        } else {
            unwindRequested[msg.sender] = 0;
        }
        // prune finished unwinders so _creditFreed's loop doesn't grow unbounded
        if (unwindRequested[msg.sender] == 0) _pruneUnwinder(msg.sender);
        hollar.safeTransfer(msg.sender, hollarSent);
        emit FreedPulled(msg.sender, hollarSent);
    }

    /// @dev swap-remove a finished unwinder; a later requestUnwind re-registers it
    function _pruneUnwinder(address vault) internal {
        if (!_isUnwinding[vault]) return;
        _isUnwinding[vault] = false;
        unwindYieldAllowance[vault] = 0;
        uint256 n = _unwinders.length;
        for (uint256 i = 0; i < n; i++) {
            if (_unwinders[i] == vault) {
                _unwinders[i] = _unwinders[n - 1];
                _unwinders.pop();
                return;
            }
        }
    }

    /// @inheritdoc ILeveragedLoop
    /// @dev permissionless: bounded by deployHfFloor, deployTranche and an oracle-fair minOut
    function pokeBorrow() external override nonReentrant whenNotPaused whenNotEmergencyPaused returns (uint256) {
        return abi.decode(_delegate(abi.encodeCall(SubLoopLogic.pokeBorrowQuoted, (0))), (uint256));
    }

    /// @inheritdoc ISubLoop
    function pokeBorrowQuoted(uint256)
        external override onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused whenNotEmergencyPaused returns (uint256)
    {
        return abi.decode(_delegate(msg.data), (uint256));
    }

    /// @inheritdoc ISubLoop
    function reconcile() external override nonReentrant returns (uint8) {
        return abi.decode(_delegate(msg.data), (uint8));
    }

    /// @inheritdoc ISubLoop
    function removeIntent(uint128) external override nonReentrant {
        _delegate(msg.data);
    }

    /// @inheritdoc ISubLoop
    function execute(address, uint256, address, uint256, address, uint256, bytes calldata)
        external override nonReentrant returns (bytes4)
    {
        return abi.decode(_delegate(msg.data), (bytes4));
    }

    /// @inheritdoc ILeveragedLoop
    function pokeRepay() external override nonReentrant whenNotPaused returns (uint256) {
        return abi.decode(_delegate(abi.encodeCall(SubLoopLogic.pokeRepayQuoted, (0))), (uint256));
    }

    /// @inheritdoc ISubLoop
    function pokeRepayQuoted(uint256) external override onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        return abi.decode(_delegate(msg.data), (uint256));
    }

    /// @inheritdoc IYieldSource
    /// @notice zero-only probe; realization goes through harvestFor with owned units
    function harvest() external override nonReentrant whenNotPaused whenNotEmergencyPaused returns (uint256) {
        if (msg.sender != harvester) revert NotHarvester();
        if (harvestCapacity() != 0) revert InvalidParameters();
        return 0;
    }

    function accountingLocked() external view override returns (bool) { return _reentrancyGuardEntered(); }

    /// @notice Main recovery funding has released this much borrowed capital.
    /// Only that vault's immutable ownership ledger may reclassify its basis.
    function releasePrincipal(address vault, uint256 amount) external override nonReentrant {
        if (!hasRole(VAULT_ROLE, vault) || msg.sender != ISourceYieldVault(vault).yieldAccounting()) {
            revert InvalidParameters();
        }
        _principalOf[vault] -= amount;
        principalEquity -= amount;
    }

    function _harvestable() private view returns (uint256) {
        uint256 equity = _totalEquity() * 1e10;
        uint256 reserved = principalEquity + unwindTargetEquity + executionCostReserve();
        if (equity <= reserved) return 0;
        (uint256 coll8, uint256 debt8,,uint256 lt,,) = pool.getUserAccountData(address(this));
        uint256 protected8 = debt8 == 0 ? 0 : lt == 0 ? coll8
            : Math.mulDiv(debt8, deployHfFloor * 10_000, WAD * lt, Math.Rounding.Up);
        uint256 withdrawable = coll8 > protected8 ? (coll8 - protected8) * 1e10 : 0;
        return Math.min(equity - reserved, withdrawable);
    }

    function harvestCapacity() public view override returns (uint256) {
        uint256 available = _harvestable();
        if (available == 0 || (principalEquity != 0 && available * WAD < principalEquity * harvestThreshold)) return 0;
        return Math.mulDiv(available, _totalShares, _liveEquity18());
    }

    /// @notice Burn only the realized owner's units at the pre-withdrawal NAV.
    /// The Harvester caps and distributes the batch before the first withdrawal.
    function harvestFor(address vault, uint256 shares)
        external override nonReentrant whenNotPaused whenNotEmergencyPaused settlesIntents
        returns (uint256 amount, uint256 burned)
    {
        if (msg.sender != harvester) revert NotHarvester();
        if (shares == 0) return (0, 0);
        if (shares > _sharesOf[vault]) revert InsufficientShares();
        uint256 equity = _liveEquity18();
        uint256 value = Math.mulDiv(equity, shares, _totalShares);
        value = Math.min(value, _harvestable());
        (uint256 pHollar, uint256 pPrime) = _oracleRate();
        amount = Math.mulDiv(value, pHollar, pPrime * 1e12);
        if (amount == 0) return (0, 0);
        uint256 actualValue = Math.mulDiv(amount, pPrime * 1e12, pHollar);
        burned = Math.mulDiv(actualValue, _totalShares, equity, Math.Rounding.Up);
        ISourceYieldVault(vault).burnYieldShares(burned);
        _sharesOf[vault] -= burned;
        _totalShares -= burned;
        pool.withdraw(address(prime), amount, address(this));
        prime.safeTransfer(harvester, amount);
        emit Harvested(amount);
    }

    /// @inheritdoc ILeveragedLoop
    /// @dev sets repay target x solving (coll − x)·lt / (debt − x) = targetHf; pokeRepay executes it
    function deLever() external override nonReentrant {
        _delegate(abi.encodeCall(SubLoopLogic.deLever, ()));
    }

    /// @inheritdoc ILeveragedLoop
    function healthFactor() external view override returns (uint256) {
        return _healthFactor();
    }

    /// @inheritdoc ISubLoop
    function effectiveHealthFactor() external view override returns (uint256 hf) {
        (,,, hf) = _effectiveAccount();
    }

    /// @inheritdoc IYieldSource
    function totalEquity() external view override returns (uint256) {
        return _totalEquity();
    }

    /// @notice HOLLAR value of the permitted execution loss on the PRIME position;
    /// a harvest holdback, not a funded guarantee.
    function executionCostReserve() public view returns (uint256) {
        uint256 balance = primeAToken.balanceOf(address(this));
        if (balance == 0 || dcaSlippagePpm == 0) return 0;
        (uint256 pHollar, uint256 pPrime) = _oracleRate();
        uint256 grossHollar = balance * pPrime * 1e12 / pHollar;
        return (grossHollar * dcaSlippagePpm + 999_999) / 1_000_000;
    }

    /// @inheritdoc IYieldSource
    /// @dev basis is principalEquity + unwindTargetEquity; the earned cost allowance is not a liability
    function negativeCarryBps() external view override returns (uint256) {
        uint256 reserved18 = principalEquity + unwindTargetEquity;
        if (reserved18 == 0) return 0;
        uint256 equity18 = _totalEquity() * 1e10;
        if (equity18 >= reserved18) return 0;
        return ((reserved18 - equity18) * 1e4) / reserved18;
    }

    /// @inheritdoc IYieldSource
    function equityOf(address vault) external view override returns (uint256) {
        if (_totalShares == 0) return 0;
        return (_liveEquity18() * _sharesOf[vault]) / _totalShares / 1e10;
    }

    /// @inheritdoc IYieldSource
    function sharesOf(address vault) external view override returns (uint256) {
        return _sharesOf[vault];
    }

    /// @inheritdoc IYieldSource
    function totalShares() external view override returns (uint256) {
        return _totalShares;
    }

    /// @inheritdoc IYieldSource
    function freedOf(address vault) external view override returns (uint256) {
        return freedHollar[vault];
    }

    /// @inheritdoc IYieldSource
    /// @dev decremented on each pullFreed, so it is the still-owed in-flight amount
    function pendingUnwindOf(address vault) external view override returns (uint256) {
        return unwindRequested[vault];
    }

    /// @inheritdoc IYieldSource
    function emergencyPaused() external view override returns (bool) {
        return _emergencyPaused;
    }

    /// @inheritdoc IYieldSource
    function principalOf(address vault) external view override returns (uint256) {
        return _principalOf[vault];
    }

    /// @inheritdoc IYieldSource
    function unwindExecutionCost(address vault) external view override returns (uint256) {
        return _unwindExecutionCost[vault];
    }

    function registerVault(address vault) external onlyRole(ADMIN_ROLE) {
        _grantRole(VAULT_ROLE, vault);
    }

    function setTranches(uint256 _deployTranche, uint256 _unwindTranche) external onlyRole(ADMIN_ROLE) {
        deployTranche = _deployTranche;
        unwindTranche = _unwindTranche;
    }

    /// @notice Configure the HOLLAR↔aPRIME router route. Mainnet: 222/43/1043/143.
    function configureDca(
        uint32 _hollarAssetId,
        uint32 _primeAssetId,
        uint32 _aPrimeAssetId,
        uint32 _primePoolId,
        uint32 _slippagePpm
    ) external onlyRole(ADMIN_ROLE) {
        if (_slippagePpm >= 1_000_000) revert InvalidParameters();
        hollarAssetId = _hollarAssetId;
        primeAssetId = _primeAssetId;
        aPrimeAssetId = _aPrimeAssetId;
        primePoolId = _primePoolId;
        dcaSlippagePpm = _slippagePpm;
    }

    /// @notice ICE for entries and routine unwinds: `ttl` seconds per intent (0 keeps the router),
    /// `driftBps` of keeper-quote tolerance on top of the solver's 1 bp haircut
    function configureIntents(uint32 ttl, uint16 driftBps) external onlyRole(ADMIN_ROLE) {
        if (ttl >= 1 days || driftBps >= 9_999) revert InvalidParameters();
        intentTtl = ttl;
        intentDriftBps = driftBps;
    }

    function setParams(
        uint256 _targetHf,
        uint256 _deployHfFloor,
        uint256 _deLeverTrigger,
        uint256 _harvestThreshold
    ) external onlyRole(ADMIN_ROLE) {
        targetHf = _targetHf;
        deployHfFloor = _deployHfFloor;
        deLeverTrigger = _deLeverTrigger;
        harvestThreshold = _harvestThreshold;
    }

    /// @notice set the carry recipient; can't be zeroed, which would silently stop harvests.
    function setHarvester(address _harvester) external onlyRole(ADMIN_ROLE) {
        if (_harvester == address(0)) revert ZeroAddress();
        harvester = _harvester;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Stop withdrawals and new risk across all attached vaults; retain safety repayment.
    function pauseEmergency() external onlyRole(GUARDIAN_ROLE) {
        _emergencyPaused = true;
        emit EmergencyPauseUpdated(true);
    }

    function unpauseEmergency() external onlyRole(ADMIN_ROLE) {
        _emergencyPaused = false;
        emit EmergencyPauseUpdated(false);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice All initial deposits, upward rebalances and loop ramps share this capacity.
    function admissionCapacity() external view override returns (uint256) {
        return _admissionCapacity();
    }

    function previewHarvest(uint256 shares) external view override returns (uint256) {
        if (_totalShares == 0) return 0;
        uint256 value = Math.min(Math.mulDiv(_liveEquity18(), shares, _totalShares), _harvestable());
        (uint256 pHollar, uint256 pPrime) = _oracleRate();
        return Math.mulDiv(value, pHollar, pPrime * 1e12);
    }

    function setExecutionController(address controller) external onlyRole(ADMIN_ROLE) {
        if (controller.code.length == 0 || address(executionController) != address(0)) revert InvalidParameters();
        executionController = ExecutionController(controller);
        emit ExecutionControllerSet(controller);
    }

    event ExecutionControllerSet(address indexed controller);

    function _delegate(bytes memory data) private returns (bytes memory) {
        return Address.functionDelegateCall(logic, data);
    }
}
