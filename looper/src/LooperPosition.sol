// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC6551} from "solady/accounts/ERC6551.sol";

import {IAavePool} from "./interfaces/IAavePool.sol";
import {IIntentForward} from "./interfaces/IIntentForward.sol";
import {ILooperPosition} from "./interfaces/ILooperPosition.sol";
import {LooperLogic} from "./LooperLogic.sol";
import {Dispatch} from "./lib/Dispatch.sol";

/// @title LooperPosition
/// @notice One leveraged Aave position per clone, owned by the holder of factory NFT `tokenId`. The clone
/// is the Aave user, the ICE intent owner and the forward receiver, so each fill calls it back as itself
/// and it runs the next rung. Storage and entry points only; the logic lives in `LooperLogic`.
/// The clone is also the NFT's ERC-6551 account: the holder can `execute` any EVM call from it, except into
/// the account itself, the dispatch precompile, the pool and the position's own tokens, and no credit delegation.
contract LooperPosition is ILooperPosition, IIntentForward, ERC6551 {
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(bytes4 selector);

    /// @dev Every Aave debt token has it; a delegation would let someone borrow against this position after a sale.
    bytes4 internal constant APPROVE_DELEGATION = bytes4(keccak256("approveDelegation(address,uint256)"));

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

    /// @dev The registry lets anyone create this account, so the first initialise must come from the NFT
    /// contract it is bound to, for its own token id. Later calls fall through to `AlreadyInitialized`.
    function initialize(uint256 id, Params calldata p) external {
        if (s.factory == address(0)) {
            (, address tokenContract, uint256 boundId) = token();
            if (msg.sender != tokenContract || id != boundId) revert NotFactory();
        }
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
        return IIntentForward.execute.selector;
    }

    /// @notice One rung of the active ladder. Only callable by the position itself, behind try/catch.
    /// A returned stall keeps the rung's effects; a revert (named or Aave's) rolls them back.
    function step() external returns (Stall, uint256) {
        if (msg.sender != address(this)) revert NotOwner();
        return LooperLogic.step(s, pool);
    }

    // ── token-bound account (ERC-6551, holder only) ──

    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        public
        payable
        override
        returns (bytes memory)
    {
        _checkCall(target, data);
        return super.execute(target, value, data, operation);
    }

    function executeBatch(Call[] calldata calls, uint8 operation) public payable override returns (bytes[] memory) {
        for (uint256 i = 0; i < calls.length; ++i) {
            _checkCall(calls[i].target, calls[i].data);
        }
        return super.executeBatch(calls, operation);
    }

    // ── views ──

    function factory() external view returns (address) {
        return s.factory;
    }

    function tokenId() external view returns (uint256) {
        return s.tokenId;
    }

    function owner() public view override(ILooperPosition, ERC6551) returns (address) {
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

    // ── account internals ──

    function _checkCall(address target, bytes calldata data) internal view {
        _checkTarget(target);
        if (data.length >= 4 && bytes4(data[:4]) == APPROVE_DELEGATION) revert SelectorNotAllowed(APPROVE_DELEGATION);
    }

    /// @dev Pool or token calls would move funds behind the ladder's books, and a self-call would pass the
    /// self-only gates; a dispatch would act as the position's Substrate account, which no NFT transfer resets.
    function _checkTarget(address target) internal view {
        if (
            target == address(this) || target == Dispatch.DISPATCH || target == address(pool)
                || target == address(s.coll) || target == address(s.aColl) || target == address(s.debt)
                || target == address(s.vDebt) || target == address(s.feeAsset) || target == _precompile(s.debtAssetId)
                || target == _precompile(s.aCollAssetId) || target == _precompile(s.feeAssetId)
        ) revert TargetNotAllowed(target);
    }

    function _precompile(uint32 assetId) internal pure returns (address) {
        return address(uint160((uint256(1) << 32) | assetId));
    }

    /// @dev No upgrades: a new implementation still means a new factory.
    function _authorizeUpgrade(address) internal pure override {
        revert Unauthorized();
    }

    /// @dev An unknown selector reverts instead of being read as compressed calldata.
    function _useLibZipCdFallback() internal pure override returns (bool) {
        return false;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("LooperPosition", "1");
    }
}
