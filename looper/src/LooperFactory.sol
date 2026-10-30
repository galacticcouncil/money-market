// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAavePool, IAaveOracle, IPoolAddressesProvider} from "./interfaces/IAavePool.sol";
import {ILooperFactory} from "./interfaces/ILooperFactory.sol";
import {ILooperPosition} from "./interfaces/ILooperPosition.sol";

/// @title LooperFactory
/// @notice Permissionless, admin-free deployer of one EIP-1167 `LooperPosition` clone per position. Each
/// position is an NFT: the clone's address depends only on its token id, and whoever holds the token owns
/// the position. The NFT is enumerable, so a holder's positions are `tokenOfOwnerByIndex` then `predict`.
/// A new implementation means a new factory.
contract LooperFactory is ILooperFactory, ERC721Enumerable {
    using SafeERC20 for IERC20;

    error SelfOwnDetected();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant STEP_MARGIN = 0.05e18;
    /// @dev Matches the position's emergency unwind floor, below which no exit sliver is sized.
    uint256 internal constant MIN_STEP_HF = 1.01e18;

    IAavePool public immutable pool;
    address public immutable implementation;

    uint256 public nextId = 1;

    constructor(IAavePool pool_, address implementation_) ERC721("Looper Position", "LOOP") {
        if (implementation_.code.length == 0 || ILooperPosition(implementation_).pool() != pool_) {
            revert InvalidImplementation();
        }
        pool = pool_;
        implementation = implementation_;
    }

    /// @notice `feeBudget` of `feeAsset` funds the position's forward fees; anyone can top it up later with a
    /// plain transfer, and the remainder is paid out on close.
    function open(ILooperPosition.Params calldata p, uint256 amount, uint256 feeBudget)
        external
        returns (uint256 id, address position)
    {
        _validate(p);
        id = nextId++;
        position = Clones.cloneDeterministic(implementation, bytes32(id));
        _mint(msg.sender, id);
        if (feeBudget > 0) IERC20(p.feeAsset).safeTransferFrom(msg.sender, position, feeBudget);
        ILooperPosition(position).initialize(id, p);
        IERC20(p.collateral).safeTransferFrom(msg.sender, position, amount);
        ILooperPosition(position).deposit(amount);
        emit PositionCreated(id, position);
    }

    /// @notice Every deposit goes through here, so only a clone of this factory receives collateral.
    function deposit(uint256 id, uint256 amount) external {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        address position = predict(id);
        IERC20(ILooperPosition(position).params().collateral).safeTransferFrom(msg.sender, position, amount);
        ILooperPosition(position).deposit(amount);
    }

    function predict(uint256 id) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, bytes32(id));
    }

    /// @dev A position holding its own NFT could never be controlled again, so that transfer reverts.
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
        internal
        override
    {
        if (to == predict(firstTokenId)) revert SelfOwnDetected();
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    /// @notice Largest leverage (WAD) `minHf` and Aave's LTV allow: `min(minHf / (minHf − LT), 1 / (1 − LTV))`.
    function maxLeverage(address collateral, uint8 eMode, uint256 minHf) public view returns (uint256) {
        (uint256 ltv, uint256 lt) = _ltvLt(collateral, eMode);
        uint256 lt18 = lt * 1e14;
        if (lt == 0 || ltv == 0 || lt18 >= minHf || ltv >= BPS) return 0;
        return Math.min(Math.mulDiv(minHf, WAD, minHf - lt18), Math.mulDiv(BPS, WAD, BPS - ltv));
    }

    function _ltvLt(address asset, uint8 eMode) internal view returns (uint256 ltv, uint256 lt) {
        if (eMode != 0) {
            IAavePool.EModeCategory memory e = pool.getEModeCategoryData(eMode);
            return (e.ltv, e.liquidationThreshold);
        }
        uint256 cfg = pool.getConfiguration(asset);
        return (cfg & 0xFFFF, (cfg >> 16) & 0xFFFF);
    }

    function _validate(ILooperPosition.Params calldata p) internal view {
        address[5] memory a = [p.collateral, p.aCollateral, p.debt, p.variableDebt, p.feeAsset];
        for (uint256 i = 0; i < 5; ++i) {
            if (a[i] == address(0)) revert InvalidParams();
            for (uint256 j = 0; j < i; ++j) {
                if (a[i] == a[j]) revert InvalidParams();
            }
        }
        if (pool.getReserveData(p.collateral).aTokenAddress != p.aCollateral) revert InvalidParams();
        if (pool.getReserveData(p.debt).variableDebtTokenAddress != p.variableDebt) revert InvalidParams();
        if (
            !_idMatches(p.debt, p.debtAssetId) || !_idMatches(p.aCollateral, p.aCollateralAssetId)
                || !_idMatches(p.feeAsset, p.feeAssetId)
        ) revert AssetIdMismatch();
        uint256 cc = pool.getConfiguration(p.collateral);
        uint256 dc = pool.getConfiguration(p.debt);
        // bits: 56 active, 57 frozen, 58 borrowing enabled, 60 paused
        if (
            !_bit(cc, 56) || _bit(cc, 57) || _bit(cc, 60) || !_bit(dc, 56) || _bit(dc, 57) || !_bit(dc, 58)
                || _bit(dc, 60)
        ) {
            revert InvalidParams();
        }
        if (p.eMode != 0 && (((cc >> 168) & 0xFF) != p.eMode || ((dc >> 168) & 0xFF) != p.eMode)) {
            revert InvalidParams();
        }
        if (p.stepHf < MIN_STEP_HF || p.stepHf + STEP_MARGIN > p.minHf) revert InvalidParams();
        if (p.slippageBps >= BPS) revert InvalidParams();
        if (p.feeReserve == 0 || p.minIntentDebt == 0 || p.minIntentAToken == 0) revert InvalidParams();
        if (!_pricesNonZero(p)) revert InvalidParams();
        if (p.leverage <= WAD || p.leverage > maxLeverage(p.collateral, p.eMode, p.minHf)) revert LeverageTooHigh();
    }

    function _pricesNonZero(ILooperPosition.Params calldata p) internal view returns (bool) {
        IAaveOracle oracle = IAaveOracle(IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle());
        if (p.eMode != 0) {
            address source = pool.getEModeCategoryData(p.eMode).priceSource;
            if (source != address(0)) return oracle.getAssetPrice(source) != 0;
        }
        return oracle.getAssetPrice(p.collateral) != 0 && oracle.getAssetPrice(p.debt) != 0;
    }

    /// @dev Hydration exposes asset `id` as an ERC20 precompile at `(1 << 32) | id`. A native asset lives
    /// there; a bound ERC20's precompile reports the contract's own `totalSupply`. Equal non-zero supplies in
    /// the same block identify the asset for every practical purpose.
    function _idMatches(address token, uint32 id) internal view returns (bool) {
        address precompile = address(uint160((uint256(1) << 32) | id));
        if (token == precompile) return true;
        (bool ok, bytes memory ret) = precompile.staticcall(abi.encodeCall(IERC20.totalSupply, ()));
        if (!ok || ret.length != 32) return false;
        uint256 supply = abi.decode(ret, (uint256));
        return supply != 0 && supply == IERC20(token).totalSupply();
    }

    function _bit(uint256 cfg, uint256 bit) internal pure returns (bool) {
        return (cfg >> bit) & 1 == 1;
    }
}
