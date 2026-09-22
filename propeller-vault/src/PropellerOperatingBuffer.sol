// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IAavePool, IPoolAddressesProvider, IAaveOracle} from "./interfaces/IAavePool.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IHollarDiscountDebtToken} from "./interfaces/IPropellerDiscount.sol";
import {IOperatingBuffer} from "./interfaces/IOperatingBuffer.sol";

interface IOperatingVault {
    function pool() external view returns (IAavePool);
    function hollar() external view returns (IERC20);
    function hollarDebtToken() external view returns (IERC20);
    function collateral() external view returns (IERC20);
    function yieldSource() external view returns (IYieldSource);
    function swapper() external view returns (ISwapper);
    function compoundSlippageBps() external view returns (uint16);
    function discountController() external view returns (address);
    function paused() external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

// Aave ReserveData is static ABI data. Only its first five words are needed;
// later fields are intentionally ignored (including the newer reserve fields).
interface IReserveRate {
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
    function getReserveData(address asset) external view
        returns (uint256 configuration, uint128 liquidityIndex, uint128 liquidityRate,
            uint128 variableBorrowIndex, uint128 variableBorrowRate);
}

/// @notice Per-vault, user-owned HOLLAR. No admin sweep and no treasury entitlement.
/// Debt units allocate the live (discounted) debt balance, including interest
/// after an exit starts. Source repayments and operating cash never cross exits.
contract PropellerOperatingBuffer is IOperatingBuffer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant RAY = 1e27;
    address public immutable override vault;
    IERC20 public immutable hollar;
    IERC20 public immutable debtToken;
    IAavePool public immutable pool;

    struct Position {
        uint256 units;
        uint256 principal;
        uint256 cash;
        uint256 sourceRemaining;
        address owner;
    }
    // Key zero is active holders; withdrawal id N uses key N+1.
    mapping(uint256 => Position) public positions;
    uint256 public totalUnits;
    uint256 public override ownedCash;
    uint256 public bootstrapCash;
    uint256 public sourceHead = 1;
    uint256 public sourceTail = 1;
    uint256 public unallocatedSource;
    uint256 public override activeSourceRemaining;
    uint32 public coverageSeconds;
    uint16 public exitCostBps;
    uint128 public stressRateRay;

    error Unauthorized();
    error InvalidConfiguration();
    error UnfundedBuffer();
    error TransferMismatch();
    error OutstandingDebt();
    error Paused();

    event Configured(uint32 coverageSeconds, uint16 exitCostBps, uint128 stressRateRay);
    event BootstrapFunded(address indexed donor, uint256 amount);
    event BootstrapAllocated(uint256 amount);
    event PositionFunded(uint256 indexed key, address indexed donor, uint256 amount);
    event Repaid(uint256 indexed key, uint256 interest, uint256 principal, uint256 cashSpent);
    event ExitReserved(uint256 indexed id, uint256 cash, uint256 debt, uint256 sourceClaim);
    event BufferClaimed(uint256 indexed id, address indexed owner, uint256 amount);
    event SourceCredited(uint256 indexed key, uint256 amount, uint256 remaining);

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidConfiguration();
        vault = vault_;
        IOperatingVault v = IOperatingVault(vault_);
        hollar = v.hollar();
        debtToken = v.hollarDebtToken();
        pool = v.pool();
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    function configure(uint32 seconds_, uint16 costBps_, uint128 rateRay_) external nonReentrant {
        if (!IOperatingVault(vault).hasRole(keccak256("ADMIN_ROLE"), msg.sender)) revert Unauthorized();
        // These are governance choices, not implicitly enabled model defaults.
        if (seconds_ == 0 || costBps_ == 0 || costBps_ >= BPS || rateRay_ == 0) revert InvalidConfiguration();
        coverageSeconds = seconds_;
        exitCostBps = costBps_;
        stressRateRay = rateRay_;
        emit Configured(seconds_, costBps_, rateRay_);
    }

    function _receive(uint256 amount) private {
        uint256 before_ = hollar.balanceOf(address(this));
        hollar.safeTransferFrom(msg.sender, address(this), amount);
        if (hollar.balanceOf(address(this)) != before_ + amount) revert TransferMismatch();
    }

    /// @notice Irrevocable sponsorship, not yet owned by any share cohort.
    function fundBootstrap(uint256 amount) external nonReentrant {
        _receive(amount);
        bootstrapCash += amount;
        emit BootstrapFunded(msg.sender, amount);
    }

