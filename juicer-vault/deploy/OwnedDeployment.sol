// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice creates a contract that makes its creator the owner (HydraAugustus) and hands it to `owner_` in the
///         same transaction, so the deploying account never owns it
/// @dev outside src/: production builds keep their sources, and bytecode, unchanged
contract OwnedDeployment {
    address public immutable deployed;

    error ZeroAddress();
    error CreateFailed();
    error NotHandedOver();

    constructor(bytes memory initcode, address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        address created;
        assembly ("memory-safe") {
            created := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (created == address(0)) revert CreateFailed();
        IOwnable(created).transferOwnership(owner_);
        if (IOwnable(created).owner() != owner_) revert NotHandedOver();
        deployed = created;
    }
}
