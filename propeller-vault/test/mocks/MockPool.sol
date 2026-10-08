// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice minimal aave v3 pool mock with real getUserAccountData units:
///         8dp usd bases, lt/ltv in bps, hf in wad. hf is enforced on borrow/withdraw.
contract MockPool is IAavePool {
    struct Reserve {
        MockERC20 aToken;
        MockERC20 debtToken;
        uint16 ltBps; // liquidation threshold
        uint16 ltvBps; // loan-to-value (borrow power)
        uint8 decimals;
        uint256 priceWad; // 1e18 = $1
        bool exists;
    }

    mapping(address => Reserve) public reserves;
    address[] public assets;
    uint256 public repayLimit = type(uint256).max;
    uint128 public variableBorrowRate;
    uint256 public borrowRoundingLoss;
    uint256 public repayRoundingLoss;

    function setDebtRounding(uint256 borrowLoss, uint256 repayLoss) external {
        borrowRoundingLoss = borrowLoss;
        repayRoundingLoss = repayLoss;
    }

    function getReserveNormalizedVariableDebt(address) external pure returns (uint256) { return 1e27; }

    function setVariableBorrowRate(uint128 rate) external { variableBorrowRate = rate; }

    function getReserveData(address) external view returns (uint256, uint128, uint128, uint128, uint128) {
        return (0, 1e27, 0, 1e27, variableBorrowRate);
    }
    mapping(address => uint256) public supplyRoundingLoss;
    mapping(address => uint256) public withdrawRoundingLoss;

    /// @notice Model pessimistic aToken balance rounding independently of exact transfers.
    function setCollateralRounding(address asset, uint256 supplyLoss, uint256 withdrawLoss) external {
        supplyRoundingLoss[asset] = supplyLoss;
        withdrawRoundingLoss[asset] = withdrawLoss;
    }

    function setRepayLimit(uint256 limit) external {
        repayLimit = limit;
    }
    /// @notice isolated reserves are never auto-enabled as collateral (live prime is isolated).
    mapping(address => bool) public isolationMode;
    /// @notice aave's use-as-collateral flag: auto-set only on a first supply with ltv > 0.
    mapping(address => mapping(address => bool)) public usingAsCollateral;

    uint256 internal constant BPS = 1e4;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HF_MAX = type(uint256).max;

    function initReserve(
        address asset,
        address aToken,
        address debtToken,
        uint16 ltBps,
        uint16 ltvBps,
        uint8 dec,
        uint256 priceWad
    ) external {
        reserves[asset] = Reserve(MockERC20(aToken), MockERC20(debtToken), ltBps, ltvBps, dec, priceWad, true);
        assets.push(asset);
    }

    function setPrice(address asset, uint256 priceWad) external {
        reserves[asset].priceWad = priceWad;
    }

    /// @notice list a reserve in isolation mode (no auto-enable on first supply).
    function setIsolationMode(address asset, bool on) external {
        isolationMode[asset] = on;
    }

    /// @notice change a reserve's max ltv; existing suppliers are not retro-enabled.
    function setLtv(address asset, uint16 ltvBps) external {
        reserves[asset].ltvBps = ltvBps;
    }

    /// @notice price ($1 = 1e18) and decimals, used by MockSwapper to price swaps.
    function assetPrice(address asset) external view returns (uint256 priceWad, uint8 dec) {
        Reserve storage r = reserves[asset];
        return (r.priceWad, r.decimals);
    }

    function _usd8(address asset, uint256 amt) internal view returns (uint256) {
        Reserve storage r = reserves[asset];
        // amt(native) * price(1e18=$1) / 10^dec → 18dp USD; / 1e10 → 8dp USD
        return (amt * r.priceWad) / (10 ** r.decimals) / 1e10;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        Reserve storage r = reserves[asset];
        bool firstSupply = r.aToken.balanceOf(onBehalfOf) == 0;
        r.aToken.mint(onBehalfOf, amount - supplyRoundingLoss[asset]);
        // like aave: auto-enable only on a first supply, never for ltv-0 or isolated reserves
        if (firstSupply && r.ltvBps > 0 && !isolationMode[asset]) {
            usingAsCollateral[onBehalfOf][asset] = true;
        }
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        reserves[asset].aToken.burn(msg.sender, amount + withdrawRoundingLoss[asset]);
        require(_hf(msg.sender) >= WAD, "MockPool: HF<1 after withdraw");
        // pool must hold the asset (was supplied here); send it out
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        reserves[asset].debtToken.mint(onBehalfOf, amount > borrowRoundingLoss ? amount - borrowRoundingLoss : 0);
        MockERC20(asset).mint(msg.sender, amount); // GHO/HOLLAR-style: minted on borrow
        require(_hf(onBehalfOf) >= WAD, "MockPool: HF<1 after borrow");
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        override
        returns (uint256)
    {
        uint256 d = reserves[asset].debtToken.balanceOf(onBehalfOf);
        uint256 r = amount > d ? d : amount;
        if (r > repayLimit) r = repayLimit;
        IERC20(asset).transferFrom(msg.sender, address(this), r);
        uint256 burned = r == d ? r : r > repayRoundingLoss ? r - repayRoundingLoss : 0;
        reserves[asset].debtToken.burn(onBehalfOf, burned);
        return r;
    }

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external override {
        Reserve storage r = reserves[asset];
        if (useAsCollateral) {
            // Aave: UNDERLYING_BALANCE_ZERO + USER_IN_ISOLATION_MODE_OR_LTV_ZERO
            require(r.aToken.balanceOf(msg.sender) > 0, "MockPool: balance 0");
            require(r.ltvBps > 0, "MockPool: ltv 0");
            usingAsCollateral[msg.sender][asset] = true;
        } else {
            usingAsCollateral[msg.sender][asset] = false;
            require(_hf(msg.sender) >= WAD, "MockPool: HF<1 after disable");
        }
    }

    /// @notice Aave reserve configuration bitmap: bits 0-15 LTV, 16-31 LT.
    function getConfiguration(address asset) external view returns (uint256) {
        Reserve storage r = reserves[asset];
        return uint256(r.ltvBps) | (uint256(r.ltBps) << 16);
    }

    /// @notice on-behalf withdraw (first hop of an unwind route); `from` must keep hf >= 1.
    function mockWithdrawTo(address asset, uint256 amount, address from, address to)
        external
        returns (uint256)
    {
        reserves[asset].aToken.burn(from, amount);
        require(_hf(from) >= WAD, "MockPool: HF<1 after withdraw");
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function getUserAccountData(address user)
        external
        view
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        (uint256 collBase8, uint256 collWithLt8, uint256 debtBase8, uint256 wAvgLtBps) = _account(user);
        uint256 hf = debtBase8 == 0 ? HF_MAX : (collWithLt8 * WAD) / debtBase8;
        // availableBorrowsBase: simplistic LTV-based headroom (not exercised in deploy test)
        return (collBase8, debtBase8, 0, wAvgLtBps, 0, hf);
    }

    // doubles as its own addresses provider + oracle, priced like MockSwapper
    function ADDRESSES_PROVIDER() external view returns (address) { return address(this); }
    function getPriceOracle() external view returns (address) { return address(this); }
    function getAssetPrice(address asset) external view returns (uint256) {
        return reserves[asset].priceWad / 1e10; // 1e18 $1 → 1e8 (8dp USD)
    }

    function _hf(address user) internal view returns (uint256) {
        (, uint256 collWithLt8, uint256 debtBase8,) = _account(user);
        return debtBase8 == 0 ? HF_MAX : (collWithLt8 * WAD) / debtBase8;
    }

    function _account(address user)
        internal
        view
        returns (uint256 collBase8, uint256 collWithLt8, uint256 debtBase8, uint256 wAvgLtBps)
    {
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; i++) {
            Reserve storage r = reserves[assets[i]];
            uint256 c = r.aToken.balanceOf(user);
            // only flagged balances count, like aave
            if (c > 0 && usingAsCollateral[user][assets[i]]) {
                uint256 v = _usd8(assets[i], c);
                collBase8 += v;
                collWithLt8 += (v * r.ltBps) / BPS;
            }
            uint256 d = r.debtToken.balanceOf(user);
            if (d > 0) debtBase8 += _usd8(assets[i], d);
        }
        wAvgLtBps = collBase8 == 0 ? 0 : (collWithLt8 * BPS) / collBase8;
    }
}
