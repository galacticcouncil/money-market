// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HarvestTest} from "./Harvest.t.sol";

/// @notice EVM mock benchmark, not native-chain throughput evidence.
contract YieldCheckpointGasTest is HarvestTest {
    function _coldTransfer(address receiver) private returns (uint256 gasUsed) {
        address rewards = address(vault.yieldAccounting());
        address ledger = address(vault.mainDebt());
        vm.cool(address(vault));
        vm.cool(rewards);
        vm.cool(ledger);
        vm.cool(address(loop));
        vm.cool(address(pool));
        vm.cool(address(aPrime));
        vm.cool(address(hollarDebt));
        vm.cool(address(fees));
        uint256 before_ = gasleft();
        vault.transfer(receiver, 1e14);
        return before_ - gasleft();
    }

    function test_checkpointGasDoesNotGrowWithHolderCount() public {
        _depositAndRamp();
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) / 20);
        address receiver = address(0xB0B);
        vault.transfer(receiver, 1e14);
        uint256 snapshot = vm.snapshotState();
        aPrime.mint(address(loop), 1e6);
        uint256 few = _coldTransfer(receiver);
        vm.revertToStateAndDelete(snapshot);
        for (uint256 i; i < 100; ++i) vault.transfer(address(uint160(0x10000 + i)), 1e14);
        aPrime.mint(address(loop), 1e6);
        uint256 many = _coldTransfer(receiver);
        emit log_named_uint("checkpoint transfer, two holders", few);
        emit log_named_uint("checkpoint transfer, 102 holders", many);
        assertLe(many, few + 25_000, "checkpoint must not scan historical holders");
    }
}
