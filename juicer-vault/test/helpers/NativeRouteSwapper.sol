// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DcaDispatch} from "../../src/lib/DcaDispatch.sol";

/// Fork-only adapter: executes real runtime routes, not a production Augustus implementation.
contract NativeRouteSwapper {
    using SafeERC20 for IERC20;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;

    function _id(address token) private pure returns (uint32 id) {
        if (token == HOLLAR) return 222;
        id = uint32(uint160(token));
        require(uint160(token) == (uint160(1) << 32) + id, "native asset");
    }
    function sell(address tokenIn, address tokenOut, uint256 amount, uint256 minOut, bytes calldata)
        external returns (uint256 received)
    {
        require(amount <= type(uint128).max && minOut <= type(uint128).max);
        uint32 input = _id(tokenIn);
        uint32 out = _id(tokenOut);
        require((input == 43 && (out == 34 || out == 1000765))
            || ((input == 34 || input == 1000765) && out == 222), "unsupported pair");
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount);
        DcaDispatch.Hop[] memory hops = new DcaDispatch.Hop[](0);
        DcaDispatch.routerSell(input, out, uint128(amount), uint128(minOut), hops);
        received = IERC20(tokenOut).balanceOf(address(this)) - before;
        require(received >= minOut);
        IERC20(tokenOut).safeTransfer(msg.sender, received);
    }
}
