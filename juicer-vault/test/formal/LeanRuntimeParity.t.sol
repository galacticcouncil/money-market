// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {JuicerYieldAccounting} from "../../src/JuicerYieldAccounting.sol";
import {SyntheticFloor} from "../../src/lib/CompoundLogic.sol";
import {SubLoopLogic, SubLoopStorage} from "../../src/lib/SubLoopLogic.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ParityVault is MockERC20 {
    address public yieldSource = address(this);
    address public mainDebt = address(this);
    address public feeController = address(this);
    uint256 public totalQueuedShares;
    uint256 public held;
    uint256 public equity;
    uint256 public required;
    uint256 public fundedValue;
    uint256 public basis;
    uint256 public fee;
    bool customFunding;
    uint256 fundingDebt;
    uint256 fundingPrincipal;
    uint256 fundingCash;

    constructor() MockERC20("parity", "p", 18) {}
    function configure(uint256[] memory r) external {
        held = r[6]; equity = r[7]; required = r[8]; fundedValue = r[11]; basis = r[12]; fee = r[13];
    }
    function walletOf(address a) external view returns (uint256) { return balanceOf(a); }
    function convertToAssets(uint256 a) external pure returns (uint256) { return a; }
    function quoteHollar(uint256) external view returns (uint256) { return fundedValue; }
    function activePosition() external view returns (uint256, uint256, uint256) {
        if (customFunding) return (fundingDebt, fundingPrincipal, 0);
        uint256 debt = required == 0 ? 0 : required - 2e10;
        return (debt, debt, 0);
    }
    function activeFunds() external view returns (uint256) { return fundingCash; }
    function configureFunding(uint256 debt, uint256 principal, uint256 cash, uint256 fee_) external {
        customFunding = true; fundingDebt = debt; fundingPrincipal = principal; fundingCash = cash; fee = fee_;
    }
    function pendingSourceAccounting() external pure returns (bool) { return false; }
    function accountingLocked() external pure returns (bool) { return false; }
    function sharesOf(address) external view returns (uint256) { return held; }
    function equityOf(address) external view returns (uint256) { return equity / 1e10; }
    function principalOf(address) external view returns (uint256) { return basis; }
    function releasePrincipal(address, uint256 value) external { basis -= value; }
    function protocolFeeBps(address) external view returns (uint256) { return fee; }
}

contract ParityPool {
    uint256 coll;
    uint256 debt;
    uint256 lt;
    uint256 hf;
    uint256 price;
    function configure(uint256[] memory r) external { price = r[8]; coll = r[9]; debt = r[10]; lt = r[11]; hf = r[12]; }
    function ADDRESSES_PROVIDER() external view returns (address) { return address(this); }
    function getPriceOracle() external view returns (address) { return address(this); }
    function getAssetPrice(address) external view returns (uint256) { return price; }
    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (coll, debt, 0, lt, 0, hf);
    }
    function setUserUseReserveAsCollateral(address, bool) external {}
}

contract ParityLoop is SubLoopLogic {
    function seed(uint256[] memory r, address pool_, address hollar_, address prime_) external {
        pool = IAavePool(pool_); hollar = IERC20(hollar_); prime = IERC20(prime_); primeAToken = IERC20(prime_);
        pendingIntent = PendingIntent(uint64(r[1]), 0, uint8(r[0]), false, uint128(r[2]), uint128(r[3]),
            0, uint128(r[4]), uint128(r[5]));
        intentNonce = uint64(r[1]);
        if (r.length > 13) reservedFreed = r[13];
        targetHf = 1.05e18; deLeverTrigger = 1.10e18;
    }
    function setLastNonce(uint64 n) external { intentNonce = n; }
    function observed() external view returns (uint8, uint256) { return _outcome(pendingIntent); }
    function flight() external view returns (uint8, uint256) { return _inFlight8(); }
    function effective() external view returns (uint256, uint256, uint256, uint256) { return _effectiveAccount(); }
    function equity() external view returns (uint256) { return _totalEquity(); }
    function pendingKind() external view returns (uint8) { return pendingIntent.kind; }
}

