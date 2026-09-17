// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ManagedOracle} from "./ManagedOracle.sol";
import {ICheckedOracle} from "./interfaces/ICheckedOracle.sol";
import {IHydraChainlinkOracle} from "./dependencies/hydra-chainlink/IHydraChainlinkOracle.sol";

/// @notice A ManagedOracle that refuses pushed prices which disagree with an
/// on-chain check feed (Hydration's EMA oracle precompile) by more than
/// `maxDiffBps`.
///
/// Threat model:
/// - The pushed price is the manipulation-prone side: a compromised relayer
///   key, a bad VAA, or a fat-fingered manual update can move it arbitrarily
///   in one call. ManagedOracle has no bound on it at all.
/// - The check feed is Hydration's pool EMA precompile. Moving it meaningfully
///   needs sustained imbalance, not a single transaction.
///
/// The check happens at write time, not at read time (cf. ClampedOracle): a
/// bad update is rejected outright rather than reported clamped, so reads stay
/// a plain storage load and the reported price is always exactly what was
/// pushed and accepted.
///
/// Roles:
/// - `pusher` may only push prices that pass the check. Compromising it caps
///   the damage at `maxDiffBps` around the pool EMA.
/// - `owner` (governance) configures the check feed, the band and the pusher,
///   and may push unchecked via `setPriceUnchecked` — the escape hatch for a
///   dead check feed. Owner is therefore fully trusted, as in ManagedOracle.
///
/// Fail-closed: no usable check price (feed reverts, returns <= 0, or is
/// unset) means no checked update. The price freezes at its last value until
/// the feed recovers, governance swaps the feed, or the owner pushes
/// unchecked.
///
/// The constructor price is not checked: deploying is an owner action, of the
/// same weight as `setPriceUnchecked`, and requiring the initial value to sit
/// inside the band would make a wrapper undeployable exactly when the managed
/// price legitimately diverges from the pool.
contract CheckedOracle is ManagedOracle, ICheckedOracle {
    uint256 public constant MAX_BPS = 10_000;

    /// @dev Upper bound on check-feed decimals; keeps the scaling factor sane.
    uint8 internal constant MAX_FEED_DECIMALS = 36;

    address public override checkOracle;
    uint8 public override checkDecimals;
    uint256 public override maxDiffBps;
    address public override pusher;

    modifier onlyPriceSetter() {
        if (msg.sender != pusher && msg.sender != owner())
            revert NotPriceSetter();
        _;
    }

    constructor(
        string memory description_,
        uint256 version_,
        address initialOwner,
        int256 initialPrice,
        address checkOracle_,
        uint256 maxDiffBps_,
        address pusher_
    ) ManagedOracle(description_, version_, initialOwner, initialPrice) {
        _setCheckOracle(checkOracle_);
        _setMaxDiffBps(maxDiffBps_);
        _setPusher(pusher_);
    }

    // ---------------------------------------------------------------------
    // price pushing
    // ---------------------------------------------------------------------

    /// @notice Pushes `price`, provided it sits within `maxDiffBps` of the
    /// check feed. Callable by the pusher or the owner.
    function setPrice(int256 price) external override onlyPriceSetter {
        if (price <= 0) revert InvalidPrice();

        (bool ok, uint256 check) = _checkPrice();
        if (!ok) revert CheckPriceUnavailable();

        uint256 p = uint256(price);
        if (!_withinBand(p, check))
            revert PriceDeviationTooLarge(
                price,
                int256(check),
                _deviationBps(p, check),
                maxDiffBps
            );

        _setPrice(price);
    }

    /// @notice Pushes `price` without consulting the check feed. Owner only;
    /// the escape hatch for a dead or wrong check feed.
    function setPriceUnchecked(int256 price) external override onlyOwner {
        (bool ok, uint256 check) = _checkPrice();
        uint80 roundId = _setPrice(price);

        emit PriceSetUnchecked(roundId, price, ok ? int256(check) : int256(0));
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    /// @notice The check feed's current price, normalised to this oracle's
    /// decimals. `ok` is false when the feed is unusable.
    function checkPrice() external view override returns (bool ok, int256 price) {
        uint256 check;
        (ok, check) = _checkPrice();
        return (ok, int256(check));
    }

    /// @notice Whether `setPrice(price)` would be accepted right now, and by
    /// how much `price` deviates from the check feed. `deviationBps` is 0 when
    /// the check price is unavailable.
    function previewSetPrice(
        int256 price
    ) external view override returns (bool ok, uint256 deviationBps) {
        if (price <= 0) return (false, 0);

        (bool hasCheck, uint256 check) = _checkPrice();
        if (!hasCheck) return (false, 0);

        uint256 p = uint256(price);
        return (_withinBand(p, check), _deviationBps(p, check));
    }

    // ---------------------------------------------------------------------
    // configuration (owner)
    // ---------------------------------------------------------------------

    function setCheckOracle(address checkOracle_) external override onlyOwner {
        _setCheckOracle(checkOracle_);
    }

    function setMaxDiffBps(uint256 maxDiffBps_) external override onlyOwner {
        _setMaxDiffBps(maxDiffBps_);
    }

    function setPusher(address pusher_) external override onlyOwner {
        _setPusher(pusher_);
    }

    function _setCheckOracle(address checkOracle_) internal {
        if (checkOracle_ == address(0)) revert InvalidFeed();

        uint8 feedDecimals = _feedDecimals(checkOracle_);
        checkOracle = checkOracle_;
        checkDecimals = feedDecimals;

        emit CheckOracleUpdated(checkOracle_, feedDecimals);
    }

    function _setMaxDiffBps(uint256 maxDiffBps_) internal {
        if (maxDiffBps_ > MAX_BPS) revert InvalidBps();
        maxDiffBps = maxDiffBps_;

        emit MaxDiffBpsUpdated(maxDiffBps_);
    }

    function _setPusher(address pusher_) internal {
        emit PusherUpdated(pusher, pusher_);
        pusher = pusher_;
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------

    /// @dev Reads the check feed and rescales it to `decimals`. Any failure
    /// mode of the feed surfaces as `ok == false`, never as a revert.
    function _checkPrice() internal view returns (bool ok, uint256 price) {
        address feed = checkOracle;
        if (feed == address(0)) return (false, 0);

        try IHydraChainlinkOracle(feed).latestAnswer() returns (int256 answer) {
            if (answer <= 0) return (false, 0);
            return (true, _scale(uint256(answer)));
        } catch {
            return (false, 0);
        }
    }

    function _scale(uint256 answer) internal view returns (uint256) {
        uint8 d = checkDecimals;
        if (d == decimals) return answer;
        if (d < decimals) return answer * (10 ** uint256(decimals - d));
        return answer / (10 ** uint256(d - decimals));
    }

    /// @dev |p - c| / c <= maxDiffBps / MAX_BPS, cross-multiplied so the band
    /// edges are exact rather than rounded.
    function _withinBand(uint256 p, uint256 c) internal view returns (bool) {
        uint256 diff = p > c ? p - c : c - p;
        return diff * MAX_BPS <= maxDiffBps * c;
    }

    function _deviationBps(
        uint256 p,
        uint256 c
    ) internal pure returns (uint256) {
        uint256 diff = p > c ? p - c : c - p;
        return (diff * MAX_BPS) / c;
    }

    /// @dev Feeds that don't answer `decimals()` are assumed to match this
    /// oracle's own 8; the assumption is emitted in CheckOracleUpdated.
    function _feedDecimals(address feed) internal view returns (uint8) {
        try IHydraChainlinkOracle(feed).decimals() returns (uint8 d) {
            if (d > MAX_FEED_DECIMALS) revert InvalidFeed();
            return d;
        } catch {
            return decimals;
        }
    }
}
