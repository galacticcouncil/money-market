// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IQueueVault {
    function requestRedeem(uint256 shares, address receiver) external returns (uint256);
}
interface IQueueDebt {
    function fundPosition(uint256 key, uint256 amount) external;
}
interface IQueueToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Local-fork stress actor only. Batches independent public user actions;
/// it cannot bypass vault cooldowns, source funding, or native execution limits.
contract NativeQueueActor {
    address public immutable owner = msg.sender;

    function request(address vault, uint256 shares, uint256 count) external {
        require(msg.sender == owner);
        for (uint256 i; i < count; ++i) IQueueVault(vault).requestRedeem(shares, address(this));
    }

    function fund(address token, address ledger, uint256 firstKey, uint256 count, uint256 amount) external {
        require(msg.sender == owner);
        require(IQueueToken(token).transferFrom(owner, address(this), count * amount));
        require(IQueueToken(token).approve(ledger, count * amount));
        for (uint256 i; i < count; ++i) IQueueDebt(ledger).fundPosition(firstKey + i, amount);
        require(IQueueToken(token).approve(ledger, 0));
    }
}