    /// @notice Explicit recovery donation to active holders (0) or exit id+1.
    function fundPosition(uint256 key, uint256 amount) external nonReentrant {
        if (key != 0 && positions[key].owner == address(0)) revert InvalidConfiguration();
        _receive(amount);
        positions[key].cash += amount;
        ownedCash += amount;
        emit PositionFunded(key, msg.sender, amount);
    }

    function debtOf(uint256 key) public view returns (uint256) {
        return totalUnits == 0 ? 0 : Math.mulDiv(debtToken.balanceOf(vault), positions[key].units, totalUnits);
    }

    function interestOf(uint256 key) public view returns (uint256) {
        uint256 debt = debtOf(key);
        uint256 principal = positions[key].principal;
        return debt > principal ? debt - principal : 0;
    }

    function activeUnderfunded() external view override returns (bool) {
        uint256 backing = IOperatingVault(vault).yieldSource().equityOf(vault) * 1e10
            + positions[0].cash + activeSourceRemaining;
        return backing < debtOf(0);
    }

    function _rates() private view returns (uint256 rate, uint256 discount) {
        (,,,, uint128 rawRate) = IReserveRate(address(pool)).getReserveData(address(hollar));
        rate = rawRate;
        if (IOperatingVault(vault).discountController() != address(0)) {
            discount = IHollarDiscountDebtToken(address(debtToken)).getDiscountPercent(vault);
            if (discount > BPS) revert InvalidConfiguration();
        }
    }

    function effectiveRateRay() public view returns (uint256 rate) {
        uint256 discount;
        (rate, discount) = _rates();
        rate = Math.mulDiv(rate, BPS - discount, BPS);
        if (rate < stressRateRay) rate = stressRateRay;
    }

    function targetCash() public view returns (uint256) {
        if (coverageSeconds == 0) revert InvalidConfiguration();
        (uint256 grossRate, uint256 discount) = _rates();
        uint256 debt = debtOf(0);
        // GHO discounts gross INDEX growth, not the rate before compounding.
        uint256 liveInterest = discount == BPS ? 0 : Math.mulDiv(
            _interestBound(debt, grossRate), BPS - discount, BPS, Math.Rounding.Up);
        uint256 interest = Math.max(liveInterest, _interestBound(debt, stressRateRay));
        uint256 gross = IOperatingVault(vault).yieldSource().exitCostExposure(vault);
        return interest + Math.mulDiv(gross, exitCostBps, BPS, Math.Rounding.Up);
    }

    function _interestBound(uint256 debt, uint256 rate) private view returns (uint256) {
        // Bound compounded interest conservatively by r*t/(1-r*t). This is
        // above exp(r*t)-1 for 0 <= r*t < 1, without a floating-point engine.
        uint256 rt = Math.mulDiv(rate, coverageSeconds, 365 days, Math.Rounding.Up);
        if (rt >= RAY) revert InvalidConfiguration();
        return Math.mulDiv(debt, rt, RAY - rt, Math.Rounding.Up);
    }

    function ready() external view returns (bool) {
        return coverageSeconds != 0 && positions[0].cash >= targetCash() + interestOf(0);
    }

    function beforeDeposit() external override onlyVault nonReentrant returns (uint256) {
        if (coverageSeconds == 0) revert InvalidConfiguration();
        if (activeSourceRemaining != 0) revert OutstandingDebt();
        _repay(0, 0);
        if (interestOf(0) != 0) revert UnfundedBuffer();
        return debtToken.balanceOf(vault);
    }

    function borrowed(uint256 previousDebt, uint256 newShares, uint256 previousSupply)
        external override onlyVault nonReentrant
    {
        // Scaled Aave debt may mint a wei above/below the requested cash amount.
        uint256 amount = debtToken.balanceOf(vault) - previousDebt;
        uint256 units;
        if (totalUnits == 0) units = amount * 1e18;
        else {
            if (previousDebt == 0) revert OutstandingDebt();
            units = Math.mulDiv(amount, totalUnits, previousDebt, Math.Rounding.Up);
        }
        Position storage active = positions[0];
        active.units += units;
        active.principal += amount;
        totalUnits += units;
        uint256 proportional = previousSupply == 0 ? 0
            : Math.mulDiv(active.cash, newShares, previousSupply, Math.Rounding.Up);
        uint256 target = targetCash();
        uint256 topup = target > active.cash ? target - active.cash : 0;
        if (topup < proportional) topup = proportional;
        if (topup > bootstrapCash) revert UnfundedBuffer();
        bootstrapCash -= topup;
        active.cash += topup;
        ownedCash += topup;
        emit BootstrapAllocated(topup);
    }

