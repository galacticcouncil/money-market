// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SubLoopLogic} from "../src/lib/SubLoopLogic.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {IsolationRulesPool} from "./mocks/IsolationRulesPool.sol";
import {SubLoopUnwindTest} from "./SubLoopUnwind.t.sol";
import {IceIntentsTest} from "./IceIntents.t.sol";

library AuditPr46Iso {
    function deploy(MockERC20 hollar, MockERC20 aHollar, MockERC20 hollarDebt, MockERC20 prime, MockERC20 aPrime,
        MockERC20 primeDebt) internal returns (IsolationRulesPool iso, MockERC20 dot)
    {
        iso = new IsolationRulesPool();
        iso.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        iso.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        iso.setIsolationMode(address(prime), true);
        dot = new MockERC20("DOT", "DOT", 10);
        iso.initReserve(address(dot), address(new MockERC20("aDOT", "aDOT", 10)),
            address(new MockERC20("dDOT", "dDOT", 10)), 6500, 5000, 10, 5e18);
    }

    function newLoop(address pool, address hollar, address prime, address aPrime, address admin)
        internal returns (SubLoop)
    {
        return SubLoop(address(new ERC1967Proxy(address(new SubLoop(address(new SubLoopLogic()))),
            abi.encodeCall(SubLoop.initialize, (pool, hollar, prime, aPrime, 1.05e18, 1.10e18, admin)))));
    }

    function dust(IsolationRulesPool iso, MockERC20 dot, address onBehalfOf) internal {
        dot.mint(address(this), 1e6);
        dot.approve(address(iso), 1e6);
        iso.supply(address(dot), 1e6, onBehalfOf, 0);
    }
}

contract AuditPr46ForeignCollateralRouterTest is SubLoopUnwindTest {
    IsolationRulesPool iso;
    MockERC20 dot;

    function _rewire() internal {
        (iso, dot) = AuditPr46Iso.deploy(hollar, aHollar, hollarDebt, prime, aPrime, primeDebt);
        pool = MockPool(address(iso));
        loop = AuditPr46Iso.newLoop(address(iso), address(hollar), address(prime), address(aPrime), address(this));
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(iso), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);
        loop.registerVault(address(this));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function test_pr46_clearedForeignFlagLetsTheLoopDeploy() public {
        _rewire();
        AuditPr46Iso.dust(iso, dot, address(loop));
        assertTrue(iso.usingAsCollateral(address(loop), address(dot)));
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        vm.expectRevert(bytes("62"));
        loop.deposit(SEED);

        vm.prank(address(0xBEEF));
        loop.clearCollateral(address(dot));
        assertFalse(iso.usingAsCollateral(address(loop), address(dot)));
        assertGt(loop.deposit(SEED), 0);
        assertTrue(iso.usingAsCollateral(address(loop), address(prime)));
    }

    function test_pr46_primeIsNeverCleared() public {
        vm.expectRevert(SubLoop.InvalidParameters.selector);
        loop.clearCollateral(address(prime));
    }
}

contract AuditPr46ForeignCollateralIntentTest is IceIntentsTest {
    IsolationRulesPool iso;
    MockERC20 dot;

    function _rewire() internal {
        (iso, dot) = AuditPr46Iso.deploy(hollar, aHollar, hollarDebt, prime, aPrime, primeDebt);
        pool = MockPool(address(iso));
        loop = AuditPr46Iso.newLoop(address(iso), address(hollar), address(prime), address(aPrime), address(this));
        dispatch.configure(address(iso), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);
        loop.registerVault(address(this));
        loop.grantRole(loop.KEEPER_ROLE(), address(this));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        loop.configureIntents(600, 5);
    }

    function test_pr46_clearedForeignFlagUnfreezesSettlementAndNavHolds() public {
        _rewire();
        _deposit(SEED);
        AuditPr46Iso.dust(iso, dot, address(loop));
        assertEq(loop.pokeBorrowQuoted(ENTRY_RATE), SEED);
        uint128 id = dispatch.lastId();
        uint256 out = dispatch.quote(id, 1);
        dispatch.fill(id, out);

        assertEq(loop.totalEquity(), out * 1e2 + 5e4, "the unflagged fill still counts beside the dust");
        vm.expectRevert(bytes("62"));
        loop.reconcile();

        loop.clearCollateral(address(dot));
        assertEq(loop.reconcile(), FILLED);
        assertTrue(iso.usingAsCollateral(address(loop), address(prime)));
        assertEq(loop.totalEquity(), out * 1e2, "flagged, the fill counts once");
        _rampSteps(5);
        assertApproxEqRel(loop.totalEquity(), 1_000e8, 0.01e18);
    }
}
