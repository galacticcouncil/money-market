// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import "@aave/periphery-v3/contracts/misc/interfaces/IEACAggregatorProxy.sol";

interface IHypervisorLite {
    function pool() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function baseLower() external view returns (int24);
    function baseUpper() external view returns (int24);
    function limitLower() external view returns (int24);
    function limitUpper() external view returns (int24);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IUniswapV3PoolLite {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IERC20Lite {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title GammaHypervisorOracleAdapter
/// @notice Chainlink-compatible USD price (8 decimals) for one Gamma Hypervisor
///         share token, computed as FAIR VALUE rather than pool-spot NAV.
///
///         The Hypervisor itself has no price function: its implicit NAV is
///         `getTotalAmounts() / totalSupply()`, where the two Uniswap v3 positions
///         are converted to token amounts at the pool's CURRENT tick. On a pool where
///         the vault is ~all of the liquidity that tick is one swap away, so a naive
///         NAV oracle is manipulable within a block.
///
///         This adapter never reads the pool price. It derives the sqrtPriceX96 the
///         pool WOULD sit at if it agreed with the external feeds (feed0/feed1, both
///         USD 8 dec), converts each position's liquidity to amounts at THAT price,
///         adds tokensOwed (collected-but-unclaimed fees) and idle vault balances,
///         values the total at the feed prices and divides by share supply.
///         (Maker G-UNI / Arrakis LP-oracle pattern.)
///
///         Notes:
///         - `feed1 == address(0)` means "token1 is worth exactly $1" (HOLLAR).
///         - Fees earned since the vault's last poke are not yet in tokensOwed and are
///           ignored -> answer is slightly conservative.
///         - Liquidity `L` and the tick bounds are the only vault inputs and neither
///           can be moved by a swap. Rebalances change the bounds but not the value.
///         - Implements latestRoundData too, so it can also serve as a stableswap
///           MMOracle peg source if ever needed.
contract GammaHypervisorOracleAdapter is IEACAggregatorProxy {
    uint8 public constant decimals = 8;
    uint256 public constant version = 4;
    uint256 private constant FEED_UNIT = 1e8;
    uint256 private constant Q96 = 2**96;

    IHypervisorLite public immutable hypervisor;
    IUniswapV3PoolLite public immutable pool;
    IERC20Lite public immutable token0;
    IERC20Lite public immutable token1;
    IEACAggregatorProxy public immutable feed0;
    IEACAggregatorProxy public immutable feed1;
    uint8 public immutable token0Decimals;
    uint8 public immutable token1Decimals;
    uint8 public immutable shareDecimals;
    string private _description;

    constructor(address _hypervisor, address _feed0, address _feed1, string memory description_) {
        require(_hypervisor != address(0), "Zero hypervisor");
        require(_feed0 != address(0), "Zero feed0");
        hypervisor = IHypervisorLite(_hypervisor);
        pool = IUniswapV3PoolLite(hypervisor.pool());
        token0 = IERC20Lite(hypervisor.token0());
        token1 = IERC20Lite(hypervisor.token1());
        feed0 = IEACAggregatorProxy(_feed0);
        feed1 = IEACAggregatorProxy(_feed1);
        require(feed0.decimals() == decimals, "feed0 decimals");
        if (_feed1 != address(0)) require(feed1.decimals() == decimals, "feed1 decimals");
        token0Decimals = token0.decimals();
        token1Decimals = token1.decimals();
        shareDecimals = hypervisor.decimals();
        _description = description_;
    }

    // ------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------

    /// @notice USD price of one whole share (10**shareDecimals units), 8 decimals.
    ///         Returns 0 when the vault has no shares (AaveOracle then falls back).
    function latestAnswer() public view returns (int256) {
        uint256 supply = hypervisor.totalSupply();
        if (supply == 0) return 0;
        (uint256 p0, uint256 p1) = _feedPrices();
        uint160 sqrtP = _sqrtPriceFromFeeds(p0, p1);
        return int256(_valueAt(sqrtP, p0, p1, supply));
    }

    /// @notice Same valuation but with the positions converted at the POOL's own
    ///         spot price. Monitoring only: the gap to latestAnswer() is the pool's
    ///         displacement from the feeds. Never wire this into the money market.
    function spotAnswer() external view returns (int256) {
        uint256 supply = hypervisor.totalSupply();
        if (supply == 0) return 0;
        (uint256 p0, uint256 p1) = _feedPrices();
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        return int256(_valueAt(sqrtP, p0, p1, supply));
    }

    /// @notice sqrtPriceX96 implied by the feeds (token1 raw units per token0 raw unit).
    function fairSqrtPriceX96() external view returns (uint160) {
        (uint256 p0, uint256 p1) = _feedPrices();
        return _sqrtPriceFromFeeds(p0, p1);
    }

    /// @notice Vault holdings (both positions + tokensOwed + idle) if the pool sat at `sqrtPriceX96`.
    function totalAmountsAt(uint160 sqrtPriceX96) public view returns (uint256 amount0, uint256 amount1) {
        (uint256 b0, uint256 b1) = _positionAmounts(hypervisor.baseLower(), hypervisor.baseUpper(), sqrtPriceX96);
        (uint256 l0, uint256 l1) = _positionAmounts(hypervisor.limitLower(), hypervisor.limitUpper(), sqrtPriceX96);
        amount0 = token0.balanceOf(address(hypervisor)) + b0 + l0;
        amount1 = token1.balanceOf(address(hypervisor)) + b1 + l1;
    }

    function _valueAt(uint160 sqrtP, uint256 p0, uint256 p1, uint256 supply) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = totalAmountsAt(sqrtP);
        uint256 usd = _mulDiv(a0, p0, 10**token0Decimals) + _mulDiv(a1, p1, 10**token1Decimals);
        return _mulDiv(usd, 10**shareDecimals, supply);
    }

    function _feedPrices() internal view returns (uint256 p0, uint256 p1) {
        int256 a0 = feed0.latestAnswer();
        require(a0 > 0, "feed0 price");
        p0 = uint256(a0);
        if (address(feed1) == address(0)) {
            p1 = FEED_UNIT;
        } else {
            int256 a1 = feed1.latestAnswer();
            require(a1 > 0, "feed1 price");
            p1 = uint256(a1);
        }
    }

    /// @dev price(token1 raw per token0 raw) = (p0 / p1) * 10^dec1 / 10^dec0;
    ///      sqrtPriceX96 = sqrt(price * 2^192).
    function _sqrtPriceFromFeeds(uint256 p0, uint256 p1) internal view returns (uint160) {
        uint256 ratioX192 = _mulDiv(p0 * 10**token1Decimals, 2**192, p1 * 10**token0Decimals);
        uint256 s = _sqrt(ratioX192);
        require(s >= MIN_SQRT_RATIO && s < MAX_SQRT_RATIO, "sqrt price out of range");
        return uint160(s);
    }

    function _positionAmounts(int24 tickLower, int24 tickUpper, uint160 sqrtP)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 key = keccak256(abi.encodePacked(address(hypervisor), tickLower, tickUpper));
        (uint128 liquidity, , , uint128 owed0, uint128 owed1) = pool.positions(key);
        (amount0, amount1) = _amountsForLiquidity(sqrtP, getSqrtRatioAtTick(tickLower), getSqrtRatioAtTick(tickUpper), liquidity);
        amount0 += owed0;
        amount1 += owed1;
    }

    // ------------------------------------------------------------------
    // Chainlink surface
    // ------------------------------------------------------------------

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external view returns (uint256) {
        return block.number;
    }

    function getAnswer(uint256) external view returns (int256) {
        return latestAnswer();
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return block.timestamp;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, latestAnswer(), block.timestamp, block.timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 r = uint80(block.number);
        return (r, latestAnswer(), block.timestamp, block.timestamp, r);
    }

    // ------------------------------------------------------------------
    // Uniswap v3 math (LiquidityAmounts / TickMath / FullMath, solc 0.8 ports)
    // ------------------------------------------------------------------

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function _amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            amount0 = _amount0ForLiquidity(sqrtA, sqrtB, liquidity);
        } else if (sqrtP < sqrtB) {
            amount0 = _amount0ForLiquidity(sqrtP, sqrtB, liquidity);
            amount1 = _amount1ForLiquidity(sqrtA, sqrtP, liquidity);
        } else {
            amount1 = _amount1ForLiquidity(sqrtA, sqrtB, liquidity);
        }
    }

    function _amount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _mulDiv(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    function _amount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _mulDiv(liquidity, sqrtB - sqrtA, Q96);
    }

    /// @notice sqrt(1.0001^tick) * 2^96 — Uniswap v3 TickMath.getSqrtRatioAtTick.
    function getSqrtRatioAtTick(int24 tick) public pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= uint256(int256(MAX_TICK)), "T");

            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // round up, and convert Q128.128 -> Q64.96
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @dev floor(a*b/denominator) with full 512-bit intermediate (FullMath.mulDiv).
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0, "div0");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1, "mulDiv overflow");
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
        }
    }

    /// @dev floor(sqrt(x)), Babylonian method.
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; r <<= 64; }
        if (xx >= 0x10000000000000000) { xx >>= 64; r <<= 32; }
        if (xx >= 0x100000000) { xx >>= 32; r <<= 16; }
        if (xx >= 0x10000) { xx >>= 16; r <<= 8; }
        if (xx >= 0x100) { xx >>= 8; r <<= 4; }
        if (xx >= 0x10) { xx >>= 4; r <<= 2; }
        if (xx >= 0x4) { r <<= 1; }
        unchecked {
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            uint256 r1 = x / r;
            return r < r1 ? r : r1;
        }
    }
}
