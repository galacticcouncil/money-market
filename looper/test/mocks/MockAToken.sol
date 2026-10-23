// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IFinalizeTransfer {
    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 fromBefore,
        uint256 toBefore
    ) external;
}

/// @notice Aave-style aToken: scaled balances times a liquidity index (half-up ray math), transfers
/// HF-checked by the pool. `move` is the mock pallet's reserve/refund path (no allowance).
contract MockAToken {
    uint256 internal constant RAY = 1e27;

    address public immutable pool;
    address public immutable UNDERLYING_ASSET_ADDRESS;
    uint8 public immutable decimals;
    uint256 public index = RAY;
    mapping(address => uint256) public scaledBalanceOf;
    uint256 public scaledTotalSupply;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address pool_, address underlying, uint8 dec) {
        pool = pool_;
        UNDERLYING_ASSET_ADDRESS = underlying;
        decimals = dec;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "MockAToken: pool");
        _;
    }

    function totalSupply() external view returns (uint256) {
        return rayMul(scaledTotalSupply, index);
    }

    function balanceOf(address who) public view returns (uint256) {
        return rayMul(scaledBalanceOf[who], index);
    }

    function setIndex(uint256 i) external {
        require(i >= index, "MockAToken: index only grows");
        index = i;
    }

    function mint(address to, uint256 amount) external onlyPool {
        uint256 scaled = rayDiv(amount, index);
        scaledBalanceOf[to] += scaled;
        scaledTotalSupply += scaled;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        uint256 scaled = _scaledOut(from, amount);
        scaledBalanceOf[from] -= scaled;
        scaledTotalSupply -= scaled;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function move(address from, address to, uint256 amount) external {
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = balanceOf(from);
        uint256 toBefore = balanceOf(to);
        uint256 s = _scaledOut(from, amount);
        scaledBalanceOf[from] -= s;
        scaledBalanceOf[to] += s;
        emit Transfer(from, to, amount);
        IFinalizeTransfer(pool).finalizeTransfer(UNDERLYING_ASSET_ADDRESS, from, to, amount, fromBefore, toBefore);
    }

    /// @dev the whole balance always moves the whole scaled balance, never one unit more
    function _scaledOut(address from, uint256 amount) internal view returns (uint256) {
        require(amount <= balanceOf(from), "MockAToken: balance");
        if (amount == balanceOf(from)) return scaledBalanceOf[from];
        uint256 s = rayDiv(amount, index);
        return s > scaledBalanceOf[from] ? scaledBalanceOf[from] : s;
    }

    function rayMul(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function rayDiv(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }
}
