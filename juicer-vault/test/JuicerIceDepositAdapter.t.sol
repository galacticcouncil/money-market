// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JuicerIceDepositAdapter} from "../src/JuicerIceDepositAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Juicer ETH", "jETH") ERC4626(asset_) {}
}

contract PartialDepositVault is MockVault {
    constructor(IERC20 asset_) MockVault(asset_) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return super.deposit(assets / 2, receiver);
    }
}

contract NoDepositVault is MockVault {
    constructor(IERC20 asset_) MockVault(asset_) {}

    function deposit(uint256 assets, address) public pure override returns (uint256) {
        return assets;
    }
}

contract ReentrantDepositVault is MockVault {
    constructor(IERC20 asset_) MockVault(asset_) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        JuicerIceDepositAdapter(msg.sender)
            .execute(address(this), 99, address(0), 0, asset(), assets, abi.encode(address(this), 0));
        return super.deposit(assets, receiver);
    }
}

contract StickyApprovalToken is MockERC20 {
    constructor() MockERC20("sticky", "STICKY", 18) {}

    function _spendAllowance(address owner, address spender, uint256 amount) internal view override {
        require(allowance(owner, spender) >= amount, "insufficient allowance");
    }
}

contract IceForwarder {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // one external frame models the runtime's transfer + callback rollback scope.
    function forward(
        JuicerIceDepositAdapter adapter,
        address owner,
        uint256 intentId,
        IERC20 token,
        uint256 amount,
        address vault,
        uint256 minShares
    ) external returns (bytes4) {
        require(token.transferFrom(owner, address(adapter), amount), "transfer failed");
        vm.prank(owner);
        bytes4 ack =
            adapter.execute(owner, intentId, address(0), 0, address(token), amount, abi.encode(vault, minShares));
        require(ack == JuicerIceDepositAdapter.execute.selector, "bad ack");
        return ack;
    }
}

