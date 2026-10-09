// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";

/// @notice Scan-3 finding F-8: negative autoRange LIMITS are accepted by _validateRangeConfig.
/// The V4LE-131 fix rejected a negative autoLend tolerance because it armed thresholds INSIDE
/// the LP range; the autoRange limits got no sign check. A negative limit inverts the margin:
///   rangeLower = positionTickLower - autoRangeLowerLimit  (= posLower + |limit| -> inside)
///   rangeUpper = positionTickUpper + autoRangeUpperLimit  (= posUpper - |limit| -> inside)
/// On this harness (2-bucket positions, live price at the interior bucket) both inverted
/// triggers are already satisfied at configuration time, so setPositionConfig immediately
/// executes a full AUTO_RANGE rebalance inside the config call - liquidity drained and
/// reminted before the caller gets control back.
contract Scan3NegRangeLimitTest is RevertHookTest {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    function _negativeLimitConfig(int24 spacing) internal pure returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: false,
            autoExitSwapOnUpperTrigger: false,
            autoRangeLowerLimit: -spacing, // negative margin -> trigger lands on the interior bucket
            autoRangeUpperLimit: -spacing, // negative margin -> trigger lands on the interior bucket
            autoRangeLowerDelta: -137 * spacing, // upperDelta - lowerDelta != position width (V4LE-16 gate)
            autoRangeUpperDelta: 137 * spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
    }

    /// @notice GATE 1: a negative autoRange limit must be refused like the V4LE-131 negative
    /// tolerance, but _validateRangeConfig accepts it (the V4LE-16 clause only rejects
    /// lowerDelta >= lowerLimit, which holds when BOTH are negative and delta < limit).
    function test_Scan3_NegativeAutoRangeLimitsAccepted() public {
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        // no revert: the config is stored and the inverted triggers execute immediately
        hook.setPositionConfig(token3Id, _negativeLimitConfig(poolKey.tickSpacing));

        // EFFECT: the already-satisfied inverted band drained and reminted the position
        // inside the config call itself (no swap happened in this test)
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "position drained at config time");
        uint256 replacementId = positionManager.nextTokenId() - 1;
        assertTrue(replacementId != token3Id, "replacement exists");
        assertGt(positionManager.getPositionLiquidity(replacementId), 0, "replacement minted at config time");

        // the old token's config was cleared by the migration, the replacement carries it
        (uint8 oldFlags,,,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(oldFlags, 0, "old config cleared by immediate remint");
        (uint8 newFlags,,,,,,,,,,,,) = hook.positionConfigs(replacementId);
        assertEq(newFlags, PositionModeFlags.MODE_AUTO_RANGE, "replacement still configured for autoRange");
    }

    /// @notice GATE 2: armed heads of the replacement sit where the inverted limits put them:
    /// strictly inside the replacement's own band edges +/- the (negative) limit, proving the
    /// direction inversion rather than an arithmetic accident.
    function test_Scan3_NegativeLimit_TriggerMathInverted() public {
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        int24 spacing = poolKey.tickSpacing;
        hook.setPositionConfig(token3Id, _negativeLimitConfig(spacing));

        uint256 replacementId = positionManager.nextTokenId() - 1;
        (, PositionInfo info) = positionManager.getPoolAndPositionInfo(replacementId);

        // with a POSITIVE limit the triggers sit OUTSIDE [tickLower, tickUpper];
        // with the negative limits they must sit INSIDE
        (, uint32 lowerSize, int24 lowerHead) = hook.lowerTriggerAfterSwap(poolId);
        (, uint32 upperSize, int24 upperHead) = hook.upperTriggerAfterSwap(poolId);
        assertGt(lowerSize, 0, "lower trigger armed");
        assertGt(upperSize, 0, "upper trigger armed");

        // expected armed values from the stored negative limits
        RevertHookState.PositionConfig memory stored = _storedConfig(replacementId);
        assertLt(stored.autoRangeLowerLimit, 0, "lower limit stored negative");
        assertLt(stored.autoRangeUpperLimit, 0, "upper limit stored negative");
        int24 rLower = info.tickLower();
        int24 rUpper = info.tickUpper();
        int24 expectedLower = int24(int256(rLower) - int256(stored.autoRangeLowerLimit));
        int24 expectedUpper = int24(int256(rUpper) + int256(stored.autoRangeUpperLimit));
        assertEq(lowerHead, expectedLower, "lower head = posLower - negativeLimit = INSIDE");
        assertEq(upperHead, expectedUpper, "upper head = posUpper + negativeLimit = INSIDE");
        assertTrue(lowerHead > rLower && lowerHead < rUpper, "lower trigger inside the range");
        assertTrue(upperHead > rLower && upperHead < rUpper, "upper trigger inside the range");
    }

    /// @notice F-9: negative RELATIVE autoExit offsets are accepted (pure AUTO_EXIT configs skip
    /// _validateRangeConfig entirely - it early-returns without MODE_AUTO_RANGE - and the sign
    /// check exists only for the autoLend tolerance, V4LE-131). The relative exit tick is
    ///   exitLower = positionTickLower - autoExitTickLower
    /// so a negative offset puts the EXIT trigger INSIDE the range: a fresh config whose exit
    /// band is already satisfied executes a full AUTO_RANGE... full EXIT inside setPositionConfig
    /// although the position never left its range.
    function test_Scan3_NegativeRelativeExitOffsetAccepted_ImmediateExit() public {
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        int24 spacing = poolKey.tickSpacing;
        assertTrue(positionManager.getPositionLiquidity(token3Id) > 0, "precondition: live");

        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: true,
            autoExitTickLower: -spacing, // NEGATIVE relative offset: lands on the interior bucket
            autoExitTickUpper: type(int24).max, // upper side disabled
            autoExitSwapOnLowerTrigger: false,
            autoExitSwapOnUpperTrigger: false,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        // GATE: must revert InvalidConfig (sign check like V4LE-131) but is accepted
        hook.setPositionConfig(token3Id, config);

        // EFFECT: the inverted relative exit trigger sits at posLower - (-spacing) = interior
        // bucket = live price -> already satisfied -> immediate full exit inside the config call
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "position exited at config time while in-range");
        (, int24 tickNow,,) = poolManager.getSlot0(poolId);
        assertTrue(tickNow >= tickLower3 && tickNow <= tickUpper3, "price never left the range");
    }

    function _storedConfig(uint256 tokenId) internal view returns (RevertHookState.PositionConfig memory c) {
        uint8 modeFlags;
        RevertHookState.AutoCollectMode acm;
        bool rel;
        bool exSL;
        bool exSU;
        int24 exL;
        int24 exU;
        int24 loLim;
        int24 upLim;
        int24 loDelta;
        int24 upDelta;
        int24 tol;
        uint16 bps;
        (modeFlags, acm, rel, exSL, exSU, exL, exU, loLim, upLim, loDelta, upDelta, tol, bps) =
            hook.positionConfigs(tokenId);
        c = RevertHookState.PositionConfig({
            modeFlags: modeFlags,
            autoCollectMode: acm,
            autoExitIsRelative: rel,
            autoExitTickLower: exL,
            autoExitTickUpper: exU,
            autoExitSwapOnLowerTrigger: exSL,
            autoExitSwapOnUpperTrigger: exSU,
            autoRangeLowerLimit: loLim,
            autoRangeUpperLimit: upLim,
            autoRangeLowerDelta: loDelta,
            autoRangeUpperDelta: upDelta,
            autoLendToleranceTick: tol,
            autoLeverageTargetBps: bps
        });
    }
}
