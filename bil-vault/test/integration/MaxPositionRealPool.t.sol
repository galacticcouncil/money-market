// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RealDecentralPoolTest} from "./RealDecentralPool.t.sol";
import {BILVault} from "../../src/BILVault.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {DecentralPool} from "decentral-contracts/DecentralPool.sol";

/// @notice MAX_POSITION split against the real Decentral contracts: bounded
///         reinvest gas, and recycling returned principal between payouts.
contract MaxPositionRealPoolTest is RealDecentralPoolTest {
    uint256 internal constant MAX_REINVEST = 500_000e18;
    uint256 internal constant OLD_KEEPER_GAS = 5_000_000;

    /// @dev Deposit `principal` (split by the vault), mature it and approve every
    ///      piece's yield + principal withdrawal, leaving payouts ready to execute.
    function _readyPrincipal(uint256 principal) internal returns (uint256 count) {
        vm.prank(ADMIN);
        vault.setTvlCap(principal);
        hollar.mint(USER, principal);
        vm.startPrank(USER);
        hollar.approve(address(vault), principal);
        vault.deposit(principal, USER);
        vm.stopPrank();
        hollar.mint(address(pool), principal / 10); // yield funding
        count = vault.getPositionCount();
        vm.warp(block.timestamp + 60 days + 1);
        for (uint256 i; i < count; ++i) {
            (uint256 tokenId,,,,,) = vault.getPosition(i);
            vault.pokeDecentral(i);
            vm.prank(ADMIN);
            pool.approveYieldWithdrawal(tokenId);
            vault.pokeDecentral(i);
            vm.prank(ADMIN);
            pool.approvePrincipalWithdrawal(tokenId);
        }
        vm.warp(block.timestamp + 1 hours + 1);
    }

    /// @dev Everything paid back into idle, nothing invested.
    function _idlePrincipal(uint256 principal) internal {
        uint256 count = _readyPrincipal(principal);
        for (uint256 i; i < count; ++i) vault.pokeDecentral(i);
        assertGt(vault.idleHollar(), principal);
        assertEq(vault.totalInvestedPrincipal(), 0);
    }

    function _coolAll() internal {
        vm.cool(address(vault));
        vm.cool(address(pool));
        vm.cool(address(poolToken));
        vm.cool(address(hollar));
    }

    function _poke(uint256 gasLimit) internal returns (bool ok) {
        _coolAll();
        (ok,) = address(vault).call{gas: gasLimit}(abi.encodeCall(BILVault.pokeQueue, ()));
    }

    function _redeemed(uint256 count) internal view returns (uint256 n) {
        for (uint256 i; i < count; ++i) {
            (,,,,, uint8 state) = vault.getPosition(i);
            if (state == 4) ++n;
        }
    }

    function test_reinvestIsBoundedPerPoke() public {
        _idlePrincipal(2_000_000e18);
        uint256 before = vault.getPositionCount();

        assertTrue(_poke(OLD_KEEPER_GAS), "one poke fits the old 5M keeper gas");
        assertEq(vault.totalInvestedPrincipal(), MAX_REINVEST, "at most 5 pieces per poke");
        assertEq(vault.getPositionCount() - before, 5);

        // the remainder drains over later pokes, never needing more gas
        for (uint256 i; i < 3; ++i) assertTrue(_poke(OLD_KEEPER_GAS));
        assertEq(vault.totalInvestedPrincipal(), 2_000_000e18, "tvl cap reached after four pokes");
    }

    function test_minimumAboveBatchCapStillReinvests() public {
        _idlePrincipal(2_000_000e18); // tvl cap 2M
        vm.prank(ADMIN);
        vault.setMinReinvestAmount(600_000e18);

        // the trigger sees the full 2M room; each poke moves one 500k batch
        for (uint256 i = 1; i <= 3; ++i) {
            assertTrue(_poke(OLD_KEEPER_GAS));
            assertEq(vault.totalInvestedPrincipal(), i * MAX_REINVEST);
        }
        // 500k of room left is under the 600k trigger: nothing more, by configuration
        assertTrue(_poke(OLD_KEEPER_GAS));
        assertEq(vault.totalInvestedPrincipal(), 3 * MAX_REINVEST);
    }

    function test_reinvestIntoFreshPoolMakesProgress() public {
        _idlePrincipal(5_000_000e18);
        vm.startPrank(ADMIN);
        pool = DecentralPool(factory.createPool(address(hollar), 1800, 30, 60, 1, 1e18, 1_000_000e18));
        vault.registerPool(IDecentralPool(address(pool)));
        vault.setActiveDepositPool(IDecentralPool(address(pool)));
        vm.stopPrank();

        assertTrue(_poke(15_000_000), "fresh pool, cold storage, 15M gas");
        assertEq(vault.totalInvestedPrincipal(), MAX_REINVEST);
    }

    function test_returnedPrincipalRecyclesBetweenPayouts() public {
        uint256 count = _readyPrincipal(250_000e18);
        assertEq(count, 3);
        // Decentral can stage only one capped payout at a time
        hollar.burn(address(pool), hollar.balanceOf(address(pool)) - 100_000e18);

        // keeper ordering after the fix: queue/reinvest right after each payout
        for (uint256 i; i < count; ++i) {
            vault.pokeDecentral(i);
            vault.pokeQueue();
        }
        assertEq(_redeemed(count), count, "every piece paid out from a 100k buffer");
        assertEq(vault.totalInvestedPrincipal(), 250_000e18, "principal is back in Decentral");
    }

    function test_withoutInterleavingOnlyOnePayoutFits() public {
        uint256 count = _readyPrincipal(250_000e18);
        hollar.burn(address(pool), hollar.balanceOf(address(pool)) - 100_000e18);

        // all payouts first, queue last: the buffer is spent after the first piece
        for (uint256 i; i < count; ++i) vault.pokeDecentral(i);
        assertEq(_redeemed(count), 1, "documents why the keeper must interleave");
    }
}
