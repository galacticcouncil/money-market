// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAavePool, IPoolAddressesProvider, IAaveOracle} from "../interfaces/IAavePool.sol";
import {ExecutionController} from "../ExecutionController.sol";
import {DcaDispatch} from "./DcaDispatch.sol";

// same selectors as SubLoop's own declarations, which tests and integrators reference
error InvalidParameters();
error HealthyEnough();

/// @dev SubLoop's storage layout, events and shared views. The loop and its delegate logic both
/// inherit it, so the logic reads and writes the loop's storage under delegatecall.
abstract contract SubLoopStorage is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VARIABLE_RATE = 2;
    /// @dev per-step HF floor for the in-route unwind withdraw, just above aave's 1.0 limit
    uint256 internal constant STEP_HF_FLOOR = 1.02e18;

    // config
    IAavePool public pool;
    IERC20 public hollar;
    IERC20 public prime;
    IERC20 public primeAToken; // collateral receipt (this loop's Aave position)
    /// @notice only caller of harvest and recipient of surplus PRIME
    address public harvester;

    // policy params
    uint256 public targetHf; // e.g. 1.05e18
    uint256 public deployHfFloor; // borrow only while HF would stay >= this (≥ target, swap-lag buffer)
    uint256 public deLeverTrigger; // e.g. 1.10e18
    uint256 public harvestThreshold; // WAD fraction of equity
    uint256 public deployTranche; // HOLLAR per pokeBorrow lever-in
    uint256 public unwindTranche; // aPRIME per pokeRepay sell sliver

    // router route config (HOLLAR↔aPRIME)
    uint32 public hollarAssetId; // 222
    uint32 public primeAssetId; // 43
    uint32 public aPrimeAssetId; // 1043
    uint32 public primePoolId; // stableswap 143 (HOLLAR↔PRIME)
    uint32 public dcaSlippagePpm; // Permill slippage vs the oracle-fair min-out

    // equity shares
    mapping(address => uint256) internal _sharesOf;
    uint256 internal _totalShares;
    /// @notice Principal (cost-basis) equity, HOLLAR 18dp — the seed deposited,
    ///         net of unwinds. Equity above this is harvestable carry (yield).
    uint256 public principalEquity;

    // unwind / de-lever state
    uint256 public unwindTargetEquity; // total equity (HOLLAR, 18dp) being unwound
    mapping(address => uint256) public unwindRequested; // per-vault equity targeted (18dp)
    mapping(address => uint256) public freedHollar; // per-vault equity freed, not yet pulled (18dp)
    uint256 public reservedFreed; // Σ freedHollar (HOLLAR held back for vaults to pull)
    uint256 public unwindOrderId;
    address[] internal _unwinders; // vaults with an open unwind request
    mapping(address => bool) internal _isUnwinding;
    /// @notice Outstanding safety de-lever debt repay (HOLLAR 18dp). Set by
    ///         deLever, drained by pokeRepay ahead of the proportional split.
    uint256 public deleverDebtTarget;
    bool internal _emergencyPaused;
    mapping(address => uint256) public unwindYieldAllowance;
    mapping(address => uint256) internal _unwindExecutionCost;
    uint256[37] private __gap;
    mapping(address => uint256) internal _principalOf;
    ExecutionController public executionController;

    event Borrowed(uint256 amount, uint256 hfAfter);
    event Repaid(uint256 amount, uint256 hfAfter);
    event DeLevered(uint256 hfBefore, uint256 hfAfter);
    event UnwindYieldSpent(address indexed vault, uint256 cost);

    function _healthFactor() internal view returns (uint256 hf) {
        (, , , , , hf) = pool.getUserAccountData(address(this));
    }

    function _totalEquity() internal view returns (uint256) {
        (uint256 collBase, uint256 debtBase, , , , ) = pool.getUserAccountData(address(this));
        uint256 cash = hollar.balanceOf(address(this));
        if (cash > reservedFreed) collBase += (cash - reservedFreed) / 1e10;
        return collBase > debtBase ? collBase - debtBase : 0;
    }

    function _liveEquity18() internal view returns (uint256) {
        uint256 gross = _totalEquity() * 1e10;
        return gross > unwindTargetEquity ? gross - unwindTargetEquity : 0;
    }

    function _admissionCapacity() internal view returns (uint256) {
        uint256 capacity = address(executionController) == address(0) ? type(uint256).max
            : executionController.available(address(this), address(hollar), address(primeAToken));
        return deployTranche == 0 ? capacity : Math.min(capacity, deployTranche);
    }

    /// @dev (pHollar, pPrime) from the market's AaveOracle (USD, 8dp) — the same
    ///      feed Aave uses for HF, so swap min-outs resist pool-spot manipulation.
    function _oracleRate() internal view returns (uint256 pHollar, uint256 pPrime) {
        address oracle = IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle();
        pHollar = IAaveOracle(oracle).getAssetPrice(address(hollar));
        pPrime = IAaveOracle(oracle).getAssetPrice(address(prime));
        if (pHollar == 0 || pPrime == 0) revert InvalidParameters();
    }

    function _minimumOut(uint256 fairOut) internal view returns (uint128) {
        uint256 minimum = fairOut * (1_000_000 - dcaSlippagePpm) / 1_000_000;
        if (minimum == 0 || minimum > type(uint128).max) revert InvalidParameters();
        return uint128(minimum);
    }
}

