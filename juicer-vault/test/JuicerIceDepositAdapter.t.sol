// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JuicerIceDepositAdapter} from "../src/JuicerIceDepositAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Juicer ETH", "jETH") ERC4626(asset_) {}
}

/// @notice The lazy executor's forward: it moves `amountOut` to the adapter, then calls `execute`
///         as the intent owner. Tests replay that by minting to the adapter and pranking the owner.
contract JuicerIceDepositAdapterTest is Test {
    JuicerIceDepositAdapter adapter;
    MockERC20 weth;
    MockERC20 usdt;
    MockVault vault;
    address user = makeAddr("user");

    function setUp() public {
        adapter = new JuicerIceDepositAdapter();
        weth = new MockERC20("WETH", "WETH", 18);
        usdt = new MockERC20("USDT", "USDT", 6);
        vault = new MockVault(IERC20(address(weth)));
    }

    /// @dev Calls `execute` as the owner; tests fund the adapter first, as the executor would.
    function _forward(MockERC20 assetOut, uint256 amountOut, uint256 minShares) internal returns (bytes4) {
        vm.prank(user);
        return adapter.execute(
            user, 42, address(usdt), 3_000e6, address(assetOut), amountOut, abi.encode(address(vault), minShares)
        );
    }

    function test_depositsForUserAndReturnsSelector() public {
        uint256 expected = vault.previewDeposit(1 ether);
        weth.mint(address(adapter), 1 ether);

        vm.expectEmit(address(adapter));
        emit JuicerIceDepositAdapter.IceDeposit(user, 42, address(vault), address(usdt), 3_000e6, 1 ether, expected);
        bytes4 ret = _forward(weth, 1 ether, expected);

        assertEq(ret, JuicerIceDepositAdapter.execute.selector);
        assertEq(vault.balanceOf(user), expected);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        // holds nothing between forwards
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(vault.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(vault)), 0);
    }

    function test_revertsOnAssetMismatch() public {
        usdt.mint(address(adapter), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(JuicerIceDepositAdapter.AssetMismatch.selector, address(weth), address(usdt))
        );
        _forward(usdt, 1e6, 0);
    }

    function test_revertsBelowMinShares() public {
        uint256 expected = vault.previewDeposit(1 ether);
        weth.mint(address(adapter), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(JuicerIceDepositAdapter.Slippage.selector, expected, expected + 1));
        _forward(weth, 1 ether, expected + 1);
    }

    function test_revertsWhenFundsNotForwarded() public {
        vm.expectRevert();
        _forward(weth, 1 ether, 0);
    }

    function testFuzz_sharesGoToUser(uint96 amountOut) public {
        vm.assume(amountOut > 0);
        weth.mint(address(this), 5 ether);
        weth.approve(address(vault), 5 ether);
        vault.deposit(5 ether, address(this)); // non-empty vault
        uint256 expected = vault.previewDeposit(amountOut);
        weth.mint(address(adapter), amountOut);
        _forward(weth, amountOut, expected);
        assertEq(vault.balanceOf(user), expected);
        assertEq(weth.balanceOf(address(adapter)), 0);
    }
}
