// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IAavePool} from "./interfaces/IAavePool.sol";
import {ILooperPosition} from "./interfaces/ILooperPosition.sol";
import {LooperLogic} from "./LooperLogic.sol";

/// @title LooperPosition
/// @notice One leveraged Aave position per clone, owned by the holder of factory NFT `tokenId`. The clone
/// is the Aave user, the ICE intent owner and the forward receiver, so each fill calls it back as itself
/// and it runs the next rung. Storage and entry points only; the logic lives in `LooperLogic`.
contract LooperPosition is ILooperPosition {
    IAavePool public immutable pool;

    LooperLogic.State internal s;

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    constructor(IAavePool pool_) {
        pool = pool_;
    }

    // ── factory ──

    function initialize(uint256 id, Params calldata p) external {
        LooperLogic.initialize(s, pool, id, p);
    }

    function deposit(uint256 amount) external {
        if (msg.sender != s.factory) revert NotFactory();
        LooperLogic.deposit(s, pool, amount);
    }

    // ── owner ──

    function withdraw(uint256 amount) external onlyOwner {
        LooperLogic.withdraw(s, pool, amount);
    }

    function close() external onlyOwner {
        LooperLogic.close(s);
    }

    function cancel(uint128 intentId) external onlyOwner {
        LooperLogic.cancel(s, intentId);
    }

    function resume(uint128 intentId) external onlyOwner {
        LooperLogic.resume(s, pool, intentId);
    }

    function setSlippage(uint16 bps) external onlyOwner {
        LooperLogic.setSlippage(s, bps);
    }

    function setFeeReserve(uint256 amount) external onlyOwner {
        LooperLogic.setFeeReserve(s, amount);
    }

    // ── lazy executor ──

    function execute(
        address owner_,
        uint256 intentId,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        bytes calldata data
    ) external returns (bytes4) {
        if (msg.sender != address(this) || owner_ != address(this)) revert WrongIntent();
        LooperLogic.execute(s, intentId, assetIn, amountIn, assetOut, amountOut, data);
        return this.execute.selector;
    }

    /// @notice One rung of the active ladder. Only callable by the position itself, behind try/catch.
    /// A returned stall keeps the rung's effects; a revert (named or Aave's) rolls them back.
    function step() external returns (Stall, uint256) {
        if (msg.sender != address(this)) revert NotOwner();
        return LooperLogic.step(s, pool);
    }

    // ── views ──

    function factory() external view returns (address) {
        return s.factory;
    }

    function tokenId() external view returns (uint256) {
        return s.tokenId;
    }

    function owner() public view returns (address) {
        return IERC721(s.factory).ownerOf(s.tokenId);
    }

    function params() external view returns (Params memory) {
        return Params({
            collateral: address(s.coll),
            aCollateral: address(s.aColl),
            debt: address(s.debt),
            variableDebt: address(s.vDebt),
            feeAsset: address(s.feeAsset),
            debtAssetId: s.debtAssetId,
            aCollateralAssetId: s.aCollAssetId,
            feeAssetId: s.feeAssetId,
            eMode: s.eMode,
            slippageBps: s.slippageBps,
            leverage: s.targetLeverage,
            minHf: s.minHf,
            stepHf: s.stepHf,
            feeReserve: s.feeReserve,
            minIntentDebt: s.minIntentDebt,
            minIntentAToken: s.minIntentAToken
        });
    }

    function slippageBps() external view returns (uint16) {
        return s.slippageBps;
    }

    function feeReserve() external view returns (uint256) {
        return s.feeReserve;
    }

    function targetLeverage() external view returns (uint256) {
        return s.targetLeverage;
    }

    function ladder() external view returns (Ladder) {
        return s.ladder;
    }

    function stalled() external view returns (Stall) {
        return s.stalled;
    }

    function closing() external view returns (bool) {
        return s.closing;
    }

    function nonce() external view returns (uint64) {
        return s.nonce;
    }

    function request() external view returns (uint256) {
        return s.request;
    }

    function principal() external view returns (uint256) {
        return s.principal;
    }

    function pending() external view returns (PendingIntent memory) {
        return s.pending;
    }

    function collateral() external view returns (uint256 c) {
        (c,,,,,) = pool.getUserAccountData(address(this));
    }

    function debt() external view returns (uint256 d) {
        (, d,,,,) = pool.getUserAccountData(address(this));
    }

    function healthFactor() external view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(address(this));
    }

    function aaveLeverage() external view returns (uint256) {
        return LooperLogic.aaveLeverage(pool);
    }

    /// @notice Aave HF with an in-flight exit sliver counted back as collateral.
    function effectiveHealthFactor() external view returns (uint256) {
        return LooperLogic.effectiveHealthFactor(s, pool);
    }

    /// @notice Equity in collateral units: own aToken + debt-asset cash − debt, plus an in-flight input whose
    /// output has not landed yet. The fee budget is not part of it.
    function nav() public view returns (uint256) {
        return LooperLogic.nav(s, pool);
    }

    function leverage() external view returns (uint256) {
        return LooperLogic.leverage(s, pool);
    }

    function pnl() external view returns (int256) {
        return SafeCast.toInt256(nav()) - SafeCast.toInt256(s.principal);
    }

    /// @notice Debt-asset volume a ramp of `amount` collateral at `lev` (WAD) trades, for quoting routes.
    function plannedVolume(uint256 amount, uint256 lev) external view returns (uint256) {
        return LooperLogic.plannedVolume(s, pool, amount, lev);
    }

    function isClosed() external view returns (bool) {
        return LooperLogic.isClosed(s);
    }
}
