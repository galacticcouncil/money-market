// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IAavePool, IPoolAddressesProvider, IAaveOracle} from "./interfaces/IAavePool.sol";
import {ExecutionController} from "./ExecutionController.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {PropellerYieldAccounting} from "./PropellerYieldAccounting.sol";
import {IPropellerFeeController} from "./interfaces/IPropellerFeeController.sol";
import {IMainDebt} from "./interfaces/IMainDebt.sol";

interface IMainDebtVault {
    function executionController() external view returns (ExecutionController);
    function pool() external view returns (IAavePool);
    function hollar() external view returns (IERC20);
    function hollarDebtToken() external view returns (IERC20);
    function collateral() external view returns (IERC20);
    function yieldSource() external view returns (IYieldSource);
    function swapper() external view returns (ISwapper);
    function compoundSlippageBps() external view returns (uint16);
    function paused() external view returns (bool);
    function feeController() external view returns (IPropellerFeeController);
}

interface IReserveRate {
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
}

/// @notice per-vault Main debt and settlement accounting. debt units allocate the live (discounted)
/// debt balance; source repayments and operating cash never cross between exits.
contract PropellerMainDebt is IMainDebt, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant RAY = 1e27;
    address public immutable override vault;
    address public immutable override yieldAccounting;
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
    struct SourceFee {
        uint256 yieldRemaining;
        uint256 feeRemaining;
    }
    mapping(uint256 => SourceFee) public sourceFees;
    uint256 public override sourceFeeReserve;
    uint256 public totalUnits;
    uint256 public override ownedCash;
    uint256 public sourceHead = 1;
    uint256 public sourceTail = 1;
    uint256 public unallocatedSource;
    uint256 public override activeSourceRemaining;
    uint256 public sourceOutstanding;
    uint256 public sourceCostCheckpoint;
    uint256 public unallocatedCost;
    uint256 private allocationAmount;
    uint256 private allocationCost;
    uint256 private allocationTotal;
    uint256 private allocationWeight;
    uint256 private allocationCursor;
    uint256 private allocationTail;

    error Unauthorized();
    error InvalidConfiguration();
    error UnfundedInterest();
    error TransferMismatch();
    error OutstandingDebt();
    error Paused();

    event PositionFunded(uint256 indexed key, address indexed donor, uint256 amount);
    event Repaid(uint256 indexed key, uint256 interest, uint256 principal, uint256 cashSpent);
    event ExitReserved(uint256 indexed id, uint256 cash, uint256 debt, uint256 sourceClaim);
    event SurplusClaimed(uint256 indexed id, address indexed owner, uint256 amount);
    event SourceCredited(uint256 indexed key, uint256 amount, uint256 remaining);
    event SourceYieldSpent(uint256 indexed key, uint256 cost);

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidConfiguration();
        vault = vault_;
        yieldAccounting = address(new PropellerYieldAccounting(vault_));
        IMainDebtVault v = IMainDebtVault(vault_);
        hollar = v.hollar();
        debtToken = v.hollarDebtToken();
        pool = v.pool();
        sourceCostCheckpoint = v.yieldSource().unwindExecutionCost(vault_);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    function _receive(uint256 amount) private {
        uint256 before_ = hollar.balanceOf(address(this));
        hollar.safeTransferFrom(msg.sender, address(this), amount);
        if (hollar.balanceOf(address(this)) != before_ + amount) revert TransferMismatch();
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

    function quoteCollateral(uint256 amount) external view override returns (uint256) {
        return _quote(address(hollar), address(IMainDebtVault(vault).collateral()), amount, Math.Rounding.Down);
    }

    function quoteHollar(uint256 amount) external view override returns (uint256) {
        return _quote(address(IMainDebtVault(vault).collateral()), address(hollar), amount, Math.Rounding.Down);
    }

    function activePosition() external view override returns (uint256 debt, uint256 principal, uint256 cash) {
        return (debtOf(0), positions[0].principal, positions[0].cash);
    }

    function activeFunds() public view override returns (uint256) {
        uint256 gross = positions[0].cash + activeSourceRemaining;
        return gross - Math.min(gross, sourceFees[0].feeRemaining);
    }

    function pendingSourceAccounting() external view override returns (bool) { return _pendingAllocation(); }

    function activeUnderfunded() public view override returns (bool) {
        uint256 debt = debtOf(0);
        if (debt == 0) return false;
        // No amount of gross carry services interest at a 100% fee. Net cash
        // or already fee-reserved receivables must cover that obligation first.
        IPropellerFeeController controller = IMainDebtVault(vault).feeController();
        if (address(controller) != address(0) && controller.protocolFeeBps(vault) == BPS
            && interestOf(0) > activeFunds()) return true;
        PropellerYieldAccounting rewards = PropellerYieldAccounting(yieldAccounting);
        uint256 sourceBacking = IMainDebtVault(vault).yieldSource().equityOf(vault) * 1e10 - rewards.sourceValue();
        return sourceBacking + activeFunds() < debt || sourceBacking < rewards.requiredSourceBacking();
    }

    function ready() external view returns (bool) {
        return !activeUnderfunded() && !_pendingAllocation();
    }

    function _pendingAllocation() private view returns (bool) {
        return unallocatedSource != 0 || unallocatedCost != 0
            || IMainDebtVault(vault).yieldSource().unwindExecutionCost(vault) != sourceCostCheckpoint;
    }

    function beforeDeposit() external override onlyVault nonReentrant returns (uint256) {
        if (activeSourceRemaining != 0 || _pendingAllocation()) revert OutstandingDebt();
        _repay(0, 0);
        // Earned source equity can back interest until the next harvest. Do not
        // demand a cash top-up merely because another block accrued interest.
        if (interestOf(0) != 0 && activeUnderfunded()) revert UnfundedInterest();
        return debtToken.balanceOf(vault);
    }

    function borrowed(uint256 previousDebt)
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
    }

    function startExit(uint256 id, address owner, uint256 shares, uint256 supply,
        uint256 sourceClaim, uint256 sourcePrincipal, uint256 sourceFee)
        external override onlyVault nonReentrant returns (uint256 debt)
    {
        // Allocate already-received source cash before admitting a new claim.
        if (_pendingAllocation()) revert OutstandingDebt();
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
        IPropellerFeeController controller = IMainDebtVault(vault).feeController();
        if (address(controller) != address(0)) {
            uint256 yield = sourceClaim > sourcePrincipal ? sourceClaim - sourcePrincipal : 0;
            uint256 fee = Math.min(sourceFee, yield);
            sourceFees[key] = SourceFee(yield, fee);
            sourceFeeReserve += fee;
        } else if (sourceFee != 0) {
            revert InvalidConfiguration();
        }
        sourceOutstanding += sourceClaim;
        sourceTail = key + 1;
        emit ExitReserved(id, exit.cash, debt, sourceClaim);
    }

    function expectDelever(uint256 amount, uint256 sourcePrincipal) external override onlyVault {
        if (activeSourceRemaining != 0 || allocationAmount != 0 || allocationCost != 0 || _pendingAllocation()) revert OutstandingDebt();
        IPropellerFeeController controller = IMainDebtVault(vault).feeController();
        uint256 yield = amount > sourcePrincipal ? amount - sourcePrincipal : 0;
        uint256 fee = address(controller) == address(0) ? 0
            : Math.mulDiv(yield, controller.protocolFeeBps(vault), BPS);
        sourceFees[0] = SourceFee(yield, fee);
        sourceFeeReserve += fee;
        activeSourceRemaining += amount;
        sourceOutstanding += amount;
    }

    /// @notice credit source proceeds and costs to claims in a frozen proportional batch, 64 per call,
    /// so the first exit can't take the whole cost allowance. new exits join the next batch.
    function creditSource(uint256 amount) external override onlyVault nonReentrant returns (uint256 activeCost) {
        uint256 cumulativeCost = IMainDebtVault(vault).yieldSource().unwindExecutionCost(vault);
        unallocatedCost += cumulativeCost - sourceCostCheckpoint;
        sourceCostCheckpoint = cumulativeCost;
        if (amount != 0) {
            _receive(amount);
            unallocatedSource += amount;
            ownedCash += amount;
        }
        uint256 feesPaid;
        if (allocationAmount == 0 && allocationCost == 0) {
            if (unallocatedSource == 0 && unallocatedCost == 0) return 0;
            if (unallocatedSource + unallocatedCost > sourceOutstanding) revert TransferMismatch();
            allocationAmount = unallocatedSource;
            allocationCost = unallocatedCost;
            allocationTotal = sourceOutstanding;
            allocationCursor = sourceHead;
            allocationTail = sourceTail;
            uint256 activeCredit;
            (activeCredit, activeCost) = _allocate(activeSourceRemaining);
            activeSourceRemaining -= activeCredit + activeCost;
            positions[0].cash += activeCredit;
            feesPaid = _settleSourceFee(0, activeSourceRemaining, activeCost);
            if (activeCredit != 0) emit SourceCredited(0, activeCredit, activeSourceRemaining);
            if (activeCost != 0) emit SourceYieldSpent(0, activeCost);
            // The resize target is net repayment funding, including actual
            // source expenses and fees; neither is an unpaid user debt claim.
            activeCost += feesPaid;
        }
        uint256 cursor = allocationCursor;
        for (uint256 i; cursor < allocationTail && i < 64; ++i) {
            Position storage p = positions[cursor];
            (uint256 credited, uint256 cost) = _allocate(p.sourceRemaining);
            p.sourceRemaining -= credited + cost;
            p.cash += credited;
            feesPaid += _settleSourceFee(cursor, p.sourceRemaining, cost);
            if (credited != 0) emit SourceCredited(cursor, credited, p.sourceRemaining);
            if (cost != 0) emit SourceYieldSpent(cursor, cost);
            if (cursor == sourceHead && p.sourceRemaining == 0) ++sourceHead;
            ++cursor;
        }
        if (feesPaid != 0) {
            ownedCash -= feesPaid;
            IPropellerFeeController controller = IMainDebtVault(vault).feeController();
            hollar.forceApprove(address(controller), feesPaid);
            controller.collectSourceFee(feesPaid);
            hollar.forceApprove(address(controller), 0);
        }
        allocationCursor = cursor;
        if (cursor == allocationTail) {
            if (allocationWeight != allocationTotal) revert TransferMismatch();
            allocationAmount = 0;
            allocationCost = 0;
            allocationWeight = 0;
        }
    }

    function _settleSourceFee(uint256 key, uint256 remaining, uint256 cost) private returns (uint256 charged) {
        SourceFee storage fee = sourceFees[key];
        uint256 beforeFee = fee.feeRemaining;
        uint256 beforeYield = fee.yieldRemaining;
        fee.yieldRemaining -= Math.min(beforeYield, cost);
        if (beforeYield != 0) fee.feeRemaining = Math.mulDiv(beforeFee, fee.yieldRemaining, beforeYield);
        // A fee on an unfinished claim stays reserved: later costs can still
        // reduce it even after an outside Main repayment or a partial surplus.
        if (remaining == 0) {
            charged = fee.feeRemaining;
            positions[key].cash -= charged;
            delete sourceFees[key];
        }
        sourceFeeReserve -= beforeFee - fee.feeRemaining;
    }

    function _allocate(uint256 weight) private returns (uint256 credited, uint256 cost) {
        uint256 reduction = allocationAmount + allocationCost;
        uint256 before_ = Math.mulDiv(reduction, allocationWeight, allocationTotal);
        allocationWeight += weight;
        uint256 after_ = Math.mulDiv(reduction, allocationWeight, allocationTotal);
        credited = Math.mulDiv(after_, allocationAmount, reduction) - Math.mulDiv(before_, allocationAmount, reduction);
        cost = after_ - before_ - credited;
        unallocatedSource -= credited;
        unallocatedCost -= cost;
        sourceOutstanding -= credited + cost;
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
        uint256 spendable = p.cash - Math.min(p.cash, sourceFees[key].feeRemaining);
        uint256 amount = Math.min(spendable, limit);
        if (amount != 0) {
            (paid, reduced) = _pay(amount);
            // Finish a scaled-debt rounding tail from this cohort's own cash.
            // A partial liquidity-limited repayment is not a rounding retry.
            if (paid == amount && reduced < amount && spendable > paid) {
                (uint256 extraCash, uint256 extraDebt) = _pay(
                    Math.min(spendable - paid, amount - reduced + _roundingQuantum()));
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
        IERC20 collateral = IMainDebtVault(vault).collateral();
        uint256 before_ = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(vault, address(this), amount);
        if (collateral.balanceOf(address(this)) != before_ + amount) revert TransferMismatch();
        uint256 wanted = interestOf(0);
        uint256 cash = _spendableActiveCash();
        uint256 sellAmount;
        if (wanted > cash && amount != 0) {
            uint256 slippage = IMainDebtVault(vault).compoundSlippageBps();
            sellAmount = Math.min(amount, _quote(address(hollar), address(collateral),
                Math.mulDiv(wanted - cash, BPS, BPS - slippage, Math.Rounding.Up), Math.Rounding.Up));
            ExecutionController control = IMainDebtVault(vault).executionController();
            if (address(control) != address(0)) {
                // a need below the lane minimum sells the minimum; the surplus stays as active cash
                (, uint128 floor,) = control.limits(control.lane(address(this), address(collateral), address(hollar)));
                if (sellAmount < floor) sellAmount = amount < floor ? 0 : floor;
            }
            if (sellAmount != 0) _sellForInterest(collateral, control, sellAmount, slippage);
            if (collateral.balanceOf(address(this)) != before_ + amount - sellAmount) revert TransferMismatch();
        }
        _repay(0, 0);
        remaining = amount - sellAmount;
        collateral.safeTransfer(vault, remaining);
        if (collateral.balanceOf(address(this)) != before_) revert TransferMismatch();
    }

    function _sellForInterest(IERC20 collateral, ExecutionController control, uint256 sellAmount, uint256 slippage)
        private
    {
        uint256 fairOut = _quote(address(collateral), address(hollar), sellAmount, Math.Rounding.Down);
        uint256 minimum = Math.mulDiv(fairOut, BPS - slippage, BPS);
        ISwapper swapper = IMainDebtVault(vault).swapper();
        uint256 cashBefore = hollar.balanceOf(address(this));
        collateral.forceApprove(address(swapper), sellAmount);
        if (address(control) != address(0)) minimum = Math.max(minimum,
            control.consume(address(collateral), address(hollar), sellAmount, fairOut));
        swapper.sell(address(collateral), address(hollar), sellAmount, minimum, "");
        collateral.forceApprove(address(swapper), 0);
        uint256 received = hollar.balanceOf(address(this)) - cashBefore;
        if (address(control) != address(0)) control.record(address(collateral), address(hollar), received);
        if (received == 0 || received < minimum) revert TransferMismatch();
        positions[0].cash += received;
        ownedCash += received;
    }

    function _spendableActiveCash() private view returns (uint256 cash) {
        cash = positions[0].cash;
        cash -= Math.min(cash, sourceFees[0].feeRemaining);
    }

    /// @notice due interest whose sale lane can't trade now; the harvester skips
    /// this vault instead of rolling back every vault's batch
    function serviceBlocked() external view override returns (bool) {
        ExecutionController control = IMainDebtVault(vault).executionController();
        return address(control) != address(0) && interestOf(0) > _spendableActiveCash()
            && control.available(address(this), address(IMainDebtVault(vault).collateral()), address(hollar)) == 0;
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

    function surplusOf(uint256 id) public view returns (uint256) {
        Position storage p = positions[id + 1];
        if (p.units != 0) return 0;
        return p.cash - Math.min(p.cash, sourceFees[id + 1].feeRemaining);
    }

    /// @notice Permissionless, but the recipient is the original withdrawal owner.
    /// Later source recoveries remain independently claimable, without a haircut.
    function claimSurplus(uint256 id) external nonReentrant returns (uint256 amount) {
        if (IMainDebtVault(vault).paused()) revert Paused();
        Position storage p = positions[id + 1];
        if (p.owner == address(0)) revert InvalidConfiguration();
        if (p.units != 0) revert OutstandingDebt();
        amount = surplusOf(id);
        p.cash -= amount;
        ownedCash -= amount;
        hollar.safeTransfer(p.owner, amount);
        emit SurplusClaimed(id, p.owner, amount);
    }
}
