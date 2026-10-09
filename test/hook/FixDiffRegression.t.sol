// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AutoRangeLib} from "src/shared/planning/AutoRangeLib.sol";
import {AutoLend} from "src/automators/AutoLend.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";

/// @dev Minimal stand-in for the position manager so AutoLend's constructor chain
///      (Swapper -> WETH9()/poolManager()) can run without a fork.
contract MockPositionManager {
    function WETH9() external view returns (address) {
        return address(0x1000000000000000000000000000000000001);
    }

    function poolManager() external view returns (address) {
        return address(0x2000000000000000000000000000000000002);
    }
}

/// @dev Exposes AutoLend's internal zone checks so the regression test can drive the exact
///      execution-time arithmetic sites directly.
contract AutoLendZoneHarness is AutoLend {
    constructor(address positionManager_, address operator_, address feeRecipient_)
        AutoLend(
            IPositionManager(positionManager_),
            address(0x3000000000000000000000000000000000003),
            address(0x4000000000000000000000000000000000004),
            IPermit2(address(0x5000000000000000000000000000000000005)),
            IV4Oracle(address(0x6000000000000000000000000000000000006)),
            operator_,
            feeRecipient_
        )
    {}

    function depositTriggerZone(int24 tickLower, int24 tickUpper, int24 currentTick, int24 lowerZone, int24 upperZone)
        external
        pure
        returns (bool)
    {
        PositionConfig memory config = PositionConfig({
            isActive: true,
            lowerTickZone: lowerZone,
            upperTickZone: upperZone,
            lowerTickZoneWithdraw: 0,
            upperTickZoneWithdraw: 0,
            maxRewardX64: 0
        });
        return _validateDepositTrigger(config, tickLower, tickUpper, currentTick);
    }

    function withdrawTriggerZone(
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        int24 lowerZoneWithdraw,
        int24 upperZoneWithdraw,
        address currency0,
        address lentToken
    ) external pure returns (bool) {
        PositionConfig memory config = PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: lowerZoneWithdraw,
            upperTickZoneWithdraw: upperZoneWithdraw,
            maxRewardX64: 0
        });
        return _validateWithdrawTrigger(config, Currency.wrap(currency0), lentToken, tickLower, tickUpper, currentTick);
    }
}

