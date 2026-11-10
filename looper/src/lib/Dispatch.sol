// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Calls into Hydration's dispatch precompile with the caller's own account as origin.
library Dispatch {
    address internal constant DISPATCH = 0x0000000000000000000000000000000000000401;
    uint8 internal constant PAYMENT_PALLET = 203;
    uint8 internal constant SET_CURRENCY_CALL = 0;
    uint8 internal constant INTENT_PALLET = 98; // construct_runtime: Intent = 98 (runtime 447)
    uint8 internal constant SUBMIT_INTENT_CALL = 0;
    uint8 internal constant REMOVE_INTENT_CALL = 1;

    /// @dev `intent.submit_intent(IntentInput{Swap{.., partial: false}, Some(deadline),
    /// Some(Forward{contract, data})})`. The pallet takes `amountIn` at submit; the solver pays at
    /// least `amountOut` and the lazy executor then calls `forward.execute(..., data)`.
    function encodeSubmitIntent(
        uint32 assetIn,
        uint32 assetOut,
        uint128 amountIn,
        uint128 amountOut,
        uint64 deadlineMs,
        address forward,
        bytes memory data
    ) internal pure returns (bytes memory) {
        bytes memory swap = abi.encodePacked(
            INTENT_PALLET,
            SUBMIT_INTENT_CALL,
            bytes1(0x00), // IntentDataInput::Swap
            _le32(assetIn),
            _le32(assetOut),
            _le128(amountIn),
            _le128(amountOut),
            bytes1(0x00) // partial: false
        );
        return abi.encodePacked(
            swap,
            bytes1(0x01),
            _le64(deadlineMs), // deadline: Some(unix ms)
            bytes2(0x0100),
            forward, // on_resolved: Some(OnResolved::Forward), contract H160
            _compact(uint32(data.length)),
            data
        );
    }

    /// @dev `intent.remove_intent(id)`: the reserved input returns to the caller.
    function encodeRemoveIntent(uint128 id) internal pure returns (bytes memory) {
        return abi.encodePacked(INTENT_PALLET, REMOVE_INTENT_CALL, _le128(id));
    }

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

    // ── SCALE helpers ──

    function _le32(uint32 x) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(x)), bytes1(uint8(x >> 8)), bytes1(uint8(x >> 16)), bytes1(uint8(x >> 24)));
    }

    function _le64(uint64 x) private pure returns (bytes memory b) {
        b = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            b[i] = bytes1(uint8(x >> (8 * i)));
        }
    }

    function _le128(uint128 x) private pure returns (bytes memory b) {
        b = new bytes(16);
        for (uint256 i = 0; i < 16; i++) {
            b[i] = bytes1(uint8(x >> (8 * i)));
        }
    }

    /// @dev SCALE compact-u32, all four modes.
    function _compact(uint32 x) private pure returns (bytes memory) {
        if (x < 64) {
            return abi.encodePacked(bytes1(uint8(x) << 2));
        } else if (x < 16384) {
            uint16 v = (uint16(x) << 2) | 0x01;
            return abi.encodePacked(bytes1(uint8(v)), bytes1(uint8(v >> 8)));
        } else if (x < 1073741824) {
            return _le32((x << 2) | 0x02);
        } else {
            return abi.encodePacked(bytes1(0x03), _le32(x));
        }
    }
}
