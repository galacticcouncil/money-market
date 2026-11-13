// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MockERC20} from "./MockERC20.sol";
import {MockPool} from "./MockPool.sol";

/// @notice dispatch precompile (0x0401) stand-in for ICE: records `intent.submit_intent`, takes the
///         input like the pallet's reserve, and lets tests fill, expire or remove it. `router.sell`
///         runs at oracle prices like MockDispatch so safety de-levers stay synchronous.
contract MockIntentDispatch {
    uint8 internal constant ROUTER_PALLET = 67;
    uint8 internal constant INTENT_PALLET = 98;
    uint8 public constant OPEN = 1;
    uint8 public constant FILLED = 2;
    uint8 public constant RETURNED = 3;

    struct Intent {
        address owner;
        uint32 assetIn;
        uint32 assetOut;
        uint256 amountIn;
        uint256 amountOut;
        uint64 deadline;
        address forward;
        bytes data;
        uint8 state;
    }

    MockPool public pool;
    MockERC20 public hollar;
    MockERC20 public prime;
    uint32 public hollarId;
    uint32 public aPrimeId;
    uint16 public feeBps;
    uint64 public counter;
    uint128 public lastId;
    uint256 public routerSells;
    mapping(uint128 => Intent) internal _intents;

    function configure(address _pool, address _hollar, address _prime, uint32 _hollarId, uint32 _aPrimeId)
        external
    {
        pool = MockPool(_pool);
        hollar = MockERC20(_hollar);
        prime = MockERC20(_prime);
        hollarId = _hollarId;
        aPrimeId = _aPrimeId;
    }

    function setFeeBps(uint16 _feeBps) external {
        feeBps = _feeBps;
    }

    function intent(uint128 id) external view returns (Intent memory) {
        return _intents[id];
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (uint8(input[0]) == INTENT_PALLET) {
            if (uint8(input[1]) == 0) _submit(input);
            else if (uint8(input[1]) == 1) _remove(input);
            else revert("MockIntentDispatch: intent call");
            return "";
        }
        require(uint8(input[0]) == ROUTER_PALLET && uint8(input[1]) == 0, "MockIntentDispatch: not router.sell");
        _routerSell(_le32(input, 2), _le32(input, 6), _le(input, 10, 16), _le(input, 26, 16));
        return "";
    }

    // ── test controls: what the solver, the cleanup worker and the oracle-priced pool would do ──

    /// @notice pay the fill to the owner, as the solver does; the pallet never fills below the limit
    function fill(uint128 id, uint256 amountOut) external {
        Intent storage it = _intents[id];
        require(it.state == OPEN, "MockIntentDispatch: not open");
        require(amountOut >= it.amountOut, "MockIntentDispatch: below limit");
        require(block.timestamp * 1000 < it.deadline, "MockIntentDispatch: expired");
        it.state = FILLED;
        if (it.assetOut == aPrimeId) {
            _supplyFor(it.owner, amountOut);
        } else {
            prime.burn(address(this), it.amountIn);
            hollar.mint(it.owner, amountOut);
        }
    }

    /// @notice oracle-priced output less `bps`, like the solver's simulated AMM output less its haircut
    function quote(uint128 id, uint16 bps) public view returns (uint256 out) {
        Intent storage it = _intents[id];
        (uint256 pHollar,) = pool.assetPrice(address(hollar));
        (uint256 pPrime,) = pool.assetPrice(address(prime));
        out = it.assetIn == hollarId ? it.amountIn * pHollar / pPrime / 1e12 : it.amountIn * pPrime * 1e12 / pHollar;
        out = out * (10_000 - bps) / 10_000;
    }

    /// @notice `cleanup_intent` after the deadline: the reserved input goes back, with no callback
    function cleanup(uint128 id) external {
        Intent storage it = _intents[id];
        require(it.state == OPEN, "MockIntentDispatch: not open");
        require(block.timestamp * 1000 >= it.deadline, "MockIntentDispatch: active");
        _refund(it);
    }

    // ── pallet behaviour ──

    function _submit(bytes calldata input) internal {
        require(uint8(input[2]) == 0 && uint8(input[43]) == 0, "MockIntentDispatch: not a full swap");
        require(uint8(input[44]) == 1 && uint8(input[53]) == 1 && uint8(input[54]) == 0, "MockIntentDispatch: shape");
        Intent memory it;
        it.owner = msg.sender;
        it.assetIn = _le32(input, 3);
        it.assetOut = _le32(input, 7);
        it.amountIn = _le(input, 11, 16);
        it.amountOut = _le(input, 27, 16);
        it.deadline = uint64(_le(input, 45, 8));
        it.forward = address(bytes20(input[55:75]));
        (uint256 len, uint256 skip) = _compact(input, 75);
        it.data = input[75 + skip:75 + skip + len];
        it.state = OPEN;
        require(it.deadline > block.timestamp * 1000 && it.deadline < (block.timestamp + 1 days) * 1000,
            "MockIntentDispatch: deadline");
        // the pallet reserves the input; an aToken transfer is HF-checked like this withdraw
        if (it.assetIn == hollarId) hollar.burn(msg.sender, it.amountIn);
        else pool.mockWithdrawTo(address(prime), it.amountIn, msg.sender, address(this));
        lastId = (uint128(block.timestamp * 1000) << 64) | ++counter;
        _intents[lastId] = it;
    }

    function _remove(bytes calldata input) internal {
        Intent storage it = _intents[uint128(_le(input, 2, 16))];
        require(it.state == OPEN && it.owner == msg.sender, "MockIntentDispatch: not removable");
        _refund(it);
    }

    function _refund(Intent storage it) internal {
        it.state = RETURNED;
        if (it.assetIn == hollarId) hollar.mint(it.owner, it.amountIn);
        else {
            prime.approve(address(pool), it.amountIn);
            pool.supply(address(prime), it.amountIn, it.owner, 0);
        }
    }

    function _supplyFor(address owner, uint256 amount) internal {
        prime.mint(address(this), amount);
        prime.approve(address(pool), amount);
        pool.supply(address(prime), amount, owner, 0);
    }

    function _routerSell(uint32 assetIn, uint32 assetOut, uint256 amountIn, uint256 minOut) internal {
        ++routerSells;
        (uint256 pHollar,) = pool.assetPrice(address(hollar));
        (uint256 pPrime,) = pool.assetPrice(address(prime));
        if (assetIn == hollarId && assetOut == aPrimeId) {
            hollar.burn(msg.sender, amountIn);
            uint256 out6 = (amountIn * pHollar) / pPrime / 1e12 * (10_000 - feeBps) / 10_000;
            require(out6 >= minOut, "MockIntentDispatch: minOut");
            _supplyFor(msg.sender, out6);
        } else if (assetIn == aPrimeId && assetOut == hollarId) {
            pool.mockWithdrawTo(address(prime), amountIn, msg.sender, address(this));
            prime.burn(address(this), amountIn);
            uint256 out18 = (amountIn * pPrime * 1e12) / pHollar * (10_000 - feeBps) / 10_000;
            require(out18 >= minOut, "MockIntentDispatch: minOut");
            hollar.mint(msg.sender, out18);
        } else {
            revert("MockIntentDispatch: unknown pair");
        }
    }

    function _compact(bytes calldata b, uint256 o) internal pure returns (uint256 len, uint256 size) {
        uint8 mode = uint8(b[o]) & 3;
        if (mode == 0) return (uint8(b[o]) >> 2, 1);
        require(mode == 1, "MockIntentDispatch: compact");
        return ((uint256(uint8(b[o])) | (uint256(uint8(b[o + 1])) << 8)) >> 2, 2);
    }

    function _le32(bytes calldata b, uint256 o) internal pure returns (uint32) {
        return uint32(_le(b, o, 4));
    }

    function _le(bytes calldata b, uint256 o, uint256 n) internal pure returns (uint256 x) {
        for (uint256 i = 0; i < n; i++) {
            x |= uint256(uint8(b[o + i])) << (8 * i);
        }
    }
}
