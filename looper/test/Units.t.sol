// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Units} from "../src/lib/Units.sol";

contract UnitsTest is Test {
    uint8 internal constant DEC_C = 6;
    uint8 internal constant DEC_D = 18;

    function testFuzz_toBase_should_round_in_the_named_direction_when_converting_either_leg(
        uint128 x,
        uint64 price,
        bool debtLeg
    ) public pure {
        price = uint64(bound(price, 1, 1e14));
        uint8 dec = debtLeg ? DEC_D : DEC_C;
        uint256 down = Units.toBase(x, price, dec, Math.Rounding.Down);
        uint256 up = Units.toBase(x, price, dec, Math.Rounding.Up);
        assertLe(down * 10 ** dec, uint256(x) * price);
        assertGe(up * 10 ** dec, uint256(x) * price);
        assertLe(up - down, 1);
    }

    function testFuzz_fromBase_should_round_in_the_named_direction_when_converting_either_leg(
        uint128 x,
        uint64 price,
        bool debtLeg
    ) public pure {
        price = uint64(bound(price, 1, 1e14));
        uint8 dec = debtLeg ? DEC_D : DEC_C;
        uint256 down = Units.fromBase(x, price, dec, Math.Rounding.Down);
        uint256 up = Units.fromBase(x, price, dec, Math.Rounding.Up);
        assertLe(down * price, uint256(x) * 10 ** dec);
        assertGe(up * price, uint256(x) * 10 ** dec);
        assertLe(up - down, 1);
    }

    function testFuzz_conversions_should_be_monotonic_when_the_amount_grows(uint128 a, uint128 b, uint64 price)
        public
        pure
    {
        price = uint64(bound(price, 1, 1e14));
        (uint256 lo, uint256 hi) = a < b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        assertLe(Units.toBase(lo, price, DEC_D, Math.Rounding.Down), Units.toBase(hi, price, DEC_D, Math.Rounding.Down));
        assertLe(Units.fromBase(lo, price, DEC_C, Math.Rounding.Up), Units.fromBase(hi, price, DEC_C, Math.Rounding.Up));
    }

    /// The collateral leg has fewer decimals than base, so a down/up round trip loses at most one unit.
    function testFuzz_round_trip_should_lose_at_most_one_unit_when_the_token_has_fewer_decimals_than_base(
        uint96 x,
        uint64 price
    ) public pure {
        price = uint64(bound(price, 1e6, 1e14));
        uint256 base = Units.toBase(x, price, DEC_C, Math.Rounding.Down);
        uint256 back = Units.fromBase(base, price, DEC_C, Math.Rounding.Down);
        assertLe(back, x);
        assertLe(x - back, 1);
    }

    /// The debt leg has more decimals than base: the round trip never gains and loses under one base unit.
    function testFuzz_round_trip_should_never_gain_when_the_token_has_more_decimals_than_base(uint128 x, uint64 price)
        public
        pure
    {
        price = uint64(bound(price, 1e6, 1e14));
        uint256 back =
            Units.fromBase(Units.toBase(x, price, DEC_D, Math.Rounding.Down), price, DEC_D, Math.Rounding.Down);
        assertLe(back, x);
        assertLe(Units.toBase(x - back, price, DEC_D, Math.Rounding.Up), 1);
    }

    function test_sat_should_return_zero_when_the_subtrahend_is_larger() public pure {
        assertEq(Units.sat(3, 5), 0);
        assertEq(Units.sat(5, 3), 2);
    }

    function testFuzz_rayToTokens_should_floor_when_converting_a_scaled_delta(uint128 scaled, uint128 index)
        public
        pure
    {
        index = uint128(bound(index, 1e27, 1e29));
        uint256 t = Units.rayToTokens(scaled, index);
        assertLe(t * 1e27, uint256(scaled) * index);
        assertGt((t + 1) * 1e27, uint256(scaled) * index);
    }
}
