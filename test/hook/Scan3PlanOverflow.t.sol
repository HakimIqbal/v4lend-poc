// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";

import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";

/// @notice Scan-3 candidate: AutoRangeLib.plan uses raw checked int24 addition while config
///         validation only checks tick-spacing alignment (no magnitude bound) and evaluates the
///         same-position condition in int256. An accepted extreme delta therefore panics with
///         0x11 at execution time, after the dispatch already removed the position's triggers
///         (removal runs outside the action's catch), leaving the automation silently dead
///         until the owner reconfigures.
contract Scan3PlanOverflowTest is RevertHookTest {
    function testScan3_AcceptedExtremeDeltaConsumesTriggerAndKillsAutoRange() public {
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        int24 spacing = poolKey.tickSpacing; // 60
        // spacing-aligned, lowerDelta < upperDelta, both below int24.max => passes
        // _isValidTickConfig(delta, spacing, 0) and the int256 clauses of _validateRangeConfig.
        // baseTick + 8_388_600 overflows int24 for any baseTick >= 8.
        int24 lowerDelta = 8_387_940; // % 60 == 0
        int24 upperDelta = 8_388_600; // % 60 == 0

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: type(int24).min, // lower trigger disabled
                autoRangeUpperLimit: 0, // fires at tickUpper => reachable trigger
                autoRangeLowerDelta: lowerDelta,
                autoRangeUpperDelta: upperDelta,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Config accepted: the range trigger is armed at tickUpper.
        (, uint32 upperSize, int24 upperHead) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperSize, 1, "extreme-delta config armed");
        assertEq(upperHead, tickUpper3, "trigger sits at tickUpper");

        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);

        // Cross the trigger: dispatch removes triggers (outside catch), then AutoRangeLib.plan
        // panics inside the caught action => HookActionFailed, position untouched, no triggers left.
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(
            _sawIndexedTokenEvent(logs, RevertHookState.HookActionFailed.selector, token3Id),
            "accepted config fails at execution"
        );

        // Failure side effects: liquidity untouched, triggers consumed, config still set
        // (automation silently dead until reconfigure).
        assertEq(positionManager.getPositionLiquidity(token3Id), liquidityBefore, "position untouched");
        (, uint32 upperSizeAfter,) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperSizeAfter, 0, "triggers consumed before the failed action");
        (uint8 modeFlags,,,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_RANGE, "config remains armed-but-dead");
    }
}
