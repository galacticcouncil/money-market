// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Owns the Hydration Uniswap v3 factory, so new pools get the protocol fee
// without a referendum: anyone can switch one of our pools to 4/4.

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UniswapV3FeeSetter {
    /// The live Hydration Uniswap v3 factory; only its pools are accepted.
    IUniswapV3Factory public constant FACTORY = IUniswapV3Factory(0x776c4Fd6A6170165a91bA45Dec40a14bcc8eC354);

    /// Governance's EVM identity (the dispatcher's Aave manager); the only caller of the owner functions.
    address public constant MANAGER = 0xAa7e0000000000000000000000000000000Aa7e0;

    /// The treasury's EVM identity: the first 20 bytes of PalletId("py/trsry")'s account, which
    /// dispatcher.dispatchAsTreasury acts as. Every permissionless collect pays here.
    address public constant TREASURY = 0x6d6f646C70792f74727372790000000000000000;

    /// Divisor for the protocol's share: 4 means 1/4 of the swap fee, on both tokens.
    uint8 public constant FEE_PROTOCOL = 4;

    /// Only MANAGER may call this.
    error NotManager(address caller);

    /// The factory must never be handed to address(0): nobody could ever collect fees or move it again.
    error ZeroOwner();

    /// The pool already reads 4/4, so there is nothing to set.
    error FeeAlreadySet(address pool);

    /// The factory's list does not hold this address, so it is not one of our pools.
    error UnknownPool(address pool);

    /// Anyone: set one of our pools' protocol fee to 4/4, unless it already is.
    function setFee(IUniswapV3Pool pool) external {
        _checkPool(pool);
        (,,,,, uint8 packed,) = pool.slot0();
        // token0's divisor is the low 4 bits, token1's the high 4 bits.
        if (packed % 16 == FEE_PROTOCOL && packed >> 4 == FEE_PROTOCOL) revert FeeAlreadySet(address(pool));
        pool.setFeeProtocol(FEE_PROTOCOL, FEE_PROTOCOL);
    }

    /// Anyone: send all of one of our pools' collected protocol fees to TREASURY; returns the amounts sent.
    function collectToTreasury(IUniswapV3Pool pool) external returns (uint128 amount0, uint128 amount1) {
        _checkPool(pool);
        // The pool caps each request at what it holds, so the maximum takes everything.
        return pool.collectProtocol(TREASURY, type(uint128).max, type(uint128).max);
    }

    /// Manager only: send a pool's collected protocol fees to `recipient`; returns the amounts sent.
    function collectProtocol(IUniswapV3Pool pool, address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        if (msg.sender != MANAGER) revert NotManager(msg.sender);
        return pool.collectProtocol(recipient, amount0Requested, amount1Requested);
    }

    /// Manager only: hand the factory to `newOwner` (the escape hatch). After this the setter has no power.
    function setFactoryOwner(address newOwner) external {
        if (msg.sender != MANAGER) revert NotManager(msg.sender);
        if (newOwner == address(0)) revert ZeroOwner();
        FACTORY.setOwner(newOwner);
    }

    // The pool's claims are untrusted; only the factory's list decides whether it is ours.
    function _checkPool(IUniswapV3Pool pool) private view {
        if (FACTORY.getPool(pool.token0(), pool.token1(), pool.fee()) != address(pool)) {
            revert UnknownPool(address(pool));
        }
    }
}
