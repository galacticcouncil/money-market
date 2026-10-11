// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {VariableDebtToken} from "@aave/core-v3/contracts/protocol/tokenization/VariableDebtToken.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IAaveIncentivesController} from "@aave/core-v3/contracts/interfaces/IAaveIncentivesController.sol";

contract LeanScaledDebtTest is Test {
    VariableDebtToken debt;
    uint256 public index = 1e27;
    string constant TRACE = "formal/.stateful/scaled-debt.jsonl";

    function ADDRESSES_PROVIDER() external pure returns (IPoolAddressesProvider) {
        return IPoolAddressesProvider(address(0));
    }

    function getReserveNormalizedVariableDebt(address) external view returns (uint256) { return index; }

    function _actor(uint256 i) internal pure returns (address) { return address(uint160(0x1000 + i)); }

    function _record(uint256 op, uint256 actor, uint256 amount, bool ok) internal {
        uint256[] memory action = new uint256[](3);
        action[0] = op; action[1] = actor; action[2] = amount;
        uint256[] memory state = new uint256[](15);
        state[0] = index;
        state[1] = debt.scaledTotalSupply();
        state[2] = debt.totalSupply();
        for (uint256 i; i < 4; ++i) {
            state[3 + i] = debt.scaledBalanceOf(_actor(i));
            state[7 + i] = debt.balanceOf(_actor(i));
            state[11 + i] = debt.getPreviousIndex(_actor(i));
        }
        vm.serializeUint("scaled", "action", action);
        vm.serializeBool("scaled", "ok", ok);
        vm.writeLine(TRACE, vm.serializeUint("scaled", "state", state));
    }

    function _step(uint256 op, uint256 actor, uint256 amount) internal returns (bool ok) {
        if (op == 2) {
            require(amount >= index && amount < 2 ** 128);
            index = amount;
            ok = true;
        } else if (op == 0) {
            (ok,) = address(debt).call(abi.encodeCall(debt.mint, (_actor(actor), _actor(actor), amount, index)));
        } else {
            (ok,) = address(debt).call(abi.encodeCall(debt.burn, (_actor(actor), amount, index)));
        }
        _record(op, actor, amount, ok);
    }

    function test_scaledDebtHistories() public {
        debt = new VariableDebtToken(IPool(address(this)));
        debt.initialize(IPool(address(this)), address(0x222), IAaveIncentivesController(address(0)),
            18, "variable debt", "vd", "");
        vm.writeFile(TRACE, "");
        _record(999, 0, 0, true);
        uint256 reverts;
        for (uint256 i; i < 512; ++i) {
            uint256 actor = (i * 7 + i / 5) % 4;
            uint256 op = i % 8 == 0 ? 2 : i % 3 == 0 ? 1 : 0;
            uint256 amount = op == 2 ? index + index / 53 + i :
                i % 17 == 0 ? 0 : i % 19 == 0 ? 1 : uint256(keccak256(abi.encode(i))) % 1e21;
            if (op == 1 && i % 9 == 0) amount = debt.balanceOf(_actor(actor));
            if (!_step(op, actor, amount)) ++reverts;
        }
        for (uint256 i; i < 4; ++i) {
            assertTrue(_step(1, i, debt.balanceOf(_actor(i))));
            assertEq(debt.scaledBalanceOf(_actor(i)), 0);
        }
        assertGt(reverts, 20);
        assertEq(debt.totalSupply(), 0);
        _record(998, 0, 516, true);
    }
}
