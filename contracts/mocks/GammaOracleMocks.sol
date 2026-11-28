// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

/// Test doubles for GammaHypervisorOracleAdapter. Not for deployment.

contract MockV3PoolLite {
    uint160 public sqrtPriceX96;
    int24 public tick;
    struct Pos { uint128 liquidity; uint256 fg0; uint256 fg1; uint128 owed0; uint128 owed1; }
    mapping(bytes32 => Pos) internal _positions;

    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external { sqrtPriceX96 = _sqrtPriceX96; tick = _tick; }

    function setPosition(address owner, int24 lower, int24 upper, uint128 liquidity, uint128 owed0, uint128 owed1) external {
        _positions[keccak256(abi.encodePacked(owner, lower, upper))] = Pos(liquidity, 0, 0, owed0, owed1);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 2000, 2000, 4, true);
    }

    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128) {
        Pos memory p = _positions[key];
        return (p.liquidity, p.fg0, p.fg1, p.owed0, p.owed1);
    }
}

contract MockERC20Lite {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    constructor(uint8 _decimals) { decimals = _decimals; }
    function setBalance(address who, uint256 amount) external { balanceOf[who] = amount; }
}

contract MockHypervisorLite {
    address public pool;
    address public token0;
    address public token1;
    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;
    uint256 public totalSupply;
    uint8 public constant decimals = 18;

    constructor(address _pool, address _token0, address _token1) { pool = _pool; token0 = _token0; token1 = _token1; }
    function setTicks(int24 bl, int24 bu, int24 ll, int24 lu) external { baseLower = bl; baseUpper = bu; limitLower = ll; limitUpper = lu; }
    function setTotalSupply(uint256 s) external { totalSupply = s; }
}

contract MockFeed {
    uint8 public decimals;
    int256 public latestAnswer;
    constructor(uint8 _decimals, int256 _answer) { decimals = _decimals; latestAnswer = _answer; }
    function setAnswer(int256 a) external { latestAnswer = a; }
}
