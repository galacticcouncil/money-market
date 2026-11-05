// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {QueueLib} from "../../src/libraries/QueueLib.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";

/// @dev Pool stub that accepts `acceptLimit` deposits, then refuses.
contract RefusingPool {
    uint256 public accepted;
    uint256 public acceptLimit;
    uint256 internal nextId = 1;

    constructor(uint256 _acceptLimit) {
        acceptLimit = _acceptLimit;
    }

    function fixedAPYWad() external pure returns (uint256) {
        return 0.18e18;
    }

    function minimumInvestmentPeriodSeconds() external pure returns (uint256) {
        return 60 days;
    }

    function deposit(uint256) external returns (uint256) {
        require(accepted < acceptLimit, "full");
        accepted++;
        return nextId++;
    }
}

/// @dev Holds the storage QueueLib.investSplit writes, so the library can be
///      exercised against a pool that refuses part-way through a split.
contract InvestHarness {
    QueueLib.NFTPosition[] public positions;
    mapping(uint256 => IDecentralPool) public positionPool;
    uint256[] public heap;

    function invest(IDecentralPool pool, uint256 amount, uint256 cap)
        external
        returns (uint256 invested, uint256 tokenId, uint256 rateAdded, uint256 offsetAdded)
    {
        return QueueLib.investSplit(positions, positionPool, heap, pool, amount, cap);
    }

    function count() external view returns (uint256) {
        return positions.length;
    }

    function heapLength() external view returns (uint256) {
        return heap.length;
    }

    function principalOf(uint256 i) external view returns (uint256) {
        return positions[i].principal;
    }
}

contract MaxPositionTest is BaseTest {
    uint256 internal constant CAP = 100_000e18;

    function setUp() public override {
        super.setUp();
        hollar.mint(alice, 2_000_000e18);
    }

    function _principal(uint256 i) internal view returns (uint256 p, uint256 maturity) {
        (, p,,, maturity,) = vault.getPosition(i);
    }

    /// @dev Pieces created by the last call, from index `from`.
    function _assertSplit(uint256 from, uint256 amount) internal view {
        uint256 n = (amount + CAP - 1) / CAP;
        assertEq(vault.getPositionCount() - from, n, "piece count");
        (, uint256 maturity0) = _principal(from);
        uint256 sum;
        uint256 lo = type(uint256).max;
        uint256 hi;
        for (uint256 i = from; i < from + n; i++) {
            (uint256 p, uint256 m) = _principal(i);
            assertLe(p, CAP, "piece over cap");
            assertEq(m, maturity0, "pieces share one maturity");
            sum += p;
            if (p < lo) lo = p;
            if (p > hi) hi = p;
        }
        assertEq(sum, amount, "pieces sum to amount");
        assertLe(hi - lo, 1, "pieces even to the wei");
        if (n > 1) assertGt(lo, CAP / 2 - 1, "no piece under half the cap");
    }

    function test_depositAtCapIsOnePosition() public {
        _deposit(alice, CAP);
        _assertSplit(0, CAP);
        assertEq(vault.getPositionCount(), 1);
    }

    function test_depositSplitsEvenly() public {
        _deposit(alice, 250_000e18);
        _assertSplit(0, 250_000e18);
        assertEq(vault.getPositionCount(), 3);
        assertEq(vault.totalInvestedPrincipal(), 250_000e18);
    }

    function test_depositJustOverCapHalves() public {
        _deposit(alice, CAP + 1);
        _assertSplit(0, CAP + 1);
        (uint256 a,) = _principal(0);
        (uint256 b,) = _principal(1);
        assertEq(a, 50_000e18 + 1);
        assertEq(b, 50_000e18);
    }

    function testFuzz_depositSplit(uint256 amount) public {
        amount = bound(amount, TEN_HOLLAR, INITIAL_TVL_CAP);
        uint256 shares = _deposit(alice, amount);
        _assertSplit(0, amount);
        assertEq(vault.totalInvestedPrincipal(), amount);
        assertEq(vault.idleHollar(), 0);
        assertGt(shares, 0);
    }

    function test_depositRevertsWhenAPieceIsRefused() public {
        // 3k + 1 splits as [k + 1, k, k]: refusing exactly `k` lets the first piece land
        uint256 k = 83_333e18;
        uint256 amount = 3 * k + 1;
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.deposit.selector, k), "refused");
        uint256 balanceBefore = hollar.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(BILVault.DecentralDepositFailed.selector);
        vault.deposit(amount, alice);

        assertEq(vault.getPositionCount(), 0, "no partial positions survive");
        assertEq(hollar.balanceOf(alice), balanceBefore, "depositor keeps their HOLLAR");
        assertEq(vault.totalInvestedPrincipal(), 0);
    }

    function test_reinvestSplitsReturnedPrincipal() public {
        _deposit(alice, 250_000e18);
        vm.warp(block.timestamp + SIXTY_DAYS + 1);
        for (uint256 i; i < 3; i++) _processPositionFull(i);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 250_000e18, "principal + yield back in the vault");
        uint256 before = vault.getPositionCount();

        vault.pokeQueue();

        assertEq(vault.idleHollar(), 0, "all idle reinvested");
        _assertSplit(before, idle);
    }
}

contract InvestSplitLibTest is BaseTest {
    uint256 internal constant CAP = 100_000e18;

    function test_partialRefusalRecordsOnlyLandedPieces() public {
        InvestHarness h = new InvestHarness();
        RefusingPool p = new RefusingPool(1);

        (uint256 invested, uint256 tokenId, uint256 rateAdded,) =
            h.invest(IDecentralPool(address(p)), 250_000e18, CAP);

        uint256 piece = uint256(250_000e18) / 3 + 1; // 250k % 3 == 1, so the first piece takes the wei
        assertEq(invested, piece, "only the first piece landed");
        assertEq(tokenId, 1);
        assertEq(h.count(), 1, "one position recorded");
        assertEq(h.heapLength(), 1, "one maturity queued");
        assertEq(h.principalOf(0), piece);
        assertEq(rateAdded, 0.18e18 * piece);
    }

    function test_fullRefusalRecordsNothing() public {
        InvestHarness h = new InvestHarness();
        RefusingPool p = new RefusingPool(0);

        (uint256 invested, uint256 tokenId,,) = h.invest(IDecentralPool(address(p)), 250_000e18, CAP);

        assertEq(invested, 0);
        assertEq(tokenId, 0);
        assertEq(h.count(), 0);
        assertEq(h.heapLength(), 0);
    }

    function test_zeroAmountIsANoop() public {
        InvestHarness h = new InvestHarness();
        RefusingPool p = new RefusingPool(5);
        (uint256 invested,,,) = h.invest(IDecentralPool(address(p)), 0, CAP);
        assertEq(invested, 0);
        assertEq(p.accepted(), 0);
    }
}
