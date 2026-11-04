// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {CheckedOracle} from "./CheckedOracle.sol";
import {IDiscountedCheckedOracle} from "./interfaces/IDiscountedCheckedOracle.sol";

/// @notice A CheckedOracle that stores pushed prices at `coefficient` of
/// their value, and checks the discounted value against the check feed. The
/// pushed price is an off-chain fair value and the asset trades at a basis to
/// it locally, so discounting keeps the published price near the market
/// without widening the band. `setPriceUnchecked` is not discounted.
contract DiscountedCheckedOracle is CheckedOracle, IDiscountedCheckedOracle {
    /// @dev Neutral coefficient: publish the pushed price unchanged.
    uint256 public constant ONE = 1e8;

    /// @dev A discount deeper than 10% means the fair value and the market
    /// have diverged structurally; that is a decision to revisit the feed, not
    /// to dial further. A premium (> ONE) is never allowed: this contract only
    /// ever marks down.
    uint256 public constant override MIN_COEFFICIENT = 0.9e8;
    uint256 public constant override MAX_COEFFICIENT = ONE;

    uint256 public override coefficient;

    constructor(
        string memory description_,
        uint256 version_,
        address initialOwner,
        int256 initialPrice,
        address checkOracle_,
        uint256 maxDiffBps_,
        address pusher_,
        uint256 coefficient_
    )
        CheckedOracle(
            description_,
            version_,
            initialOwner,
            initialPrice,
            checkOracle_,
            maxDiffBps_,
            pusher_
        )
    {
        _setCoefficient(coefficient_);
        _setDiscountedPrice(initialPrice, false);
    }

    // ---------------------------------------------------------------------
    // price pushing
    // ---------------------------------------------------------------------

    /// @notice Discounts `raw` by `coefficient`, then stores it if the result
    /// sits within `maxDiffBps` of the check feed (or unconditionally while no
    /// check feed is set). Callable by the pusher or the owner.
    function setPrice(int256 raw) external override onlyPriceSetter {
        _setDiscountedPrice(raw, true);
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    /// @notice `raw` after the discount, as `setPrice` would store it.
    function discount(int256 raw) external view override returns (int256) {
        return _discount(raw);
    }

    /// @notice Whether `setPrice(raw)` would be accepted right now, and by how
    /// much the *discounted* value deviates from the check feed — the pusher
    /// passes the raw price here, exactly as it would to `setPrice`.
    function previewSetPrice(
        int256 raw
    ) external view override returns (bool ok, uint256 deviationBps) {
        if (raw <= 0) return (false, 0);

        int256 adjusted = _discount(raw);
        if (adjusted <= 0) return (false, 0);
        if (!checked()) return (true, 0);

        (bool hasCheck, uint256 check) = _checkPrice();
        if (!hasCheck) return (false, 0);

        uint256 p = uint256(adjusted);
        return (_withinBand(p, check), _deviationBps(p, check));
    }

    // ---------------------------------------------------------------------
    // configuration (owner)
    // ---------------------------------------------------------------------

    /// @notice Sets the discount. Takes effect on the next push; the stored
    /// price is left alone, so changing the dial never publishes a value that
    /// was not checked against the feed.
    function setCoefficient(uint256 coefficient_) external override onlyOwner {
        _setCoefficient(coefficient_);
    }

    function _setCoefficient(uint256 coefficient_) internal {
        if (coefficient_ < MIN_COEFFICIENT || coefficient_ > MAX_COEFFICIENT)
            revert InvalidCoefficient();

        emit CoefficientUpdated(coefficient, coefficient_);
        coefficient = coefficient_;
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------

    /// @dev Discounts `raw`, optionally gates the result on the check feed,
    /// stores it and reports what happened. The single path by which this
    /// oracle ever takes a price, constructor included.
    function _setDiscountedPrice(int256 raw, bool enforceBand) internal {
        if (raw <= 0) revert InvalidPrice();

        int256 adjusted = _discount(raw);
        if (adjusted <= 0) revert InvalidPrice();

        if (enforceBand && checkOracle != address(0)) {
            (bool ok, uint256 check) = _checkPrice();
            if (!ok) revert CheckPriceUnavailable();

            uint256 p = uint256(adjusted);
            if (!_withinBand(p, check))
                revert PriceDeviationTooLarge(
                    adjusted,
                    int256(check),
                    _deviationBps(p, check),
                    maxDiffBps
                );
        }

        uint80 roundId = _setPrice(adjusted);

        emit PriceDiscounted(roundId, raw, coefficient, adjusted);
    }

    /// @dev `raw * coefficient / 1e8`, truncated — so the published price is
    /// never above `raw` scaled by the coefficient.
    function _discount(int256 raw) internal view returns (int256) {
        return int256((uint256(raw) * coefficient) / ONE);
    }
}
