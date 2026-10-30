// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {OwnedDeployment} from "../deploy/OwnedDeployment.sol";
import {DiscountDeployment, IReservePool} from "../deploy/DiscountDeployment.sol";
import {JuicerDiscount} from "../src/JuicerDiscount.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockDiscountAToken, MockDiscountDebtToken} from "./mocks/MockDiscount.sol";
import {Artifacts} from "./helpers/Artifacts.t.sol";

contract CreatorOwned {
    address public owner;
    uint256 public mapped;

    constructor(uint256 mapped_) {
        owner = msg.sender;
        mapped = mapped_;
    }

    function transferOwnership(address next) external {
        require(msg.sender == owner, "owner");
        owner = next;
    }
}

contract ListingPool {
    mapping(address => address) public aTokens;

    function list(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    function getReserveData(address asset) external view returns (IReservePool.ReserveData memory data) {
        data.aTokenAddress = aTokens[asset];
    }
}

contract LaunchDeploymentTest is Test {
    address constant GOV = address(0xAa7e0000000000000000000000000000000Aa7e0);
    address constant COMMITTEE = address(0xC011);
    address constant DEPLOYER = address(0xD3);

    function test_ownedHandsOverInItsConstructor() public {
        vm.prank(DEPLOYER);
        OwnedDeployment d = new OwnedDeployment(abi.encodePacked(type(CreatorOwned).creationCode, abi.encode(7)), GOV);
        CreatorOwned owned = CreatorOwned(d.deployed());
        assertEq(owned.owner(), GOV);
        assertEq(owned.mapped(), 7);
        assertEq(address(owned), vm.computeCreateAddress(address(d), 1));
        vm.prank(DEPLOYER);
        vm.expectRevert("owner");
        owned.transferOwnership(DEPLOYER);
    }

    function test_ownedRefusesNoOwnerAndFailedCreation() public {
        bytes memory code = abi.encodePacked(type(CreatorOwned).creationCode, abi.encode(7));
        vm.expectRevert(OwnedDeployment.ZeroAddress.selector);
        new OwnedDeployment(code, address(0));
        vm.expectRevert(OwnedDeployment.CreateFailed.selector);
        new OwnedDeployment(hex"60006000fd", GOV);
    }

    function _discountSetup()
        internal
        returns (DiscountDeployment d, ListingPool pool, SyntheticToken synth, MockDiscountDebtToken debt, bytes memory code)
    {
        pool = new ListingPool();
        synth = SyntheticToken(Artifacts.syntheticToken("Synthetic", "jsHOLLAR", GOV));
        debt = new MockDiscountDebtToken(address(pool));
        code = vm.getCode("JuicerDiscount.sol:JuicerDiscount");
        vm.prank(DEPLOYER);
        d = new DiscountDeployment(GOV, address(pool), address(debt), address(synth), COMMITTEE, keccak256(code));
    }

    function test_governanceCreatesTheDiscountOnceTheSyntheticIsListed() public {
        (DiscountDeployment d, ListingPool pool, SyntheticToken synth, MockDiscountDebtToken debt, bytes memory code) =
            _discountSetup();
        vm.prank(GOV);
        vm.expectRevert(DiscountDeployment.NotListed.selector);
        d.deploy(code);

        MockDiscountAToken aSynth = new MockDiscountAToken(address(pool), address(synth));
        pool.list(address(synth), address(aSynth));
        address expected = vm.computeCreateAddress(address(d), 1);
        vm.prank(GOV);
        JuicerDiscount discount = JuicerDiscount(d.deploy(code));
        assertEq(address(discount), expected);
        assertEq(d.discount(), expected);
        assertEq(address(discount.aSynthetic()), address(aSynth));
        assertEq(address(discount.debtToken()), address(debt));
        assertTrue(discount.hasRole(discount.DEFAULT_ADMIN_ROLE(), GOV));
        assertTrue(discount.hasRole(discount.RATE_ADMIN_ROLE(), COMMITTEE));
        assertFalse(discount.hasRole(discount.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertFalse(discount.hasRole(discount.RATE_ADMIN_ROLE(), DEPLOYER));
        assertFalse(discount.hasRole(discount.DEFAULT_ADMIN_ROLE(), address(d)));

        vm.prank(GOV);
        vm.expectRevert(DiscountDeployment.AlreadyDeployed.selector);
        d.deploy(code);
    }

    function test_onlyGovernanceWithThePinnedCode() public {
        (DiscountDeployment d, ListingPool pool, SyntheticToken synth,, bytes memory code) = _discountSetup();
        pool.list(address(synth), address(new MockDiscountAToken(address(pool), address(synth))));
        vm.prank(DEPLOYER);
        vm.expectRevert(DiscountDeployment.Unauthorized.selector);
        d.deploy(code);
        vm.prank(GOV);
        vm.expectRevert(DiscountDeployment.InvalidCode.selector);
        d.deploy(abi.encodePacked(code, hex"00"));
    }
}
