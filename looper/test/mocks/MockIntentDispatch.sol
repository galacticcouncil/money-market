// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MockERC20} from "./MockERC20.sol";
import {MockAToken} from "./MockAToken.sol";
import {MockPool} from "./MockPool.sol";

/// @notice Dispatch precompile (0x0401) stand-in for pallet-intent and MultiTransactionPayment: parses
/// the exact SCALE of `submit_intent`, `remove_intent` and `set_currency`, reserves the input, builds ids
/// `(submission_ms << 64) | counter`, enforces the per-asset ED floors, charges the forward fee in the
/// owner's fee currency at fill and queues the forward. A failed dispatch burns its frame like the real one.
/// Etched at 0x0401, so it is configured after `vm.etch` and has no constructor state.
contract MockIntentDispatch {
    uint8 internal constant INTENT_PALLET = 98;
    uint8 internal constant PAYMENT_PALLET = 203;

    enum State {
        None,
        Open,
        Filled,
        Returned
    }

    struct Intent {
        address owner;
        uint32 assetIn;
        uint32 assetOut;
        uint256 amountIn;
        uint256 minOut;
        uint64 deadline;
        address forward;
        bytes data;
        State state;
    }

    struct Forward {
        address owner;
        uint128 id;
        uint32 assetIn;
        uint256 amountIn;
        uint32 assetOut;
        uint256 amountOut;
        address contract_;
        bytes data;
    }

    event CurrencySet(address account, uint32 assetId);
    event Queued(uint128 id, address who, uint256 fee);
    event FailedToQueueCallback(uint128 id, address who);

    MockPool public pool;
    mapping(uint32 => address) public token;
    mapping(uint32 => bool) public isAToken;
    mapping(uint32 => uint256) public ed;
    mapping(address => uint32) public currencyOf;
    mapping(address => bool) public hasCurrency;
    uint256 public fee;
    uint64 public counter;
    uint128 public lastId;
    mapping(uint128 => Intent) internal _intents;
    mapping(address => uint256) public liveCount;
    Forward[] internal _queue;
    uint256 public head;

    /// @dev persistent until cleared: a failed dispatch reverts the whole frame, flag writes included
    bool public failSubmit;
    bool public failRemove;
    bool public rejectSetCurrency;
    uint256 public submits;

    function configure(address pool_, uint256 fee_) external {
        pool = MockPool(pool_);
        fee = fee_;
    }

    function register(uint32 id, address t, bool aToken, uint256 ed_) external {
        token[id] = t;
        isAToken[id] = aToken;
        ed[id] = ed_;
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function setFailures(bool failSubmit_, bool failRemove_, bool rejectSetCurrency_) external {
        (failSubmit, failRemove, rejectSetCurrency) = (failSubmit_, failRemove_, rejectSetCurrency_);
    }

    /// @notice governance's `reset_payment_currency`: an EVM account then pays in WETH, which it never holds
    function resetCurrency(address who) external {
        hasCurrency[who] = false;
        currencyOf[who] = 0;
    }

    function intent(uint128 id) external view returns (Intent memory) {
        return _intents[id];
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function queued(uint256 i) external view returns (Forward memory) {
        return _queue[i];
    }

    function popTop() external returns (Forward memory f) {
        f = _queue[head++];
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        uint8 pallet = uint8(input[0]);
        uint8 call = uint8(input[1]);
        if (pallet == PAYMENT_PALLET && call == 0) {
            if (rejectSetCurrency) _burn();
            uint32 id = uint32(_le(input, 2, 4));
            currencyOf[msg.sender] = id;
            hasCurrency[msg.sender] = true;
            emit CurrencySet(msg.sender, id);
        } else if (pallet == INTENT_PALLET && call == 0) {
            _submit(input);
        } else if (pallet == INTENT_PALLET && call == 1) {
            _remove(uint128(_le(input, 2, 16)));
        } else {
            _burn();
        }
        return "";
    }

    // ── what the solver and the cleanup worker do ──

    /// @notice oracle-fair output of `id` less `bps`, an aToken priced as its underlying
    function quote(uint128 id, uint256 bps) public view returns (uint256) {
        Intent storage it = _intents[id];
        (uint256 pIn, uint8 dIn) = _priced(it.assetIn);
        (uint256 pOut, uint8 dOut) = _priced(it.assetOut);
        uint256 out = it.amountIn * pIn * 10 ** dOut / (pOut * 10 ** dIn);
        return out * (10_000 - bps) / 10_000;
    }

    /// @notice pay the fill to the owner, then queue the forward and charge its fee (or drop it)
    function fill(uint128 id, uint256 amountOut) external {
        Intent storage it = _intents[id];
        require(it.state == State.Open, "MockIntentDispatch: not open");
        require(amountOut >= it.minOut, "MockIntentDispatch: below limit");
        require(block.timestamp * 1000 < it.deadline, "MockIntentDispatch: expired");
        it.state = State.Filled;
        --liveCount[it.owner];
        _pay(it.assetOut, it.owner, amountOut);
        if (it.forward == address(0)) return;
        address feeToken = token[currencyOf[it.owner]];
        if (!hasCurrency[it.owner] || feeToken == address(0) || MockERC20(feeToken).balanceOf(it.owner) < fee) {
            emit FailedToQueueCallback(id, it.owner);
            return;
        }
        if (fee > 0) MockERC20(feeToken).move(it.owner, address(this), fee);
        _queue.push(Forward(it.owner, id, it.assetIn, it.amountIn, it.assetOut, amountOut, it.forward, it.data));
        emit Queued(id, it.owner, fee);
    }

    /// @notice `cleanup_intent` after the deadline: the reserved input goes back, no callback
    function cleanup(uint128 id) external {
        Intent storage it = _intents[id];
        require(it.state == State.Open, "MockIntentDispatch: not open");
        require(block.timestamp * 1000 >= it.deadline, "MockIntentDispatch: active");
        _refund(it);
    }

    // ── pallet ──

    function _submit(bytes calldata input) internal {
        if (failSubmit) _burn();
        require(uint8(input[2]) == 0 && uint8(input[43]) == 0, "MockIntentDispatch: not a full swap");
        require(uint8(input[44]) == 1 && uint8(input[53]) == 1 && uint8(input[54]) == 0, "MockIntentDispatch: shape");
        Intent memory it;
        it.owner = msg.sender;
        it.assetIn = uint32(_le(input, 3, 4));
        it.assetOut = uint32(_le(input, 7, 4));
        it.amountIn = _le(input, 11, 16);
        it.minOut = _le(input, 27, 16);
        it.deadline = uint64(_le(input, 45, 8));
        it.forward = address(bytes20(input[55:75]));
        (uint256 len, uint256 skip) = _compact(input, 75);
        it.data = input[75 + skip:75 + skip + len];
        it.state = State.Open;
        if (it.amountIn < ed[it.assetIn] || it.minOut < ed[it.assetOut] || it.deadline <= block.timestamp * 1000) {
            _burn();
        }
        _move(it.assetIn, msg.sender, address(this), it.amountIn);
        ++submits;
        lastId = (uint128(block.timestamp * 1000) << 64) | ++counter;
        _intents[lastId] = it;
        ++liveCount[msg.sender];
    }

    function _remove(uint128 id) internal {
        Intent storage it = _intents[id];
        if (failRemove || it.state != State.Open || it.owner != msg.sender) _burn();
        _refund(it);
    }

    function _refund(Intent storage it) internal {
        it.state = State.Returned;
        --liveCount[it.owner];
        _move(it.assetIn, address(this), it.owner, it.amountIn);
    }

    function _move(uint32 id, address from, address to, uint256 amount) internal {
        if (isAToken[id]) MockAToken(token[id]).move(from, to, amount);
        else MockERC20(token[id]).move(from, to, amount);
    }

    function _pay(uint32 id, address to, uint256 amount) internal {
        if (!isAToken[id]) {
            MockERC20(token[id]).mint(to, amount);
            return;
        }
        MockERC20 underlying = MockERC20(MockAToken(token[id]).UNDERLYING_ASSET_ADDRESS());
        underlying.mint(address(this), amount);
        underlying.approve(address(pool), amount);
        pool.supply(address(underlying), amount, address(this), 0);
        MockAToken(token[id]).move(address(this), to, amount);
    }

    function _priced(uint32 id) internal view returns (uint256 price, uint8 dec) {
        address t = isAToken[id] ? MockAToken(token[id]).UNDERLYING_ASSET_ADDRESS() : token[id];
        price = pool.getAssetPrice(t);
        dec = MockERC20(t).decimals();
    }

    /// @dev the real precompile consumes the whole frame on a failed dispatch
    function _burn() internal pure {
        assembly {
            invalid()
        }
    }

    function _compact(bytes calldata b, uint256 o) internal pure returns (uint256 len, uint256 size) {
        uint8 mode = uint8(b[o]) & 3;
        if (mode == 0) return (uint8(b[o]) >> 2, 1);
        require(mode == 1, "MockIntentDispatch: compact");
        return ((uint256(uint8(b[o])) | (uint256(uint8(b[o + 1])) << 8)) >> 2, 2);
    }

    function _le(bytes calldata b, uint256 o, uint256 n) internal pure returns (uint256 x) {
        for (uint256 i = 0; i < n; i++) {
            x |= uint256(uint8(b[o + i])) << (8 * i);
        }
    }
}
