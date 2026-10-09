// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AutoRangeLib} from "../../src/shared/planning/AutoRangeLib.sol";

contract Scan3VerifyTest is Test {
    function test_PlanInt24Overflow() public {
        // config that _validateRangeConfig accepts (spacing-aligned, lowerDelta < upperDelta,
        // autoRangeLowerLimit = int24.min sentinel so the first clause is skipped,
        // upperDelta + upperLimit > 0)
        int24 spacing = 100;
        int24 lowerDelta = 8_388_000; // % 100 == 0, < int24.max
        int24 upperDelta = 8_388_600; // % 100 == 0, > lowerDelta, < int24.max
        // fired bucket near tick 700 (a position with tickUpper ~ 600, upperLimit 100)
        (int24 lo, int24 hi) = AutoRangeLib.plan(700, spacing, lowerDelta, upperDelta);
        // silence unused
        lo; hi;
    }

    function test_PlanInt24Underflow() public {
        int24 spacing = 1;
        int24 lowerDelta = -8_388_600;
        int24 upperDelta = -8_300_000;
        (int24 lo, int24 hi) = AutoRangeLib.plan(-800_000, spacing, lowerDelta, upperDelta);
        lo; hi;
    }

    function test_Uint128AbiDecodeTruncatesOrReverts() public {
        bytes memory data = abi.encode((uint256(1) << 128) | 5);
        bool ok;
        uint128 v;
        // solhint-disable-next-line no-empty-blocks
        try this.decodeU128(data) returns (uint128 r) {
            ok = true;
            v = r;
        } catch {
            ok = false;
        }
        // distinguish: truncation => v == 5 ; strict decode => ok == false
        emit log_named_uint("ok(1=reverted-not,0=reverted)", ok ? 1 : 0);
        emit log_named_uint("decoded", v);
        assertTrue(true);
    }

    function decodeU128(bytes memory data) external pure returns (uint128) {
        return abi.decode(data, (uint128));
    }
}
