// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ExecutionController} from "../ExecutionController.sol";
import {PropellerYieldAccounting} from "../PropellerYieldAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMainDebtVault} from "../PropellerMainDebt.sol";
import {IMainDebt} from "../interfaces/IMainDebt.sol";
import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {IPropellerFeeController} from "../interfaces/IPropellerFeeController.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {ISyntheticToken} from "../interfaces/ISyntheticToken.sol";

interface IEntrySource {
    function primeAToken() external view returns (address);
}

/// @dev shared by the vault's peg top-up and the helper's borrowing path
library SyntheticFloor {
    using SafeERC20 for IERC20;

    /// @dev synthetic that floors `debt` at liquidation threshold `lt`, plus a 0.5% buffer
    function buffered(uint256 debt, uint256 lt) internal pure returns (uint256 amount) {
        amount = Math.ceilDiv(debt * 10_000, lt);
        amount += amount / 200;
    }

    /// @dev aave auto-enables collateral only on a first ltv>0 supply; a failed
    /// enable reverts, since unflagged synthetic would leave the floor inert
    function supply(IAavePool pool, ISyntheticToken synthetic, uint256 amount) internal {
        synthetic.mint(address(this), amount);
        IERC20(address(synthetic)).forceApprove(address(pool), amount);
        pool.supply(address(synthetic), amount, address(this), 0);
        pool.setUserUseReserveAsCollateral(address(synthetic), true);
    }
}

interface ICompoundVault is IMainDebtVault {
    function feeController() external view returns (IPropellerFeeController);
    function mainDebt() external view returns (IMainDebt);
    function yieldAccounting() external view returns (PropellerYieldAccounting);
    function synthetic() external view returns (ISyntheticToken);
    function syntheticSupplied() external view returns (uint256);
    function loopShares() external view returns (uint256);
    function reinvestAssets() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalQueuedCollateral() external view returns (uint256);
    function synthLtBps() external view returns (uint256);
}