/// @notice SubLoop's execution paths: the ramp, the unwind spiral, the safety de-lever and their
/// router trades. Reached only by delegatecall from the SubLoop, which applies roles, pauses and
/// the reentrancy guard; this contract holds no funds and its own storage stays empty.
contract SubLoopLogic is SubLoopStorage {
    using SafeERC20 for IERC20;

    function fundDeploy(uint256 amount) external {
        _fundDeploy(amount);
    }

    /// @dev permissionless: bounded by deployHfFloor, deployTranche and an oracle-fair minOut
    function pokeBorrow() external returns (uint256 borrowed) {
        _dropMetDelever();
        if (unwindTargetEquity != 0 || deleverDebtTarget != 0) return 0;
        // the route's aave hop mints aPRIME without enabling it as collateral
        if (primeAToken.balanceOf(address(this)) > 0) {
            pool.setUserUseReserveAsCollateral(address(prime), true);
        }
        // maxDebt = collBase·wAvgLT / deployHfFloor, against current collateral only
        (uint256 collBase8, uint256 debtBase8, , uint256 wAvgLtBps, , ) =
            pool.getUserAccountData(address(this));
        // don't borrow against carry the harvester is about to remove
        uint256 equity8 = _totalEquity();
        uint256 basis8 = (principalEquity + unwindTargetEquity) / 1e10;
        uint256 earned8 = equity8 > basis8 ? equity8 - basis8 : 0;
        uint256 deployCollateral8 = collBase8 - Math.min(collBase8, earned8);
        uint256 collWithLt8 = (deployCollateral8 * wAvgLtBps) / 1e4;
        uint256 maxDebt8 = (collWithLt8 * WAD) / deployHfFloor; // 8dp USD
        if (maxDebt8 <= debtBase8) {
            emit Borrowed(0, _healthFactor());
            return 0;
        }
        // HOLLAR is 18dp and $1 ⇒ amount(18dp) = borrowBase(8dp) · 1e10.
        uint256 borrowHollar = (maxDebt8 - debtBase8) * 1e10;
        // tranche the synchronous sale so a one-shot borrow-to-floor can't trip slippage
        if (deployTranche > 0 && borrowHollar > deployTranche) borrowHollar = deployTranche;
        if (address(executionController) != address(0)) borrowHollar = Math.min(borrowHollar, _admissionCapacity());
        if (borrowHollar == 0) {
            emit Borrowed(0, _healthFactor());
            return 0;
        }
        pool.borrow(address(hollar), borrowHollar, VARIABLE_RATE, 0, address(this));
        _fundDeploy(borrowHollar);
        emit Borrowed(borrowHollar, _healthFactor());
        return borrowHollar;
    }

    /// @dev synchronous HOLLAR→aPRIME router sale (stableswap + aave supply in one route)
    function _fundDeploy(uint256 amount) internal {
        if (amount == 0) return;
        // fair aPRIME (6dp) = HOLLAR (18dp) · pHollar/pPrime / 1e12, off the aave oracle
        (uint256 pHollar, uint256 pPrime) = _oracleRate();
        uint256 fairOut = (amount * pHollar) / pPrime / 1e12;
        if (amount > type(uint128).max) revert InvalidParameters();
        uint128 minOut = _minimumOut(fairOut);
        ExecutionController control = executionController;
        uint256 before_;
        if (address(control) != address(0)) {
            uint256 quoted = control.consume(address(hollar), address(primeAToken), amount, fairOut);
            if (quoted > type(uint128).max) revert InvalidParameters();
            minOut = uint128(Math.max(minOut, quoted));
            before_ = primeAToken.balanceOf(address(this));
        }
        DcaDispatch.routerSell(hollarAssetId, aPrimeAssetId, uint128(amount), minOut, _deployRoute());
        if (address(control) != address(0)) control.record(address(hollar), address(primeAToken), primeAToken.balanceOf(address(this)) - before_);
        pool.setUserUseReserveAsCollateral(address(prime), true);
    }

    /// @dev HOLLAR →[stableswap primePoolId]→ PRIME →[Aave]→ aPRIME.
    function _deployRoute() internal view returns (DcaDispatch.Hop[] memory r) {
        r = new DcaDispatch.Hop[](2);
        r[0] = DcaDispatch.Hop(DcaDispatch.POOL_STABLESWAP, true, primePoolId, hollarAssetId, primeAssetId);
        r[1] = DcaDispatch.Hop(DcaDispatch.POOL_AAVE, false, 0, primeAssetId, aPrimeAssetId);
    }

    /// @dev aPRIME →[Aave]→ PRIME →[stableswap primePoolId]→ HOLLAR.
    function _unwindRoute() internal view returns (DcaDispatch.Hop[] memory r) {
        r = new DcaDispatch.Hop[](2);
        r[0] = DcaDispatch.Hop(DcaDispatch.POOL_AAVE, false, 0, aPrimeAssetId, primeAssetId);
        r[1] = DcaDispatch.Hop(DcaDispatch.POOL_STABLESWAP, true, primePoolId, primeAssetId, hollarAssetId);
    }

    function pokeRepay() external returns (uint256 work) {
        uint256 previousTarget = deleverDebtTarget;
        _dropMetDelever();
        // Clearing a completed safety commitment is useful work too: otherwise
        // a keeper that skips zero-work simulations would leave ramping blocked.
        work = previousTarget > deleverDebtTarget ? 1 : 0;
        if (unwindTargetEquity == 0 && deleverDebtTarget == 0) return work;
        if (_emergencyPaused && deleverDebtTarget == 0) return work;
        // sell an HF-safe aPRIME sliver; capping at STEP_HF_FLOOR keeps the in-route withdraw from reverting
        if (unwindTargetEquity > 0 || deleverDebtTarget > 0) {
            (uint256 coll8, uint256 debt8, , uint256 lt, , ) = pool.getUserAccountData(address(this));
            if (debt8 > 0 && lt > 0) {
                // min collateral to keep HF ≥ 1.02 after the withdraw:
                //   minColl8 = floor * debt8 * 1e4 / (lt_bps * WAD)
                uint256 minColl8 = (STEP_HF_FLOOR * debt8 * 10000) / (lt * WAD);
                if (coll8 > minColl8) {
                    // size at the oracle price, not $1, or a PRIME premium oversells past the HF floor.
                    // aPRIME(6dp) = budgetUSD8 · 0.9 · 1e6 / pPrime(8dp)
                    (uint256 pHollar, uint256 pPrime) = _oracleRate();
                    uint256 sellAmt = ((coll8 - minColl8) * 90 / 100) * 1e6 / pPrime;
                    if (unwindTranche > 0 && sellAmt > unwindTranche) sellAmt = unwindTranche;
                    if (deleverDebtTarget == 0) {
                        uint256 need = _unwindNeedAPrime(coll8, debt8, pPrime);
                        if (sellAmt > need) sellAmt = need;
                    }
                    uint256 apBal = primeAToken.balanceOf(address(this));
                    if (sellAmt > apBal) sellAmt = apBal;
                    if (sellAmt > 0) {
                        // min-out off the AaveOracle fair rate (aPRIME 1:1 PRIME).
                        // fair HOLLAR (18dp) = sellAmt aPRIME (6dp) · pPrime/pHollar · 1e12.
                        uint256 fairOut = (sellAmt * pPrime * 1e12) / pHollar;
                        _sellForUnwind(sellAmt, fairOut);
                    }
                }
            } else if (debt8 == 0) {
                deleverDebtTarget = 0;
                if (_emergencyPaused) return 0;
                (uint256 pHollar, uint256 pPrime) = _oracleRate();
                uint256 sellAmt = Math.mulDiv(unwindTargetEquity, pHollar, pPrime * 1e12, Math.Rounding.Up);
                uint256 apBal = primeAToken.balanceOf(address(this));
                if (sellAmt > apBal) sellAmt = apBal;
                if (unwindTranche > 0 && sellAmt > unwindTranche) sellAmt = unwindTranche;
                if (sellAmt > 0) {
                    uint256 fairOut = (sellAmt * pPrime * 1e12) / pHollar;
                    _sellForUnwind(sellAmt, fairOut);
                }
            }
        }

        // HOLLAR the spiral delivered, excluding what vaults have yet to pull
        uint256 bal = hollar.balanceOf(address(this));
        uint256 avail = bal > reservedFreed ? bal - reservedFreed : 0;
        if (avail == 0) {
            // Neither an HF block nor rounding proves a claim is unrecoverable.
            emit Repaid(0, _healthFactor());
            return work;
        }

        // safety de-lever first: the full proceeds repay loop debt, no payout or split
        uint256 deleverRepaid;
        if (deleverDebtTarget > 0) {
            deleverRepaid = avail < deleverDebtTarget ? avail : deleverDebtTarget;
            hollar.forceApprove(address(pool), 0);
            hollar.forceApprove(address(pool), deleverRepaid);
            deleverRepaid = pool.repay(address(hollar), deleverRepaid, VARIABLE_RATE, address(this));
            hollar.forceApprove(address(pool), 0);
            deleverDebtTarget -= deleverRepaid;
            avail -= deleverRepaid;
            if (avail == 0) {
                emit Repaid(deleverRepaid, _healthFactor());
                return deleverRepaid;
            }
        }

        if (_emergencyPaused) {
            emit Repaid(deleverRepaid, _healthFactor());
            return deleverRepaid;
        }

        // repay the sold slice's debt portion so the position shrinks proportionally; free the rest
        //   preColl = currentColl + avail ; repay = avail · debt/preColl
        (uint256 collBase8, uint256 debtBase8, , , , ) = pool.getUserAccountData(address(this));
        uint256 avail8 = avail / 1e10;
        uint256 preColl8 = collBase8 + avail8;
        uint256 repay8 = preColl8 == 0 ? 0 : (avail8 * debtBase8) / preColl8;
        uint256 repayHollar = repay8 * 1e10;
        if (repayHollar > avail) repayHollar = avail;

        if (repayHollar > 0) {
            hollar.forceApprove(address(pool), 0);
            hollar.forceApprove(address(pool), repayHollar);
            repayHollar = pool.repay(address(hollar), repayHollar, VARIABLE_RATE, address(this));
            hollar.forceApprove(address(pool), 0);
        }

        uint256 freed = avail - repayHollar;
        if (freed > 0) _creditFreed(freed);
        emit Repaid(deleverRepaid + repayHollar, _healthFactor());
        return deleverRepaid + repayHollar + freed;
    }

    function _sellForUnwind(uint256 amount, uint256 fairOut) internal {
        ExecutionController control = executionController;
        uint256 minimum;
        if (address(control) != address(0)) {
            uint256 wanted = amount;
            (amount, minimum) = control.prepare(address(primeAToken), address(hollar), amount, fairOut,
                deleverDebtTarget != 0);
            if (amount == 0) return;
            fairOut = Math.mulDiv(fairOut, amount, wanted);
        }
        if (amount > type(uint128).max) revert InvalidParameters();
        minimum = Math.max(minimum, _minimumOut(fairOut));
        if (minimum > type(uint128).max) revert InvalidParameters();
        uint256 before_ = hollar.balanceOf(address(this));
        DcaDispatch.routerSell(aPrimeAssetId, hollarAssetId, uint128(amount), uint128(minimum), _unwindRoute());
        uint256 received = hollar.balanceOf(address(this)) - before_;
        if (address(control) != address(0)) control.record(address(primeAToken), address(hollar), received);
        if (received >= fairOut || deleverDebtTarget != 0) return;
        uint256 cost = fairOut - received;
        uint256 target = unwindTargetEquity;
        uint256 weight;
        uint256 charged;
        // Only realized execution loss, capped by each vault's un-compounded
        // yield. Costs above this allowance remain an unfunded source liability.
        for (uint256 i; i < _unwinders.length; ++i) {
            address v = _unwinders[i];
            uint256 remaining = unwindRequested[v] - freedHollar[v];
            uint256 prior = target == 0 ? 0 : cost * weight / target;
            weight += remaining;
            uint256 cut = target == 0 ? 0 : cost * weight / target - prior;
            if (cut > unwindYieldAllowance[v]) cut = unwindYieldAllowance[v];
            if (cut > remaining) cut = remaining;
            unwindYieldAllowance[v] -= cut;
            unwindRequested[v] -= cut;
            _unwindExecutionCost[v] += cut;
            charged += cut;
            if (cut != 0) emit UnwindYieldSpent(v, cut);
        }
        unwindTargetEquity -= charged;
    }

    /// @dev drop a de-lever target once HF is back at targetHf (repaid or price recovered)
    function _dropMetDelever() internal {
        if (deleverDebtTarget != 0 && _healthFactor() >= targetHf) deleverDebtTarget = 0;
    }

    /// @dev aPRIME (6dp) still needed: target·coll/(coll − debt) HOLLAR less idle HOLLAR,
    /// padded by the slippage allowance so fees don't leave a tail
    function _unwindNeedAPrime(uint256 coll8, uint256 debt8, uint256 pPrime) internal view returns (uint256) {
        if (coll8 <= debt8) return type(uint256).max;
        // A remaining claim below one USD8/PRIME unit still needs funding.
        // Round required sales up; truncating either conversion pins that tail.
        uint256 need8 = Math.mulDiv(Math.ceilDiv(unwindTargetEquity, 1e10), coll8,
            coll8 - debt8, Math.Rounding.Up);
        uint256 bal = hollar.balanceOf(address(this));
        uint256 idle8 = bal > reservedFreed ? (bal - reservedFreed) / 1e10 : 0;
        if (need8 <= idle8) return 0;
        return Math.mulDiv(need8 - idle8, 1e12,
            pPrime * (1_000_000 - dcaSlippagePpm), Math.Rounding.Up);
    }

    /// @dev credit freed HOLLAR pro rata by each request's uncredited remainder; Σrem == target,
    /// so at most `freed` is distributed and reservedFreed never overstates the balance
    function _creditFreed(uint256 freed) internal {
        uint256 target = unwindTargetEquity;
        if (target == 0) return;
        uint256 n = _unwinders.length;
        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            address v = _unwinders[i];
            uint256 rem = unwindRequested[v] - freedHollar[v];
            if (rem == 0) continue;
            uint256 cut = (freed * rem) / target;
            if (cut > rem) cut = rem;
            freedHollar[v] += cut;
            distributed += cut;
        }
        reservedFreed += distributed;
        // shrink the target so the spiral stops once everything requested is freed
        unwindTargetEquity = unwindTargetEquity > distributed ? unwindTargetEquity - distributed : 0;
        // rounding dust stays idle and joins the next pokeRepay's avail
    }

    /// @dev sets repay target x solving (coll − x)·lt / (debt − x) = targetHf; pokeRepay executes it
    function deLever() external {
        uint256 hf = _healthFactor();
        if (hf > deLeverTrigger) revert HealthyEnough();
        (uint256 coll8, uint256 debt8, , uint256 ltBps, , ) = pool.getUserAccountData(address(this));
        uint256 ltWad = ltBps * 1e14; // bps → WAD
        // degenerate (no debt / LT ≥ target HF) or already at/above target
        if (debt8 == 0 || targetHf <= ltWad) revert HealthyEnough();
        if (hf >= targetHf) revert HealthyEnough();
        uint256 x8 = (targetHf * debt8 - ltWad * coll8) / (targetHf - ltWad);
        uint256 x18 = x8 * 1e10;
        if (x18 == 0 || x18 <= deleverDebtTarget) revert HealthyEnough();
        deleverDebtTarget = x18; // re-derive, don't accumulate
        emit DeLevered(hf, _healthFactor());
    }

    function _authorizeUpgrade(address) internal pure override {
        revert InvalidParameters();
    }
}
