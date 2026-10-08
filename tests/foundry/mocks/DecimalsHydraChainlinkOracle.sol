// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IHydraChainlinkOracle} from "../../../contracts/dependencies/hydra-chainlink/IHydraChainlinkOracle.sol";

/// @dev Like MockHydraChainlinkOracle but with a configurable scale.
contract DecimalsHydraChainlinkOracle is IHydraChainlinkOracle {
    uint8 private immutable _decimals;
    int256 private _answer;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }
}

/// @dev Answers prices but has no `decimals()` -- the scale has to be assumed.
contract NoDecimalsHydraChainlinkOracle is IHydraChainlinkOracle {
    int256 private _answer;

    constructor(int256 answer_) {
        _answer = answer_;
    }

    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }
}