contract JuicerIceDepositAdapterTest is Test {
    JuicerIceDepositAdapter adapter;
    IceForwarder forwarder;
    MockERC20 weth;
    MockERC20 usdt;
    MockVault vault;
    MockVault secondVault;
    address user = makeAddr("user");
    address otherUser = makeAddr("other user");

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
        usdt = new MockERC20("USDT", "USDT", 6);
        vault = new MockVault(IERC20(address(weth)));
        secondVault = new MockVault(IERC20(address(weth)));
        adapter = new JuicerIceDepositAdapter();
        forwarder = new IceForwarder();
    }

    function _fund(MockERC20 token, address owner, uint256 amount) internal {
        token.mint(owner, amount);
        vm.prank(owner);
        token.approve(address(forwarder), amount);
    }

    function _forward(MockERC20 token, uint256 amountOut, uint256 minShares) internal returns (bytes4) {
        return forwarder.forward(adapter, user, 42, token, amountOut, address(vault), minShares);
    }

    function test_depositsForUserAndReturnsSelector() public {
        uint256 expected = vault.previewDeposit(1 ether);
        _fund(weth, user, 1 ether);

        vm.expectEmit(address(adapter));
        emit JuicerIceDepositAdapter.IceDeposit(user, 42, address(vault), address(0), 0, 1 ether, expected);
        bytes4 ret = _forward(weth, 1 ether, expected);

        assertEq(ret, JuicerIceDepositAdapter.execute.selector);
        assertEq(vault.balanceOf(user), expected);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(vault.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(vault)), 0);
    }

    function test_revertsOnAssetMismatchAndRestoresOutput() public {
        _fund(usdt, user, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(JuicerIceDepositAdapter.AssetMismatch.selector, address(weth), address(usdt))
        );
        _forward(usdt, 1e6, 0);
        assertEq(usdt.balanceOf(user), 1e6);
        assertEq(usdt.balanceOf(address(adapter)), 0);
    }

    function test_slippageRevertsTransferApprovalAndDeposit() public {
        uint256 expected = vault.previewDeposit(1 ether);
        _fund(weth, user, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(JuicerIceDepositAdapter.Slippage.selector, expected, expected + 1));
        _forward(weth, 1 ether, expected + 1);

        assertEq(weth.balanceOf(user), 1 ether);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(user), 0);
        assertEq(weth.allowance(address(adapter), address(vault)), 0);
    }

    function test_fakeVaultCannotPlantAnUnfundedApproval() public {
        NoDepositVault fake = new NoDepositVault(weth);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(JuicerIceDepositAdapter.InsufficientBalance.selector, 0, 1 ether));
        adapter.execute(user, 42, address(0), 0, address(weth), 1 ether, abi.encode(address(fake), 0));
        assertEq(weth.allowance(address(adapter), address(fake)), 0);
    }

    function test_fakeVaultCannotAcknowledgeWithoutConsumingOutput() public {
        NoDepositVault fake = new NoDepositVault(weth);
        _fund(weth, user, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(JuicerIceDepositAdapter.BalanceMismatch.selector, 0, 1 ether));
        forwarder.forward(adapter, user, 42, weth, 1 ether, address(fake), 0);

        assertEq(weth.balanceOf(user), 1 ether);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(fake)), 0);
    }

    function test_revertsWhenCallerDoesNotMatchReceiver() public {
        weth.mint(address(adapter), 1 ether);
        vm.prank(otherUser);
        vm.expectRevert(abi.encodeWithSelector(JuicerIceDepositAdapter.CallerMismatch.selector, otherUser, user));
        adapter.execute(user, 42, address(0), 0, address(weth), 1 ether, abi.encode(address(vault), 0));
        assertEq(weth.balanceOf(address(adapter)), 1 ether);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(JuicerIceDepositAdapter.ZeroAmount.selector);
        adapter.execute(user, 42, address(0), 0, address(weth), 0, abi.encode(address(vault), 0));
    }

    function test_intentsKeepSeparateOwnersAmountsAndVaults() public {
        _fund(weth, user, 1 ether);
        _fund(weth, otherUser, 2 ether);
        forwarder.forward(adapter, otherUser, 43, weth, 2 ether, address(secondVault), 2 ether);
        _forward(weth, 1 ether, 1 ether);

        assertEq(vault.balanceOf(user), 1 ether);
        assertEq(vault.balanceOf(otherUser), 0);
        assertEq(secondVault.balanceOf(otherUser), 2 ether);
        assertEq(secondVault.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(vault)), 0);
        assertEq(weth.allowance(address(adapter), address(secondVault)), 0);
    }

    function test_sameVaultSupportsMultipleOwners() public {
        _fund(weth, user, 1 ether);
        _fund(weth, otherUser, 2 ether);
        _forward(weth, 1 ether, 1 ether);
        forwarder.forward(adapter, otherUser, 43, weth, 2 ether, address(vault), 2 ether);

        assertEq(vault.balanceOf(user), 1 ether);
        assertEq(vault.balanceOf(otherUser), 2 ether);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(vault)), 0);
    }

    function test_depositsOnlyCurrentOutputDespiteUnsolicitedTokens() public {
        weth.mint(address(adapter), 0.5 ether);
        _fund(weth, user, 1 ether);
        _forward(weth, 1 ether, 1 ether);

        assertEq(vault.balanceOf(user), 1 ether);
        assertEq(weth.balanceOf(address(adapter)), 0.5 ether);
    }

    function test_partialConsumptionRevertsTheWholeForward() public {
        PartialDepositVault partialVault = new PartialDepositVault(weth);
        _fund(weth, user, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(JuicerIceDepositAdapter.BalanceMismatch.selector, 0, 0.5 ether));
        forwarder.forward(adapter, user, 42, weth, 1 ether, address(partialVault), 0);

        assertEq(weth.balanceOf(user), 1 ether);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(partialVault)), 0);
        assertEq(partialVault.balanceOf(user), 0);
        assertEq(weth.allowance(address(adapter), address(partialVault)), 0);
    }

    function test_reentrancyCannotRedirectAnActiveDeposit() public {
        ReentrantDepositVault reentrant = new ReentrantDepositVault(weth);
        _fund(weth, user, 1 ether);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        forwarder.forward(adapter, user, 42, weth, 1 ether, address(reentrant), 0);

        assertEq(weth.balanceOf(user), 1 ether);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(reentrant)), 0);
    }

    function test_clearsApprovalEvenWhenTransferFromDoesNot() public {
        StickyApprovalToken token = new StickyApprovalToken();
        MockVault target = new MockVault(token);
        _fund(token, user, 1 ether);
        forwarder.forward(adapter, user, 42, token, 1 ether, address(target), 1 ether);

        assertEq(target.balanceOf(user), 1 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.allowance(address(adapter), address(target)), 0);
    }

    function testFuzz_sharesGoToUser(uint96 amountOut) public {
        vm.assume(amountOut > 0);
        weth.mint(address(this), 5 ether);
        weth.approve(address(vault), 5 ether);
        vault.deposit(5 ether, address(this));
        uint256 expected = vault.previewDeposit(amountOut);
        _fund(weth, user, amountOut);
        _forward(weth, amountOut, expected);
        assertEq(vault.balanceOf(user), expected);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(weth.allowance(address(adapter), address(vault)), 0);
    }
}