contract LeanRuntimeParityTest is Test {
    using stdJson for string;
    string vectors;
    address constant OWNER = address(0xa11ce);
    address constant RECEIVER = address(0xb0b);

    function setUp() public { vectors = vm.readFile("formal/runtime-vectors.json"); }

    function _row(string memory key, uint256 i) internal view returns (uint256[] memory) {
        return vectors.readUintArray(string.concat(".", key, "[", vm.toString(i), "]"));
    }
    function _count(string memory key) internal view returns (uint256) {
        return vectors.readUint(string.concat(".", key, "Count"));
    }
    function _store(JuicerYieldAccounting y, uint256 slot, uint256 value) internal {
        vm.store(address(y), bytes32(slot), bytes32(value));
    }
    function _map(JuicerYieldAccounting y, uint256 slot, uint256 key, uint256 value) internal {
        vm.store(address(y), keccak256(abi.encode(key, slot)), bytes32(value));
    }
    function _book(JuicerYieldAccounting y, uint256[] memory r) internal {
        _store(y, 0, r[0]); _store(y, 1, r[1]); _store(y, 2, r[2]); _store(y, 3, r[3]);
        _store(y, 10, r[4]); _store(y, 13, r[5]);
    }
    // slots are checked against forge's storage layout by formal/check-runtime.py.
    function _account(JuicerYieldAccounting y, uint256[] memory r, uint256 offset) internal {
        uint256 key = uint160(OWNER);
        _map(y, 4, key, r[offset]); _map(y, 5, key, r[offset + 1]);
        _map(y, 11, key, r[offset + 2]); _map(y, 14, key, r[offset + 3]);
    }
    function _assertBook(JuicerYieldAccounting y, uint256[] memory r, uint256 offset) internal view {
        assertEq(y.sourceShares(), r[offset], "source"); assertEq(y.protocolShares(), r[offset + 1], "protocol");
        assertEq(y.totalUnits(), r[offset + 2], "total"); assertEq(y.rewardIndex(), r[offset + 3], "index");
        assertEq(y.epoch(), r[offset + 4], "epoch"); assertEq(y.unitScale(), r[offset + 5], "scale");
    }

    function test_leanSyntheticFloor() public view {
        for (uint256 i; i < _count("peg"); ++i) {
            uint256[] memory r = _row("peg", i);
            assertEq(SyntheticFloor.buffered(r[0], r[1]), r[2]);
            assertGe(r[2] * r[1] / 10000, r[0]);
        }
    }

    function test_leanTake() public {
        for (uint256 i; i < _count("take"); ++i) {
            uint256[] memory r = _row("take", i);
            ParityVault v = new ParityVault();
            JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
            v.mint(address(y), r[0]); _store(y, 2, r[1]); _map(y, 4, uint160(OWNER), r[2]);
            vm.prank(address(v));
            if (r[4] == 0) { vm.expectRevert(); y.settle(OWNER, RECEIVER, r[3]); }
            else {
                y.settle(OWNER, RECEIVER, r[3]);
                assertEq(y.balanceOf(RECEIVER), r[5], "taken"); assertEq(y.balanceOf(OWNER), r[6], "left");
                assertEq(y.totalUnits(), r[1], "total unchanged");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_leanTransferDisplayBounds(uint128 fSeed, uint96 tSeed, uint96 uSeed, uint128 sSeed) public {
        uint256 t = bound(tSeed, 1, type(uint96).max);
        uint256 f = bound(fSeed, t, type(uint128).max);
        uint256 u = bound(uSeed, 1, t);
        uint256 vUnits = (t - u) / 2;
        uint256 slice = f * u / t;
        uint256 shares = bound(sSeed, 1, slice);
        ParityVault v = new ParityVault(); JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
        v.mint(address(y), f); _store(y, 2, t);
        _map(y, 4, uint160(OWNER), u); _map(y, 4, uint160(RECEIVER), vUnits);
        uint256 recipientBefore = y.fundedOf(RECEIVER);
        vm.prank(address(v)); y.settle(OWNER, RECEIVER, shares);
        uint256 moved = u - y.balanceOf(OWNER);
        uint256 debit = slice - y.fundedOf(OWNER);
        uint256 credit = y.fundedOf(RECEIVER) - recipientBefore;
        uint256 lower = f * moved / t;
        uint256 upper = (f * moved + t - 1) / t;
        assertGe(debit, lower); assertLe(debit, upper);
        assertGe(credit, lower); assertLe(credit, upper);
        assertLe(debit, credit + 1); assertLe(credit, debit + 1);
        assertEq(y.balanceOf(OWNER) + y.balanceOf(RECEIVER), u + vUnits);
        assertEq(y.totalUnits(), t);
    }

    function test_leanAccountEpochAndRescale() public {
        for (uint256 i; i < _count("accounts"); ++i) {
            uint256[] memory r = _row("accounts", i);
            ParityVault v = new ParityVault(); JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
            _book(y, r); _account(y, r, 6); v.mint(OWNER, r[10]);
            assertEq(y.balanceOf(OWNER), r[11]);
            vm.prank(address(v)); y.settle(OWNER, RECEIVER, 0);
            assertEq(y.balanceOf(OWNER), r[11], "settle preserves view");
            assertEq(y.accountIndex(OWNER), y.rewardIndex());
            assertEq(y.accountEpoch(OWNER), y.epoch()); assertEq(y.accountScale(OWNER), y.unitScale());
        }
    }

    function test_leanAllocationWriteOffAndRescale() public {
        for (uint256 i; i < _count("allocations"); ++i) {
            uint256[] memory r = _row("allocations", i);
            ParityVault v = new ParityVault(); JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
            v.configure(r); _book(y, r);
            v.mint(address(y), r[10]); v.mint(OWNER, r[9] - r[10]);
            vm.prank(address(v)); y.checkpoint(address(0), address(0));
            _assertBook(y, r, 14);
        }
    }

    function test_leanExitFold() public {
        for (uint256 i; i < _count("exits"); ++i) {
            uint256[] memory r = _row("exits", i);
            ParityVault v = new ParityVault(); JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
            _book(y, r); _account(y, r, 6);
            _map(y, 16, 1, r[10]); _map(y, 6, 1, r[11]); _map(y, 12, 1, r[12]); _map(y, 15, 1, r[13]);
            v.mint(OWNER, r[14]); v.mint(address(y), r[16]);
            vm.prank(address(v));
            (uint256 reward, uint256 fee, uint256 folded) = y.startExit(1, OWNER, r[15]);
            _assertBook(y, r, 17);
            // the private stored units are compared before the public view's total cap.
            assertEq(uint256(vm.load(address(y), keccak256(abi.encode(uint256(uint160(OWNER)), uint256(4))))), r[23]);
            assertEq(reward, r[24]); assertEq(fee, r[25]); assertEq(folded, r[26]);
            assertEq(v.balanceOf(address(v)), folded); assertEq(v.balanceOf(address(y)), r[16] - folded);
            assertEq(y.requestUnits(1), 0); assertEq(y.requestIndex(1), 0);
            assertEq(y.requestEpoch(1), 0); assertEq(y.requestScale(1), 0);
        }
    }

    function test_leanIceViewsAndDelever() public {
        for (uint256 i; i < _count("ice"); ++i) {
            uint256[] memory r = _row("ice", i);
            MockERC20 h = new MockERC20("h", "h", 18); MockERC20 p = new MockERC20("p", "p", 6);
            ParityPool pool = new ParityPool(); pool.configure(r);
            ParityLoop loop = new ParityLoop(); loop.seed(r, address(pool), address(h), address(p));
            h.mint(address(loop), r[0] == 1 ? r[6] : r[7]); p.mint(address(loop), r[0] == 1 ? r[7] : r[6]);
            (uint8 observed, uint256 output) = loop.observed(); assertEq(observed, r[14]); assertEq(output, r[15]);
            (uint8 kind, uint256 value) = loop.flight(); assertEq(kind, r[16]); assertEq(value, r[17]);
            (uint256 coll, uint256 debt,, uint256 hf) = loop.effective();
            assertEq(coll, r[18]); assertEq(debt, r[19]); assertEq(hf, r[20]); assertEq(loop.equity(), r[21]);
            if (r[22] == 0) { vm.expectRevert(); loop.deLever(); }
            else { loop.deLever(); assertEq(loop.deleverDebtTarget(), r[23]); }
        }
    }

    function test_leanCallbackGuards() public {
        for (uint256 i; i < _count("callbacks"); ++i) {
            uint256[] memory r = _row("callbacks", i);
            MockERC20 h = new MockERC20("h", "h", 18); MockERC20 p = new MockERC20("p", "p", 6);
            ParityLoop loop = new ParityLoop(); loop.seed(r, address(new ParityPool()), address(h), address(p));
            loop.setLastNonce(uint64(r[6]));
            address caller = r[10] == 1 ? address(loop) : address(this);
            vm.prank(caller);
            (bool ok,) = address(loop).call(abi.encodeCall(SubLoopLogic.execute,
                (caller, 0, address(0), 0, r[11] == 1 ? address(p) : address(h), r[9], abi.encode(uint8(r[8]), uint64(r[7])))));
            assertEq(ok, r[12] != 0);
            assertEq(loop.pendingKind(), r[12] == 2 ? 0 : r[0]);
        }
    }

    function test_leanRequiredBacking() public {
        ParityVault v = new ParityVault(); JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
        for (uint256 i; i < _count("funding"); ++i) {
            uint256[] memory r = _row("funding", i);
            v.configureFunding(r[0], r[1], r[2], r[3]);
            assertEq(y.requiredSourceBacking(), r[4]);
        }
    }

    function test_leanHarvestSplit() public {
        ParityVault v = new ParityVault(); JuicerYieldAccounting y = new JuicerYieldAccounting(address(v));
        for (uint256 i; i < _count("harvest"); ++i) {
            uint256[] memory r = _row("harvest", i);
            v.configureFunding(0, 0, 0, r[4]);
            _store(y, 7, r[1]); _store(y, 8, r[2]); _store(y, 9, r[3]);
            vm.prank(address(v)); (uint256 reward, uint256 service, uint256 fee) = y.splitHarvest(r[0]);
            assertEq(reward, r[5]); assertEq(service, r[6]); assertEq(fee, r[7]);
            assertEq(reward + service + fee, r[0]);
            assertEq(y.harvestUnits(), 0); assertEq(y.harvestRewardUnits(), 0); assertEq(y.harvestProtocolUnits(), 0);
        }
    }
}