    function startExit(uint256 id, address owner, uint256 shares, uint256 supply, uint256 sourceClaim)
        external override onlyVault nonReentrant returns (uint256 debt)
    {
        uint256 key = id + 1;
        if (key != sourceTail || owner == address(0)) revert InvalidConfiguration();
        Position storage active = positions[0];
        Position storage exit = positions[key];
        exit.units = Math.mulDiv(active.units, shares, supply);
        exit.cash = Math.mulDiv(active.cash, shares, supply);
        uint256 principal = Math.mulDiv(active.principal, shares, supply);
        active.units -= exit.units;
        active.cash -= exit.cash;
        active.principal -= principal;
        debt = debtOf(key);
        if (debt == 0) {
            totalUnits -= exit.units;
            exit.units = 0;
        }
        exit.principal = debt;
        exit.owner = owner;
        exit.sourceRemaining = sourceClaim;
        sourceTail = key + 1;
        emit ExitReserved(id, exit.cash, debt, sourceClaim);
    }

    function expectDelever(uint256 amount) external override onlyVault {
        activeSourceRemaining += amount;
    }

    /// @notice Preserve each source claim even if its Main debt is already paid.
    /// Bounded work; call again with zero to distribute a large batch's remainder.
    function creditSource(uint256 amount) external override onlyVault nonReentrant {
        if (amount != 0) {
            _receive(amount);
            unallocatedSource += amount;
            ownedCash += amount;
        }
        uint256 activeCredit = Math.min(unallocatedSource, activeSourceRemaining);
        activeSourceRemaining -= activeCredit;
        unallocatedSource -= activeCredit;
        positions[0].cash += activeCredit;
        if (activeCredit != 0) emit SourceCredited(0, activeCredit, activeSourceRemaining);
        uint256 head = sourceHead;
        for (uint256 i; head < sourceTail && i < 64; ++i) {
            Position storage p = positions[head];
            uint256 credited = Math.min(unallocatedSource, p.sourceRemaining);
            p.sourceRemaining -= credited;
            p.cash += credited;
            unallocatedSource -= credited;
            if (credited != 0) emit SourceCredited(head, credited, p.sourceRemaining);
            if (p.sourceRemaining != 0) break;
            ++head;
        }
        sourceHead = head;
    }

    function repay(uint256 key, uint256 principalLimit, uint256 recovery)
        external override onlyVault nonReentrant returns (uint256 paid, uint256 principalPaid, uint256 reduced)
    {
        if (recovery != 0) {
            _receive(recovery);
            positions[key].cash += recovery;
            ownedCash += recovery;
        }
        return _repay(key, principalLimit);
    }

    function _roundingQuantum() private view returns (uint256) {
        return 2 * Math.ceilDiv(IReserveRate(address(pool)).getReserveNormalizedVariableDebt(address(hollar)), RAY);
    }

    function _pay(uint256 amount) private returns (uint256 paid, uint256 reduced) {
        uint256 cashBefore = hollar.balanceOf(address(this));
        uint256 debtBefore = debtToken.balanceOf(vault);
        hollar.forceApprove(address(pool), amount);
        paid = pool.repay(address(hollar), amount, 2, vault);
        hollar.forceApprove(address(pool), 0);
        uint256 afterDebt = debtToken.balanceOf(vault);
        if (paid > amount || hollar.balanceOf(address(this)) + paid != cashBefore
            || afterDebt > debtBefore) revert TransferMismatch();
        reduced = debtBefore - afterDebt;
        if (reduced != paid && Math.max(reduced, paid) - Math.min(reduced, paid) > _roundingQuantum()) {
            revert TransferMismatch();
        }
    }

