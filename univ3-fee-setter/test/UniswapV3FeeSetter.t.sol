// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Fork tests for UniswapV3FeeSetter against the live Hydration factory.
// Every test runs on its own copy of the latest mainnet block; nothing reaches the real chain.

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3PoolEvents} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolEvents.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UniswapV3FeeSetter} from "../src/UniswapV3FeeSetter.sol";

contract UniswapV3FeeSetterTest is Test {
    IUniswapV3Factory constant FACTORY = IUniswapV3Factory(0x776c4Fd6A6170165a91bA45Dec40a14bcc8eC354);
    address constant AAVE_MANAGER = 0xAa7e0000000000000000000000000000000Aa7e0; // factory owner today
    IUniswapV3Pool constant POOL_1 = IUniswapV3Pool(0x5C6208A3c316A801f8996750aA7b6f45Fc988548); // aDOT/HOLLAR, 4/4

    address bob = makeAddr("bob"); // creates pools
    address carol = makeAddr("carol"); // a stranger who calls setFee
    address mallory = makeAddr("mallory"); // passes fake pools to setFee
    address treasury = makeAddr("treasury"); // Tara: where governance sends collected fees

    UniswapV3FeeSetter setter;

    function setUp() public {
        vm.createSelectFork("hydration");
        // Hydration blocks carry an empty mixHash, and the "paris" EVM refuses a block without one.
        vm.prevrandao(bytes32(0));
        setter = new UniswapV3FeeSetter();
    }

    // As the Aave manager, make the setter the factory owner (the referendum, later).
    function handOver() internal {
        vm.prank(AAVE_MANAGER);
        FACTORY.setOwner(address(setter));
    }

    // Bob creates a pool on two made-up token addresses; createPool never calls the tokens.
    function createdPool() internal returns (IUniswapV3Pool) {
        vm.prank(bob);
        return IUniswapV3Pool(FACTORY.createPool(address(0x1111), address(0x2222), 3000));
    }

    // A created pool, initialized at price 1 (sqrtPriceX96 = 2^96), so its lock is open.
    function freshPool() internal returns (IUniswapV3Pool pool) {
        pool = createdPool();
        vm.prank(bob);
        pool.initialize(2 ** 96);
    }

    // Unpack slot0.feeProtocol: token0's divisor in the low 4 bits, token1's in the high 4.
    function feeOf(IUniswapV3Pool pool) internal view returns (uint8 fee0, uint8 fee1) {
        (,,,,, uint8 packed,) = pool.slot0();
        return (packed % 16, packed >> 4);
    }

    // 1. After the handover, Carol's setFee switches Bob's fresh pool to 4/4.
    function test_afterHandover_strangerSwitchesFreshPoolToFourFour() public {
        handOver();
        IUniswapV3Pool pool = freshPool();
        (uint8 before0, uint8 before1) = feeOf(pool);
        assertEq(before0, 0);
        assertEq(before1, 0);

        vm.prank(carol);
        setter.setFee(pool);

        (uint8 fee0, uint8 fee1) = feeOf(pool);
        assertEq(fee0, 4);
        assertEq(fee1, 4);
    }

    // 2. Before the handover, Carol's setFee reverts and the pool stays 0/0.
    function test_beforeHandover_setFeeReverts() public {
        assertEq(FACTORY.owner(), AAVE_MANAGER);
        IUniswapV3Pool pool = freshPool();

        vm.expectRevert(); // the pool's owner check has no message
        vm.prank(carol);
        setter.setFee(pool);

        (uint8 fee0, uint8 fee1) = feeOf(pool);
        assertEq(fee0, 0);
        assertEq(fee1, 0);
    }

    // 3. After the handover, setFee on a pool that was never initialized reverts with "LOK".
    function test_uninitializedPool_reverts() public {
        handOver();
        IUniswapV3Pool pool = createdPool();

        vm.expectRevert(bytes("LOK"));
        vm.prank(carol);
        setter.setFee(pool);
    }

    // 4. Carol calls setFee twice on the same pool: the second call reverts with FeeAlreadySet, the pool stays 4/4.
    function test_secondCall_revertsFeeAlreadySet() public {
        handOver();
        IUniswapV3Pool pool = freshPool();
        vm.prank(carol);
        setter.setFee(pool);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.FeeAlreadySet.selector, address(pool)));
        vm.prank(carol);
        setter.setFee(pool);

        (uint8 fee0, uint8 fee1) = feeOf(pool);
        assertEq(fee0, 4);
        assertEq(fee1, 4);
    }

    // 5. setFee on pool 1, already at 4/4, reverts with FeeAlreadySet.
    function test_poolAlreadyAtFourFour_revertsFeeAlreadySet() public {
        handOver();
        (uint8 before0, uint8 before1) = feeOf(POOL_1);
        assertEq(before0, 4);
        assertEq(before1, 4);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.FeeAlreadySet.selector, address(POOL_1)));
        vm.prank(carol);
        setter.setFee(POOL_1);
    }

    // 6. Carol's setFee makes the pool emit SetFeeProtocol(0, 0, 4, 4).
    function test_setFee_emitsSetFeeProtocol() public {
        handOver();
        IUniswapV3Pool pool = freshPool();

        vm.expectEmit(address(pool));
        emit IUniswapV3PoolEvents.SetFeeProtocol(0, 0, 4, 4);
        vm.prank(carol);
        setter.setFee(pool);
    }

    // 7. Governance set Bob's pool to 1/10 before the handover; Carol's setFee moves it to 4/4.
    function test_poolAtOneTenth_isUpdatedToFourFour() public {
        IUniswapV3Pool pool = freshPool();
        vm.prank(AAVE_MANAGER);
        pool.setFeeProtocol(10, 10);
        handOver();
        (uint8 before0, uint8 before1) = feeOf(pool);
        assertEq(before0, 10);
        assertEq(before1, 10);

        vm.prank(carol);
        setter.setFee(pool);

        (uint8 fee0, uint8 fee1) = feeOf(pool);
        assertEq(fee0, 4);
        assertEq(fee1, 4);
    }

    // 8. Bob's pool sits at 4/0 (only token0 set); Carol's setFee moves it to 4/4, so the check needs both sides.
    function test_poolAtFourZero_isUpdatedToFourFour() public {
        IUniswapV3Pool pool = freshPool();
        vm.prank(AAVE_MANAGER);
        pool.setFeeProtocol(4, 0);
        handOver();
        (uint8 before0, uint8 before1) = feeOf(pool);
        assertEq(before0, 4);
        assertEq(before1, 0);

        vm.prank(carol);
        setter.setFee(pool);

        (uint8 fee0, uint8 fee1) = feeOf(pool);
        assertEq(fee0, 4);
        assertEq(fee1, 4);
    }

    // 9. Mallory's fake copies pool 1's tokens and fee and names our factory: refused with UnknownPool.
    function test_fakeCopyingPoolOne_revertsUnknownPool() public {
        handOver();
        FakePool fake = new FakePool(POOL_1.token0(), POOL_1.token1(), POOL_1.fee(), 0);
        assertEq(fake.factory(), address(FACTORY)); // a check on pool.factory() would let it through

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.UnknownPool.selector, address(fake)));
        vm.prank(mallory);
        setter.setFee(IUniswapV3Pool(address(fake)));
    }

    // 10. Mallory's fake claims made-up tokens that have no pool (getPool returns zero): refused with UnknownPool.
    function test_fakeWithNoRealPool_revertsUnknownPool() public {
        handOver();
        FakePool fake = new FakePool(address(0x3333), address(0x4444), 3000, 0);
        assertEq(FACTORY.getPool(address(0x3333), address(0x4444), 3000), address(0));

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.UnknownPool.selector, address(fake)));
        vm.prank(mallory);
        setter.setFee(IUniswapV3Pool(address(fake)));
    }

    // 11. Mallory's fake reports 4/4: refused with UnknownPool, not FeeAlreadySet, so the list check runs first.
    function test_fakeReportingFourFour_revertsUnknownPoolFirst() public {
        handOver();
        FakePool fake = new FakePool(POOL_1.token0(), POOL_1.token1(), POOL_1.fee(), 68); // 68 = 4/4

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.UnknownPool.selector, address(fake)));
        vm.prank(mallory);
        setter.setFee(IUniswapV3Pool(address(fake)));
    }

    // 12. Carol passes her own wallet address (no code): reverts with no message.
    function test_walletAddress_revertsWithoutMessage() public {
        handOver();

        vm.expectRevert(bytes(""));
        vm.prank(carol);
        setter.setFee(IUniswapV3Pool(carol));
    }

    // 13. After the handover, the manager collects everything from pool 1 to Tara: she receives the
    //     returned amounts, and the pool keeps 1 wei of each token.
    function test_managerCollectsAll_treasuryReceivesAmounts() public {
        handOver();
        IERC20 token0 = IERC20(POOL_1.token0()); // aDOT
        IERC20 token1 = IERC20(POOL_1.token1()); // HOLLAR
        (uint128 held0, uint128 held1) = POOL_1.protocolFees();
        assertGt(held0, 1); // pool 1 has fees to collect at this block
        assertGt(held1, 1);

        vm.prank(AAVE_MANAGER);
        (uint128 sent0, uint128 sent1) =
            setter.collectProtocol(POOL_1, treasury, type(uint128).max, type(uint128).max);

        assertEq(sent0, held0 - 1);
        assertEq(sent1, held1 - 1);
        assertEq(token0.balanceOf(treasury), sent0);
        assertEq(token1.balanceOf(treasury), sent1);
        (uint128 left0, uint128 left1) = POOL_1.protocolFees();
        assertEq(left0, 1);
        assertEq(left1, 1);
    }

    // 14. After the handover, the manager collects 100 HOLLAR and no aDOT: Tara gets exactly 100 HOLLAR,
    //     and the pool's HOLLAR fees drop by exactly 100.
    function test_managerCollectsPart_exactAmountMoves() public {
        handOver();
        IERC20 hollar = IERC20(POOL_1.token1()); // 18 decimals
        (uint128 held0, uint128 held1) = POOL_1.protocolFees();

        vm.prank(AAVE_MANAGER);
        (uint128 sent0, uint128 sent1) = setter.collectProtocol(POOL_1, treasury, 0, 100e18);

        assertEq(sent0, 0);
        assertEq(sent1, 100e18);
        assertEq(hollar.balanceOf(treasury), 100e18);
        (uint128 left0, uint128 left1) = POOL_1.protocolFees();
        assertEq(left0, held0);
        assertEq(left1, held1 - 100e18);
    }

    // 15. Carol calls collectProtocol: refused with NotManager(carol), and the pool's fees are unchanged.
    function test_strangerCollect_revertsNotManager() public {
        handOver();
        (uint128 held0, uint128 held1) = POOL_1.protocolFees();

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.NotManager.selector, carol));
        vm.prank(carol);
        setter.collectProtocol(POOL_1, carol, type(uint128).max, type(uint128).max);

        (uint128 left0, uint128 left1) = POOL_1.protocolFees();
        assertEq(left0, held0);
        assertEq(left1, held1);
    }

    // 16. Before the handover, the manager's collect reverts with no message: the pool's owner check
    //     refuses, because the setter is not the owner yet.
    function test_beforeHandover_collectReverts() public {
        vm.expectRevert(bytes(""));
        vm.prank(AAVE_MANAGER);
        setter.collectProtocol(POOL_1, treasury, type(uint128).max, type(uint128).max);
    }

    // 17. The manager's collect makes the pool emit CollectProtocol with the setter as the sender.
    function test_collect_emitsCollectProtocolFromSetter() public {
        handOver();

        vm.expectEmit(address(POOL_1));
        emit IUniswapV3PoolEvents.CollectProtocol(address(setter), treasury, 0, 100e18);
        vm.prank(AAVE_MANAGER);
        setter.collectProtocol(POOL_1, treasury, 0, 100e18);
    }

    // 18. The manager takes the factory back: FACTORY.owner() is the manager, and Carol's setFee on a
    //     fresh pool now reverts, because the setter has no power left.
    function test_managerTakesFactoryBack_setterLosesPower() public {
        handOver();
        vm.prank(AAVE_MANAGER);
        setter.setFactoryOwner(AAVE_MANAGER);
        assertEq(FACTORY.owner(), AAVE_MANAGER);

        IUniswapV3Pool pool = freshPool();
        vm.expectRevert(bytes(""));
        vm.prank(carol);
        setter.setFee(pool);
    }

    // 19. The manager passes zero: refused with ZeroOwner, and the setter still owns the factory.
    function test_zeroOwner_reverts() public {
        handOver();

        vm.expectRevert(UniswapV3FeeSetter.ZeroOwner.selector);
        vm.prank(AAVE_MANAGER);
        setter.setFactoryOwner(address(0));

        assertEq(FACTORY.owner(), address(setter));
    }

    // 20. Carol tries to take the factory: refused with NotManager(carol), and the owner is unchanged.
    function test_strangerSetFactoryOwner_revertsNotManager() public {
        handOver();

        vm.expectRevert(abi.encodeWithSelector(UniswapV3FeeSetter.NotManager.selector, carol));
        vm.prank(carol);
        setter.setFactoryOwner(carol);

        assertEq(FACTORY.owner(), address(setter));
    }

    // 21. Take back, enable fee tier 2500, hand back: the tier is live, the setter owns the factory
    //     again, and Carol's setFee works on a fresh pool.
    function test_takeBackEnableTierHandBack_works() public {
        handOver();
        vm.startPrank(AAVE_MANAGER);
        setter.setFactoryOwner(AAVE_MANAGER);
        FACTORY.enableFeeAmount(2500, 50);
        FACTORY.setOwner(address(setter));
        vm.stopPrank();

        assertEq(FACTORY.feeAmountTickSpacing(2500), 50);
        assertEq(FACTORY.owner(), address(setter));
        IUniswapV3Pool pool = freshPool();
        vm.prank(carol);
        setter.setFee(pool);
        (uint8 fee0, uint8 fee1) = feeOf(pool);
        assertEq(fee0, 4);
        assertEq(fee1, 4);
    }

    // 22. Before the handover, the manager's setFactoryOwner reverts with no message: the factory's own
    //     owner check refuses, because the setter is not the owner yet.
    function test_beforeHandover_setFactoryOwnerReverts() public {
        vm.expectRevert(bytes(""));
        vm.prank(AAVE_MANAGER);
        setter.setFactoryOwner(AAVE_MANAGER);
    }
}

// Test only: claims to be a pool. It reports the tokens, fee and fee byte it was built with,
// names our factory, and ignores setFeeProtocol.
contract FakePool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint8 immutable feeProtocol;

    constructor(address token0_, address token1_, uint24 fee_, uint8 feeProtocol_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        feeProtocol = feeProtocol_;
    }

    function factory() external pure returns (address) {
        return 0x776c4Fd6A6170165a91bA45Dec40a14bcc8eC354; // our factory
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (2 ** 96, 0, 0, 1, 1, feeProtocol, true);
    }

    function setFeeProtocol(uint8, uint8) external {}
}
