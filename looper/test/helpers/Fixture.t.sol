// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {ILooperPosition} from "../../src/interfaces/ILooperPosition.sol";
import {LooperFactory} from "../../src/LooperFactory.sol";
import {LooperPosition} from "../../src/LooperPosition.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {MockIntentDispatch} from "../mocks/MockIntentDispatch.sol";
import {MockAssetPrecompile} from "../mocks/MockAssetPrecompile.sol";

/// @notice PRIME (6 dec, $2.50, LTV 75 %, LT 80 %) / HOLLAR (18 dec, $1) on a mock Aave pool, HDX (12 dec)
/// as the fee asset, the mock pallet etched at 0x0401, asset precompiles etched at `(1 << 32) | id`, a
/// factory, and drivers for fills and forwards.
abstract contract Fixture is Test {
    address internal constant DISPATCH = 0x0000000000000000000000000000000000000401;
    uint32 internal constant HOLLAR_ID = 222;
    uint32 internal constant APRIME_ID = 1043;
    uint32 internal constant ADOT_ID = 1001;
    uint32 internal constant HDX_ID = 0;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant FEE = 1e12;
    uint256 internal constant FEE_RESERVE = 5e12;
    uint256 internal constant FEE_BUDGET = 1_000e12;
    uint256 internal constant ED_HDX = 1e12;
    uint256 internal constant ED_HOLLAR = 0.01e18;
    uint256 internal constant ED_APRIME = 0.01e6;
    uint16 internal constant SLIP = 100;
    uint256 internal constant FILL_BPS = 50;
    uint256 internal constant GAS_LIMIT = 2_000_000;
    uint256 internal constant TTL_MS = 300_000;
    uint256 internal constant DEPOSIT = 1_000e6;

    MockERC20 internal prime;
    MockERC20 internal hollar;
    MockERC20 internal dot;
    MockERC20 internal hdx;
    MockPool internal pool;
    MockAToken internal aPrime;
    MockAToken internal aDot;
    MockERC20 internal vHollar;
    MockIntentDispatch internal pallet;
    LooperFactory internal factory;
    LooperPosition internal impl;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        prime = new MockERC20("PRIME", "PRIME", 6);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        dot = new MockERC20("DOT", "DOT", 10);
        hdx = new MockERC20("HDX", "HDX", 12);
        pool = new MockPool();
        (aPrime,) = pool.addReserve(address(prime), 6, 7_500, 8_000, 2.5e8);
        (, vHollar) = pool.addReserve(address(hollar), 18, 0, 0, 1e8);
        (aDot,) = pool.addReserve(address(dot), 10, 6_000, 7_000, 5e8);

        vm.etch(DISPATCH, address(new MockIntentDispatch()).code);
        pallet = MockIntentDispatch(DISPATCH);
        pallet.configure(address(pool), FEE);
        pallet.register(HOLLAR_ID, address(hollar), false, ED_HOLLAR);
        pallet.register(APRIME_ID, address(aPrime), true, ED_APRIME);
        pallet.register(ADOT_ID, address(aDot), true, 1e6);
        pallet.register(HDX_ID, address(hdx), false, ED_HDX);
        etchPrecompile(HOLLAR_ID, address(hollar));
        etchPrecompile(APRIME_ID, address(aPrime));
        etchPrecompile(HDX_ID, address(hdx));
        // live assets have supply; the asset-id check at `open` compares non-zero supplies
        hollar.mint(makeAddr("hollarHolder"), 1e18);
        giftAToken(prime, aPrime, makeAddr("aPrimeHolder"), 1e6);

        impl = new LooperPosition(IAavePool(address(pool)));
        factory = new LooperFactory(IAavePool(address(pool)), address(impl));

        for (uint256 i = 0; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            prime.mint(u, 1_000_000e6);
            hdx.mint(u, 1_000_000e12);
            vm.startPrank(u);
            prime.approve(address(factory), type(uint256).max);
            hdx.approve(address(factory), type(uint256).max);
            vm.stopPrank();
        }
    }

    function defaultParams(uint256 lev) internal view returns (ILooperPosition.Params memory p) {
        p.collateral = address(prime);
        p.aCollateral = address(aPrime);
        p.debt = address(hollar);
        p.variableDebt = address(vHollar);
        p.feeAsset = address(hdx);
        p.debtAssetId = HOLLAR_ID;
        p.aCollateralAssetId = APRIME_ID;
        p.feeAssetId = HDX_ID;
        p.slippageBps = SLIP;
        p.leverage = lev;
        p.minHf = 1.15e18;
        p.stepHf = 1.05e18;
        p.feeReserve = FEE_RESERVE;
        p.minIntentDebt = 2 * ED_HOLLAR;
        p.minIntentAToken = 2 * ED_APRIME;
    }

    // ── positions ──

    function open(address user, uint256 amount, uint256 lev) internal returns (LooperPosition pos) {
        return openWith(user, amount, defaultParams(lev));
    }

    function openWith(address user, uint256 amount, ILooperPosition.Params memory p)
        internal
        returns (LooperPosition pos)
    {
        vm.prank(user);
        (, address a) = factory.open(p, amount, FEE_BUDGET);
        pos = LooperPosition(a);
    }

    function topUp(address user, LooperPosition pos, uint256 amount) internal {
        uint256 id = pos.tokenId();
        vm.prank(user);
        factory.deposit(id, amount);
    }

    function setFeeReserve(LooperPosition pos, uint256 amount) internal {
        vm.prank(pos.owner());
        pos.setFeeReserve(amount);
    }

    function etchPrecompile(uint32 id, address token) internal {
        vm.etch(address(uint160((uint256(1) << 32) | id)), address(new MockAssetPrecompile(IERC20(token))).code);
    }

    /// @dev Intent floors are fixed at open; tests that move one mid-life write the position's slot
    /// (`LooperLogic.State` slot 10 `minIntentDebt`, slot 11 `minIntentAToken`).
    function pokeMinIntentDebt(LooperPosition pos, uint256 v) internal {
        vm.store(address(pos), bytes32(uint256(10)), bytes32(v));
        assertEq(pos.params().minIntentDebt, v, "slot layout");
    }

    function pokeMinIntentAToken(LooperPosition pos, uint256 v) internal {
        vm.store(address(pos), bytes32(uint256(11)), bytes32(v));
        assertEq(pos.params().minIntentAToken, v, "slot layout");
    }

    function pend(LooperPosition pos) internal view returns (ILooperPosition.PendingIntent memory) {
        return pos.pending();
    }

    function hasPending(LooperPosition pos) internal view returns (bool) {
        return pos.pending().kind != ILooperPosition.Kind.None;
    }

    // ── pallet drivers ──

    function liveId() internal view returns (uint128) {
        return pallet.lastId();
    }

    function fillOnly(uint256 bps) internal returns (uint128 id, uint256 out) {
        id = pallet.lastId();
        out = pallet.quote(id, bps);
        pallet.fill(id, out);
    }

    /// @dev the lazy executor's `dispatch_top`: calls as the owner with the fixed gas limit
    function dispatchTop() internal returns (bool ok, bytes memory ret) {
        MockIntentDispatch.Forward memory f = pallet.popTop();
        bytes memory data = abi.encodeCall(
            LooperPosition.execute,
            (f.owner, uint256(f.id), pallet.token(f.assetIn), f.amountIn, pallet.token(f.assetOut), f.amountOut, f.data)
        );
        vm.prank(f.owner, f.owner);
        (ok, ret) = f.contract_.call{gas: GAS_LIMIT}(data);
    }

    function fill(uint256 bps) internal returns (uint256 out) {
        (, out) = fillOnly(bps);
        (bool ok, bytes memory ret) = dispatchTop();
        assertTrue(ok, "callback reverted");
        assertEq(bytes4(ret), LooperPosition.execute.selector, "ack");
    }

    function fillId(uint128 id, uint256 bps) internal returns (uint256 out) {
        out = pallet.quote(id, bps);
        pallet.fill(id, out);
    }

    /// @dev the forward is consumed without its callback running (reverted or dropped)
    function dropForward() internal {
        pallet.popTop();
    }

    function giftAToken(MockERC20 asset, MockAToken aToken, address to, uint256 amount) internal {
        address donor = makeAddr("donor");
        asset.mint(donor, amount);
        vm.startPrank(donor);
        asset.approve(address(pool), amount);
        pool.supply(address(asset), amount, donor, 0);
        vm.stopPrank();
        aToken.move(donor, to, amount);
    }

    function drive(LooperPosition pos, uint256 maxRungs) internal returns (uint256 rungs) {
        while (hasPending(pos) && rungs < maxRungs) {
            fill(FILL_BPS);
            ++rungs;
        }
    }

    function ramp(LooperPosition pos) internal returns (uint256) {
        return drive(pos, 80);
    }

    function warpPastDeadline(LooperPosition pos) internal {
        vm.warp(pend(pos).deadline / 1000 + 1);
    }

    // ── assertions ──

    /// @dev the pallet's intent set and the position's record describe the same thing
    function assertLane(LooperPosition pos) internal view {
        assertEq(pallet.liveCount(address(pos)), hasPending(pos) ? 1 : 0, "pallet intent set vs pending");
    }

    function account(LooperPosition pos) internal view returns (uint256 c, uint256 d, uint256 lt, uint256 hf) {
        (c, d,, lt,, hf) = pool.getUserAccountData(address(pos));
    }

    function deployHf(LooperPosition pos) internal view returns (uint256) {
        (,,, uint256 lt,,) = pool.getUserAccountData(address(pos));
        uint256 l = pos.targetLeverage();
        uint256 h = (lt * 1e14 * l + (l - WAD) - 1) / (l - WAD);
        uint256 m = pos.params().minHf;
        return h > m ? h : m;
    }
}
