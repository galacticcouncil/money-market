// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {DiscountedCheckedOracle} from "../../contracts/DiscountedCheckedOracle.sol";
import {ICheckedOracle} from "../../contracts/interfaces/ICheckedOracle.sol";
import {IDiscountedCheckedOracle} from "../../contracts/interfaces/IDiscountedCheckedOracle.sol";

import {MockHydraChainlinkOracle} from "./mocks/MockHydraChainlinkOracle.sol";
import {RevertingHydraChainlinkOracle} from "./mocks/RevertingHydraChainlinkOracle.sol";

contract DiscountedCheckedOracleTest is Test {
    MockHydraChainlinkOracle check;

    address owner = address(0xA11CE);
    address pusher = address(0xB0B);
    address stranger = address(0xDEAD);

    uint256 constant ONE = 1e8;
    uint256 constant C985 = 0.985e8; // the apyUSD haircut: -1.5%

    function setUp() public {
        check = new MockHydraChainlinkOracle();
    }

    /// @dev Build an 8-decimal price from `whole` and `frac2Digits` (hundredths).
    function p(
        uint256 whole,
        uint256 frac2Digits
    ) internal pure returns (int256) {
        return int256(whole * 1e8 + (frac2Digits * 1e6));
    }

    function _deploy(
        int256 initialPrice,
        uint256 maxDiffBps,
        uint256 coefficient
    ) internal returns (DiscountedCheckedOracle) {
        return _deploy(initialPrice, maxDiffBps, coefficient, address(check));
    }

    function _deploy(
        int256 initialPrice,
        uint256 maxDiffBps,
        uint256 coefficient,
        address checkFeed
    ) internal returns (DiscountedCheckedOracle) {
        return
            new DiscountedCheckedOracle(
                "TEST/USD",
                1,
                owner,
                initialPrice,
                checkFeed,
                maxDiffBps,
                pusher,
                coefficient
            );
    }

    function _kill(address feed) internal {
        vm.etch(feed, address(new RevertingHydraChainlinkOracle()).code);
    }

    function _discounted(
        int256 raw,
        uint256 coefficient
    ) internal pure returns (int256) {
        return int256((uint256(raw) * coefficient) / ONE);
    }

    // ---------------------------------------------------------------------
    // construction
    // ---------------------------------------------------------------------

    function testConstructorDiscountsTheSeed() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(2, 0), 200, C985);

        // 2.00 * 0.985 = 1.97, not 2.00
        assertEq(oracle.latestAnswer(), p(1, 97));
        assertEq(oracle.coefficient(), C985);
    }

    /// @dev The base constructor writes round 1, the discounted restate is 2.
    function testConstructorLandsAtRoundTwo() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        assertEq(oracle.latestRound(), 2);
    }

    function testConstructorSeedIsNotChecked() public {
        // Feed says 1.00 with a 2% band; the discounted seed is 4.925, far
        // outside it, and the constructor still accepts it.
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(5, 0), 200, C985);

        assertEq(oracle.latestAnswer(), _discounted(p(5, 0), C985));
    }

    function testConstructorStoresInheritedConfig() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 250, C985);

        assertEq(oracle.checkOracle(), address(check));
        assertEq(oracle.checkDecimals(), 8);
        assertEq(oracle.maxDiffBps(), 250);
        assertEq(oracle.pusher(), pusher);
        assertEq(oracle.owner(), owner);
        assertEq(oracle.decimals(), 8);
        assertTrue(oracle.checked());
    }

    function testConstructorRejectsCoefficientAbovePar() public {
        check.pushAnswer(p(1, 0));
        vm.expectRevert(IDiscountedCheckedOracle.InvalidCoefficient.selector);
        _deploy(p(1, 0), 200, ONE + 1);
    }

    function testConstructorRejectsCoefficientBelowFloor() public {
        check.pushAnswer(p(1, 0));
        vm.expectRevert(IDiscountedCheckedOracle.InvalidCoefficient.selector);
        _deploy(p(1, 0), 200, 0.9e8 - 1);
    }

    function testConstructorRejectsNonPositiveSeed() public {
        check.pushAnswer(p(1, 0));
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        _deploy(0, 200, C985);
    }

    function testConstructorAcceptsNeutralCoefficient() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, ONE);

        assertEq(oracle.latestAnswer(), p(1, 0));
    }

    // ---------------------------------------------------------------------
    // pushing
    // ---------------------------------------------------------------------

    function testPushStoresDiscountedValue() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, C985);

        vm.prank(pusher);
        oracle.setPrice(p(2, 0));

        assertEq(oracle.latestAnswer(), p(1, 97));
    }

    /// @dev The whole point: raw sits outside the band, discounted sits inside.
    function testDiscountBringsAPushInsideTheBand() public {
        // Mirrors apyUSD: feed 1.42471577, raw 1.45280668, band 100 bps.
        check.pushAnswer(142471577);
        DiscountedCheckedOracle oracle = _deploy(142471577, 100, C985);

        (bool rawOk, ) = oracle.previewSetPrice(145280668);
        assertTrue(rawOk, "discounted push should be accepted");

        vm.prank(pusher);
        oracle.setPrice(145280668);

        assertEq(oracle.latestAnswer(), _discounted(145280668, C985));

        // ... whereas undiscounted it would not have been: same oracle at par
        // rejects the identical push.
        DiscountedCheckedOracle atPar = _deploy(142471577, 100, ONE);
        vm.prank(pusher);
        vm.expectRevert();
        atPar.setPrice(145280668);
    }

    function testPushRejectedWhenDiscountedValueLeavesTheBand() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 100, C985);

        // 2.00 * 0.985 = 1.97, nowhere near 1.00 +/- 1%
        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(2, 0));

        assertEq(oracle.latestAnswer(), int256(98500000)); // seed unchanged: 0.985
    }

    function testPushRevertsOnNonPositiveRaw() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(0);
    }

    /// @dev A raw price so small the discount truncates it to zero.
    function testPushRevertsWhenDiscountTruncatesToZero() public {
        check.pushAnswer(1);
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, 0.9e8);

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(1); // 1 * 0.9e8 / 1e8 == 0
    }

    function testPushStillGatesCallers() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, C985);

        vm.prank(stranger);
        vm.expectRevert(ICheckedOracle.NotPriceSetter.selector);
        oracle.setPrice(p(1, 0));
    }

    function testOwnerCanPushAndIsDiscountedToo() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, C985);

        vm.prank(owner);
        oracle.setPrice(p(2, 0));

        assertEq(oracle.latestAnswer(), p(1, 97));
    }

    function testPushFailsClosedWhenCheckFeedDies() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, C985);
        _kill(address(check));

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.CheckPriceUnavailable.selector);
        oracle.setPrice(p(1, 0));
    }

    function testEmitsPriceDiscounted() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, C985);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit IDiscountedCheckedOracle.PriceDiscounted(
            3, // seed used rounds 1 and 2
            p(2, 0),
            C985,
            p(1, 97)
        );

        vm.prank(pusher);
        oracle.setPrice(p(2, 0));
    }

    // ---------------------------------------------------------------------
    // unchecked mode
    // ---------------------------------------------------------------------

    function testUncheckedStillDiscounts() public {
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985, address(0));
        assertFalse(oracle.checked());

        vm.prank(pusher);
        oracle.setPrice(p(2, 0));

        assertEq(oracle.latestAnswer(), p(1, 97));
    }

    function testSetPriceUncheckedIsNotDiscounted() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 100, C985);

        vm.prank(owner);
        oracle.setPriceUnchecked(p(2, 0));

        assertEq(oracle.latestAnswer(), p(2, 0));
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    function testDiscountView() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        assertEq(oracle.discount(p(2, 0)), p(1, 97));

        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.discount(0);

        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.discount(-1);
    }

    function testPreviewTakesRawAndMirrorsSetPrice() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 100, C985);

        // raw 1.015 -> discounted 0.999775, ~2 bps from the feed
        (bool ok, uint256 dev) = oracle.previewSetPrice(int256(101500000));
        assertTrue(ok);
        assertLe(dev, 100);

        vm.prank(pusher);
        oracle.setPrice(int256(101500000)); // preview said yes, so this must pass
    }

    function testPreviewRejectsNonPositive() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        (bool ok, uint256 dev) = oracle.previewSetPrice(0);
        assertFalse(ok);
        assertEq(dev, 0);
    }

    function testPreviewUncheckedAcceptsAnything() public {
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985, address(0));

        (bool ok, uint256 dev) = oracle.previewSetPrice(p(1000, 0));
        assertTrue(ok);
        assertEq(dev, 0);
    }

    function testBoundsAreExposed() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        assertEq(oracle.ONE(), ONE);
        assertEq(oracle.MIN_COEFFICIENT(), 0.9e8);
        assertEq(oracle.MAX_COEFFICIENT(), ONE);
    }

    // ---------------------------------------------------------------------
    // configuration
    // ---------------------------------------------------------------------

    function testSetCoefficientTakesEffectOnNextPushOnly() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 10_000, ONE);
        assertEq(oracle.latestAnswer(), p(1, 0));

        vm.prank(owner);
        oracle.setCoefficient(C985);

        // stored price untouched by the dial itself
        assertEq(oracle.latestAnswer(), p(1, 0));

        vm.prank(pusher);
        oracle.setPrice(p(1, 0));
        assertEq(oracle.latestAnswer(), int256(98500000)); // 0.985
    }

    function testSetCoefficientOwnerOnly() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        vm.prank(pusher);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setCoefficient(ONE);
    }

    function testSetCoefficientRejectsOutOfBounds() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        vm.startPrank(owner);
        vm.expectRevert(IDiscountedCheckedOracle.InvalidCoefficient.selector);
        oracle.setCoefficient(ONE + 1);

        vm.expectRevert(IDiscountedCheckedOracle.InvalidCoefficient.selector);
        oracle.setCoefficient(0.9e8 - 1);

        vm.expectRevert(IDiscountedCheckedOracle.InvalidCoefficient.selector);
        oracle.setCoefficient(0);
        vm.stopPrank();
    }

    function testSetCoefficientEmits() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit IDiscountedCheckedOracle.CoefficientUpdated(C985, ONE);

        vm.prank(owner);
        oracle.setCoefficient(ONE);
    }

    function testCoefficientBoundsAcceptTheirEdges() public {
        check.pushAnswer(p(1, 0));
        DiscountedCheckedOracle oracle = _deploy(p(1, 0), 200, C985);

        vm.startPrank(owner);
        oracle.setCoefficient(0.9e8);
        assertEq(oracle.coefficient(), 0.9e8);
        oracle.setCoefficient(ONE);
        assertEq(oracle.coefficient(), ONE);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------

    /// @dev Whatever is stored is the raw price scaled by the coefficient, and
    /// never above it.
    function testFuzzStoredIsRawTimesCoefficient(
        uint256 raw,
        uint256 coefficient
    ) public {
        raw = bound(raw, 1e8, 1e24);
        coefficient = bound(coefficient, 0.9e8, ONE);

        check.pushAnswer(int256(raw));
        DiscountedCheckedOracle oracle = _deploy(
            int256(raw),
            10_000,
            coefficient
        );

        vm.prank(pusher);
        oracle.setPrice(int256(raw));

        int256 expected = _discounted(int256(raw), coefficient);
        assertEq(oracle.latestAnswer(), expected);
        assertLe(oracle.latestAnswer(), int256(raw));
    }

    /// @dev preview and setPrice agree for every input.
    function testFuzzPreviewMatchesSetPrice(
        uint256 raw,
        uint256 checkAnswer,
        uint256 coefficient,
        uint256 maxDiffBps
    ) public {
        raw = bound(raw, 1e6, 1e24);
        checkAnswer = bound(checkAnswer, 1e6, 1e24);
        coefficient = bound(coefficient, 0.9e8, ONE);
        maxDiffBps = bound(maxDiffBps, 0, 10_000);

        check.pushAnswer(int256(checkAnswer));
        DiscountedCheckedOracle oracle = _deploy(
            int256(checkAnswer),
            maxDiffBps,
            coefficient
        );

        (bool ok, ) = oracle.previewSetPrice(int256(raw));

        vm.prank(pusher);
        if (ok) {
            oracle.setPrice(int256(raw));
            assertEq(
                oracle.latestAnswer(),
                _discounted(int256(raw), coefficient)
            );
        } else {
            vm.expectRevert();
            oracle.setPrice(int256(raw));
        }
    }

    /// @dev A compromised pusher stays bounded by the band, discount or not.
    function testFuzzPusherBounded(uint256 raw, uint256 coefficient) public {
        raw = bound(raw, 1, uint256(type(int256).max) / ONE);
        coefficient = bound(coefficient, 0.9e8, ONE);

        int256 anchor = p(1, 0);
        check.pushAnswer(anchor);
        DiscountedCheckedOracle oracle = _deploy(anchor, 100, coefficient);

        vm.prank(pusher);
        try oracle.setPrice(int256(raw)) {
            int256 stored = oracle.latestAnswer();
            uint256 diff = stored > anchor
                ? uint256(stored - anchor)
                : uint256(anchor - stored);
            assertLe((diff * 10_000) / uint256(anchor), 100);
        } catch {
            // rejected: the stored price is whatever the seed left
        }
    }
}
