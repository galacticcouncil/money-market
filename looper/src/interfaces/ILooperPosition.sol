// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAavePool} from "./IAavePool.sol";

interface ILooperPosition {
    enum Ladder {
        None,
        Ramp,
        Unwind
    }

    enum Kind {
        None,
        Entry,
        Exit
    }

    enum Stall {
        None,
        AaveRefused,
        IntentRejected,
        IntentTooSmall,
        InsufficientHeadroom,
        TailUnfunded,
        Returned,
        Cancelled,
        FeeBudgetLow
    }

    /// @dev Chosen by the user at `open`. `aCollateral`/`variableDebt` must match Aave's reserve data and
    /// each asset id its token. Forward fees are paid from a separate `feeAsset` balance; a rung submits only
    /// while that balance is at least `feeReserve`. Hf and `leverage` are WAD.
    struct Params {
        address collateral;
        address aCollateral;
        address debt;
        address variableDebt;
        address feeAsset;
        uint32 debtAssetId;
        uint32 aCollateralAssetId;
        uint32 feeAssetId;
        uint8 eMode;
        uint16 slippageBps;
        uint256 leverage;
        uint256 minHf;
        uint256 stepHf;
        uint256 feeReserve;
        uint256 minIntentDebt;
        uint256 minIntentAToken;
    }

    /// @dev `inSnap`/`outSnap`: debt-asset balance, or `scaledBalanceOf` for the aToken leg.
    struct PendingIntent {
        uint64 nonce;
        Kind kind;
        uint128 amountIn;
        uint128 minOut;
        uint128 reconcileOut;
        uint64 submittedAt;
        uint64 deadline;
        uint256 inSnap;
        uint256 outSnap;
    }

    event Deposited(uint256 amount);
    event RungSubmitted(Kind kind, uint64 nonce, uint256 amountIn, uint256 minOut);
    event RungFilled(Kind kind, uint64 nonce, uint256 amountOut);
    event RungReturned(Kind kind, uint64 nonce);
    event LadderCompleted(uint256 leverage);
    event LadderStopped(Stall reason, uint256 remainder);
    event WithdrawRequested(uint256 amount);
    event Withdrawn(uint256 requested, uint256 paid);
    event Closed();
    event Cancelled();

    error NotOwner();
    error NotFactory();
    error PositionAlreadyInitialized();
    error SlippageTooHigh();
    error InvalidParams();
    error Busy();
    error NothingToDo();
    error WrongIntent();
    error FeeCurrencyRejected();
    /// @dev Internal: a named stop raised inside a rung, caught and recorded as `stalled`.
    error Stalled(Stall reason, uint256 remainder);

    function factory() external view returns (address);
    function pool() external view returns (IAavePool);
    function owner() external view returns (address);
    function tokenId() external view returns (uint256);
    function params() external view returns (Params memory);
    function initialize(uint256 tokenId, Params calldata p) external;
    function deposit(uint256 amount) external;
    function step() external returns (Stall, uint256);
    function isClosed() external view returns (bool);
}
