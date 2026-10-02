// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DcaDispatch} from "../../src/lib/DcaDispatch.sol";

/// Fork-only adapter: executes real runtime routes, not a production Augustus implementation.
contract NativeRouteSwapper {
    using SafeERC20 for IERC20;
    function sell(address tokenIn, address tokenOut, uint256 amount, uint256 minOut, bytes calldata)
        external returns (uint256 received)
    {
        require(amount <= type(uint128).max && minOut <= type(uint128).max);
        require(uint160(tokenIn) == (uint160(1) << 32) + 43, "PRIME only");
        uint32 out = uint32(uint160(tokenOut));
        require(uint160(tokenOut) == (uint160(1) << 32) + out && (out == 34 || out == 1000765));
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount);
        DcaDispatch.Hop[] memory hops = new DcaDispatch.Hop[](0);
        DcaDispatch.routerSell(43, out, uint128(amount), uint128(minOut), hops);
        received = IERC20(tokenOut).balanceOf(address(this)) - before;
        require(received >= minOut);
        IERC20(tokenOut).safeTransfer(msg.sender, received);
    }
}
