// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMainDebtVault} from "../PropellerMainDebt.sol";
import {IMainDebt} from "../interfaces/IMainDebt.sol";
import {IPropellerFeeController} from "../interfaces/IPropellerFeeController.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {ISyntheticToken} from "../interfaces/ISyntheticToken.sol";

interface ICompoundVault is IMainDebtVault {
    function feeController() external view returns (IPropellerFeeController);
    function mainDebt() external view returns (IMainDebt);
    function synthetic() external view returns (ISyntheticToken);
    function syntheticSupplied() external view returns (uint256);
}

/// @dev Stateless delegatecall implementation, deployed immutably with the vault
/// implementation. The vault supplies the reentrancy and pause guards. No storage
/// layouts, configurable delegate targets, or token approvals survive the call.
contract CompoundLogic {
    using SafeERC20 for IERC20;
    error ZeroAmount();
    error ZeroAddress();
    error PrincipalShortfall();
    event Harvested(uint256 collateralAmount);

    function repay(uint256 key, uint256 amount, uint256 recovery)
        external returns (uint256 principalPaid, uint256 burn, uint256 paid)
    {
        ICompoundVault v = ICompoundVault(address(this));
        uint256 debt = v.hollarDebtToken().balanceOf(address(this));
        IERC20 hollar = v.hollar();
        IMainDebt buffer = v.mainDebt();
        hollar.forceApprove(address(buffer), recovery);
        (, principalPaid, paid) = buffer.repay(key, amount, recovery);
        hollar.forceApprove(address(buffer), 0);
        burn = debt == 0 ? 0 : v.syntheticSupplied() * paid / debt;
        if (burn != 0) {
            ISyntheticToken synthetic = v.synthetic();
            v.pool().withdraw(address(synthetic), burn, address(this));
            synthetic.burn(address(this), burn);
        }
    }

    function compound(address tokenIn, uint256 amountIn, uint256 minimum, bytes calldata route) external {
        if (amountIn == 0) revert ZeroAmount();
        ICompoundVault v = ICompoundVault(address(this));
        IPropellerFeeController controller = v.feeController();
        IMainDebt buffer = v.mainDebt();
        if (address(controller) == address(0) || address(buffer) == address(0)) revert ZeroAddress();
        IERC20 collateral = v.collateral();
        ISwapper swapper = v.swapper();
        IAavePool pool = v.pool();
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 inputBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore + amountIn) revert PrincipalShortfall();
        uint256 floor = controller.quoteCollateral(address(this), tokenIn, amountIn)
            * (10_000 - v.compoundSlippageBps()) / 10_000;
        if (minimum < floor) minimum = floor;
        if (tokenIn != address(collateral)) {
            IERC20(tokenIn).forceApprove(address(swapper), amountIn);
            swapper.sell(tokenIn, address(collateral), amountIn, minimum, route);
            IERC20(tokenIn).forceApprove(address(swapper), 0);
            if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore) revert PrincipalShortfall();
        }
        uint256 out = collateral.balanceOf(address(this)) - collateralBefore;
        if (out == 0 || out < minimum) revert PrincipalShortfall();
        collateral.forceApprove(address(controller), out);
        out -= controller.collectFee(out, msg.sender);
        collateral.forceApprove(address(controller), 0);
        collateral.forceApprove(address(buffer), out);
        out = buffer.harvest(out);
        collateral.forceApprove(address(buffer), 0);
        if (out != 0) {
            collateral.forceApprove(address(pool), out);
            pool.supply(address(collateral), out, address(this), 0);
            collateral.forceApprove(address(pool), 0);
        }
        if (collateral.balanceOf(address(this)) != collateralBefore) revert PrincipalShortfall();
        emit Harvested(out);
    }
}
