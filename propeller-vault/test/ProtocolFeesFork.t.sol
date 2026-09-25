// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Harvester} from "../src/Harvester.sol";
import {PropellerFeeController} from "../src/PropellerFeeController.sol";
import {PropellerMainDebt} from "../src/PropellerMainDebt.sol";
import {IAavePool, IPoolAddressesProvider, IAaveOracle} from "../src/interfaces/IAavePool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeSwapper} from "./mocks/MockFeeAttack.sol";

interface IFeeForkPool {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }
    function getReserveData(address asset) external view returns (ReserveData memory);
}

contract FeeForkSource {
    function unwindExecutionCost(address) external pure returns (uint256) { return 0; }
    function emergencyPaused() external pure returns (bool) { return false; }
    address public prime;
    address public harvester;
    address public vault;

    constructor(address token) {
        prime = token;
    }

    function configure(address h, address v) external {
        harvester = h;
        vault = v;
    }

    function totalShares() external pure returns (uint256) {
        return 1;
    }

    function sharesOf(address v) external view returns (uint256) {
        return v == vault ? 1 : 0;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Real forked Aave Pool/aToken supply code, with controlled ERC20
/// collateral, oracle quotes, swap output and source weights. Forge cannot run
/// Hydration's Substrate asset/DEX precompiles: this is NOT a full network E2E test.
contract ProtocolFeesForkTest is Test {
    address constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address constant ETH = 0x0000000000000000000000000000000100000022;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant TREASURY = address(0xFEE);
    uint256 constant GROSS = 1e15;

    MockERC20 collateral;
    MockERC20 prime;
    IERC20 aToken;
    CollateralVault vault;
    Harvester harvester;
    PropellerFeeController fees;

    function setUp() public {
        string memory rpc = vm.envOr("FEE_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 blockNumber = vm.envOr("FEE_FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);

        IFeeForkPool.ReserveData memory reserve = IFeeForkPool(POOL).getReserveData(ETH);
        IFeeForkPool.ReserveData memory hollarReserve = IFeeForkPool(POOL).getReserveData(HOLLAR);
        aToken = IERC20(reserve.aTokenAddress);
        vm.etch(ETH, address(new MockERC20("Fork collateral", "ETH", 18)).code);
        collateral = MockERC20(ETH);
        // Give the controlled underlying enough cash without modifying live Aave code.
        collateral.mint(address(aToken), aToken.totalSupply());
        prime = new MockERC20("PRIME", "PRIME", 6);
        FeeForkSource source = new FeeForkSource(address(prime));
        MockFeeSwapper swapper = new MockFeeSwapper();
        swapper.configure(GROSS, GROSS, 10_000);
        vault = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Fork ETH",
                            "pETH",
                            ETH,
                            POOL,
                            address(source),
                            address(swapper),
                            HOLLAR,
                            address(0),
                            address(aToken),
                            hollarReserve.variableDebtTokenAddress,
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );
        harvester = new Harvester(address(source), address(prime), address(this));
        source.configure(address(harvester), address(vault));
        fees = new PropellerFeeController(address(this), TREASURY);
        PropellerMainDebt buffer = new PropellerMainDebt(address(vault));
        vault.setMainDebt(address(buffer));
        harvester.setFeeController(address(fees));
        harvester.addVault(address(vault));
        vault.setFeeController(address(fees));
        fees.registerVault(address(vault), address(harvester));

        address oracle = IPoolAddressesProvider(IAavePool(POOL).ADDRESSES_PROVIDER()).getPriceOracle();
        vm.mockCall(oracle, abi.encodeCall(IAaveOracle.getAssetPrice, (ETH)), abi.encode(3_000e8));
        vm.mockCall(oracle, abi.encodeCall(IAaveOracle.getAssetPrice, (address(prime))), abi.encode(1e8));
        prime.mint(address(harvester), 3e6);
    }

    function testFork_feeLeavesOnlyNetInRealAave() public {
        _checkRate(500);
    }

    function testFork_zeroFeeSuppliesFullGross() public {
        _checkRate(0);
    }

    function testFork_fullFeeSkipsRealAaveZeroSupply() public {
        _checkRate(10_000);
    }

    function testFork_ledgerNeedsNoSponsoredBalance() public view {
        PropellerMainDebt buffer = PropellerMainDebt(address(vault.mainDebt()));
        assertEq(buffer.ownedCash(), 0);
        assertTrue(buffer.ready());
    }

    function _checkRate(uint16 bps) internal {
        fees.setProtocolFeeBps(address(vault), bps);
        harvester.harvest(new uint256[](0));
        uint256 fee = GROSS * bps / 10_000;
        assertEq(fees.claimableProtocolFees(ETH), fee);
        assertEq(collateral.balanceOf(address(fees)), fee);
        assertApproxEqAbs(aToken.balanceOf(address(vault)), GROSS - fee, 1);
        assertEq(collateral.balanceOf(address(vault)), 0);
        assertEq(aToken.balanceOf(address(fees)), 0);
        vm.prank(address(0xB0B));
        fees.claimProtocolFees(ETH);
        assertEq(collateral.balanceOf(TREASURY), fee);
        assertEq(fees.claimableProtocolFees(ETH), 0);
    }
}