/// @notice Regression suite for the int24 overflow finding: config fields validated in int256
///         were executed in raw checked int24 arithmetic at AutoRangeLib.plan, AutoRangeLib.isReady
///         and AutoLend's deposit/withdraw zone checks. Every case below panicked with 0x11
///         before the saturating-int256 fix and must now return the clamped/saturated result.
contract FixDiffRegressionTest is Test {
    int24 constant SPACING = 60;
    address constant TOKEN0 = address(0xA11CE);
    address constant TOKEN1 = address(0xB0B);

    AutoLendZoneHarness internal harness;

    function setUp() public {
        harness = new AutoLendZoneHarness(address(new MockPositionManager()), address(this), address(0xFEE1));
    }

    // ==================== AutoRangeLib.plan (AutoRangeLib.sol:50-51) ====================

    /// @dev Pre-fix: `baseTick + 8_388_600` overflowed int24 => panic(0x11) inside plan().
    ///      Post-fix: sum saturates at type(int24).max, then the V4LE-74 clamp bounds the upper
    ///      tick to the pool's usable maximum.
    function test_FixDiff_Plan_ExtremePositiveDeltas_SaturatesInsteadOfPanic() public {
        (int24 newTickLower, int24 newTickUpper) = AutoRangeLib.plan(192_696, SPACING, 8_387_940, 8_388_600);

        assertEq(int256(newTickLower), int256(type(int24).max), "lower delta saturates at int24.max");
        assertEq(int256(newTickUpper), 887_220, "upper clamps to maxUsableTick(60)");
    }

    /// @dev Pre-fix: `-192720 + (-8_388_600)` underflowed int24 => panic(0x11) inside plan().
    function test_FixDiff_Plan_ExtremeNegativeDeltas_SaturatesInsteadOfPanic() public {
        (int24 newTickLower, int24 newTickUpper) = AutoRangeLib.plan(-192_696, SPACING, -8_388_600, -8_387_940);

        assertEq(int256(newTickLower), -887_220, "lower clamps to minUsableTick(60)");
        assertEq(int256(newTickUpper), int256(type(int24).min), "upper delta saturates at int24.min");
    }

    // ==================== AutoRangeLib.isReady (AutoRangeLib.sol:23-32) ====================

    /// @dev Pre-fix: `tickUpper + type(int24).min` underflowed int24 => panic(0x11).
    ///      int256 reference semantics (Scan3LimitOverflow reference test): ready = true.
    function test_FixDiff_IsReady_ExtremeNegativeUpperLimit_ReturnsReady() public {
        assertTrue(AutoRangeLib.isReady(0, -240, -120, 0, type(int24).min), "saturated sentinel: ready");
    }

    /// @dev Pre-fix: `tickLower - type(int24).max` underflowed int24 => panic(0x11).
    ///      int256 semantics: both limits >= 0 inside the band => not ready (false).
    function test_FixDiff_IsReady_ExtremePositiveLowerLimit_ReturnsNotReady() public {
        assertFalse(AutoRangeLib.isReady(0, -120, 120, type(int24).max, 0), "saturated sentinel: not ready");
    }

    /// @dev Pre-fix: `tickLower - type(int24).min` (0 - int24.min = 8_388_608) overflowed int24 => panic(0x11).
    function test_FixDiff_IsReady_ExtremeNegativeLowerLimit_ReturnsReady() public {
        assertTrue(AutoRangeLib.isReady(0, 0, -120, type(int24).min, 0), "saturated sentinel: ready");
    }

    // ==================== AutoLend._validateDepositTrigger (AutoLend.sol:476-477) ====================

    /// @dev Pre-fix: `tickUpper + upperTickZone` (120 + 8_388_607) overflowed int24 => panic(0x11).
    ///      Post-fix: upper bound is 8_388_727 in int256, current tick is far below and inside
    ///      the lower zone => returns isAbove = false, no revert.
    function test_FixDiff_DepositZone_ExtremePositiveUpperZone_SaturatesInsteadOfPanic() public {
        bool isAbove = harness.depositTriggerZone(-240, 120, -887_220, 0, type(int24).max);
        assertFalse(isAbove, "saturated sentinel: not above");
    }

    /// @dev Pre-fix: `tickLower - lowerTickZone` (0 - int24.min) overflowed int24 => panic(0x11).
    ///      Post-fix: lower bound is 8_388_608 in int256, current tick is below it => isAbove false.
    function test_FixDiff_DepositZone_ExtremeNegativeLowerZone_SaturatesInsteadOfPanic() public {
        bool isAbove = harness.depositTriggerZone(0, 120, -887_220, type(int24).min, 0);
        assertFalse(isAbove, "saturated sentinel: not above");
    }

    // ==================== AutoLend._validateWithdrawTrigger (AutoLend.sol:493,496) ====================

    /// @dev Pre-fix: `tickLower - type(int24).max` underflowed int24 => panic(0x11).
    ///      Post-fix: bound is -8_388_847 in int256, current tick is above it => ready (true).
    function test_FixDiff_WithdrawZone_ExtremePositiveLowerZone_SaturatesInsteadOfPanic() public {
        bool isToken0Lent = harness.withdrawTriggerZone(-240, 120, 0, type(int24).max, 0, TOKEN0, TOKEN0);
        assertTrue(isToken0Lent, "saturated sentinel: token0 path ready");
    }

    /// @dev Pre-fix: `tickUpper + type(int24).max` (120 + 8_388_607) overflowed int24 => panic(0x11).
    ///      Post-fix: bound is 8_388_727 in int256, current tick is below it => ready (false side).
    function test_FixDiff_WithdrawZone_ExtremePositiveUpperZone_SaturatesInsteadOfPanic() public {
        bool isToken0Lent = harness.withdrawTriggerZone(-240, 120, 0, 0, type(int24).max, TOKEN0, TOKEN1);
        assertFalse(isToken0Lent, "saturated sentinel: token1 path ready");
    }
}
