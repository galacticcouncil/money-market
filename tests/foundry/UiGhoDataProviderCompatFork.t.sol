// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";

import {UiGhoDataProviderCompat, IGhoPool, IGhoToken} from "../../contracts/UiGhoDataProviderCompat.sol";
import {IUiGhoDataProvider} from "../../contracts/interfaces/IUiGhoDataProvider.sol";

contract UiGhoDataProviderCompatForkTest is Test {
    address internal constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address internal constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address internal constant BROKEN_PROVIDER = 0x5A31E4a57212eB5ad02a1b9fd736A1fDd9Caa05D;
    uint256 internal constant FIRST_BROKEN_BLOCK = 16_683_446;

    bool internal forkEnabled;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_HYDRATION", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FIRST_BROKEN_BLOCK);
        forkEnabled = true;
    }

    function testPostJuicerBlockRegression() public {
        if (!forkEnabled) return;

        (bool oldSuccess, bytes memory oldResult) =
            BROKEN_PROVIDER.staticcall(abi.encodeWithSelector(IUiGhoDataProvider.getGhoReserveData.selector));
        assertFalse(oldSuccess);
        assertEq(oldResult.length, 0);

        UiGhoDataProviderCompat replacement = new UiGhoDataProviderCompat(IGhoPool(POOL), IGhoToken(HOLLAR));
        IUiGhoDataProvider.GhoReserveData memory data = replacement.getGhoReserveData();

        assertGt(data.ghoBaseVariableBorrowRate, 0);
        assertGt(data.ghoCurrentBorrowIndex, 0);
        assertEq(data.ghoDiscountedPerToken, 0);
        assertEq(data.ghoDiscountRate, 0);
        assertEq(data.ghoMinDebtTokenBalanceForDiscount, 0);
        assertEq(data.ghoMinDiscountTokenBalanceForDiscount, 0);
    }
}
