// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DcaDispatch} from "juicer-vault/lib/DcaDispatch.sol";

import {IAavePool, IAToken, IAaveOracle, IPoolAddressesProvider} from "./interfaces/IAavePool.sol";
import {ILooperPosition as P} from "./interfaces/ILooperPosition.sol";
import {Units} from "./lib/Units.sol";
import {Dispatch} from "./lib/Dispatch.sol";

/// @title LooperLogic
/// @notice Every position's ladder, Aave and intent logic, deployed once and reached by DELEGATECALL so
/// the position implementation keeps only its storage and entry points. Runs in the position's context:
/// `address(this)` is the position, events are the position's.
library LooperLogic {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TTL_MS = 5 minutes * 1000;
    uint256 internal constant A_TOKEN_ROUNDING = 1000;
    /// @dev Aave base units of oracle rounding tolerated between two Aave figures.
    uint256 internal constant TOL = 10;
    uint256 internal constant CAP_BPS = 9_000;
    uint256 internal constant EMERGENCY_STEP = 0.02e18;
    uint256 internal constant EMERGENCY_FLOOR = 1.01e18;
    /// @dev A failed dispatch burns its whole frame; the catch path still needs `CATCH_RESERVE` to record
    /// the stall and acknowledge inside the 2,000,000 forward gas limit.
    uint256 internal constant DISPATCH_GAS = 1_000_000;
    uint256 internal constant CATCH_RESERVE = 100_000;

    struct State {
        address factory;
        uint64 tokenId;
        uint8 eMode;
        uint8 decC;
        uint8 decD;
        IERC20 coll;
        uint32 debtAssetId;
        uint32 aCollAssetId;
        uint16 collId;
        IAToken aColl;
        uint16 slippageBps;
        P.Ladder ladder;
        P.Stall stalled;
        bool closing;
        IERC20 debt;
        uint64 nonce;
        IERC20 vDebt;
        uint32 feeAssetId;
        IERC20 feeAsset;
        uint256 targetLeverage;
        uint256 minHf;
        uint256 stepHf;
        uint256 feeReserve;
        uint256 minIntentDebt;
        uint256 minIntentAToken;
        uint256 request;
        uint256 principal;
        P.PendingIntent pending;
    }

    // ── factory ──

    /// @dev The first caller becomes the factory; the factory clones and initialises in one transaction.
    function initialize(State storage s, IAavePool pool, uint256 id, P.Params calldata p) external {
        if (s.factory != address(0)) revert P.AlreadyInitialized();
        s.factory = msg.sender;
        s.tokenId = SafeCast.toUint64(id);
        s.coll = IERC20(p.collateral);
        s.aColl = IAToken(p.aCollateral);
        s.debt = IERC20(p.debt);
        s.vDebt = IERC20(p.variableDebt);
        s.feeAsset = IERC20(p.feeAsset);
        s.feeAssetId = p.feeAssetId;
        s.debtAssetId = p.debtAssetId;
        s.aCollAssetId = p.aCollateralAssetId;
        s.eMode = p.eMode;
        s.slippageBps = p.slippageBps;
        s.targetLeverage = p.leverage;
        s.minHf = p.minHf;
        s.stepHf = p.stepHf;
        s.feeReserve = p.feeReserve;
        s.minIntentDebt = p.minIntentDebt;
        s.minIntentAToken = p.minIntentAToken;
        s.decC = uint8(pool.getConfiguration(p.collateral) >> 48);
        s.decD = uint8(pool.getConfiguration(p.debt) >> 48);
        s.collId = pool.getReserveData(p.collateral).id;

        _feeCurrency(s);
        if (p.eMode != 0) pool.setUserEMode(p.eMode);
        _normalise(s, pool, false);
    }

    function deposit(State storage s, IAavePool pool, uint256 amount) external {
        _feeCurrency(s);
        if (s.pending.kind != P.Kind.None || s.ladder != P.Ladder.None) revert P.Busy();
        if (amount == 0 || s.coll.balanceOf(address(this)) < amount) revert P.NothingToDo();
        _approve(s.coll, pool, amount);
        pool.supply(address(s.coll), amount, address(this), 0);
        _normalise(s, pool, false);
        s.principal += amount;
        s.ladder = P.Ladder.Ramp;
        s.stalled = P.Stall.None;
        s.closing = false;
        emit P.Deposited(amount);
        _attempt(s);
    }

    // ── owner ──

    function withdraw(State storage s, IAavePool pool, uint256 amount) external {
        _tryFeeCurrency(s);
        _requireIdle(s);
        _normalise(s, pool, true);
        (uint256 c, uint256 d,,,,) = pool.getUserAccountData(address(this));
        uint256 equity = Units.sat(c, d);
        if (equity == 0) revert P.NothingToDo();
        (uint256 pC,) = _prices(s, pool);
        if (amount >= s.aColl.balanceOf(address(this)) || Units.toBase(amount, pC, s.decC, Math.Rounding.Up) >= equity)
        {
            _startClose(s);
            return;
        }
        s.ladder = P.Ladder.Unwind;
        s.closing = false;
        s.stalled = P.Stall.None;
        s.request = amount;
        emit P.WithdrawRequested(amount);
        _attempt(s);
    }

    function close(State storage s) external {
        _tryFeeCurrency(s);
        _requireIdle(s);
        if (isClosed(s)) revert P.NothingToDo();
        _startClose(s);
    }

    /// @notice Remove the live intent; success of `remove_intent` proves it was this position's.
    function cancel(State storage s, uint128 intentId) external {
        _tryFeeCurrency(s);
        P.PendingIntent memory p = s.pending;
        if (p.kind == P.Kind.None) revert P.NothingToDo();
        if (!_prefixOk(intentId, p)) revert P.WrongIntent();
        if (!Dispatch.dispatch(DcaDispatch.encodeRemoveIntent(intentId), DISPATCH_GAS)) revert P.WrongIntent();
        _settle(s, p, false, 0);
        s.stalled = P.Stall.Cancelled;
        emit P.Cancelled();
    }

    /// @notice Past the deadline: remove or reconcile the pending intent. Stalled with nothing pending:
    /// clear the stall and run one rung.
    function resume(State storage s, IAavePool pool, uint128 intentId) external {
        _tryFeeCurrency(s);
        P.PendingIntent memory p = s.pending;
        if (p.kind != P.Kind.None) {
            if (block.timestamp * 1000 < p.deadline) revert P.Busy();
            if (!_prefixOk(intentId, p)) revert P.WrongIntent();
            if (Dispatch.dispatch(DcaDispatch.encodeRemoveIntent(intentId), DISPATCH_GAS)) {
                _settle(s, p, false, 0);
                return;
            }
            // After the deadline a failed removal leaves two cases: filled, or returned (now or later).
            uint256 out = _outDelta(s, pool, p);
            if (out >= p.reconcileOut) {
                _settle(s, p, true, out);
                _attempt(s);
            } else {
                _settle(s, p, false, 0);
            }
            return;
        }
        if (s.stalled == P.Stall.None || s.ladder == P.Ladder.None) revert P.NothingToDo();
        s.stalled = P.Stall.None;
        _attempt(s);
    }

    function setSlippage(State storage s, uint16 bps) external {
        _tryFeeCurrency(s);
        if (bps >= BPS) revert P.SlippageTooHigh();
        s.slippageBps = bps;
    }

    /// @dev Forward fees follow the fee multiplier: the owner keeps the reserve above one callback's fee.
    function setFeeReserve(State storage s, uint256 amount) external {
        _tryFeeCurrency(s);
        if (amount == 0) revert P.InvalidParams();
        s.feeReserve = amount;
    }

    // ── lazy executor ──

    function execute(
        State storage s,
        uint256 intentId,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        bytes calldata data
    ) external {
        (P.Kind kind, uint64 n) = abi.decode(data, (P.Kind, uint64));
        P.PendingIntent memory p = s.pending;
        if (p.kind == P.Kind.None || p.nonce != n || p.kind != kind) {
            if (n == 0 || n > s.nonce) revert P.WrongIntent();
            return;
        }
        (address tokenIn, address tokenOut) =
            kind == P.Kind.Entry ? (address(s.debt), address(s.aColl)) : (address(s.aColl), address(s.debt));
        if (
            assetIn != tokenIn || assetOut != tokenOut || amountIn != p.amountIn || amountOut < p.minOut
                || !_prefixOk(intentId, p)
        ) revert P.WrongIntent();
        _settle(s, p, true, amountOut);
        _attempt(s);
    }

    function step(State storage s, IAavePool pool) external returns (P.Stall, uint256) {
        return s.ladder == P.Ladder.Unwind ? _rungDown(s, pool) : _rung(s, pool);
    }

    // ── views ──

    function aaveLeverage(IAavePool pool) public view returns (uint256) {
        (uint256 c, uint256 d,,,,) = pool.getUserAccountData(address(this));
        if (c == 0) return 0;
        if (c <= d) return type(uint256).max;
        return Math.mulDiv(c, WAD, c - d);
    }

    function effectiveHealthFactor(State storage s, IAavePool pool) external view returns (uint256) {
        (uint256 c, uint256 d,, uint256 lt,, uint256 hf) = pool.getUserAccountData(address(this));
        P.PendingIntent memory p = s.pending;
        if (p.kind != P.Kind.Exit || d == 0 || _outDelta(s, pool, p) >= p.reconcileOut) return hf;
        (uint256 pC,) = _prices(s, pool);
        return Math.mulDiv(c + Units.toBase(p.amountIn, pC, s.decC, Math.Rounding.Down), lt * 1e14, d);
    }

    function nav(State storage s, IAavePool pool) public view returns (uint256) {
        (uint256 pC, uint256 pD) = _prices(s, pool);
        return Units.fromBase(_navBase(s, pool, pC, pD), pC, s.decC, Math.Rounding.Down);
    }

    function leverage(State storage s, IAavePool pool) external view returns (uint256) {
        (uint256 pC, uint256 pD) = _prices(s, pool);
        uint256 n = _navBase(s, pool, pC, pD);
        if (n == 0) return 0;
        return Math.mulDiv(Units.toBase(s.aColl.balanceOf(address(this)), pC, s.decC, Math.Rounding.Down), WAD, n);
    }

    function plannedVolume(State storage s, IAavePool pool, uint256 amount, uint256 lev)
        external
        view
        returns (uint256)
    {
        (uint256 pC, uint256 pD) = _prices(s, pool);
        uint256 base = Math.mulDiv(Units.toBase(amount, pC, s.decC, Math.Rounding.Down), Units.sat(lev, WAD), WAD);
        return Units.fromBase(base, pD, s.decD, Math.Rounding.Down);
    }

    function isClosed(State storage s) public view returns (bool) {
        return s.ladder == P.Ladder.None && s.pending.kind == P.Kind.None && s.vDebt.balanceOf(address(this)) == 0
            && s.aColl.scaledBalanceOf(address(this)) == 0;
    }

    // ── ramp ──

    function _rung(State storage s, IAavePool pool) internal returns (P.Stall, uint256) {
        _normalise(s, pool, false);
        (uint256 c, uint256 d,, uint256 lt, uint256 ltv,) = pool.getUserAccountData(address(this));
        if (lt == 0 || ltv == 0) return (P.Stall.AaveRefused, 0);
        uint256 deployHf = _deployHf(s, lt);
        uint256 maxDebt = Math.min(Math.mulDiv(c, lt * 1e14, deployHf), Units.sat(c * ltv / BPS, TOL));
        (uint256 pC, uint256 pD) = _prices(s, pool);
        uint256 gap = Units.fromBase(Units.sat(maxDebt, d), pD, s.decD, Math.Rounding.Down);
        uint256 amountIn = s.debt.balanceOf(address(this)) + gap;
        uint256 fair =
            Units.fromBase(Units.toBase(amountIn, pD, s.decD, Math.Rounding.Down), pC, s.decC, Math.Rounding.Down);
        uint256 minOut = fair * (BPS - s.slippageBps) / BPS;
        uint256 reconcileOut = Units.sat(minOut, A_TOKEN_ROUNDING);
        if (amountIn < s.minIntentDebt || minOut < s.minIntentAToken || reconcileOut == 0) {
            _completeRamp(s, pool);
            return (P.Stall.None, 0);
        }
        if (gap > 0) _borrow(s, pool, gap);
        _submit(s, P.Kind.Entry, amountIn, minOut, reconcileOut);
        return (P.Stall.None, 0);
    }

    function _completeRamp(State storage s, IAavePool pool) internal {
        s.ladder = P.Ladder.None;
        s.stalled = P.Stall.None;
        emit P.LadderCompleted(aaveLeverage(pool));
    }

    // ── unwind ──

    function _startClose(State storage s) internal {
        s.ladder = P.Ladder.Unwind;
        s.closing = true;
        s.stalled = P.Stall.None;
        s.request = type(uint256).max;
        emit P.WithdrawRequested(type(uint256).max);
        _attempt(s);
    }

    function _rungDown(State storage s, IAavePool pool) internal returns (P.Stall, uint256) {
        _normalise(s, pool, true);
        uint256 owed = s.vDebt.balanceOf(address(this));
        bool closing = s.closing;
        if (closing && owed == 0) return _finish(s, pool);
        (uint256 c, uint256 d,, uint256 lt,,) = pool.getUserAccountData(address(this));
        uint256 lt18 = lt * 1e14;
        (uint256 pC, uint256 pD) = _prices(s, pool);
        uint256 target = closing ? 0 : _debtTarget(s, c, d, lt18, _deployHf(s, lt), pC);
        if (!closing && d <= target + TOL) return _finish(s, pool);

        uint256 hf = d == 0 ? type(uint256).max : Math.mulDiv(c, lt18, d);
        uint256 slip = s.slippageBps;
        uint256 minProceeds = s.minIntentDebt;
        // Above stepHf the cap never crosses it, even if that stalls; at or under it, emergency slivers that each
        // raise HF.
        uint256 stepHf = s.stepHf;
        uint256 cap =
            _cap(s, c, d, lt18, pC, hf > stepHf ? stepHf : Math.max(Units.sat(hf, EMERGENCY_STEP), EMERGENCY_FLOOR));
        uint256 owedBase = closing ? Units.toBase(owed, pD, s.decD, Math.Rounding.Up) : d - target;
        if (cap == 0) {
            return (P.Stall.InsufficientHeadroom, Units.fromBase(owedBase, pD, s.decD, Math.Rounding.Up));
        }

        uint256 need = _grossColl(s, owedBase, slip, pC);
        uint256 floorIn = Math.max(
            _grossColl(s, Units.toBase(minProceeds, pD, s.decD, Math.Rounding.Up), slip, pC), s.minIntentAToken
        );
        uint256 sliver = Math.min(Math.min(Math.max(need, floorIn), cap), s.aColl.balanceOf(address(this)));
        uint256 minOut = Units.fromBase(
            Units.toBase(sliver, pC, s.decC, Math.Rounding.Down), pD, s.decD, Math.Rounding.Down
        ) * (BPS - slip) / BPS;

        if (sliver < s.minIntentAToken || minOut < minProceeds) return _tail(s, pool, owed, owedBase, pC, pD);
        _submit(s, P.Kind.Exit, sliver, minOut, minOut);
        return (P.Stall.None, 0);
    }

    /// @dev Repay what cash covers; finish only on a fresh read showing the target met.
    function _tail(State storage s, IAavePool pool, uint256 owed, uint256 owedBase, uint256 pC, uint256 pD)
        internal
        returns (P.Stall, uint256)
    {
        uint256 cash = s.debt.balanceOf(address(this));
        bool closing = s.closing;
        if (closing && cash >= owed) {
            _repay(s, pool, type(uint256).max, cash);
        } else {
            uint256 x = Math.min(cash, closing ? owed : Units.fromBase(owedBase, pD, s.decD, Math.Rounding.Up));
            if (x > 0) _repay(s, pool, x, x);
        }
        if (closing) {
            uint256 left = s.vDebt.balanceOf(address(this));
            return left == 0 ? _finish(s, pool) : (P.Stall.TailUnfunded, left);
        }
        (uint256 c, uint256 d,, uint256 lt,,) = pool.getUserAccountData(address(this));
        uint256 target = _debtTarget(s, c, d, lt * 1e14, _deployHf(s, lt), pC);
        if (d <= target + TOL) return _finish(s, pool);
        return (P.Stall.TailUnfunded, Units.fromBase(d - target, pD, s.decD, Math.Rounding.Up));
    }

    /// @dev Pays the current NFT holder, whoever opened the position.
    function _finish(State storage s, IAavePool pool) internal returns (P.Stall, uint256) {
        address owner = IERC721(s.factory).ownerOf(s.tokenId);
        if (s.closing) {
            uint256 left = s.vDebt.balanceOf(address(this));
            if (left != 0) return (P.Stall.TailUnfunded, left);
            if (s.aColl.balanceOf(address(this)) > 0) pool.withdraw(address(s.coll), type(uint256).max, owner);
            _sweep(s.debt, owner);
            _sweep(s.coll, owner);
            _sweep(s.feeAsset, owner);
            _sweepForeignATokens(s, pool, owner);
            s.principal = 0;
            s.closing = false;
            s.ladder = P.Ladder.None;
            s.stalled = P.Stall.None;
            emit P.Closed();
            return (P.Stall.None, 0);
        }
        (uint256 c, uint256 d,, uint256 lt,,) = pool.getUserAccountData(address(this));
        (uint256 pC, uint256 pD) = _prices(s, pool);
        uint256 free = Units.sat(c, Math.mulDiv(d, _deployHf(s, lt), lt * 1e14, Math.Rounding.Up));
        uint256 request = s.request;
        uint256 payout = Math.min(
            Math.min(request, Units.fromBase(free, pC, s.decC, Math.Rounding.Down)), s.aColl.balanceOf(address(this))
        );
        // the equity `nav()` reports, so a partial withdraw leaves `pnl()` unchanged
        uint256 equity = Units.fromBase(_navBase(s, pool, pC, pD), pC, s.decC, Math.Rounding.Down);
        if (payout > 0) pool.withdraw(address(s.coll), payout, owner);
        s.principal = equity > payout ? Math.mulDiv(s.principal, equity - payout, equity) : 0;
        s.ladder = P.Ladder.None;
        s.stalled = P.Stall.None;
        emit P.Withdrawn(request, payout);
        return (P.Stall.None, 0);
    }

    /// @dev The debt a position at `deployHf` carries when its equity is the current one less the request.
    function _debtTarget(State storage s, uint256 c, uint256 d, uint256 lt18, uint256 deployHf, uint256 pC)
        internal
        view
        returns (uint256)
    {
        uint256 keep = Units.sat(Units.sat(c, d), Units.toBase(s.request, pC, s.decC, Math.Rounding.Up));
        return Math.mulDiv(keep, lt18, deployHf - lt18);
    }

    function _cap(State storage s, uint256 c, uint256 d, uint256 lt18, uint256 pC, uint256 floorHf)
        internal
        view
        returns (uint256)
    {
        return Units.fromBase(
            Units.sat(c, Math.mulDiv(floorHf, d, lt18, Math.Rounding.Up)), pC, s.decC, Math.Rounding.Down
        ) * CAP_BPS / BPS;
    }

    /// @dev Collateral that sells for `base` after slippage `slip`, rounded up.
    function _grossColl(State storage s, uint256 base, uint256 slip, uint256 pC) internal view returns (uint256) {
        return Units.fromBase(Math.mulDiv(base, BPS, BPS - slip, Math.Rounding.Up), pC, s.decC, Math.Rounding.Up);
    }

    // ── intent lane ──

    function _submit(State storage s, P.Kind kind, uint256 amountIn, uint256 minOut, uint256 reconcileOut) internal {
        uint256 budget = s.feeAsset.balanceOf(address(this));
        if (budget < s.feeReserve) revert P.Stalled(P.Stall.FeeBudgetLow, s.feeReserve - budget);
        uint64 n = ++s.nonce;
        uint64 deadline = SafeCast.toUint64(block.timestamp * 1000 + TTL_MS);
        (uint32 assetIn, uint32 assetOut) =
            kind == P.Kind.Entry ? (s.debtAssetId, s.aCollAssetId) : (s.aCollAssetId, s.debtAssetId);
        bytes memory call = DcaDispatch.encodeSubmitIntent(
            assetIn,
            assetOut,
            SafeCast.toUint128(amountIn),
            SafeCast.toUint128(minOut),
            deadline,
            address(this),
            abi.encode(kind, n)
        );
        if (!Dispatch.dispatch(call, DISPATCH_GAS)) revert P.Stalled(P.Stall.IntentRejected, 0);
        uint256 cash = s.debt.balanceOf(address(this));
        uint256 scaled = s.aColl.scaledBalanceOf(address(this));
        (uint256 inSnap, uint256 outSnap) = kind == P.Kind.Entry ? (cash, scaled) : (scaled, cash);
        s.pending = P.PendingIntent({
            nonce: n,
            kind: kind,
            amountIn: uint128(amountIn),
            minOut: uint128(minOut),
            reconcileOut: SafeCast.toUint128(reconcileOut),
            submittedAt: uint64(block.timestamp),
            deadline: deadline,
            inSnap: inSnap,
            outSnap: outSnap
        });
        emit P.RungSubmitted(kind, n, amountIn, minOut);
    }

    /// @dev Bookkeeping only: never touches Aave, never advances the ladder.
    function _settle(State storage s, P.PendingIntent memory p, bool filled, uint256 amountOut) internal {
        delete s.pending;
        if (filled) {
            emit P.RungFilled(p.kind, p.nonce, amountOut);
        } else {
            s.stalled = P.Stall.Returned;
            emit P.RungReturned(p.kind, p.nonce);
        }
    }

    function _outDelta(State storage s, IAavePool pool, P.PendingIntent memory p) internal view returns (uint256) {
        if (p.kind == P.Kind.Exit) return Units.sat(s.debt.balanceOf(address(this)), p.outSnap);
        uint256 scaled = Units.sat(s.aColl.scaledBalanceOf(address(this)), p.outSnap);
        return Units.rayToTokens(scaled, pool.getReserveNormalizedIncome(address(s.coll)));
    }

    /// @dev The runtime id is `(submission_ms << 64) | counter`; only this submission's second passes.
    function _prefixOk(uint256 intentId, P.PendingIntent memory p) internal pure returns (bool) {
        return (intentId >> 64) / 1000 == p.submittedAt;
    }

    /// @dev Exactly one rung attempt through the position's own `step`, so a revert rolls back only the
    /// rung; whatever it raises becomes `stalled`. The reserve keeps enough gas to record the stall and
    /// acknowledge after a failed dispatch burned its frame.
    function _attempt(State storage s) internal {
        uint256 g = gasleft();
        g = g > CATCH_RESERVE ? g - CATCH_RESERVE : 0;
        try P(address(this)).step{gas: g}() returns (P.Stall r, uint256 remainder) {
            if (r != P.Stall.None) _stop(s, r, remainder);
        } catch (bytes memory err) {
            (P.Stall r, uint256 remainder) = _stallOf(err);
            _stop(s, r, remainder);
        }
    }

    function _stop(State storage s, P.Stall r, uint256 remainder) internal {
        s.stalled = r;
        emit P.LadderStopped(r, remainder);
    }

    function _stallOf(bytes memory err) internal pure returns (P.Stall, uint256) {
        if (err.length != 68) return (P.Stall.AaveRefused, 0);
        bytes4 sel;
        uint256 reason;
        uint256 remainder;
        assembly {
            sel := mload(add(err, 32))
            reason := mload(add(err, 36))
            remainder := mload(add(err, 68))
        }
        if (sel != P.Stalled.selector || reason > uint256(type(P.Stall).max)) return (P.Stall.AaveRefused, 0);
        return (P.Stall(reason), remainder);
    }

    // ── aave ──

    /// @dev First step of every rung, idempotent on balances: foreign collateral off before any sizing,
    /// own aToken flagged, and (unwind) debt-asset cash repaid.
    function _normalise(State storage s, IAavePool pool, bool repayCash) internal {
        uint256 cfg = pool.getUserConfiguration(address(this));
        uint256 own = s.collId;
        for (uint256 i = 0; (cfg >> (2 * i)) != 0; ++i) {
            if (i != own && (cfg >> (2 * i + 1)) & 1 == 1) {
                // a gift whose reserve refuses the disable (paused, or beside a zero-LTV gift) must not block exits
                try pool.setUserUseReserveAsCollateral(pool.getReserveAddressById(uint16(i)), false) {} catch {}
            }
        }
        if (s.aColl.scaledBalanceOf(address(this)) > 0 && (cfg >> (2 * own + 1)) & 1 == 0) {
            pool.setUserUseReserveAsCollateral(address(s.coll), true);
        }
        if (repayCash) {
            uint256 x = Math.min(s.debt.balanceOf(address(this)), s.vDebt.balanceOf(address(this)));
            if (x > 0) _repay(s, pool, x, x);
        }
    }

    function _borrow(State storage s, IAavePool pool, uint256 amount) internal {
        pool.borrow(address(s.debt), amount, 2, 0, address(this));
    }

    function _repay(State storage s, IAavePool pool, uint256 amount, uint256 allowance) internal {
        _approve(s.debt, pool, allowance);
        pool.repay(address(s.debt), amount, 2, address(this));
    }

    /// @dev The ERC20 precompile reports infinite allowance for approved contracts and rejects
    /// `uint256.max`: always reset, then set the exact amount.
    function _approve(IERC20 token, IAavePool pool, uint256 amount) internal {
        token.forceApprove(address(pool), 0);
        token.forceApprove(address(pool), amount);
    }

    function _sweep(IERC20 token, address to) internal {
        uint256 b = token.balanceOf(address(this));
        if (b > 0) token.safeTransfer(to, b);
    }

    /// @dev Best effort: a gift whose reserve refuses the transfer must not block the close.
    function _sweepForeignATokens(State storage s, IAavePool pool, address to) internal {
        address[] memory reserves = pool.getReservesList();
        for (uint256 i = 0; i < reserves.length; ++i) {
            address a = pool.getReserveData(reserves[i]).aTokenAddress;
            if (a == address(s.aColl) || a == address(0)) continue;
            uint256 b = IERC20(a).balanceOf(address(this));
            if (b == 0) continue;
            try IERC20(a).transfer(to, b) {} catch {}
        }
    }

    // ── helpers ──

    function _feeCurrency(State storage s) internal {
        if (!_tryFeeCurrency(s)) revert P.FeeCurrencyRejected();
    }

    /// @dev Exits and recovery never depend on the fee asset staying accepted: without it forwards fail to
    /// queue, fills still land, and the holder settles each rung with `resume`.
    function _tryFeeCurrency(State storage s) internal returns (bool) {
        return Dispatch.dispatch(Dispatch.encodeSetCurrency(s.feeAssetId), DISPATCH_GAS);
    }

    function _deployHf(State storage s, uint256 ltBps) internal view returns (uint256) {
        uint256 l = s.targetLeverage;
        return Math.max(Math.mulDiv(ltBps * 1e14, l, l - WAD, Math.Rounding.Up), s.minHf);
    }

    /// @dev The eMode category's price source when it has one, the Aave oracle per asset otherwise.
    function _prices(State storage s, IAavePool pool) internal view returns (uint256 pC, uint256 pD) {
        IAaveOracle oracle = IAaveOracle(IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle());
        uint8 eMode = s.eMode;
        if (eMode != 0) {
            address source = pool.getEModeCategoryData(eMode).priceSource;
            if (source != address(0)) {
                uint256 price = oracle.getAssetPrice(source);
                return (price, price);
            }
        }
        return (oracle.getAssetPrice(address(s.coll)), oracle.getAssetPrice(address(s.debt)));
    }

    function _navBase(State storage s, IAavePool pool, uint256 pC, uint256 pD) internal view returns (uint256) {
        uint256 assets = Units.toBase(s.aColl.balanceOf(address(this)), pC, s.decC, Math.Rounding.Down)
            + Units.toBase(s.debt.balanceOf(address(this)), pD, s.decD, Math.Rounding.Down);
        P.PendingIntent memory p = s.pending;
        if (p.kind != P.Kind.None && _outDelta(s, pool, p) < p.reconcileOut) {
            assets += p.kind == P.Kind.Entry
                ? Units.toBase(p.amountIn, pD, s.decD, Math.Rounding.Down)
                : Units.toBase(p.amountIn, pC, s.decC, Math.Rounding.Down);
        }
        (, uint256 d,,,,) = pool.getUserAccountData(address(this));
        return Units.sat(assets, d);
    }

    function _requireIdle(State storage s) internal view {
        if (s.pending.kind != P.Kind.None || (s.ladder != P.Ladder.None && s.stalled == P.Stall.None)) revert P.Busy();
    }
}
