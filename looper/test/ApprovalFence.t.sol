// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// The account fence refuses every approval, so a seller cannot leave one behind that still works after the
// NFT sale. Built from the audit PoC (HDX precompile allowance honoured by HOLLAR, child NFT approvals).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC4337} from "solady/accounts/ERC4337.sol";
import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";
import {LooperPosition} from "../src/LooperPosition.sol";

contract ApprovalFenceTest is Fixture {
    address internal constant HDX_PRECOMPILE = 0x0000000000000000000000000000000100000000;
    uint32 internal constant DOT_ID = 5;

    function notAllowed(bytes memory call) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(LooperPosition.SelectorNotAllowed.selector, bytes4(call));
    }

    /// @dev DOT pays the fees, so the HDX precompile is not one of the fenced targets.
    function openDotFee() internal returns (LooperPosition pos) {
        pallet.register(DOT_ID, address(dot), false, 0.01e10);
        etchPrecompile(DOT_ID, address(dot));
        dot.mint(alice, 1_000e10);
        vm.prank(alice);
        dot.approve(address(factory), type(uint256).max);
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.feeAsset = address(dot);
        p.feeAssetId = DOT_ID;
        p.feeReserve = 0.05e10;
        vm.prank(alice);
        (, address a) = factory.open(p, DEPOSIT, 10e10);
        pos = LooperPosition(payable(a));
    }

    function test_execute_should_refuse_an_approve_on_the_hdx_precompile_when_dot_pays_the_fees() public {
        LooperPosition pos = openDotFee();
        bytes memory call = abi.encodeCall(IERC20.approve, (alice, type(uint128).max));
        vm.prank(alice);
        vm.expectRevert(notAllowed(call));
        pos.execute(HDX_PRECOMPILE, 0, call);
    }

    function test_execute_should_refuse_set_approval_for_all_on_the_factory() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        bytes memory call = abi.encodeCall(IERC721.setApprovalForAll, (alice, true));
        vm.prank(alice);
        vm.expectRevert(notAllowed(call));
        pos.execute(address(factory), 0, call);
    }

    function test_execute_should_refuse_increase_allowance_and_permit_on_a_gift_token() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        bytes memory increase = abi.encodeWithSignature("increaseAllowance(address,uint256)", alice, 1);
        bytes memory permit = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(pos),
            alice,
            1,
            block.timestamp,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        vm.startPrank(alice);
        vm.expectRevert(notAllowed(increase));
        pos.execute(address(dot), 0, increase);
        vm.expectRevert(notAllowed(permit));
        pos.execute(address(dot), 0, permit);
        vm.stopPrank();
    }

    function test_execute_batch_should_refuse_the_batch_when_one_call_approves() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        dot.mint(address(pos), 100e10);
        ERC4337.Call[] memory calls = new ERC4337.Call[](2);
        calls[0] = ERC4337.Call(address(dot), 0, abi.encodeCall(IERC20.transfer, (alice, 1e10)));
        calls[1] = ERC4337.Call(address(dot), 0, abi.encodeCall(IERC20.approve, (alice, 1e10)));
        vm.prank(alice);
        vm.expectRevert(notAllowed(calls[1].data));
        pos.executeBatch(calls);
        assertEq(dot.balanceOf(address(pos)), 100e10, "nothing moved");
    }

    function test_execute_should_still_move_a_gift_out_with_a_plain_transfer() public {
        LooperPosition pos = open(alice, DEPOSIT, 3e18);
        dot.mint(address(pos), 100e10);
        vm.prank(alice);
        pos.execute(address(dot), 0, abi.encodeCall(IERC20.transfer, (alice, 100e10)));
        assertEq(dot.balanceOf(alice), 100e10);
    }
}
