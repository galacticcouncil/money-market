// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockAToken} from "./MockAToken.sol";

/// @notice Aave v3.0 pool stand-in with the real ABI and units: 8-decimal base, LT/LTV in bps, HF in
/// WAD, collateral flags in the user configuration bitmap (bit 2i+1), eMode categories with a price
/// source, LTV-capped borrows, zero-amount and no-debt reverts, the zero-LTV collateral rule and the
/// HF ≥ 1 check on aToken transfers. Doubles as its own addresses provider and oracle.
contract MockPool {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    struct Reserve {
        MockAToken aToken;
        MockERC20 vDebt;
        uint16 id;
        uint16 ltv;
        uint16 lt;
        uint8 decimals;
        uint8 eMode;
        bool frozen;
        bool paused;
        bool borrowable;
        bool isolated;
        uint256 price;
    }

    mapping(address => Reserve) public reserves;
    address[] internal _list;
    mapping(address => uint256) public userConfig;
    mapping(address => uint8) public userEMode;
    mapping(uint8 => IAavePool.EModeCategory) internal _eModes;
    mapping(address => uint256) public sourcePrice;

    // failure injection
    bool public refuseBorrow;
    bool public refuseEnable;
    bool public refuseRepay;
    uint256 public calls;
    bool public sawZeroAmount;

    function addReserve(address asset, uint8 dec, uint16 ltv, uint16 lt, uint256 price8)
        external
        returns (MockAToken aToken, MockERC20 vDebt)
    {
        aToken = new MockAToken(address(this), asset, dec);
        vDebt = new MockERC20("variable debt", "vDEBT", dec);
        reserves[asset] =
            Reserve(aToken, vDebt, uint16(_list.length), ltv, lt, dec, 0, false, false, true, false, price8);
        _list.push(asset);
    }

    // ── test controls ──

    function setPrice(address asset, uint256 price8) external {
        reserves[asset].price = price8;
    }

    function setLtvLt(address asset, uint16 ltv, uint16 lt) external {
        reserves[asset].ltv = ltv;
        reserves[asset].lt = lt;
    }

    function setFlags(address asset, bool frozen, bool paused, bool borrowable, bool isolated) external {
        Reserve storage r = reserves[asset];
        (r.frozen, r.paused, r.borrowable, r.isolated) = (frozen, paused, borrowable, isolated);
    }

    function setEModeCategory(uint8 id, uint16 ltv, uint16 lt, address source, uint256 price8) external {
        _eModes[id] = IAavePool.EModeCategory(ltv, lt, 10_100, source, "");
        sourcePrice[source] = price8;
    }

    function setReserveEMode(address asset, uint8 id) external {
        reserves[asset].eMode = id;
    }

    function setRefusals(bool borrow_, bool enable_, bool repay_) external {
        (refuseBorrow, refuseEnable, refuseRepay) = (borrow_, enable_, repay_);
    }

    function accrueDebt(address asset, address user, uint256 amount) external {
        reserves[asset].vDebt.mint(user, amount);
    }

    // ── pool ──

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        _count(amount);
        Reserve storage r = reserves[asset];
        require(!r.frozen && !r.paused, "MockPool: not suppliable");
        bool first = r.aToken.balanceOf(onBehalfOf) == 0;
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        r.aToken.mint(onBehalfOf, amount);
        if (first) _autoEnable(asset, onBehalfOf);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        Reserve storage r = reserves[asset];
        if (amount == type(uint256).max) amount = r.aToken.balanceOf(msg.sender);
        _count(amount);
        bool flagged = _isCollateral(msg.sender, r.id);
        r.aToken.burn(msg.sender, amount);
        if (r.aToken.scaledBalanceOf(msg.sender) == 0) _setCollateral(msg.sender, r.id, false);
        if (flagged) _checkOutflow(msg.sender, asset);
        uint256 held = MockERC20(asset).balanceOf(address(this));
        if (held < amount) MockERC20(asset).mint(address(this), amount - held);
        MockERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256 mode, uint16, address onBehalfOf) external {
        _count(amount);
        Reserve storage r = reserves[asset];
        require(mode == 2, "MockPool: variable only");
        require(!refuseBorrow, "MockPool: borrow refused");
        require(r.borrowable && !r.frozen && !r.paused, "MockPool: not borrowable");
        require(!_hasZeroLtvCollateral(onBehalfOf), "MockPool: zero-ltv collateral");
        r.vDebt.mint(onBehalfOf, amount);
        userConfig[onBehalfOf] |= 1 << (2 * r.id);
        (,, uint256 d, uint256 ltvSum,) = _account(onBehalfOf);
        require(d * BPS <= ltvSum, "MockPool: ltv");
        require(_hf(onBehalfOf) >= WAD, "MockPool: hf");
        MockERC20(asset).mint(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256 mode, address onBehalfOf) external returns (uint256) {
        _count(amount);
        Reserve storage r = reserves[asset];
        require(mode == 2, "MockPool: variable only");
        require(!refuseRepay, "MockPool: repay refused");
        uint256 owed = r.vDebt.balanceOf(onBehalfOf);
        require(owed > 0, "MockPool: no debt");
        uint256 pay = amount > owed ? owed : amount;
        MockERC20(asset).transferFrom(msg.sender, address(this), pay);
        r.vDebt.burn(onBehalfOf, pay);
        if (pay == owed) userConfig[onBehalfOf] &= ~(uint256(1) << (2 * r.id));
        return pay;
    }

    function setUserUseReserveAsCollateral(address asset, bool use) external {
        Reserve storage r = reserves[asset];
        if (use) {
            require(!refuseEnable, "MockPool: enable refused");
            require(r.aToken.balanceOf(msg.sender) > 0, "MockPool: balance 0");
            require(_canEnable(asset, msg.sender), "MockPool: isolation or ltv 0");
            _setCollateral(msg.sender, r.id, true);
        } else {
            _setCollateral(msg.sender, r.id, false);
            _checkOutflow(msg.sender, asset);
        }
    }

    function setUserEMode(uint8 id) external {
        userEMode[msg.sender] = id;
        require(_hf(msg.sender) >= WAD, "MockPool: hf");
    }

    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 fromBefore,
        uint256 toBefore
    ) external {
        Reserve storage r = reserves[asset];
        require(msg.sender == address(r.aToken), "MockPool: not aToken");
        if (from == to) return;
        bool flagged = _isCollateral(from, r.id);
        if (r.aToken.scaledBalanceOf(from) == 0) _setCollateral(from, r.id, false);
        if (flagged && fromBefore >= amount) _checkOutflow(from, asset);
        if (toBefore == 0 && amount > 0) _autoEnable(asset, to);
    }

    // ── views ──

    function getUserAccountData(address user)
        external
        view
        returns (uint256 c, uint256 d, uint256 available, uint256 lt, uint256 ltv, uint256 hf)
    {
        uint256 ltSum;
        uint256 ltvSum;
        (c, ltSum, d, ltvSum,) = _account(user);
        lt = c == 0 ? 0 : ltSum / c;
        ltv = c == 0 ? 0 : ltvSum / c;
        available = ltvSum / BPS > d ? ltvSum / BPS - d : 0;
        hf = d == 0 ? type(uint256).max : ltSum * WAD / BPS / d;
    }

    function getConfiguration(address asset) public view returns (uint256 cfg) {
        Reserve storage r = reserves[asset];
        cfg = uint256(r.ltv) | (uint256(r.lt) << 16) | (uint256(r.decimals) << 48) | (uint256(1) << 56);
        if (r.frozen) cfg |= 1 << 57;
        if (r.borrowable) cfg |= 1 << 58;
        if (r.paused) cfg |= 1 << 60;
        if (r.borrowable) cfg |= 1 << 61;
        cfg |= uint256(r.eMode) << 168;
        if (r.isolated) cfg |= uint256(1_000_000) << 212;
    }

    function getReserveData(address asset) external view returns (IAavePool.ReserveData memory d) {
        Reserve storage r = reserves[asset];
        d.configuration = getConfiguration(asset);
        d.liquidityIndex = uint128(address(r.aToken) == address(0) ? 0 : r.aToken.index());
        d.variableBorrowIndex = 1e27;
        d.id = r.id;
        d.aTokenAddress = address(r.aToken);
        d.variableDebtTokenAddress = address(r.vDebt);
    }

    function getReservesList() external view returns (address[] memory) {
        return _list;
    }

    function getReserveAddressById(uint16 id) external view returns (address) {
        return _list[id];
    }

    function getUserConfiguration(address user) external view returns (uint256) {
        return userConfig[user];
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return reserves[asset].aToken.index();
    }

    function getEModeCategoryData(uint8 id) external view returns (IAavePool.EModeCategory memory) {
        return _eModes[id];
    }

    function getUserEMode(address user) external view returns (uint256) {
        return userEMode[user];
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(this);
    }

    function getPriceOracle() external view returns (address) {
        return address(this);
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return reserves[asset].aToken != MockAToken(address(0)) ? reserves[asset].price : sourcePrice[asset];
    }

    function isCollateral(address user, address asset) external view returns (bool) {
        return _isCollateral(user, reserves[asset].id);
    }

    function toBase(address user, address asset, uint256 amount) public view returns (uint256) {
        Reserve storage r = reserves[asset];
        return amount * _price(user, asset) / 10 ** r.decimals;
    }

    // ── internal ──

    function _count(uint256 amount) internal {
        ++calls;
        if (amount == 0) sawZeroAmount = true;
        require(amount > 0, "MockPool: zero amount");
    }

    function _isCollateral(address user, uint16 id) internal view returns (bool) {
        return (userConfig[user] >> (2 * uint256(id) + 1)) & 1 == 1;
    }

    function _setCollateral(address user, uint16 id, bool on) internal {
        uint256 bit = uint256(1) << (2 * uint256(id) + 1);
        userConfig[user] = on ? userConfig[user] | bit : userConfig[user] & ~bit;
    }

    function _anyCollateral(address user, address except) internal view returns (bool any, bool isolated) {
        for (uint256 i = 0; i < _list.length; ++i) {
            if (_list[i] == except || !_isCollateral(user, uint16(i))) continue;
            any = true;
            if (reserves[_list[i]].isolated) isolated = true;
        }
    }

    function _canEnable(address asset, address user) internal view returns (bool) {
        if (_ltv(user, asset) == 0) return false;
        (bool any, bool isolated) = _anyCollateral(user, asset);
        if (!any) return true;
        return !isolated && !reserves[asset].isolated;
    }

    /// @dev Aave never auto-enables an isolated reserve without ISOLATED_COLLATERAL_SUPPLIER_ROLE.
    function _autoEnable(address asset, address user) internal {
        if (!reserves[asset].isolated && _canEnable(asset, user)) _setCollateral(user, reserves[asset].id, true);
    }

    function _debtBase(address user) internal view returns (uint256 d) {
        for (uint256 i = 0; i < _list.length; ++i) {
            uint256 b = reserves[_list[i]].vDebt.balanceOf(user);
            if (b > 0) d += toBase(user, _list[i], b);
        }
    }

    function _checkOutflow(address user, address asset) internal view {
        if (!_anyDebt(user)) return;
        require(_hf(user) >= WAD, "MockPool: hf after outflow");
        require(!(_hasZeroLtvCollateral(user) && _ltv(user, asset) != 0), "MockPool: zero-ltv collateral");
    }

    function _anyDebt(address user) internal view returns (bool) {
        for (uint256 i = 0; i < _list.length; ++i) {
            if (reserves[_list[i]].vDebt.balanceOf(user) > 0) return true;
        }
        return false;
    }

    function _hasZeroLtvCollateral(address user) internal view returns (bool) {
        for (uint256 i = 0; i < _list.length; ++i) {
            address a = _list[i];
            if (_isCollateral(user, uint16(i)) && reserves[a].aToken.balanceOf(user) > 0 && _ltv(user, a) == 0) {
                return true;
            }
        }
        return false;
    }

    function _inEMode(address user, address asset) internal view returns (bool) {
        uint8 e = userEMode[user];
        return e != 0 && reserves[asset].eMode == e;
    }

    function _ltv(address user, address asset) internal view returns (uint256) {
        if (reserves[asset].ltv == 0) return 0;
        return _inEMode(user, asset) ? _eModes[userEMode[user]].ltv : reserves[asset].ltv;
    }

    function _lt(address user, address asset) internal view returns (uint256) {
        return _inEMode(user, asset) ? _eModes[userEMode[user]].liquidationThreshold : reserves[asset].lt;
    }

    function _price(address user, address asset) internal view returns (uint256) {
        if (_inEMode(user, asset)) {
            address source = _eModes[userEMode[user]].priceSource;
            if (source != address(0)) return sourcePrice[source];
        }
        return reserves[asset].price;
    }

    function _account(address user)
        internal
        view
        returns (uint256 c, uint256 ltSum, uint256 d, uint256 ltvSum, uint256 n)
    {
        for (uint256 i = 0; i < _list.length; ++i) {
            address a = _list[i];
            Reserve storage r = reserves[a];
            uint256 bal = r.aToken.balanceOf(user);
            if (bal > 0 && _isCollateral(user, uint16(i))) {
                uint256 v = toBase(user, a, bal);
                c += v;
                ltSum += v * _lt(user, a);
                ltvSum += v * _ltv(user, a);
                ++n;
            }
        }
        d = _debtBase(user);
    }

    function _hf(address user) internal view returns (uint256) {
        (, uint256 ltSum, uint256 d,,) = _account(user);
        return d == 0 ? type(uint256).max : ltSum * WAD / BPS / d;
    }
}
