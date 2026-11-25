// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// The fee asset cannot be a leg reached through its precompile address. Built from the audit PoC, where a HOLLAR
// fee budget was repaid as debt and every exit stalled FeeBudgetLow.

import {Fixture} from "./helpers/Fixture.t.sol";
import {ILooperFactory} from "../src/interfaces/ILooperFactory.sol";
import {ILooperPosition} from "../src/interfaces/ILooperPosition.sol";

contract FeeAssetAliasTest is Fixture {
    function precompile(uint32 id) internal pure returns (address) {
        return address(uint160((uint256(1) << 32) | id));
    }

    function expectOpenRevert(ILooperPosition.Params memory p) internal {
        vm.prank(alice);
        vm.expectRevert(ILooperFactory.InvalidParams.selector);
        factory.open(p, DEPOSIT, 0);
    }

    function test_open_should_revert_invalid_params_when_the_fee_asset_is_the_debt_precompile() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.feeAsset = precompile(HOLLAR_ID);
        p.feeAssetId = HOLLAR_ID;
        expectOpenRevert(p);
    }

    function test_open_should_revert_invalid_params_when_the_fee_asset_is_the_atoken_precompile() public {
        ILooperPosition.Params memory p = defaultParams(3e18);
        p.feeAsset = precompile(APRIME_ID);
        p.feeAssetId = APRIME_ID;
        expectOpenRevert(p);
    }
}
