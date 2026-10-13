// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {MockERC20} from "./MockERC20.sol";

contract IsolationRulesPool is IAavePool {
    struct Reserve {
        MockERC20 aToken;
        MockERC20 debtToken;
        uint16 ltBps;
        uint16 ltvBps;
        uint8 decimals;
        uint256 priceWad;
        bool exists;
    }

    mapping(address => Reserve) public reserves;
    address[] public assets;
    uint256 public repayLimit = type(uint256).max;
    uint128 public variableBorrowRate;
    uint256 public borrowRoundingLoss;
    uint256 public repayRoundingLoss;
    uint256 public debtIndex = 1e27;
    uint256 public repayCalls;
    mapping(address => uint256) public supplyRoundingLoss;
    mapping(address => uint256) public withdrawRoundingLoss;
    mapping(address => bool) public isolationMode;
    mapping(address => mapping(address => bool)) public usingAsCollateral;
    mapping(address => bool) public isolatedSupplier;
    bool public enforceLtv;

    uint256 internal constant BPS = 1e4;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HF_MAX = type(uint256).max;

    function setDebtRounding(uint256 borrowLoss, uint256 repayLoss) external {
        borrowRoundingLoss = borrowLoss;
        repayRoundingLoss = repayLoss;
    }

    function getReserveNormalizedVariableDebt(address) external view returns (uint256) { return debtIndex; }

    function accrueInterest(address asset, address debtor, uint256 bps) external {
        uint256 next = (debtIndex * (10_000 + bps) + 9999) / 10_000;
        uint256 debt = reserves[asset].debtToken.balanceOf(debtor);
        uint256 after_ = (debt * next + debtIndex - 1) / debtIndex;
        debtIndex = next;
        reserves[asset].debtToken.mint(debtor, after_ - debt);
    }

    function setVariableBorrowRate(uint128 rate) external { variableBorrowRate = rate; }

    function getReserveData(address) external view returns (uint256, uint128, uint128, uint128, uint128) {
        return (0, 1e27, 0, uint128(debtIndex), variableBorrowRate);
    }

    function setCollateralRounding(address asset, uint256 supplyLoss, uint256 withdrawLoss) external {
        supplyRoundingLoss[asset] = supplyLoss;
        withdrawRoundingLoss[asset] = withdrawLoss;
    }

    function setRepayLimit(uint256 limit) external { repayLimit = limit; }

    function initReserve(address asset, address aToken, address debtToken, uint16 ltBps, uint16 ltvBps, uint8 dec,
        uint256 priceWad) external
    {
        reserves[asset] = Reserve(MockERC20(aToken), MockERC20(debtToken), ltBps, ltvBps, dec, priceWad, true);
        assets.push(asset);
    }

    function setPrice(address asset, uint256 priceWad) external { reserves[asset].priceWad = priceWad; }

    function setIsolationMode(address asset, bool on) external { isolationMode[asset] = on; }

    function setIsolatedSupplier(address who, bool on) external { isolatedSupplier[who] = on; }

    function setEnforceLtv(bool on) external { enforceLtv = on; }

    function setLtv(address asset, uint16 ltvBps) external { reserves[asset].ltvBps = ltvBps; }

    function assetPrice(address asset) external view returns (uint256 priceWad, uint8 dec) {
        Reserve storage r = reserves[asset];
        return (r.priceWad, r.decimals);
    }

    function _usd8(address asset, uint256 amt) internal view returns (uint256) {
        Reserve storage r = reserves[asset];
        return (amt * r.priceWad) / (10 ** r.decimals) / 1e10;
    }

    function collateralCount(address user) public view returns (uint256 n, address first) {
        for (uint256 i; i < assets.length; i++) {
            if (usingAsCollateral[user][assets[i]]) {
                if (n == 0) first = assets[i];
                n++;
            }
        }
    }

    function isolationModeActive(address user) public view returns (bool) {
        (uint256 n, address first) = collateralCount(user);
        return n == 1 && isolationMode[first];
    }

    function _validateUseAsCollateral(address user, address asset) internal view returns (bool) {
        if (reserves[asset].ltvBps == 0) return false;
        (uint256 n,) = collateralCount(user);
        if (n == 0) return true;
        return !isolationModeActive(user) && !isolationMode[asset];
    }

    function _validateAutomatic(address user, address asset, address supplier) internal view returns (bool) {
        if (isolationMode[asset] && !isolatedSupplier[supplier]) return false;
        return _validateUseAsCollateral(user, asset);
    }

    function _clearIfEmpty(address user, address asset) internal {
        if (reserves[asset].aToken.balanceOf(user) == 0) usingAsCollateral[user][asset] = false;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        Reserve storage r = reserves[asset];
        bool firstSupply = r.aToken.balanceOf(onBehalfOf) == 0;
        r.aToken.mint(onBehalfOf, amount - supplyRoundingLoss[asset]);
        if (firstSupply && _validateAutomatic(onBehalfOf, asset, msg.sender)) {
            usingAsCollateral[onBehalfOf][asset] = true;
        }
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        reserves[asset].aToken.burn(msg.sender, amount + withdrawRoundingLoss[asset]);
        _clearIfEmpty(msg.sender, asset);
        require(_hf(msg.sender) >= WAD, "MockPool: HF<1 after withdraw");
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        if (enforceLtv) {
            (uint256 collBase8,, uint256 debtBase8,, uint256 ltvCap8) = _account(onBehalfOf);
            require(collBase8 != 0, "34");
            require(debtBase8 + _usd8(asset, amount) <= ltvCap8, "36");
        }
        reserves[asset].debtToken.mint(onBehalfOf, amount > borrowRoundingLoss ? amount - borrowRoundingLoss : 0);
        MockERC20(asset).mint(msg.sender, amount);
        require(_hf(onBehalfOf) >= WAD, "MockPool: HF<1 after borrow");
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external override returns (uint256) {
        ++repayCalls;
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
        require(r.aToken.balanceOf(msg.sender) != 0, "43");
        if (useAsCollateral == usingAsCollateral[msg.sender][asset]) return;
        if (useAsCollateral) {
            require(_validateUseAsCollateral(msg.sender, asset), "62");
            usingAsCollateral[msg.sender][asset] = true;
        } else {
            usingAsCollateral[msg.sender][asset] = false;
            require(_hf(msg.sender) >= WAD, "35");
        }
    }

    function getConfiguration(address asset) external view returns (uint256) {
        Reserve storage r = reserves[asset];
        return uint256(r.ltvBps) | (uint256(r.ltBps) << 16);
    }

    function mockWithdrawTo(address asset, uint256 amount, address from, address to) external returns (uint256) {
        reserves[asset].aToken.burn(from, amount);
        _clearIfEmpty(from, asset);
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
        (uint256 collBase8, uint256 collWithLt8, uint256 debtBase8, uint256 wAvgLtBps, uint256 ltvCap8) = _account(user);
        uint256 hf = debtBase8 == 0 ? HF_MAX : (collWithLt8 * WAD) / debtBase8;
        uint256 available = ltvCap8 > debtBase8 ? ltvCap8 - debtBase8 : 0;
        uint256 ltv = collBase8 == 0 ? 0 : ltvCap8 * BPS / collBase8;
        return (collBase8, debtBase8, available, wAvgLtBps, ltv, hf);
    }

    function ADDRESSES_PROVIDER() external view returns (address) { return address(this); }
    function getPriceOracle() external view returns (address) { return address(this); }
    function getAssetPrice(address asset) external view returns (uint256) { return reserves[asset].priceWad / 1e10; }

    function _hf(address user) internal view returns (uint256) {
        (, uint256 collWithLt8, uint256 debtBase8,,) = _account(user);
        return debtBase8 == 0 ? HF_MAX : (collWithLt8 * WAD) / debtBase8;
    }

    function _account(address user)
        internal
        view
        returns (uint256 collBase8, uint256 collWithLt8, uint256 debtBase8, uint256 wAvgLtBps, uint256 ltvCap8)
    {
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; i++) {
            Reserve storage r = reserves[assets[i]];
            uint256 c = r.aToken.balanceOf(user);
            if (c > 0 && usingAsCollateral[user][assets[i]]) {
                uint256 v = _usd8(assets[i], c);
                collBase8 += v;
                collWithLt8 += (v * r.ltBps) / BPS;
                ltvCap8 += (v * r.ltvBps) / BPS;
            }
            uint256 d = r.debtToken.balanceOf(user);
            if (d > 0) debtBase8 += _usd8(assets[i], d);
        }
        wAvgLtBps = collBase8 == 0 ? 0 : (collWithLt8 * BPS) / collBase8;
    }
}
