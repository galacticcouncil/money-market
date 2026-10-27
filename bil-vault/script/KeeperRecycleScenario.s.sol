// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DecentralPool} from "decentral-contracts/DecentralPool.sol";
import {PoolToken} from "decentral-contracts/PoolToken.sol";
import {DecentralFactory} from "decentral-contracts/DecentralFactory.sol";
import {BILVault} from "../src/BILVault.sol";
import {MockHollar} from "../test/mocks/MockHollar.sol";

/// @notice Local keeper e2e (anvil): a 250k deposit split three ways against
///         the real Decentral contracts, then a pool holding only 100k so the
///         keeper must recycle returned principal between payouts.
///         Driven by keeper/e2e-recycle.sh; the broadcaster is admin + depositor.
contract KeeperRecycleScenario is Script {
    function setup() external {
        vm.startBroadcast();
        address admin = msg.sender;
        MockHollar hollar = new MockHollar();
        PoolToken poolToken = PoolToken(address(new ERC1967Proxy(
            address(new PoolToken()),
            abi.encodeWithSelector(PoolToken.initialize.selector, "DecentralPool Token", "DPT", "", admin)
        )));
        DecentralFactory factory = DecentralFactory(address(new ERC1967Proxy(
            address(new DecentralFactory()),
            abi.encodeWithSelector(DecentralFactory.initialize.selector, address(poolToken), address(new DecentralPool()), admin)
        )));
        poolToken.grantRole(poolToken.ADMIN_ROLE(), address(factory));
        address pool = factory.createPool(address(hollar), 1800, 30, 60, 1, 1e18, 1_000_000e18);
        BILVault vault = BILVault(address(new ERC1967Proxy(
            address(new BILVault()),
            abi.encodeWithSelector(BILVault.initialize.selector, pool, address(poolToken), address(hollar), 1_000_000e18, admin)
        )));
        hollar.mint(admin, 250_000e18);
        hollar.mint(pool, 50_000e18); // yield funding
        hollar.approve(address(vault), 250_000e18);
        vault.deposit(250_000e18, admin);
        vm.stopBroadcast();

        console.log("VAULT", address(vault));
        console.log("POOL", pool);
        console.log("HOLLAR", address(hollar));
    }

    function approveYields(BILVault vault) external {
        vm.startBroadcast();
        for (uint256 i; i < vault.getPositionCount(); ++i) {
            (uint256 tokenId,,,,, uint8 state) = vault.getPosition(i);
            if (state == 1) DecentralPool(address(vault.positionPool(i))).approveYieldWithdrawal(tokenId);
        }
        vm.stopBroadcast();
    }

    /// @dev Approve every principal withdrawal and trim the pool to `liquidity`.
    function approvePrincipals(BILVault vault, MockHollar hollar, uint256 liquidity) external {
        vm.startBroadcast();
        address pool = address(vault.positionPool(0));
        for (uint256 i; i < vault.getPositionCount(); ++i) {
            (uint256 tokenId,,,,, uint8 state) = vault.getPosition(i);
            if (state == 3) DecentralPool(pool).approvePrincipalWithdrawal(tokenId);
        }
        hollar.burn(pool, hollar.balanceOf(pool) - liquidity);
        vm.stopBroadcast();
    }
}