    function _repay(uint256 key, uint256 principalLimit)
        private returns (uint256 paid, uint256 principalPaid, uint256 reduced)
    {
        Position storage p = positions[key];
        uint256 debtBefore = debtToken.balanceOf(vault);
        uint256 debt = debtOf(key);
        uint256 principalBefore = p.principal;
        // An outside repayment is real funding, allocated pro rata by debt units.
        if (p.principal > debt) p.principal = debt;
        uint256 interest = debt - p.principal;
        uint256 limit = key == 0 && principalLimit != 0
            ? Math.min(debt, principalLimit)
            : interest + Math.min(p.principal, principalLimit);
        uint256 amount = Math.min(p.cash, limit);
        if (amount != 0) {
            (paid, reduced) = _pay(amount);
            // Finish a scaled-debt rounding tail from this cohort's own cash.
            // A partial liquidity-limited repayment is not a rounding retry.
            if (paid == amount && reduced < amount && p.cash > paid) {
                (uint256 extraCash, uint256 extraDebt) = _pay(
                    Math.min(p.cash - paid, amount - reduced + _roundingQuantum()));
                paid += extraCash;
                reduced += extraDebt;
            }
            p.cash -= paid;
            ownedCash -= paid;
            uint256 burned = reduced >= debt ? p.units : Math.mulDiv(reduced, totalUnits, debtBefore);
            p.units -= burned;
            totalUnits -= burned;
            uint256 principalReduction = reduced > interest ? Math.min(p.principal, reduced - interest) : 0;
            p.principal -= principalReduction;
        }
        // A zero-value debt-unit tail must not acquire someone else's future debt.
        if (debt <= reduced) {
            totalUnits -= p.units;
            p.units = 0;
        }
        principalPaid = principalBefore - p.principal;
        emit Repaid(key, Math.min(reduced, interest), reduced > interest ? Math.min(debt, reduced) - interest : 0, paid);
    }

    /// @notice Only fresh after-fee collateral may fund ordinary servicing.
    function harvest(uint256 amount) external override onlyVault nonReentrant returns (uint256 remaining) {
        IERC20 collateral = IOperatingVault(vault).collateral();
        uint256 before_ = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(vault, address(this), amount);
        if (collateral.balanceOf(address(this)) != before_ + amount) revert TransferMismatch();
        uint256 wanted = targetCash() + interestOf(0);
        uint256 cash = positions[0].cash;
        uint256 sellAmount;
        if (wanted > cash && amount != 0) {
            uint256 needed = wanted - cash;
            uint256 slippage = IOperatingVault(vault).compoundSlippageBps();
            sellAmount = Math.min(amount, _quote(address(hollar), address(collateral),
                Math.mulDiv(needed, BPS, BPS - slippage, Math.Rounding.Up), Math.Rounding.Up));
            uint256 minimum = Math.mulDiv(_quote(address(collateral), address(hollar), sellAmount,
                Math.Rounding.Down), BPS - slippage, BPS);
            ISwapper swapper = IOperatingVault(vault).swapper();
            uint256 cashBefore = hollar.balanceOf(address(this));
            collateral.forceApprove(address(swapper), sellAmount);
            swapper.sell(address(collateral), address(hollar), sellAmount, minimum, "");
            collateral.forceApprove(address(swapper), 0);
            uint256 received = hollar.balanceOf(address(this)) - cashBefore;
            if (received == 0 || received < minimum
                || collateral.balanceOf(address(this)) != before_ + amount - sellAmount) revert TransferMismatch();
            positions[0].cash += received;
            ownedCash += received;
        }
        _repay(0, 0);
        remaining = amount - sellAmount;
        collateral.safeTransfer(vault, remaining);
        if (collateral.balanceOf(address(this)) != before_) revert TransferMismatch();
    }

    function _quote(address input, address output, uint256 amount, Math.Rounding rounding)
        private view returns (uint256)
    {
        IAaveOracle oracle = IAaveOracle(IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle());
        uint256 inputPrice = oracle.getAssetPrice(input);
        uint256 outputPrice = oracle.getAssetPrice(output);
        if (inputPrice == 0 || outputPrice == 0) revert InvalidConfiguration();
        return Math.mulDiv(amount, inputPrice * 10 ** IERC20Metadata(output).decimals(),
            outputPrice * 10 ** IERC20Metadata(input).decimals(), rounding);
    }

    /// @notice Permissionless, but the recipient is the original withdrawal owner.
    /// Later source recoveries remain independently claimable, without a haircut.
    function claimBuffer(uint256 id) external nonReentrant returns (uint256 amount) {
        if (IOperatingVault(vault).paused()) revert Paused();
        Position storage p = positions[id + 1];
        if (p.owner == address(0)) revert InvalidConfiguration();
        if (p.units != 0) revert OutstandingDebt();
        amount = p.cash;
        p.cash = 0;
        ownedCash -= amount;
        hollar.safeTransfer(p.owner, amount);
        emit BufferClaimed(id, p.owner, amount);
    }
}
