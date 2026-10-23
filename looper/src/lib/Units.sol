// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Token ↔ Aave base (8-decimal USD) conversions with an explicit rounding direction.
/// `price` is base per whole token as the Aave oracle reports it.
library Units {
    uint256 internal constant RAY = 1e27;

    function toBase(uint256 x, uint256 price, uint8 decimals, Math.Rounding r) internal pure returns (uint256) {
        return Math.mulDiv(x, price, 10 ** decimals, r);
    }

    function fromBase(uint256 x, uint256 price, uint8 decimals, Math.Rounding r) internal pure returns (uint256) {
        return Math.mulDiv(x, 10 ** decimals, price, r);
    }

    function sat(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @dev Scaled aToken delta → token units at `index`, floored (what one conversion may lose).
    function rayToTokens(uint256 scaledDelta, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledDelta, index, RAY);
    }
}
