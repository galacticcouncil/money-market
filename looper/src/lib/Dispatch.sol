// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Calls into Hydration's dispatch precompile with the caller's own account as origin.
library Dispatch {
    address internal constant DISPATCH = 0x0000000000000000000000000000000000000401;
    uint8 internal constant PAYMENT_PALLET = 203;
    uint8 internal constant SET_CURRENCY_CALL = 0;

    /// @dev `MultiTransactionPayment.set_currency(asset_id)`.
    function encodeSetCurrency(uint32 assetId) internal pure returns (bytes memory) {
        return abi.encodePacked(
            PAYMENT_PALLET,
            SET_CURRENCY_CALL,
            bytes1(uint8(assetId)),
            bytes1(uint8(assetId >> 8)),
            bytes1(uint8(assetId >> 16)),
            bytes1(uint8(assetId >> 24))
        );
    }

    /// @dev A failed dispatch burns the gas of its frame, so the limit is explicit and the result is
    /// only a success flag: the precompile returns no reason.
    function dispatch(bytes memory payload, uint256 gasLimit) internal returns (bool ok) {
        (ok,) = DISPATCH.call{gas: gasLimit}(payload);
    }
}
