// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {stdError} from "forge-std/StdError.sol";

import {AutoRange} from "../../src/automators/AutoRange.sol";
import {AutoLend} from "../../src/automators/AutoLend.sol";
import {AutoRangeLib} from "../../src/shared/planning/AutoRangeLib.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

/// @title Scan3LimitOverflow — sibling of F-1 / V4LE-130 missed by the fix
///
/// V4LE-130 moved the HOOK-side trigger math to saturating int256
/// (`_computeTriggerTicksCore`, `_calculateRangeTriggerTicks`, `_calculateExitTick`), but the
/// STANDALONE readiness checks still perform raw checked int24 arithmetic on owner-configured
/// limits/zones:
///   - `AutoRangeLib.isReady`:  `tickLower - lowerTickLimit`, `tickUpper + upperTickLimit`
///   - `AutoLend._validateDepositTrigger`:  `tickUpper + upperTickZone`, `tickLower - lowerTickZone`
///   - `AutoLend._validateWithdrawTrigger`: `tickLower - lowerTickZoneWithdraw`, `tickUpper + upperTickZoneWithdraw`
///
/// Config validation only bounds these fields to "fits in int24" (AutoRange) or "not negative"
/// (AutoLend) — the same validation/execution type disagreement F-1 documents for `plan()`.
/// Result: config accepted at setup, every execution attempt panics (0x11) instead of running.
/// On the hook side the identical config is handled by saturating int256 math (V4LE-130), so
/// the same platform behaves differently for the same numbers.
contract Scan3LimitOverflowTest is AutomatorTestBase {
    AutoRange public autoRange;
    AutoLend public autoLend;

    function setUp() public override {
        super.setUp();

        autoRange =
            new AutoRange(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);
        autoRange.setVault(address(vault));
        vault.setTransformer(address(autoRange), true);

        autoLend =
            new AutoLend(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);
        autoLend.setVault(address(vault));
    }

    // ==================== unit: direct library panic sites ====================

    /// @dev Pure overflow proof for the negative-limit (mean-reversion) branch. The intended
    ///      int256 evaluation makes condition 2 false, so isReady returns TRUE (ready); the
    ///      int24 addition underflows first and panics. Reference proof in the next test.
    function test_Unit_IsReady_NegativeUpperLimit_PanicsInsteadOfReady() public {
        // Actual int24 execution panics before any comparison:
        vm.expectRevert(stdError.arithmeticError);
        this.isReadyWrapper(0, -240, -120, 0, type(int24).min);
    }

    /// @dev Positive-limit overflow: `tickLower - lowerTickLimit` underflows int24.
    function test_Unit_IsReady_PositiveLowerLimit_Panics() public {
        vm.expectRevert(stdError.arithmeticError);
        this.isReadyWrapper(0, -120, 120, type(int24).max, 0);
    }

    /// @dev Reference semantics computed in int256 — documents what the function WOULD do
    ///      without the int24 overflow (ready = true for the negative-limit case).
    function test_Unit_ReferenceInt256SaysReady() public {
        int256 tickUpper = -120;
        int256 upperTickLimit = int256(int24(type(int24).min));
        int256 currentTick = 0;
        // condition1: lowerTickLimit == 0 -> true
        // condition2: currentTick <= tickUpper + upperTickLimit = -8388728 -> false
        // whole if false -> return true
        bool wouldBeReady = !(currentTick <= tickUpper + upperTickLimit);
        assertTrue(wouldBeReady, "int256 semantics: isReady should return true (proceed)");
    }

    // ==================== e2e: AutoRange ====================

    /// @notice Extreme POSITIVE limits: config accepted (int24-fit check passes), every
    ///         execute() attempt panics at isReady instead of returning NotReady.
    function test_E2E_AutoRange_ConfigAccepted_ExecutePanics_PositiveLimits() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: type(int24).max, // accepted: fits int24 (AutoRange.sol:335-341)
            upperTickLimit: type(int24).max,
            lowerTickDelta: -120,
            upperTickDelta: 120,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config); // does NOT revert: fit-bounded only

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoRange), tokenId);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        autoRange.execute(params);
    }

    /// @notice Strongest form: a legitimate mean-reversion config (negative lower limit is an
    ///         implemented feature — see AutoRangeLib.isReady branches) whose int256 semantics
    ///         say READY (execute the range change NOW), but execute() panics at isReady.
    ///         Note: the overflow needs the limit sign to oppose the position tick sign —
    ///         this fixture's pool tick is positive (~192696), so the negative LOWER limit
    ///         underflows `tickLower - lowerTickLimit`.
    function test_E2E_AutoRange_ReadyByDesign_ExecutesAsPanic() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 currentTick = _getCurrentTick(poolKey);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: type(int24).min, // mean-reversion: huge negative zone, fits int24
            upperTickLimit: 0,
            lowerTickDelta: -120,
            upperTickDelta: 120,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        // Reference semantics in int256 for the ACTUAL position ticks: clause 1 is false
        // (currentTick is far below tickLower - lowerTickLimit), so the whole condition is
        // false and isReady returns TRUE (ready) — the range change should proceed.
        bool cond1 = int256(currentTick)
            >= int256(positionInfo.tickLower()) - int256(int24(config.lowerTickLimit));
        assertTrue(!cond1, "int256 reference: clause1 false -> isReady returns true (proceed)");

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoRange), tokenId);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        autoRange.execute(params);
    }

    // ==================== e2e: AutoLend ====================

    /// @notice AutoLend.configToken only rejects negative zones — zones up to int24.max pass.
    ///         deposit() then panics inside `_validateDepositTrigger` (tickLower - lowerTickZone).
    function test_E2E_AutoLend_ZoneConfigAccepted_DepositPanics() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: type(int24).max, // accepted: only "< 0" is rejected (AutoLend.sol:584-589)
            upperTickZone: type(int24).max,
            lowerTickZoneWithdraw: 0,
            upperTickZoneWithdraw: 0,
            maxRewardX64: 0
        });
        _configureAndApprove(tokenId, config);

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        autoLend.deposit(
            AutoLend.DepositParams({
                tokenId: tokenId,
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                deadline: block.timestamp,
                hookData: bytes(""),
                rewardX64: 0
            })
        );
    }

    // ==================== external wrappers (panic capture) ====================

    function isReadyWrapper(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int24 lowerTickLimit,
        int24 upperTickLimit
    ) external pure returns (bool) {
        return AutoRangeLib.isReady(currentTick, tickLower, tickUpper, lowerTickLimit, upperTickLimit);
    }

    function _configureAndApprove(uint256 tokenId, AutoLend.PositionConfig memory config) internal {
        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoLend), true);
    }
}
