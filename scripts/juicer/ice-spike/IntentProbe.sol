// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 { function balanceOf(address) external view returns (uint256); }

/// throwaway lark spike: submit an ICE intent from a contract and record the resolution callback
contract IntentProbe {
    address internal constant DISPATCH = 0x0000000000000000000000000000000000000401;
    address public immutable owner;
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;

    event Submitted(uint256 tokenInBefore, uint256 tokenOutBefore);
    event Called(address sender, bytes data, uint256 tokenIn, uint256 tokenOut, uint256 blockNumber);

    constructor(IERC20 tokenIn_, IERC20 tokenOut_) { owner = msg.sender; tokenIn = tokenIn_; tokenOut = tokenOut_; }

    function submit(bytes calldata scaleCall) external {
        require(msg.sender == owner, "owner");
        emit Submitted(tokenIn.balanceOf(address(this)), tokenOut.balanceOf(address(this)));
        (bool ok, bytes memory reason) = DISPATCH.call(scaleCall);
        if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
    }

    event Executed(address sender, address origin, address owner_, uint256 intentId, address assetIn, uint256 amountIn,
        address assetOut, uint256 amountOut, bytes data, uint256 tokenOutBalance);

    // lazy-executor receiver: must return its own selector as the ack
    function execute(address owner_, uint256 intentId, address assetIn, uint256 amountIn, address assetOut,
        uint256 amountOut, bytes calldata data) external returns (bytes4)
    {
        emit Executed(msg.sender, tx.origin, owner_, intentId, assetIn, amountIn, assetOut, amountOut, data,
            tokenOut.balanceOf(address(this)));
        return this.execute.selector;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        emit Called(msg.sender, data, tokenIn.balanceOf(address(this)), tokenOut.balanceOf(address(this)), block.number);
        return "";
    }
}
