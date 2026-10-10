// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {ParityVault} from "./LeanRuntimeParity.t.sol";
import {HarvestTest} from "../Harvest.t.sol";

contract RescaleCeilIndexAuditTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant D = 1 << 64;

    address constant OLD = address(0xa11ce);
    address constant ACTIVE = address(0xb0b);
    address constant REQUEST_OWNER = address(0xcafe);

    function _map(JuicerYieldAccounting y, uint256 slot, address owner, uint256 value) private {
        vm.store(address(y), keccak256(abi.encode(owner, slot)), bytes32(value));
    }

    function _seed(uint256 total, uint256 index, uint256 sourceShares, uint256 held, uint256 equity)
        private
        returns (JuicerYieldAccounting y, ParityVault v)
    {
        v = new ParityVault();
        y = new JuicerYieldAccounting(address(v));
        uint256[] memory input = new uint256[](14);
        input[6] = held;
        input[7] = equity;
        v.configure(input);
        vm.store(address(y), bytes32(uint256(0)), bytes32(sourceShares));
        vm.store(address(y), bytes32(uint256(2)), bytes32(total));
        vm.store(address(y), bytes32(uint256(3)), bytes32(index));
    }

    function _allocate(JuicerYieldAccounting y, ParityVault v) private {
        vm.prank(address(v));
        y.checkpoint(address(0), address(0));
    }

    function test_ceilShiftCoversAccountsAndWaitingRequests() public {
        (JuicerYieldAccounting y, ParityVault v) = _seed(D + 1, D, 2, 2e38, 2e38);
        v.mint(ACTIVE, RAY);
        v.mint(address(v), RAY);

        _map(y, 4, OLD, D);
        _map(y, 5, OLD, D);
        _map(y, 5, ACTIVE, D);
        _map(y, 6, address(1), D - 1);

        uint256 initialRequest = RAY * (y.rewardIndex() - y.requestIndex(1)) / RAY;
        assertEq(y.balanceOf(OLD) + y.balanceOf(ACTIVE) + initialRequest, y.totalUnits());

        _allocate(y, v);
        assertEq(y.unitScale(), 64);

        uint256 shift = y.unitScale() - y.requestScale(1);
        uint256 floorPrevious = y.requestIndex(1) >> shift;
        uint256 ceilPrevious = floorPrevious;
        if ((floorPrevious << shift) != y.requestIndex(1)) ++ceilPrevious;
        uint256 requestClaim = (y.requestUnits(1) >> shift) + RAY * (y.rewardIndex() - ceilPrevious) / RAY;
        uint256 accountClaims = y.balanceOf(OLD) + y.balanceOf(ACTIVE);
        assertEq(accountClaims + requestClaim, y.totalUnits(), "ceil-shifted requests close the remaining excess");

        vm.prank(address(v));
        y.startExit(1, REQUEST_OWNER, RAY);
        assertEq(
            y.balanceOf(OLD) + y.balanceOf(ACTIVE), y.totalUnits(), "starting the request preserves the aggregate bound"
        );
    }

    function test_fourShiftAllocationKeepsCeilShiftDefined() public {
        uint256 held = uint256(1) << 250;
        (JuicerYieldAccounting y, ParityVault v) = _seed(type(uint256).max, 1, 1, held, held + 1e10);
        v.mint(ACTIVE, RAY);
        _map(y, 5, ACTIVE, 1);

        _allocate(y, v);
        assertEq(y.unitScale(), 256, "allocation exercised four 64-bit shifts");
        assertGt(y.totalUnits(), 0, "allocation reminted units after the shifts");

        assertLe(y.balanceOf(ACTIVE), y.totalUnits());
    }
}

contract RescaleCeilIndexPublicAuditTest is HarvestTest {
    address constant REQUESTOR = address(0xcafe);
    uint256 constant RAY = 1e27;

    function _setPrime(uint256 amount) private {
        uint256 before_ = aPrime.balanceOf(address(loop));
        if (amount > before_) aPrime.mint(address(loop), amount - before_);
        else aPrime.burn(address(loop), before_ - amount);
    }

    function _cycle(JuicerYieldAccounting y, uint256 high) private {
        uint256 target = y.requiredSourceBacking() + 1e13;
        uint256 lo;
        uint256 hi = high;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            _setPrime(mid);
            if (loop.equityOf(address(vault)) * 1e10 < target) lo = mid + 1;
            else hi = mid;
        }
        _setPrime(lo);
        vault.sync();
        assertGt(y.totalAssets(), 0);
        _setPrime(high);
        vault.sync();
    }

    function test_publicControlledCyclesKeepCeilShiftDefined() public {
        _depositAndRamp();
        JuicerYieldAccounting y = vault.yieldAccounting();
        uint256 high = aPrime.balanceOf(address(loop)) * 105 / 100;
        _setPrime(high);
        vault.sync();

        vault.transfer(address(this), 1);
        assertGt(y.accountIndex(address(this)), 0);
        uint256 rounds;
        while (rounds < 40 && y.unitScale() < 256) {
            _cycle(y, high);
            ++rounds;
        }

        emit log_named_uint("rounds", rounds);
        emit log_named_uint("unit scale", y.unitScale());
        assertGe(y.unitScale(), 256, "controlled public fixture reached four cumulative shifts");
        assertLe(y.balanceOf(address(this)), y.totalUnits());
    }

    function test_publicWaitingRequestUsesCeilShift() public {
        vault.setTvlCap(type(uint256).max);
        eth.mint(address(this), RAY);
        eth.approve(address(vault), RAY);
        vault.deposit(RAY, address(this));
        eth.mint(REQUESTOR, RAY);
        vm.startPrank(REQUESTOR);
        eth.approve(address(vault), RAY);
        vault.deposit(RAY, REQUESTOR);
        vm.stopPrank();
        vault.rebalance();
        for (uint256 i; i < 40; ++i) {
            loop.pokeBorrow();
        }

        JuicerYieldAccounting y = vault.yieldAccounting();
        uint256 high = aPrime.balanceOf(address(loop)) * 105 / 100;
        _setPrime(high);
        vault.sync();
        vm.prank(REQUESTOR);
        uint256 requestId = vault.requestRedeem(RAY, REQUESTOR);
        assertEq(vault.walletOf(REQUESTOR), 0);

        for (uint256 round; round < 20 && y.unitScale() == 0; ++round) {
            _cycle(y, high);
        }
        assertEq(y.unitScale(), 64);

        uint256 shift = y.unitScale() - y.requestScale(requestId);
        uint256 floorPrevious = y.requestIndex(requestId) >> shift;
        uint256 ceilPrevious = floorPrevious;
        if ((floorPrevious << shift) != y.requestIndex(requestId)) ++ceilPrevious;
        assertEq(ceilPrevious, floorPrevious + 1, "request index has a shifted remainder");
        uint256 ceilClaim = (y.requestUnits(requestId) >> shift) + RAY * (y.rewardIndex() - ceilPrevious) / RAY;

        uint256 ownerClaim = y.balanceOf(REQUESTOR);
        uint256 totalBefore = y.totalUnits();
        vm.warp(vm.getBlockTimestamp() + vault.withdrawalDelay());
        vault.startUnwinds(1);
        assertEq(y.totalUnits(), totalBefore - ownerClaim - ceilClaim, "start burns the ceil-shifted request claim");
    }
}