/// @dev stateless delegatecall logic deployed with the vault implementation, which supplies the
/// reentrancy and pause guards. no storage, delegate targets or approvals survive a call.
contract CompoundLogic {
    using SafeERC20 for IERC20;
    // rebalance hysteresis around the reserve's max LTV: relever when utilization
    // drifts this far below it, delever when a price drop pushes it this far above
    uint256 internal constant LTV_BAND_LOW_GAP_BPS = 500;
    uint256 internal constant LTV_BAND_HIGH_GAP_BPS = 300;
    uint256 internal constant VARIABLE_RATE = 2;
    uint256 internal constant LTV_MASK = 0xFFFF; // reserve configuration bits 0-15
    error ZeroAmount();
    error ZeroAddress();
    error PrincipalShortfall();
    error NoLoopEquity();
    error PrincipalNotFloored();
    event Rebalanced(uint256 ltvBefore, uint256 ltvAfter);
    event Harvested(uint256 collateralAmount);

    function repay(uint256 key, uint256 amount, uint256 recovery)
        external returns (uint256 principalPaid, uint256 burn, uint256 paid)
    {
        ICompoundVault v = ICompoundVault(address(this));
        uint256 debt = v.hollarDebtToken().balanceOf(address(this));
        IERC20 hollar = v.hollar();
        IMainDebt buffer = v.mainDebt();
        hollar.forceApprove(address(buffer), recovery);
        (, principalPaid, paid) = buffer.repay(key, amount, recovery);
        hollar.forceApprove(address(buffer), 0);
        burn = debt == 0 ? 0 : v.syntheticSupplied() * paid / debt;
        if (burn != 0) {
            ISyntheticToken synthetic = v.synthetic();
            v.pool().withdraw(address(synthetic), burn, address(this));
            synthetic.burn(address(this), burn);
        }
    }

    /// @notice Supply collateral without borrowing or trading. Deployment is a
    /// separately quoted rebalance; waiting collateral incurs no HOLLAR debt.
    function deposit(uint256 assets) external {
        ICompoundVault v = ICompoundVault(address(this));
        IAavePool pool = v.pool();
        IERC20 collateral = v.collateral();
        ExecutionController control = v.executionController();
        address payer = msg.sender == address(control) ? control.caller() : msg.sender;
        collateral.safeTransferFrom(payer, address(this), assets);
        collateral.forceApprove(address(pool), assets);
        pool.supply(address(collateral), assets, address(this), 0);
    }

    function startExit(uint256 id, address owner, uint256 shares, uint256 supply)
        external returns (uint256 remainingShares, uint256 debt)
    {
        ICompoundVault v = ICompoundVault(address(this));
        IYieldSource source = v.yieldSource();
        PropellerYieldAccounting rewards = v.yieldAccounting();
        uint256 held = v.loopShares();
        uint256 activeSlice = Math.mulDiv(held - rewards.reservedShares(), shares, supply);
        (uint256 rewardSlice, uint256 feeSlice) = rewards.startExit(id, owner, shares);
        uint256 slice = activeSlice + rewardSlice + feeSlice;
        uint256 basis = Math.mulDiv(source.principalOf(address(this)), shares, supply);
        uint256 before_ = source.pendingUnwindOf(address(this));
        if (slice != 0) source.requestUnwindProtected(slice, basis);
        uint256 claim = source.pendingUnwindOf(address(this)) - before_;
        uint256 activeClaim = slice == 0 ? 0 : Math.mulDiv(claim, activeSlice, slice);
        uint256 taxable = activeClaim > basis ? activeClaim - basis : 0;
        uint256 fee = address(v.feeController()) == address(0) ? 0
            : Math.mulDiv(taxable, v.feeController().protocolFeeBps(address(this)), 10_000);
        if (slice != 0) fee += Math.mulDiv(claim, feeSlice, slice);
        (,,uint256 cash) = v.mainDebt().activePosition();
        debt = v.mainDebt().startExit(id, owner, shares, supply, claim, basis, fee);
        if (slice == 0 && debt > Math.mulDiv(cash, shares, supply)) revert NoLoopEquity();
        remainingShares = held - slice;
    }

    /// @dev returns state to the vault. while exits are in flight only deposited/earned
    /// credit deploys; price resizing waits
    function rebalance(bool exiting) external returns (uint256 shares, uint256 supplied, uint256 target, uint256 credit) {
        ICompoundVault v = ICompoundVault(address(this));
        IAavePool pool = v.pool();
        IERC20 hollar = v.hollar();
        IMainDebt ledger = v.mainDebt();
        shares = v.loopShares();
        supplied = v.syntheticSupplied();
        credit = v.reinvestAssets();
        (uint256 coll8, uint256 debt8,,,,) = pool.getUserAccountData(address(this));
        uint256 value8 = coll8 > supplied / 1e10 ? coll8 - supplied / 1e10 : 0;
        if (value8 == 0) return (shares, supplied, 0, credit);
        uint256 ltv = debt8 * 10_000 / value8;
        uint256 maxLtv = pool.getConfiguration(address(v.collateral())) & LTV_MASK;
        uint256 targetDebt8 = value8 * maxLtv / 10_000;
        bool resize = !exiting && ltv + LTV_BAND_LOW_GAP_BPS < maxLtv;
        if (resize || (credit != 0 && debt8 < targetDebt8)) {
            uint256 previousDebt = ledger.beforeDeposit();
            uint256 add = (targetDebt8 - debt8) * 1e10;
            if (!resize) {
                // Earned collateral bypasses price-move hysteresis, only up to
                // its own borrowing capacity and the current reserve target.
                uint256 credit8 = Math.mulDiv(value8, Math.min(credit, v.totalAssets()), v.totalAssets());
                add = Math.min(add, credit8 * maxLtv / 10_000 * 1e10);
            }
            uint256 wanted = add;
            add = Math.min(add, v.yieldSource().admissionCapacity());
            // a slice below the entry lane minimum waits for more credit
            ExecutionController control = v.executionController();
            if (add != 0 && address(control) != address(0)) add = control.fit(address(v.yieldSource()),
                address(hollar), IEntrySource(address(v.yieldSource())).primeAToken(), add);
            if (add == 0) return (shares, supplied, 0, credit);
            pool.borrow(address(hollar), add, VARIABLE_RATE, 0, address(this));
            uint256 lt = v.synthLtBps();
            uint256 extra = SyntheticFloor.buffered(add, lt);
            SyntheticFloor.supply(pool, v.synthetic(), extra);
            supplied += extra;
            // INV-1: never add debt against a breached floor; maintainPeg restores it
            if (supplied * lt / 10_000 < v.hollarDebtToken().balanceOf(address(this))) revert PrincipalNotFloored();
            hollar.forceApprove(address(v.yieldSource()), add);
            shares += v.yieldSource().deposit(add);
            ledger.borrowed(previousDebt);
            // Preserve unused reinvestment credit when the shared trade budget
            // only admits part of the intended additional borrow.
            credit = Math.mulDiv(credit, wanted - add, wanted);
        } else if (!exiting && ltv > maxLtv + LTV_BAND_HIGH_GAP_BPS) {
            uint256 activeShares = shares - v.yieldAccounting().reservedShares();
            uint256 equity8 = shares == 0 ? 0 : Math.mulDiv(v.yieldSource().equityOf(address(this)), activeShares, shares);
            uint256 repayment8 = Math.min(debt8 - targetDebt8, equity8);
            uint256 slice = equity8 == 0 ? 0 : Math.mulDiv(activeShares, repayment8, equity8);
            if (slice != 0) {
                uint256 pending = v.yieldSource().pendingUnwindOf(address(this));
                uint256 principal = v.yieldSource().principalOf(address(this));
                uint256 basis = Math.mulDiv(principal, slice, activeShares);
                v.yieldSource().requestUnwindProtected(slice, basis);
                shares -= slice;
                target = v.yieldSource().pendingUnwindOf(address(this)) - pending;
                ledger.expectDelever(target, basis);
            }
        }
        emit Rebalanced(ltv, v.hollarDebtToken().balanceOf(address(this)) / 1e10 * 10_000 / value8);
    }

    function compound(address tokenIn, uint256 amountIn, uint256 minimum, bytes calldata route) external returns (uint256 reward, uint256 serviceRemainder) {
        if (amountIn == 0) revert ZeroAmount();
        ICompoundVault v = ICompoundVault(address(this));
        IPropellerFeeController controller = v.feeController();
        IMainDebt buffer = v.mainDebt();
        if (address(controller) == address(0) || address(buffer) == address(0)) revert ZeroAddress();
        IERC20 collateral = v.collateral();
        ISwapper swapper = v.swapper();
        IAavePool pool = v.pool();
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 inputBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore + amountIn) revert PrincipalShortfall();
        uint256 fairOut = controller.quoteCollateral(address(this), tokenIn, amountIn);
        uint256 floor = fairOut * (10_000 - v.compoundSlippageBps()) / 10_000;
        if (minimum < floor) minimum = floor;
        ExecutionController control = v.executionController();
        if (address(control) != address(0)) minimum = Math.max(minimum,
            control.consume(tokenIn, address(collateral), amountIn, fairOut));
        if (tokenIn != address(collateral)) {
            IERC20(tokenIn).forceApprove(address(swapper), amountIn);
            swapper.sell(tokenIn, address(collateral), amountIn, minimum, route);
            IERC20(tokenIn).forceApprove(address(swapper), 0);
            if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore) revert PrincipalShortfall();
        }
        uint256 out = collateral.balanceOf(address(this)) - collateralBefore;
        if (address(control) != address(0)) control.record(tokenIn, address(collateral), out);
        if (out == 0 || out < minimum) revert PrincipalShortfall();
        collateral.forceApprove(address(controller), out);
        uint256 service;
        if (v.yieldAccounting().harvestUnits() != 0) {
            uint256 fee;
            (reward, service, fee) = v.yieldAccounting().splitHarvest(out);
            controller.collectHarvestFee(out, fee, msg.sender);
        } else {
            service = out - controller.collectFee(out, msg.sender);
        }
        collateral.forceApprove(address(controller), 0);
        // execution costs beyond the servicing slice come from this harvest's reward fund,
        // never from previously funded user collateral
        uint256 cashBefore = buffer.activeFunds();
        uint256 fresh = reward + service;
        collateral.forceApprove(address(buffer), fresh);
        out = buffer.harvest(fresh);
        uint256 spent = fresh - out;
        uint256 rewardSpent = spent > service ? spent - service : 0;
        reward = Math.min(reward, out);
        serviceRemainder = out - reward;
        uint256 cashAfter = buffer.activeFunds();
        if (rewardSpent != 0 && cashAfter > cashBefore) {
            v.yieldAccounting().retainServicingSurplus(Math.min(cashAfter - cashBefore, buffer.quoteHollar(rewardSpent)));
        }
        collateral.forceApprove(address(buffer), 0);
        if (out != 0) {
            collateral.forceApprove(address(pool), out);
            pool.supply(address(collateral), out, address(this), 0);
            collateral.forceApprove(address(pool), 0);
        }
        if (collateral.balanceOf(address(this)) != collateralBefore) revert PrincipalShortfall();
        emit Harvested(out);
    }
}
