// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {SteadyLPHook} from "../src/SteadyLPHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract SteadyLPHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint32 internal constant SMOOTHING_PERIOD = 7 days;
    uint32 internal constant MIN_HOLDING_PERIOD = 1 days;
    uint32 internal constant RISK_MODE_BLOCKS = 20;
    uint24 internal constant NARROW_RANGE_TICKS = 180;
    uint24 internal constant MAX_COVERAGE_BPS = 5_000;
    uint24 internal constant BASE_DYNAMIC_FEE = 3_000;
    uint24 internal constant RISK_DYNAMIC_FEE = 9_000;
    uint24 internal constant SWAP_HOOK_FEE_BPS = 1_000;
    uint24 internal constant RESERVE_SHARE_BPS = 4_000;
    uint24 internal constant SMOOTHING_SHARE_BPS = 6_000;
    uint256 internal constant LARGE_SWAP_THRESHOLD = 5 ether;
    uint24 internal constant PRICE_MOVE_TICK_THRESHOLD = 120;

    Currency internal currency0;
    Currency internal currency1;
    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal poolKey;
    PoolId internal poolId;
    SteadyLPHook internal hook;

    bytes internal hookData;
    uint256 internal tokenId;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint128 internal liquidityAmount = 100e18;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );

        SteadyLPHook.PoolConfig memory config = SteadyLPHook.PoolConfig({
            smoothingPeriod: SMOOTHING_PERIOD,
            minHoldingPeriod: MIN_HOLDING_PERIOD,
            riskModeBlocks: RISK_MODE_BLOCKS,
            narrowRangeTicks: NARROW_RANGE_TICKS,
            maxCoverageBps: MAX_COVERAGE_BPS,
            baseDynamicFee: BASE_DYNAMIC_FEE,
            riskDynamicFee: RISK_DYNAMIC_FEE,
            swapHookFeeBps: SWAP_HOOK_FEE_BPS,
            reserveShareBps: RESERVE_SHARE_BPS,
            smoothingShareBps: SMOOTHING_SHARE_BPS,
            largeSwapThreshold: LARGE_SWAP_THRESHOLD,
            priceMoveTickThreshold: PRICE_MOVE_TICK_THRESHOLD,
            payoutToken0: true
        });

        bytes memory constructorArgs = abi.encode(poolManager, config);
        deployCodeTo("SteadyLPHook.sol:SteadyLPHook", constructorArgs, flags);
        hook = SteadyLPHook(flags);

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        hookData = abi.encode(address(this));
        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            hookData
        );

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
    }

    function testDeploysCorrectly() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
    }

    function testHookPermissionsAreCorrect() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertFalse(permissions.beforeAddLiquidity);
        assertTrue(permissions.afterAddLiquidity);
        assertTrue(permissions.beforeRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterDonate);
    }

    function testAddingLiquidityRecordsPositionData() public view {
        SteadyLPHook.PositionInfo memory position =
            hook.getPositionInfo(poolKey, address(this), tickLower, tickUpper, _positionSalt());

        assertEq(position.operator, address(this));
        assertEq(position.liquidity, liquidityAmount);
        assertEq(position.tickLower, tickLower);
        assertEq(position.tickUpper, tickUpper);
        assertEq(position.addedAt, block.timestamp);
        assertEq(position.addedAtBlock, block.number);
        assertTrue(position.protectionEligible);
        assertFalse(position.riskyRange);
    }

    function testRemovingLiquidityBeforeMinimumHoldingPeriodIsMarkedIneligible() public {
        positionManager.decreaseLiquidity(
            tokenId,
            1e18,
            0,
            0,
            address(this),
            block.timestamp,
            hookData
        );

        SteadyLPHook.PositionInfo memory position =
            hook.getPositionInfo(poolKey, address(this), tickLower, tickUpper, _positionSalt());
        assertFalse(position.protectionEligible);
    }

    function testNarrowLiquidityAroundActiveTickIsFlaggedRisky() public {
        vm.warp(block.timestamp + MIN_HOLDING_PERIOD + 1);

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 narrowLower = _alignToSpacing(currentTick - 60, poolKey.tickSpacing);
        int24 narrowUpper = _alignToSpacing(currentTick + 60, poolKey.tickSpacing);

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(narrowLower),
            TickMath.getSqrtPriceAtTick(narrowUpper),
            10e18
        );

        uint256 narrowTokenId;
        (narrowTokenId,) = positionManager.mint(
            poolKey,
            narrowLower,
            narrowUpper,
            10e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            hookData
        );

        SteadyLPHook.PositionInfo memory position =
            hook.getPositionInfo(poolKey, address(this), narrowLower, narrowUpper, bytes32(narrowTokenId));

        assertTrue(position.riskyRange);
        assertFalse(position.protectionEligible);
        assertEq(position.lastRiskBlock, block.number);
    }

    function testLargeSwapActivatesRiskMode() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: LARGE_SWAP_THRESHOLD,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(hook.isRiskModeActive(poolKey));
        assertEq(hook.previewDynamicFee(poolKey), RISK_DYNAMIC_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function testSwapFeeIsSplitBetweenReserveAndSmoothing() public {
        uint256 reserveBefore = hook.getReserveState(poolKey).balance;

        swapRouter.swapExactTokensForTokens({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        SteadyLPHook.ReserveState memory reserve = hook.getReserveState(poolKey);
        SteadyLPHook.PoolState memory state = hook.getPoolState(poolKey);

        assertGt(reserve.balance, reserveBefore);
        assertGt(state.smoothedTotal, 0);

        vm.warp(block.timestamp + (SMOOTHING_PERIOD / 2));
        assertGt(hook.previewClaimableFees(poolKey, address(this), tickLower, tickUpper, _positionSalt()), 0);
    }

    function testRiskModeExpiresAfterConfiguredBlocks() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: LARGE_SWAP_THRESHOLD,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(hook.isRiskModeActive(poolKey));
        vm.roll(block.number + RISK_MODE_BLOCKS + 1);

        hook.depositReserve(poolKey, 1 ether);
        assertFalse(hook.isRiskModeActive(poolKey));
        assertEq(hook.previewDynamicFee(poolKey), BASE_DYNAMIC_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function testReserveAcceptsInflows() public {
        hook.depositReserve(poolKey, 25 ether);
        SteadyLPHook.ReserveState memory reserve = hook.getReserveState(poolKey);

        assertEq(reserve.balance, 25 ether);
        assertEq(reserve.totalInflow, 25 ether);
    }

    function testFeeSmoothingReleasesFundsGradually() public {
        hook.depositFeeInflow(poolKey, 70 ether);

        assertEq(hook.previewClaimableFees(poolKey, address(this), tickLower, tickUpper, _positionSalt()), 0);

        vm.warp(block.timestamp + (SMOOTHING_PERIOD / 2));
        uint256 halfClaimable = hook.previewClaimableFees(poolKey, address(this), tickLower, tickUpper, _positionSalt());
        assertApproxEqAbs(halfClaimable, 35 ether, 1);

        uint256 balanceBefore = token0.balanceOf(address(this));
        hook.claimReleasedFees(poolKey, tickLower, tickUpper, _positionSalt(), address(this));
        uint256 balanceAfter = token0.balanceOf(address(this));

        assertApproxEqAbs(balanceAfter - balanceBefore, 35 ether, 1);
    }

    function testLpCannotClaimMoreThanReleasedAmount() public {
        hook.depositFeeInflow(poolKey, 40 ether);
        vm.warp(block.timestamp + (SMOOTHING_PERIOD / 4));

        hook.claimReleasedFees(poolKey, tickLower, tickUpper, _positionSalt(), address(this));

        vm.expectRevert(SteadyLPHook.NothingToClaim.selector);
        hook.claimReleasedFees(poolKey, tickLower, tickUpper, _positionSalt(), address(this));
    }

    function testCompensationIsCappedByCoverageRatioAndReserveBalance() public {
        vm.warp(block.timestamp + MIN_HOLDING_PERIOD + 1);

        hook.depositReserve(poolKey, 80 ether);
        assertEq(hook.previewCompensation(poolKey, address(this), tickLower, tickUpper, _positionSalt(), 100 ether), 50 ether);

        uint256 balanceBefore = token0.balanceOf(address(this));
        hook.claimCompensation(poolKey, tickLower, tickUpper, _positionSalt(), 100 ether, address(this));
        uint256 balanceAfter = token0.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 50 ether);

        assertEq(hook.previewCompensation(poolKey, address(this), tickLower, tickUpper, _positionSalt(), 100 ether), 30 ether);
    }

    function testNoFixedApyOrGuaranteedYieldLogicExists() public {
        vm.warp(block.timestamp + 365 days);

        assertEq(hook.previewClaimableFees(poolKey, address(this), tickLower, tickUpper, _positionSalt()), 0);
        assertEq(hook.previewCompensation(poolKey, address(this), tickLower, tickUpper, _positionSalt(), 0), 0);
    }

    function _alignToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _positionSalt() internal view returns (bytes32) {
        return bytes32(tokenId);
    }
}
