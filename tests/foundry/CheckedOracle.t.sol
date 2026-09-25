// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {CheckedOracle} from "../../contracts/CheckedOracle.sol";
import {ICheckedOracle} from "../../contracts/interfaces/ICheckedOracle.sol";

import {MockHydraChainlinkOracle} from "./mocks/MockHydraChainlinkOracle.sol";
import {RevertingHydraChainlinkOracle} from "./mocks/RevertingHydraChainlinkOracle.sol";
import {DecimalsHydraChainlinkOracle, NoDecimalsHydraChainlinkOracle} from "./mocks/DecimalsHydraChainlinkOracle.sol";

contract CheckedOracleTest is Test {
    MockHydraChainlinkOracle check;

    address owner = address(0xA11CE);
    address pusher = address(0xB0B);
    address stranger = address(0xDEAD);

    function setUp() public {
        check = new MockHydraChainlinkOracle();
    }

    /// @dev Build an 8-decimal price from `whole` and `frac2Digits` (hundredths).
    /// p(1, 50) == 1.50e8, p(0, 80) == 0.80e8.
    function p(
        uint256 whole,
        uint256 frac2Digits
    ) internal pure returns (int256) {
        return int256(whole * 1e8 + (frac2Digits * 1e6));
    }

    function _deploy(
        int256 initialPrice,
        uint256 maxDiffBps
    ) internal returns (CheckedOracle) {
        return _deploy(initialPrice, maxDiffBps, address(check));
    }

    /// @dev Replace a live feed's code with one that reverts on everything:
    /// the feed died after the oracle was set up against it.
    function _kill(address feed) internal {
        vm.etch(feed, address(new RevertingHydraChainlinkOracle()).code);
    }

    function _deploy(
        int256 initialPrice,
        uint256 maxDiffBps,
        address checkFeed
    ) internal returns (CheckedOracle) {
        return
            new CheckedOracle(
                "TEST/USD",
                1,
                owner,
                initialPrice,
                checkFeed,
                maxDiffBps,
                pusher
            );
    }

    // ---------------------------------------------------------------------
    // construction
    // ---------------------------------------------------------------------

    function testConstructorStoresConfig() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        assertEq(oracle.checkOracle(), address(check));
        assertEq(oracle.checkDecimals(), 8);
        assertEq(oracle.maxDiffBps(), 200);
        assertEq(oracle.pusher(), pusher);
        assertEq(oracle.owner(), owner);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.latestAnswer(), p(1, 0));
        assertEq(oracle.latestRound(), 1);
    }

    function testConstructorPriceIsNotChecked() public {
        // Check feed says 1.00, initial price is 5.00, band is 2% -- the
        // constructor still accepts it (owner-weight action).
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(5, 0), 200);
        assertEq(oracle.latestAnswer(), p(5, 0));
    }

    function testConstructorZeroCheckFeedMeansUnchecked() public {
        CheckedOracle oracle = _deploy(p(1, 0), 200, address(0));
        assertFalse(oracle.checked());
        assertEq(oracle.checkOracle(), address(0));
        assertEq(oracle.checkDecimals(), 0);
    }

    function testConstructorRejectsDeadCheckFeed() public {
        RevertingHydraChainlinkOracle dead = new RevertingHydraChainlinkOracle();
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        _deploy(p(1, 0), 200, address(dead));
    }

    function testConstructorRejectsCheckFeedAnsweringZero() public {
        // Nothing pushed to the mock yet -> it answers 0.
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        _deploy(p(1, 0), 200);
    }

    function testConstructorRejectsBpsAboveMax() public {
        check.pushAnswer(p(1, 0));
        vm.expectRevert(ICheckedOracle.InvalidBps.selector);
        _deploy(p(1, 0), 10_001);
    }

    function testConstructorAcceptsZeroPusher() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = new CheckedOracle(
            "TEST/USD",
            1,
            owner,
            p(1, 0),
            address(check),
            200,
            address(0)
        );
        assertEq(oracle.pusher(), address(0));
    }

    // ---------------------------------------------------------------------
    // setPrice: accepted updates
    // ---------------------------------------------------------------------

    function testPusherCanSetPriceInBand() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(pusher);
        oracle.setPrice(p(1, 1)); // +1%

        assertEq(oracle.latestAnswer(), p(1, 1));
        assertEq(oracle.latestRound(), 2);
        assertEq(oracle.latestTimestamp(), block.timestamp);
    }

    function testOwnerCanSetPriceInBand() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(owner);
        oracle.setPrice(p(0, 99));

        assertEq(oracle.latestAnswer(), p(0, 99));
    }

    function testSetPriceUpdatesRoundData() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 500);

        vm.warp(block.timestamp + 1 days);
        vm.prank(pusher);
        oracle.setPrice(p(1, 2));

        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = oracle.latestRoundData();

        assertEq(roundId, 2);
        assertEq(answer, p(1, 2));
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 2);
    }

    function testExactlyAtUpperEdgeAccepted() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 1000); // +-10%

        vm.prank(pusher);
        oracle.setPrice(p(1, 10));
        assertEq(oracle.latestAnswer(), p(1, 10));
    }

    function testExactlyAtLowerEdgeAccepted() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 1000);

        vm.prank(pusher);
        oracle.setPrice(p(0, 90));
        assertEq(oracle.latestAnswer(), p(0, 90));
    }

    function testOneWeiBeyondUpperEdgeRejected() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 1000);

        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(1, 10) + 1);
    }

    function testTrackingTheCheckFeedOverTime() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        // The feed drifts up 1% a step; a pusher following it stays accepted.
        for (uint256 i = 0; i < 5; i++) {
            int256 next = (oracle.latestAnswer() * 101) / 100;
            check.pushAnswer(next);
            vm.prank(pusher);
            oracle.setPrice(next);
            assertEq(oracle.latestAnswer(), next);
        }
        assertEq(oracle.latestRound(), 6);
    }

    // ---------------------------------------------------------------------
    // setPrice: rejected updates
    // ---------------------------------------------------------------------

    function testAboveBandReverts() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(pusher);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICheckedOracle.PriceDeviationTooLarge.selector,
                p(1, 50),
                p(1, 0),
                5000,
                200
            )
        );
        oracle.setPrice(p(1, 50));

        assertEq(oracle.latestAnswer(), p(1, 0));
        assertEq(oracle.latestRound(), 1);
    }

    function testBelowBandReverts() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(pusher);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICheckedOracle.PriceDeviationTooLarge.selector,
                p(0, 80),
                p(1, 0),
                2000,
                200
            )
        );
        oracle.setPrice(p(0, 80));
    }

    function testCompromisedPusherCannotMovePriceBeyondBand() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        // 10x attempt, 1 wei above the band, and a zero-out all bounce.
        vm.startPrank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(10, 0));
        vm.expectRevert();
        oracle.setPrice(p(1, 2) + 1);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(0);
        vm.stopPrank();

        assertEq(oracle.latestAnswer(), p(1, 0));
    }

    function testStrangerCannotSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(stranger);
        vm.expectRevert(ICheckedOracle.NotPriceSetter.selector);
        oracle.setPrice(p(1, 0));
    }

    function testRemovedPusherCannotSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(owner);
        oracle.setPusher(address(0));

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.NotPriceSetter.selector);
        oracle.setPrice(p(1, 0));
    }

    function testNegativeAndZeroPriceRejected() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 10_000);

        vm.startPrank(pusher);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(0);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(-1);
        vm.stopPrank();
    }

    function testZeroToleranceOnlyAcceptsExactMatch() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 0);

        vm.prank(pusher);
        oracle.setPrice(p(1, 0));
        assertEq(oracle.latestAnswer(), p(1, 0));

        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(1, 0) + 1);
    }

    function testMaxToleranceAcceptsUpToDouble() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 10_000);

        vm.startPrank(pusher);
        oracle.setPrice(p(2, 0));
        assertEq(oracle.latestAnswer(), p(2, 0));
        oracle.setPrice(1); // 1 wei: within [0, 2c]
        vm.expectRevert();
        oracle.setPrice(p(2, 0) + 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // check feed unavailable -> fail closed
    // ---------------------------------------------------------------------

    function testRevertingCheckFeedBlocksSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);
        _kill(address(check));

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.CheckPriceUnavailable.selector);
        oracle.setPrice(p(1, 0));
    }

    function testZeroCheckPriceBlocksSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);
        check.pushAnswer(0);

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.CheckPriceUnavailable.selector);
        oracle.setPrice(p(1, 0));
    }

    function testNegativeCheckPriceBlocksSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);
        check.pushAnswer(-1);

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.CheckPriceUnavailable.selector);
        oracle.setPrice(p(1, 0));
    }

    function testCheckFeedRecoveryUnblocksSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);
        check.pushAnswer(0);

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.CheckPriceUnavailable.selector);
        oracle.setPrice(p(1, 0));

        check.pushAnswer(p(1, 0));
        vm.prank(pusher);
        oracle.setPrice(p(1, 1));
        assertEq(oracle.latestAnswer(), p(1, 1));
    }

    // ---------------------------------------------------------------------
    // setPriceUnchecked: owner escape hatch
    // ---------------------------------------------------------------------

    function testOwnerCanPushUncheckedOutsideBand() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.expectEmit(true, false, false, true);
        emit ICheckedOracle.PriceSetUnchecked(2, p(5, 0), p(1, 0));
        vm.prank(owner);
        oracle.setPriceUnchecked(p(5, 0));

        assertEq(oracle.latestAnswer(), p(5, 0));
        assertEq(oracle.latestRound(), 2);
    }

    function testOwnerCanPushUncheckedWithDeadFeed() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);
        _kill(address(check));

        vm.expectEmit(true, false, false, true);
        emit ICheckedOracle.PriceSetUnchecked(2, p(1, 5), 0);
        vm.prank(owner);
        oracle.setPriceUnchecked(p(1, 5));

        assertEq(oracle.latestAnswer(), p(1, 5));
    }

    function testPusherCannotPushUnchecked() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(pusher);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPriceUnchecked(p(5, 0));
    }

    // ---------------------------------------------------------------------
    // configuration
    // ---------------------------------------------------------------------

    function testOnlyOwnerConfigures() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.startPrank(pusher);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setMaxDiffBps(500);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setCheckOracle(address(1));
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPusher(stranger);
        vm.stopPrank();
    }

    function testSetMaxDiffBpsWidensBand() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(1, 5));

        vm.expectEmit(false, false, false, true);
        emit ICheckedOracle.MaxDiffBpsUpdated(5000);
        vm.prank(owner);
        oracle.setMaxDiffBps(5000);

        vm.prank(pusher);
        oracle.setPrice(p(1, 5));
        assertEq(oracle.latestAnswer(), p(1, 5));
    }

    function testSetMaxDiffBpsRejectsAboveMax() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(owner);
        vm.expectRevert(ICheckedOracle.InvalidBps.selector);
        oracle.setMaxDiffBps(10_001);
    }

    function testSetCheckOracleSwapsFeedAndDecimals() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        DecimalsHydraChainlinkOracle other = new DecimalsHydraChainlinkOracle(
            18,
            2e18
        );

        vm.expectEmit(true, false, false, true);
        emit ICheckedOracle.CheckOracleUpdated(address(other), 18);
        vm.prank(owner);
        oracle.setCheckOracle(address(other));

        assertEq(oracle.checkOracle(), address(other));
        assertEq(oracle.checkDecimals(), 18);

        // Band is now around 2.00, not 1.00.
        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(1, 0));

        vm.prank(pusher);
        oracle.setPrice(p(2, 0));
        assertEq(oracle.latestAnswer(), p(2, 0));
    }

    function testSetCheckOracleZeroSwitchesCheckingOff() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(5, 0));

        vm.expectEmit(true, false, false, true);
        emit ICheckedOracle.CheckOracleUpdated(address(0), 0);
        vm.prank(owner);
        oracle.setCheckOracle(address(0));

        assertFalse(oracle.checked());
        vm.prank(pusher);
        oracle.setPrice(p(5, 0));
        assertEq(oracle.latestAnswer(), p(5, 0));
    }

    function testSetCheckOracleRejectsDeadFeed() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        RevertingHydraChainlinkOracle dead = new RevertingHydraChainlinkOracle();
        vm.prank(owner);
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        oracle.setCheckOracle(address(dead));

        // The old feed is still the check.
        assertEq(oracle.checkOracle(), address(check));
    }

    function testSetCheckOracleRejectsFeedAnsweringZero() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        MockHydraChainlinkOracle silent = new MockHydraChainlinkOracle();
        vm.prank(owner);
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        oracle.setCheckOracle(address(silent));
    }

    function testSetCheckOracleRejectsFeedAnsweringNegative() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        MockHydraChainlinkOracle negative = new MockHydraChainlinkOracle();
        negative.pushAnswer(-1);
        vm.prank(owner);
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        oracle.setCheckOracle(address(negative));
    }

    function testSetPusherEmitsAndRotates() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.expectEmit(true, true, false, false);
        emit ICheckedOracle.PusherUpdated(pusher, stranger);
        vm.prank(owner);
        oracle.setPusher(stranger);

        vm.prank(pusher);
        vm.expectRevert(ICheckedOracle.NotPriceSetter.selector);
        oracle.setPrice(p(1, 0));

        vm.prank(stranger);
        oracle.setPrice(p(1, 0));
        assertEq(oracle.latestAnswer(), p(1, 0));
    }

    // ---------------------------------------------------------------------
    // decimals handling
    // ---------------------------------------------------------------------

    function testCheckFeedWith18Decimals() public {
        DecimalsHydraChainlinkOracle feed = new DecimalsHydraChainlinkOracle(
            18,
            1e18
        );
        CheckedOracle oracle = _deploy(p(1, 0), 200, address(feed));

        (bool ok, int256 price) = oracle.checkPrice();
        assertTrue(ok);
        assertEq(price, p(1, 0));

        vm.prank(pusher);
        oracle.setPrice(p(1, 1));
        assertEq(oracle.latestAnswer(), p(1, 1));

        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(1, 50));
    }

    function testCheckFeedWith6Decimals() public {
        DecimalsHydraChainlinkOracle feed = new DecimalsHydraChainlinkOracle(
            6,
            1_000_000
        );
        CheckedOracle oracle = _deploy(p(1, 0), 200, address(feed));

        (bool ok, int256 price) = oracle.checkPrice();
        assertTrue(ok);
        assertEq(price, p(1, 0));

        vm.prank(pusher);
        oracle.setPrice(p(1, 1));
        assertEq(oracle.latestAnswer(), p(1, 1));
    }

    function testCheckFeedWithoutDecimalsAssumedEight() public {
        NoDecimalsHydraChainlinkOracle feed = new NoDecimalsHydraChainlinkOracle(
            p(1, 0)
        );
        CheckedOracle oracle = _deploy(p(1, 0), 200, address(feed));

        assertEq(oracle.checkDecimals(), 8);
        (bool ok, int256 price) = oracle.checkPrice();
        assertTrue(ok);
        assertEq(price, p(1, 0));
    }

    function testCheckFeedWithAbsurdDecimalsRejected() public {
        DecimalsHydraChainlinkOracle feed = new DecimalsHydraChainlinkOracle(
            37,
            1
        );
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        _deploy(p(1, 0), 200, address(feed));
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    function testPreviewSetPrice() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        (bool ok, uint256 dev) = oracle.previewSetPrice(p(1, 1));
        assertTrue(ok);
        assertEq(dev, 100);

        (ok, dev) = oracle.previewSetPrice(p(1, 50));
        assertFalse(ok);
        assertEq(dev, 5000);

        (ok, dev) = oracle.previewSetPrice(p(0, 98));
        assertTrue(ok);
        assertEq(dev, 200);

        (ok, dev) = oracle.previewSetPrice(0);
        assertFalse(ok);
        assertEq(dev, 0);
    }

    function testPreviewSetPriceWithDeadFeed() public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);
        _kill(address(check));

        (bool ok, uint256 dev) = oracle.previewSetPrice(p(1, 0));
        assertFalse(ok);
        assertEq(dev, 0);

        (bool hasPrice, int256 price) = oracle.checkPrice();
        assertFalse(hasPrice);
        assertEq(price, 0);
    }

    // ---------------------------------------------------------------------
    // unchecked mode: no check feed set
    // ---------------------------------------------------------------------

    function _deployUnchecked(int256 initialPrice) internal returns (CheckedOracle) {
        return _deploy(initialPrice, 1000, address(0));
    }

    function testUncheckedPusherStoresAnyPositivePrice() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        vm.startPrank(pusher);
        oracle.setPrice(p(10, 0));
        assertEq(oracle.latestAnswer(), p(10, 0));
        oracle.setPrice(1);
        assertEq(oracle.latestAnswer(), 1);
        vm.stopPrank();
        assertEq(oracle.latestRound(), 3);
    }

    function testUncheckedStillRejectsNonPositive() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        vm.startPrank(pusher);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(0);
        vm.expectRevert(ICheckedOracle.InvalidPrice.selector);
        oracle.setPrice(-1);
        vm.stopPrank();
    }

    function testUncheckedStillGatesCallers() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        vm.prank(stranger);
        vm.expectRevert(ICheckedOracle.NotPriceSetter.selector);
        oracle.setPrice(p(1, 0));

        vm.prank(pusher);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPriceUnchecked(p(1, 0));
    }

    function testUncheckedViews() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        assertFalse(oracle.checked());
        (bool hasCheck, int256 checkPx) = oracle.checkPrice();
        assertFalse(hasCheck);
        assertEq(checkPx, 0);

        (bool ok, uint256 dev) = oracle.previewSetPrice(p(7, 0));
        assertTrue(ok);
        assertEq(dev, 0);

        (ok, dev) = oracle.previewSetPrice(0);
        assertFalse(ok);
        assertEq(dev, 0);
    }

    function testUncheckedOwnerPushUncheckedEmitsZeroCheck() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        vm.expectEmit(true, false, false, true);
        emit ICheckedOracle.PriceSetUnchecked(2, p(3, 0), 0);
        vm.prank(owner);
        oracle.setPriceUnchecked(p(3, 0));
        assertEq(oracle.latestAnswer(), p(3, 0));
    }

    function testUncheckedSwitchingCheckOnLater() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        vm.prank(pusher);
        oracle.setPrice(p(1, 5));

        // A check feed appears; enabling it takes effect on the next push.
        check.pushAnswer(p(1, 5));
        vm.expectEmit(true, false, false, true);
        emit ICheckedOracle.CheckOracleUpdated(address(check), 8);
        vm.prank(owner);
        oracle.setCheckOracle(address(check));

        assertTrue(oracle.checked());
        assertEq(oracle.checkDecimals(), 8);

        vm.prank(pusher);
        oracle.setPrice(p(1, 6)); // +0.95%, inside 10%
        assertEq(oracle.latestAnswer(), p(1, 6));

        vm.prank(pusher);
        vm.expectRevert();
        oracle.setPrice(p(2, 0)); // +90%
        assertEq(oracle.latestAnswer(), p(1, 6));

        // and off again
        vm.prank(owner);
        oracle.setCheckOracle(address(0));
        vm.prank(pusher);
        oracle.setPrice(p(2, 0));
        assertEq(oracle.latestAnswer(), p(2, 0));
    }

    function testUncheckedEnablingDeadFeedRefusedStaysUnchecked() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        RevertingHydraChainlinkOracle dead = new RevertingHydraChainlinkOracle();
        vm.prank(owner);
        vm.expectRevert(ICheckedOracle.InvalidFeed.selector);
        oracle.setCheckOracle(address(dead));

        assertFalse(oracle.checked());
        vm.prank(pusher);
        oracle.setPrice(p(9, 0));
        assertEq(oracle.latestAnswer(), p(9, 0));
    }

    function testUncheckedMaxDiffBpsIsInertUntilChecked() public {
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        vm.prank(owner);
        oracle.setMaxDiffBps(0);
        assertEq(oracle.maxDiffBps(), 0);

        vm.prank(pusher);
        oracle.setPrice(p(4, 0));
        assertEq(oracle.latestAnswer(), p(4, 0));
    }

    /// In unchecked mode every positive price is stored verbatim.
    function testFuzzUncheckedStoresVerbatim(uint256 price) public {
        price = bound(price, 1, uint256(type(int256).max));
        CheckedOracle oracle = _deployUnchecked(p(1, 0));

        (bool ok, uint256 dev) = oracle.previewSetPrice(int256(price));
        assertTrue(ok);
        assertEq(dev, 0);

        vm.prank(pusher);
        oracle.setPrice(int256(price));
        assertEq(oracle.latestAnswer(), int256(price));
    }

    // ---------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------

    /// An accepted price is stored verbatim and is within the band; a rejected
    /// one leaves the reported price untouched.
    function testFuzzAcceptanceMatchesBand(
        uint256 checkAnswer,
        uint256 price,
        uint256 maxDiffBps
    ) public {
        checkAnswer = bound(checkAnswer, 1, 1e30);
        price = bound(price, 1, 1e30);
        maxDiffBps = bound(maxDiffBps, 0, 10_000);

        check.pushAnswer(int256(checkAnswer));
        CheckedOracle oracle = _deploy(p(1, 0), maxDiffBps);

        uint256 diff = price > checkAnswer
            ? price - checkAnswer
            : checkAnswer - price;
        bool expected = diff * 10_000 <= maxDiffBps * checkAnswer;

        (bool ok, ) = oracle.previewSetPrice(int256(price));
        assertEq(ok, expected);

        vm.prank(pusher);
        if (expected) {
            oracle.setPrice(int256(price));
            assertEq(oracle.latestAnswer(), int256(price));
        } else {
            vm.expectRevert();
            oracle.setPrice(int256(price));
            assertEq(oracle.latestAnswer(), p(1, 0));
        }
    }

    /// Whatever the pusher tries, the reported price never leaves the band.
    function testFuzzPusherBounded(uint256 price, uint256 maxDiffBps) public {
        price = bound(price, 1, 1e30);
        maxDiffBps = bound(maxDiffBps, 0, 10_000);

        uint256 checkAnswer = uint256(p(1, 0));
        check.pushAnswer(int256(checkAnswer));
        CheckedOracle oracle = _deploy(int256(checkAnswer), maxDiffBps);

        vm.prank(pusher);
        try oracle.setPrice(int256(price)) {} catch {}

        uint256 reported = uint256(oracle.latestAnswer());
        uint256 diff = reported > checkAnswer
            ? reported - checkAnswer
            : checkAnswer - reported;
        assertLe(diff * 10_000, maxDiffBps * checkAnswer);
    }

    /// Only the pusher and the owner can ever move the price.
    function testFuzzOnlyPriceSetters(address caller) public {
        check.pushAnswer(p(1, 0));
        CheckedOracle oracle = _deploy(p(1, 0), 200);

        vm.prank(caller);
        if (caller == pusher || caller == owner) {
            oracle.setPrice(p(1, 1));
            assertEq(oracle.latestAnswer(), p(1, 1));
        } else {
            vm.expectRevert(ICheckedOracle.NotPriceSetter.selector);
            oracle.setPrice(p(1, 1));
            assertEq(oracle.latestAnswer(), p(1, 0));
        }
    }
}
