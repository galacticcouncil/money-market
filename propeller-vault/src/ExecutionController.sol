// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Shared trade budgets and short-lived, caller-supplied execution quotes.
/// Quotes tighten the independent oracle floors in each consumer. They are not
/// trusted price feeds. preview executes the real routes in a reverting subcall:
/// even a mined preview cannot borrow, trade, spend credit or retain user funds.
contract ExecutionController is AccessControl, ReentrancyGuard {
    struct Budget {
        address token;
        uint128 capacity;
        uint128 refillPerSecond;
        uint128 credit;
        uint64 updatedAt;
        uint64 expiresAt;
    }
    struct Limit { bytes32 group; uint128 minimum; uint128 maximum; }
    struct Quote { bytes32 lane; uint256 amountIn; uint256 minOut; }
    struct Trade { bytes32 lane; uint256 amountIn; uint256 amountOut; }
    struct Pacing { uint64 interval; uint64 nextAt; uint256 lastBlock; }
    mapping(bytes32 => Budget) public budgets;
    mapping(bytes32 => Limit) public limits;
    mapping(bytes32 => Pacing) public pacing;
    // Total loss against the consumer's live MM-oracle quote, including fees.
    // Zero is a usable strict floor: oracle price or better, not disabled.
    mapping(bytes32 => uint16) public maxShortfallBps;
    mapping(bytes32 => bool) public safetyLanes;
    mapping(address => mapping(bytes4 => bool)) public actions;
    uint64 public immutable maxQuoteAge;
    uint64 public immutable maxQuoteBlocks;
    address public caller;
    bool private simulating;
    mapping(bytes32 => Quote) private quotes;
    mapping(bytes32 => uint256) private spent;
    mapping(bytes32 => uint256) private minimums;
    mapping(bytes32 => bool) private activeGroups;
    Trade[] private trades;

    error InvalidPolicy();
    error InvalidQuote();
    error UnauthorizedAction();
    error QuoteRequired();
    error TradeSize();
    error Simulation(bytes result);
    event BudgetConfigured(bytes32 indexed group, Budget budget);
    event LimitConfigured(bytes32 indexed lane, Limit limit);
    event ActionConfigured(address indexed target, bytes4 selector, bool enabled);
    event PriceConfigured(bytes32 indexed lane, uint16 maxShortfallBps, bool safety);
    event PacingConfigured(bytes32 indexed group, uint64 interval);
    event Executed(address indexed caller, address indexed target, bytes4 selector);

    constructor(address admin, uint64 age, uint64 blocks_) {
        if (admin == address(0) || age == 0 || blocks_ == 0 || blocks_ > 255) revert InvalidPolicy();
        maxQuoteAge = age;
        maxQuoteBlocks = blocks_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function lane(address consumer, address tokenIn, address tokenOut) public pure returns (bytes32) {
        return keccak256(abi.encode(consumer, tokenIn, tokenOut));
    }

    function configureBudget(bytes32 group, address token, uint128 capacity, uint128 refill, uint64 expiresAt)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        if (group == bytes32(0) || token == address(0) || capacity == 0 || expiresAt <= block.timestamp)
            revert InvalidPolicy();
        Budget storage old = budgets[group];
        if (old.token != address(0) && old.token != token) revert InvalidPolicy();
        // A policy refresh does not refill an exhausted bucket.
        uint128 credit = old.token == address(0) ? capacity : uint128(Math.min(capacity, _credit(old)));
        budgets[group] = Budget(token, capacity, refill, credit, uint64(block.timestamp), expiresAt);
        emit BudgetConfigured(group, budgets[group]);
    }

    function configureLimit(address consumer, address tokenIn, address tokenOut, bytes32 group,
        uint128 minimum, uint128 maximum) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        if (consumer.code.length == 0 || tokenOut == address(0) || budgets[group].token != tokenIn
            || minimum == 0 || maximum < minimum || maximum > budgets[group].capacity) revert InvalidPolicy();
        bytes32 key = lane(consumer, tokenIn, tokenOut);
        limits[key] = Limit(group, minimum, maximum);
        emit LimitConfigured(key, limits[key]);
    }

    function configureAction(address target, bytes4 selector, bool enabled)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        if (target.code.length == 0 || target == address(this)) revert InvalidPolicy();
        actions[target][selector] = enabled;
        emit ActionConfigured(target, selector, enabled);
    }

    function configurePrice(bytes32 key, uint16 shortfallBps, bool safety)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        if (limits[key].maximum == 0 || shortfallBps >= 10_000) revert InvalidPolicy();
        maxShortfallBps[key] = shortfallBps;
        safetyLanes[key] = safety;
        emit PriceConfigured(key, shortfallBps, safety);
    }

    function configurePacing(bytes32 group, uint64 interval)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        if (budgets[group].token == address(0)) revert InvalidPolicy();
        Pacing storage p = pacing[group];
        p.interval = interval;
        // A policy refresh cannot reopen an already consumed time slot.
        if (p.lastBlock != 0) p.nextAt = uint64(Math.max(p.nextAt, block.timestamp + interval));
        emit PacingConfigured(group, interval);
    }

    function _credit(Budget storage b) private view returns (uint256) {
        return Math.min(b.capacity, uint256(b.credit) + (block.timestamp - b.updatedAt) * b.refillPerSecond);
    }

    function available(address consumer, address tokenIn, address tokenOut) public view returns (uint256 amount) {
        return _available(lane(consumer, tokenIn, tokenOut), false);
    }

    function availableSafety(address consumer, address tokenIn, address tokenOut) external view returns (uint256) {
        return _available(lane(consumer, tokenIn, tokenOut), true);
    }

    function _available(bytes32 key, bool safety) private view returns (uint256 amount) {
        Limit storage l = limits[key];
        Budget storage b = budgets[l.group];
        if (safety) {
            if (!safetyLanes[key]) return 0;
            amount = l.maximum;
        } else {
            Pacing storage p = pacing[l.group];
            if (b.expiresAt <= block.timestamp || (!activeGroups[l.group]
                && (block.timestamp < p.nextAt || (p.lastBlock != 0 && p.lastBlock == block.number)))) return 0;
            amount = Math.min(l.maximum, _credit(b));
        }
        if (caller != address(0) && (!simulating || quotes[key].amountIn != 0)) {
            amount = Math.min(amount, quotes[key].amountIn - spent[key]);
        }
        if (amount < l.minimum) return 0;
    }

    function fit(address consumer, address tokenIn, address tokenOut, uint256 wanted) external view returns (uint256 amount) {
        amount = Math.min(wanted, available(consumer, tokenIn, tokenOut));
        if (amount < limits[lane(consumer, tokenIn, tokenOut)].minimum) return 0;
    }

    function fitSafety(address consumer, address tokenIn, address tokenOut, uint256 wanted) external view returns (uint256 amount) {
        bytes32 key = lane(consumer, tokenIn, tokenOut);
        amount = Math.min(wanted, _available(key, true));
        if (amount < limits[key].minimum) return 0;
    }

    /// @notice Fit and quote an unwind slice; a direct, unquoted maintenance
    /// call can still repay existing cash but cannot initiate a new swap.
    function prepare(address tokenIn, address tokenOut, uint256 wanted, uint256 fairOut, bool safety)
        external returns (uint256 amount, uint256 minimum)
    {
        if (caller == address(0)) return (0, 0);
        bytes32 key = lane(msg.sender, tokenIn, tokenOut);
        amount = Math.min(wanted, _available(key, safety));
        if (amount == 0 || amount < limits[key].minimum) return (0, 0);
        minimum = _consume(tokenIn, tokenOut, amount, Math.mulDiv(fairOut, amount, wanted), safety);
    }

    /// @dev Called immediately before each governed trade. A failed transaction
    /// rolls back both credit and all Aave/share accounting atomically.
    function consume(address tokenIn, address tokenOut, uint256 amount, uint256 fairOut)
        external returns (uint256 minimum)
    {
        return _consume(tokenIn, tokenOut, amount, fairOut, false);
    }

    /// @dev Only a configured consumer can use its safety lane. Its code must
    /// restrict this call to an outstanding safety deleveraging commitment.
    /// Safety may bypass timing/volume expiry, never size, quote or price bounds.
    function consumeSafety(address tokenIn, address tokenOut, uint256 amount, uint256 fairOut)
        external returns (uint256 minimum)
    {
        return _consume(tokenIn, tokenOut, amount, fairOut, true);
    }

    function _consume(address tokenIn, address tokenOut, uint256 amount, uint256 fairOut, bool safety)
        private returns (uint256 minimum)
    {
        if (caller == address(0)) revert QuoteRequired();
        bytes32 key = lane(msg.sender, tokenIn, tokenOut);
        Limit storage l = limits[key];
        if (amount < l.minimum || amount == 0 || amount > _available(key, safety)) revert TradeSize();
        if (fairOut == 0) revert InvalidQuote();
        minimum = Math.mulDiv(fairOut, 10_000 - maxShortfallBps[key], 10_000, Math.Rounding.Up);
        Budget storage b = budgets[l.group];
        b.credit = uint128(_credit(b) - Math.min(_credit(b), amount));
        b.updatedAt = uint64(block.timestamp);
        Pacing storage p = pacing[l.group];
        p.nextAt = uint64(block.timestamp + p.interval);
        p.lastBlock = block.number;
        activeGroups[l.group] = true;
        if (!simulating) {
            Quote storage q = quotes[key];
            if (q.minOut == 0) revert InvalidQuote();
            minimum = Math.max(minimum, Math.mulDiv(q.minOut, amount, q.amountIn, Math.Rounding.Up));
        }
        minimums[key] = minimum;
        if (quotes[key].amountIn != 0) spent[key] += amount;
        trades.push(Trade(key, amount, 0));
    }

    function record(address tokenIn, address tokenOut, uint256 output) external {
        if (caller == address(0) || trades.length == 0) revert QuoteRequired();
        Trade storage t = trades[trades.length - 1];
        if (t.lane != lane(msg.sender, tokenIn, tokenOut) || t.amountOut != 0 || output == 0
            || output < minimums[t.lane]) revert InvalidQuote();
        t.amountOut = output;
    }

    function execute(address target, bytes calldata data, uint256 quotedBlock, bytes32 quotedHash,
        uint256 deadline, Quote[] calldata supplied) external nonReentrant returns (bytes memory result)
    {
        if (quotedBlock >= block.number || block.number - quotedBlock > maxQuoteBlocks
            || quotedHash == bytes32(0) || blockhash(quotedBlock) != quotedHash
            || block.timestamp > deadline || deadline > block.timestamp + maxQuoteAge) revert InvalidQuote();
        for (uint256 i; i < supplied.length; ++i) {
            Quote calldata q = supplied[i];
            if (q.amountIn == 0 || q.minOut == 0 || quotes[q.lane].amountIn != 0) revert InvalidQuote();
            quotes[q.lane] = q;
        }
        caller = msg.sender;
        result = _call(target, data);
        for (uint256 i; i < trades.length; ++i) {
            if (trades[i].amountOut == 0) revert InvalidQuote();
            activeGroups[limits[trades[i].lane].group] = false;
            delete minimums[trades[i].lane];
        }
        caller = address(0);
        delete trades;
        for (uint256 i; i < supplied.length; ++i) {
            delete quotes[supplied[i].lane];
            delete spent[supplied[i].lane];
        }
        emit Executed(msg.sender, target, bytes4(data[:4]));
    }

    /// @notice Use eth_call at an identified block, then bind execute to that
    /// block/hash and the measured per-lane outputs. No quote publisher is needed.
    function preview(address target, bytes calldata data) external nonReentrant
        returns (bytes memory result, Trade[] memory fills)
    {
        return _preview(target, data, new Quote[](0));
    }

    /// @notice Try a smaller buy/harvest while leaving the servicing lane's
    /// capacity intact. Caps only reduce policy limits; minOut is unused here.
    function previewBounded(address target, bytes calldata data, Quote[] calldata caps) external nonReentrant
        returns (bytes memory result, Trade[] memory fills)
    {
        return _preview(target, data, caps);
    }

    function _preview(address target, bytes calldata data, Quote[] memory caps) private
        returns (bytes memory result, Trade[] memory fills)
    {
        try this.simulate(msg.sender, target, data, caps) { revert InvalidQuote(); }
        catch (bytes memory reason) {
            if (reason.length < 4 || bytes4(reason) != Simulation.selector) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
            bytes memory payload = new bytes(reason.length - 4);
            for (uint256 i; i < payload.length; ++i) payload[i] = reason[i + 4];
            return abi.decode(abi.decode(payload, (bytes)), (bytes, Trade[]));
        }
    }

    function simulate(address actor, address target, bytes calldata data, Quote[] calldata caps) external {
        if (msg.sender != address(this)) revert UnauthorizedAction();
        caller = actor;
        simulating = true;
        for (uint256 i; i < caps.length; ++i) {
            if (caps[i].amountIn == 0 || quotes[caps[i].lane].amountIn != 0) revert InvalidQuote();
            quotes[caps[i].lane] = caps[i];
        }
        bytes memory result = _call(target, data);
        revert Simulation(abi.encode(result, trades));
    }

    function _call(address target, bytes calldata data) private returns (bytes memory result) {
        if (data.length < 4 || !actions[target][bytes4(data[:4])]) revert UnauthorizedAction();
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
    }
}
