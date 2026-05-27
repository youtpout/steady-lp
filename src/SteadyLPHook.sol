// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title SteadyLPHook
/// @notice Uniswap v4 hook that smooths real inflows, maintains a shared reserve, and reduces short-term LP abuse.
contract SteadyLPHook is BaseHook, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using CurrencySettler for Currency;

    uint256 private constant Q128 = 1 << 128;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant Q96 = 0x1000000000000000000000000;
    uint16 private constant ORACLE_BUFFER_SIZE = 64;

    error InvalidConfig();
    error UnsupportedPayoutCurrency();
    error UnsupportedHookData();
    error PositionNotFound();
    error NotPositionOperator();
    error MinimumHoldNotMet();
    error NothingToClaim();
    error NoCompensationAvailable();
    error OracleNotReady();
    error TransferFailed();

    /// @notice Configuration shared by all pools that use this hook.
    struct PoolConfig {
        uint32 smoothingPeriod;
        uint32 minHoldingPeriod;
        uint32 riskModeBlocks;
        uint24 narrowRangeTicks;
        uint24 maxCoverageBps;
        uint24 baseDynamicFee;
        uint24 riskDynamicFee;
        uint24 swapHookFeeBps;
        uint24 reserveShareBps;
        uint24 smoothingShareBps;
        uint256 largeSwapThreshold;
        uint24 priceMoveTickThreshold;
        uint32 compensationLookback;
        uint16 oracleCardinality;
        bool payoutToken0;
    }

    /// @notice Per-pool fee smoothing and risk state.
    struct PoolState {
        uint256 smoothedTotal;
        uint256 smoothedReleased;
        uint40 smoothingStartedAt;
        uint40 lastReleaseAt;
        uint256 rewardPerLiquidityX128;
        uint256 totalReleasedFees;
        uint256 totalClaimedFees;
        uint128 totalTrackedLiquidity;
        uint40 riskModeEndsAtBlock;
        uint40 lastRiskBlock;
        int24 lastObservedTick;
        uint256 totalObservedFees0;
        uint256 totalObservedFees1;
    }

    /// @notice Shared protection reserve state per pool.
    struct ReserveState {
        uint256 balance;
        uint256 lockedBalance;
        uint256 totalInflow;
        uint256 totalPaid;
    }

    struct OracleObservation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        int24 tick;
        bool initialized;
    }

    struct OracleState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
        bool initialized;
    }

    /// @notice Per-position metadata tracked by the hook.
    struct PositionInfo {
        address operator;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint40 addedAt;
        uint40 addedAtBlock;
        uint40 lastRiskBlock;
        uint256 rewardDebtX128;
        uint256 accruedClaimable;
        uint256 claimedAmount;
        uint256 depositedAmount0;
        uint256 depositedAmount1;
        uint256 pendingCompensation;
        uint256 claimedCompensation;
        bool riskyRange;
        bool protectionEligible;
    }

    event FeeInflowRecorded(PoolId indexed poolId, address indexed payer, uint256 amount, uint256 smoothedTotal);
    event FeeReleaseRecorded(PoolId indexed poolId, uint256 releasedAmount, uint256 rewardPerLiquidityX128);
    event FeesClaimed(PoolId indexed poolId, bytes32 indexed positionId, address indexed recipient, uint256 amount);
    event ReserveInflowRecorded(PoolId indexed poolId, address indexed payer, uint256 amount, uint256 reserveBalance);
    event CompensationPaid(PoolId indexed poolId, bytes32 indexed positionId, address indexed recipient, uint256 lossAmount, uint256 compensation);
    event PositionRecorded(
        PoolId indexed poolId,
        bytes32 indexed positionId,
        address indexed operator,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event PositionRiskFlagged(PoolId indexed poolId, bytes32 indexed positionId, address indexed operator, int24 tickLower, int24 tickUpper);
    event ProtectionEligibilityUpdated(PoolId indexed poolId, bytes32 indexed positionId, bool eligible);
    event RiskModeActivated(PoolId indexed poolId, uint40 indexed endsAtBlock, int24 tick, uint256 swapSize);
    event RiskModeExpired(PoolId indexed poolId);
    event PoolFeesObserved(PoolId indexed poolId, uint256 feeAmount0, uint256 feeAmount1);
    event SwapFeeCaptured(
        PoolId indexed poolId,
        address indexed payer,
        address indexed currency,
        uint256 totalFee,
        uint256 reserveShare,
        uint256 smoothingShare
    );
    event OracleObservationRecorded(PoolId indexed poolId, uint16 index, uint32 timestamp, int56 tickCumulative, int24 tick);
    event CompensationReserved(PoolId indexed poolId, bytes32 indexed positionId, uint256 lossValue, uint256 compensation);

    PoolConfig public defaultPoolConfig;

    mapping(PoolId => PoolState) internal _poolStates;
    mapping(PoolId => ReserveState) internal _reserveStates;
    mapping(bytes32 => PositionInfo) internal _positions;
    mapping(PoolId => OracleObservation[ORACLE_BUFFER_SIZE]) internal _oracleObservations;
    mapping(PoolId => OracleState) internal _oracleStates;

    constructor(IPoolManager _poolManager, PoolConfig memory _defaultPoolConfig) BaseHook(_poolManager) {
        if (
            _defaultPoolConfig.smoothingPeriod == 0 || _defaultPoolConfig.minHoldingPeriod == 0
                || _defaultPoolConfig.riskModeBlocks == 0 || _defaultPoolConfig.maxCoverageBps > BPS_DENOMINATOR
                || _defaultPoolConfig.baseDynamicFee > _defaultPoolConfig.riskDynamicFee
                || _defaultPoolConfig.riskDynamicFee > LPFeeLibrary.MAX_LP_FEE
                || _defaultPoolConfig.swapHookFeeBps > BPS_DENOMINATOR
                || _defaultPoolConfig.compensationLookback == 0
                || _defaultPoolConfig.oracleCardinality == 0
                || _defaultPoolConfig.oracleCardinality > ORACLE_BUFFER_SIZE
                || _defaultPoolConfig.reserveShareBps + _defaultPoolConfig.smoothingShareBps != BPS_DENOMINATOR
        ) revert InvalidConfig();

        defaultPoolConfig = _defaultPoolConfig;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Deposits payout tokens into the fee smoothing bucket for a pool.
    /// @param key Pool key.
    /// @param amount Amount of payout token to add.
    function depositFeeInflow(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        if (amount == 0) revert InvalidConfig();

        _transferPayoutTokenFrom(key, msg.sender, address(this), amount);
        _recordSmoothingInflow(poolId, msg.sender, amount);
    }

    /// @notice Deposits payout tokens into the shared protection reserve for a pool.
    /// @param key Pool key.
    /// @param amount Amount of payout token to add.
    function depositReserve(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        if (amount == 0) revert InvalidConfig();

        _transferPayoutTokenFrom(key, msg.sender, address(this), amount);

        ReserveState storage reserve = _reserveStates[poolId];
        reserve.balance += amount;
        reserve.totalInflow += amount;

        emit ReserveInflowRecorded(poolId, msg.sender, amount, reserve.balance);
    }

    /// @notice Claims the released fee share for a tracked position.
    /// @param key Pool key.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param salt Position salt.
    /// @param recipient Recipient of the payout token.
    /// @return amount Amount transferred.
    function claimReleasedFees(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        address recipient
    ) external returns (uint256 amount) {
        PoolId poolId = key.toId();
        bytes32 positionId = _positionKey(poolId, msg.sender, tickLower, tickUpper, salt);

        _settlePoolRelease(poolId);
        amount = _claimableAfterAccrual(positionId, poolId);
        if (amount == 0) revert NothingToClaim();

        PositionInfo storage position = _positions[positionId];
        position.accruedClaimable = 0;
        position.rewardDebtX128 = uint256(position.liquidity) * _poolStates[poolId].rewardPerLiquidityX128;
        position.claimedAmount += amount;

        _poolStates[poolId].totalClaimedFees += amount;
        _transferPayoutToken(key, recipient, amount);

        emit FeesClaimed(poolId, positionId, recipient, amount);
    }

    /// @notice Returns the released but unclaimed amount for a position at the current timestamp.
    /// @param key Pool key.
    /// @param operator Position operator.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param salt Position salt.
    function previewClaimableFees(
        PoolKey calldata key,
        address operator,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256) {
        PoolId poolId = key.toId();
        bytes32 positionId = _positionKey(poolId, operator, tickLower, tickUpper, salt);
        PositionInfo storage position = _positions[positionId];
        if (position.operator == address(0)) return 0;

        uint256 rewardPerLiquidityX128 = _previewRewardPerLiquidity(poolId);
        return _pendingRewards(position, rewardPerLiquidityX128);
    }

    /// @notice Returns the simulated compensation available for a position and loss amount.
    /// @param key Pool key.
    /// @param operator Position operator.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param salt Position salt.
    /// @param lossAmount Simulated or user-provided loss amount in payout token units.
    function previewCompensation(
        PoolKey calldata key,
        address operator,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 lossAmount
    ) public view returns (uint256) {
        PoolId poolId = key.toId();
        bytes32 positionId = _positionKey(poolId, operator, tickLower, tickUpper, salt);
        PositionInfo storage position = _positions[positionId];
        if (!position.protectionEligible || position.operator == address(0) || position.liquidity == 0 || lossAmount == 0) {
            return 0;
        }
        if (block.timestamp < position.addedAt + defaultPoolConfig.minHoldingPeriod) return 0;

        uint256 cappedByPolicy = lossAmount * defaultPoolConfig.maxCoverageBps / BPS_DENOMINATOR;
        uint256 reserveBalance = _availableReserve(poolId);
        return cappedByPolicy < reserveBalance ? cappedByPolicy : reserveBalance;
    }

    /// @notice Claims compensation from the shared reserve for an eligible position.
    /// @param key Pool key.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param salt Position salt.
    /// @param lossAmount Simulated or user-provided loss amount in payout token units.
    /// @param recipient Recipient of the payout token.
    /// @return compensation Amount paid from the reserve.
    function claimCompensation(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 lossAmount,
        address recipient
    ) external returns (uint256 compensation) {
        PoolId poolId = key.toId();
        bytes32 positionId = _positionKey(poolId, msg.sender, tickLower, tickUpper, salt);

        compensation = previewCompensation(key, msg.sender, tickLower, tickUpper, salt, lossAmount);
        if (compensation == 0) revert NoCompensationAvailable();

        ReserveState storage reserve = _reserveStates[poolId];
        reserve.balance -= compensation;
        reserve.totalPaid += compensation;

        _transferPayoutToken(key, recipient, compensation);
        emit CompensationPaid(poolId, positionId, recipient, lossAmount, compensation);
    }

    /// @notice Claims compensation that was reserved during a prior liquidity removal.
    function claimPendingCompensation(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        address recipient
    ) external nonReentrant returns (uint256 compensation) {
        PoolId poolId = key.toId();
        bytes32 positionId = _positionKey(poolId, msg.sender, tickLower, tickUpper, salt);
        PositionInfo storage position = _positions[positionId];
        if (position.operator == address(0)) revert PositionNotFound();
        if (position.operator != msg.sender) revert NotPositionOperator();

        compensation = position.pendingCompensation;
        if (compensation == 0) revert NoCompensationAvailable();

        position.pendingCompensation = 0;
        position.claimedCompensation += compensation;

        ReserveState storage reserve = _reserveStates[poolId];
        reserve.lockedBalance -= compensation;
        reserve.balance -= compensation;
        reserve.totalPaid += compensation;

        _transferPayoutToken(key, recipient, compensation);
        emit CompensationPaid(poolId, positionId, recipient, compensation, compensation);
    }

    /// @notice Returns whether risk mode is currently active for a pool.
    /// @param key Pool key.
    function isRiskModeActive(PoolKey calldata key) external view returns (bool) {
        return _isRiskModeActive(key.toId());
    }

    /// @notice Returns the position id used by the hook.
    /// @param key Pool key.
    /// @param operator Position operator.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param salt Position salt.
    function getPositionId(
        PoolKey calldata key,
        address operator,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external pure returns (bytes32) {
        return _positionKey(key.toId(), operator, tickLower, tickUpper, salt);
    }

    /// @notice Returns a tracked position.
    /// @param key Pool key.
    /// @param operator Position operator.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param salt Position salt.
    function getPositionInfo(
        PoolKey calldata key,
        address operator,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (PositionInfo memory) {
        return _positions[_positionKey(key.toId(), operator, tickLower, tickUpper, salt)];
    }

    /// @notice Returns the pool smoothing and risk state.
    /// @param key Pool key.
    function getPoolState(PoolKey calldata key) external view returns (PoolState memory) {
        return _poolStates[key.toId()];
    }

    /// @notice Returns the pool reserve state.
    /// @param key Pool key.
    function getReserveState(PoolKey calldata key) external view returns (ReserveState memory) {
        return _reserveStates[key.toId()];
    }

    /// @notice Returns the current oracle state for a pool.
    function getOracleState(PoolKey calldata key) external view returns (OracleState memory) {
        return _oracleStates[key.toId()];
    }

    /// @notice Returns a single oracle observation for a pool.
    function getOracleObservation(PoolKey calldata key, uint256 index) external view returns (OracleObservation memory) {
        return _oracleObservations[key.toId()][index];
    }

    /// @notice Returns the pending compensation already reserved for a position after liquidity removal.
    function previewPendingCompensation(
        PoolKey calldata key,
        address operator,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256) {
        return _positions[_positionKey(key.toId(), operator, tickLower, tickUpper, salt)].pendingCompensation;
    }

    /// @notice Returns the current oracle-based compensation preview for a portion of a position.
    function previewOracleCompensation(
        PoolKey calldata key,
        address operator,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidityToRemove
    ) external view returns (uint256 compensation, uint256 lossValue, uint160 twapSqrtPriceX96) {
        PoolId poolId = key.toId();
        bytes32 positionId = _positionKey(poolId, operator, tickLower, tickUpper, salt);
        PositionInfo storage position = _positions[positionId];
        if (position.operator == address(0) || liquidityToRemove == 0 || liquidityToRemove > position.liquidity) {
            return (0, 0, 0);
        }

        twapSqrtPriceX96 = _consultSqrtPriceX96(poolId, defaultPoolConfig.compensationLookback);
        lossValue = _lossValueForLiquiditySlice(key, position, liquidityToRemove, twapSqrtPriceX96);
        compensation = _capCompensation(poolId, lossValue);
    }

    /// @notice Returns the fee that would be applied on the next swap if the pool uses dynamic fees.
    /// @param key Pool key.
    function previewDynamicFee(PoolKey calldata key) external view returns (uint24) {
        if (!key.fee.isDynamicFee()) return 0;
        return _selectDynamicFee(key.toId()) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    function _afterAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta, BalanceDelta feesAccrued, bytes calldata hookData)
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        PoolId poolId = key.toId();
        _settlePoolRelease(poolId);
        _expireRiskModeIfNeeded(poolId);
        _recordOracleObservation(poolId, _currentTick(poolId));
        _recordAddedLiquidity(poolId, key, params, feesAccrued, _decodeOperator(sender, hookData));

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        _settlePoolRelease(poolId);
        _expireRiskModeIfNeeded(poolId);
        _recordOracleObservation(poolId, _currentTick(poolId));

        address operator = _decodeOperator(sender, hookData);
        bytes32 positionId = _positionKey(poolId, operator, params.tickLower, params.tickUpper, params.salt);
        PositionInfo storage position = _positions[positionId];
        if (position.operator == address(0)) revert PositionNotFound();
        if (position.operator != operator) revert NotPositionOperator();

        _accruePosition(positionId, poolId);

        if (block.timestamp < position.addedAt + defaultPoolConfig.minHoldingPeriod) {
            if (position.protectionEligible) {
                position.protectionEligible = false;
                emit ProtectionEligibilityUpdated(poolId, positionId, false);
            }
        }

        uint256 removing = uint256(-params.liquidityDelta);
        if (removing > position.liquidity) revert InvalidConfig();

        if (position.protectionEligible && !_isRiskModeActive(poolId)) {
            _reserveOracleCompensation(poolId, key, positionId, position, uint128(removing));
        }

        uint128 newLiquidity = uint128(uint256(position.liquidity) - removing);
        _reducePositionDeposits(position, removing);
        position.liquidity = newLiquidity;
        position.rewardDebtX128 = uint256(newLiquidity) * _poolStates[poolId].rewardPerLiquidityX128;
        _poolStates[poolId].totalTrackedLiquidity -= uint128(removing);
        if (newLiquidity == 0 && position.riskyRange) {
            position.protectionEligible = false;
            emit ProtectionEligibilityUpdated(poolId, positionId, false);
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _settlePoolRelease(poolId);
        _expireRiskModeIfNeeded(poolId);

        uint24 feeOverride;
        uint256 swapSize = _absolute(params.amountSpecified);
        if (swapSize >= defaultPoolConfig.largeSwapThreshold) {
            _activateRiskMode(poolId, key, swapSize);
        }

        if (key.fee.isDynamicFee()) {
            feeOverride = _selectDynamicFee(poolId) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _poolStates[poolId];
        (, int24 newTick,,) = poolManager.getSlot0(poolId);
        int24 tickDelta = _absTick(newTick - state.lastObservedTick);

        if (state.lastObservedTick != 0 && uint24(tickDelta) >= defaultPoolConfig.priceMoveTickThreshold) {
            _activateRiskMode(poolId, key, _absolute(params.amountSpecified));
        }

        state.lastObservedTick = newTick;
        _recordOracleObservation(poolId, newTick);

        int128 hookFeeDelta = _captureSwapFeeFromDelta(poolId, key, sender, params, delta);
        return (BaseHook.afterSwap.selector, hookFeeDelta);
    }

    function _positionKey(PoolId poolId, address operator, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, operator, tickLower, tickUpper, salt));
    }

    function _decodeOperator(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 0) {
            return sender;
        }
        if (hookData.length != 32) revert UnsupportedHookData();
        return abi.decode(hookData, (address));
    }

    function _recordAddedLiquidity(
        PoolId poolId,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta feesAccrued,
        address operator
    ) internal {
        bytes32 positionId = _positionKey(poolId, operator, params.tickLower, params.tickUpper, params.salt);
        PositionInfo storage position = _positions[positionId];

        if (position.operator != address(0)) {
            _accruePosition(positionId, poolId);
        }

        uint128 addedLiquidity = uint128(uint256(params.liquidityDelta));
        (uint256 addedAmount0, uint256 addedAmount1) =
            _positionAmountsForLiquidity(params.tickLower, params.tickUpper, addedLiquidity, _currentSqrtPriceX96(poolId));
        position.operator = operator;
        position.tickLower = params.tickLower;
        position.tickUpper = params.tickUpper;
        position.addedAt = uint40(block.timestamp);
        position.addedAtBlock = uint40(block.number);
        position.liquidity += addedLiquidity;
        position.depositedAmount0 += addedAmount0;
        position.depositedAmount1 += addedAmount1;
        position.rewardDebtX128 = uint256(position.liquidity) * _poolStates[poolId].rewardPerLiquidityX128;

        bool riskyRange = _isRiskyRange(key, params.tickLower, params.tickUpper);
        position.riskyRange = riskyRange;
        position.protectionEligible = !riskyRange;

        _poolStates[poolId].totalTrackedLiquidity += addedLiquidity;
        _observeFees(poolId, feesAccrued);

        emit PositionRecorded(poolId, positionId, operator, position.liquidity, params.tickLower, params.tickUpper);
        if (riskyRange) {
            position.lastRiskBlock = uint40(block.number);
            _poolStates[poolId].lastRiskBlock = uint40(block.number);
            emit PositionRiskFlagged(poolId, positionId, operator, params.tickLower, params.tickUpper);
        }
        emit ProtectionEligibilityUpdated(poolId, positionId, position.protectionEligible);
    }

    function _settlePoolRelease(PoolId poolId) internal {
        PoolState storage state = _poolStates[poolId];
        if (state.smoothingStartedAt == 0) {
            state.smoothingStartedAt = uint40(block.timestamp);
            state.lastReleaseAt = uint40(block.timestamp);
            return;
        }
        if (state.smoothedTotal == 0 || state.totalTrackedLiquidity == 0) {
            state.lastReleaseAt = uint40(block.timestamp);
            return;
        }

        uint256 elapsed = block.timestamp - state.smoothingStartedAt;
        uint256 vested = elapsed >= defaultPoolConfig.smoothingPeriod
            ? state.smoothedTotal
            : state.smoothedTotal * elapsed / defaultPoolConfig.smoothingPeriod;

        if (vested <= state.smoothedReleased) {
            state.lastReleaseAt = uint40(block.timestamp);
            return;
        }

        uint256 newlyReleased = vested - state.smoothedReleased;
        state.smoothedReleased = vested;
        state.lastReleaseAt = uint40(block.timestamp);
        state.totalReleasedFees += newlyReleased;
        state.rewardPerLiquidityX128 += newlyReleased * Q128 / state.totalTrackedLiquidity;

        emit FeeReleaseRecorded(poolId, newlyReleased, state.rewardPerLiquidityX128);
    }

    function _recordSmoothingInflow(PoolId poolId, address payer, uint256 amount) internal {
        _settlePoolRelease(poolId);

        PoolState storage state = _poolStates[poolId];
        uint256 remaining = state.smoothedTotal - state.smoothedReleased;
        state.smoothedTotal = remaining + amount;
        state.smoothedReleased = 0;
        state.smoothingStartedAt = uint40(block.timestamp);
        state.lastReleaseAt = uint40(block.timestamp);

        emit FeeInflowRecorded(poolId, payer, amount, state.smoothedTotal);
    }

    function _previewRewardPerLiquidity(PoolId poolId) internal view returns (uint256 rewardPerLiquidityX128) {
        PoolState storage state = _poolStates[poolId];
        rewardPerLiquidityX128 = state.rewardPerLiquidityX128;
        if (state.smoothingStartedAt == 0 || state.smoothedTotal == 0 || state.totalTrackedLiquidity == 0) {
            return rewardPerLiquidityX128;
        }

        uint256 elapsed = block.timestamp - state.smoothingStartedAt;
        uint256 vested = elapsed >= defaultPoolConfig.smoothingPeriod
            ? state.smoothedTotal
            : state.smoothedTotal * elapsed / defaultPoolConfig.smoothingPeriod;

        if (vested > state.smoothedReleased) {
            rewardPerLiquidityX128 += (vested - state.smoothedReleased) * Q128 / state.totalTrackedLiquidity;
        }
    }

    function _accruePosition(bytes32 positionId, PoolId poolId) internal {
        PositionInfo storage position = _positions[positionId];
        uint256 rewardPerLiquidityX128 = _poolStates[poolId].rewardPerLiquidityX128;
        uint256 pending = _pendingRewards(position, rewardPerLiquidityX128);
        if (pending > 0) {
            position.accruedClaimable += pending;
        }
        position.rewardDebtX128 = uint256(position.liquidity) * rewardPerLiquidityX128;
    }

    function _claimableAfterAccrual(bytes32 positionId, PoolId poolId) internal returns (uint256 amount) {
        PositionInfo storage position = _positions[positionId];
        if (position.operator == address(0)) revert PositionNotFound();
        if (position.operator != msg.sender) revert NotPositionOperator();

        _accruePosition(positionId, poolId);
        amount = position.accruedClaimable;
    }

    function _pendingRewards(PositionInfo storage position, uint256 rewardPerLiquidityX128) internal view returns (uint256) {
        uint256 accruedX128 = uint256(position.liquidity) * rewardPerLiquidityX128;
        uint256 pendingFromAccumulator = accruedX128 > position.rewardDebtX128 ? (accruedX128 - position.rewardDebtX128) / Q128 : 0;
        return position.accruedClaimable + pendingFromAccumulator;
    }

    function _observeFees(PoolId poolId, BalanceDelta feesAccrued) internal {
        uint256 fee0 = _positiveAmount(feesAccrued.amount0());
        uint256 fee1 = _positiveAmount(feesAccrued.amount1());
        if (fee0 == 0 && fee1 == 0) return;

        PoolState storage state = _poolStates[poolId];
        state.totalObservedFees0 += fee0;
        state.totalObservedFees1 += fee1;
        emit PoolFeesObserved(poolId, fee0, fee1);
    }

    function _captureSwapFeeFromDelta(
        PoolId poolId,
        PoolKey calldata key,
        address payer,
        SwapParams calldata params,
        BalanceDelta delta
    ) internal returns (int128) {
        (Currency unspecifiedCurrency, uint256 unspecifiedAmount) = _unspecifiedSwapAmount(key, params, delta);
        return _captureSwapFee(poolId, key, payer, unspecifiedCurrency, unspecifiedAmount);
    }

    function _captureSwapFee(
        PoolId poolId,
        PoolKey calldata key,
        address payer,
        Currency unspecifiedCurrency,
        uint256 unspecifiedAmount
    ) internal returns (int128) {
        if (defaultPoolConfig.swapHookFeeBps == 0 || unspecifiedAmount == 0) return 0;
        if (Currency.unwrap(unspecifiedCurrency) != Currency.unwrap(_payoutCurrency(key))) return 0;

        uint256 feeAmount = unspecifiedAmount * defaultPoolConfig.swapHookFeeBps / BPS_DENOMINATOR;
        if (feeAmount == 0) return 0;

        unspecifiedCurrency.take(poolManager, address(this), feeAmount, true);
        unspecifiedCurrency.settle(poolManager, address(this), feeAmount, true);
        unspecifiedCurrency.take(poolManager, address(this), feeAmount, false);

        uint256 reserveShare = feeAmount * defaultPoolConfig.reserveShareBps / BPS_DENOMINATOR;
        uint256 smoothingShare = feeAmount - reserveShare;

        ReserveState storage reserve = _reserveStates[poolId];
        reserve.balance += reserveShare;
        reserve.totalInflow += reserveShare;

        if (smoothingShare > 0) {
            _recordSmoothingInflow(poolId, payer, smoothingShare);
        }
        if (reserveShare > 0) {
            emit ReserveInflowRecorded(poolId, payer, reserveShare, reserve.balance);
        }
        emit SwapFeeCaptured(
            poolId,
            payer,
            Currency.unwrap(unspecifiedCurrency),
            feeAmount,
            reserveShare,
            smoothingShare
        );

        return int128(uint128(feeAmount));
    }

    function _unspecifiedSwapAmount(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (Currency unspecifiedCurrency, uint256 unspecifiedAmount)
    {
        bool unspecifiedIsCurrency1 = params.amountSpecified < 0 == params.zeroForOne;
        unspecifiedCurrency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        unspecifiedAmount = unspecifiedIsCurrency1 ? _absolute(int256(delta.amount1())) : _absolute(int256(delta.amount0()));
    }

    function _reserveOracleCompensation(
        PoolId poolId,
        PoolKey calldata key,
        bytes32 positionId,
        PositionInfo storage position,
        uint128 liquidityToRemove
    ) internal {
        uint160 twapSqrtPriceX96 = _consultSqrtPriceX96(poolId, defaultPoolConfig.compensationLookback);
        uint256 lossValue = _lossValueForLiquiditySlice(key, position, liquidityToRemove, twapSqrtPriceX96);
        if (lossValue == 0) return;

        uint256 compensation = _capCompensation(poolId, lossValue);
        if (compensation == 0) return;

        PositionInfo storage storedPosition = _positions[positionId];
        storedPosition.pendingCompensation += compensation;

        ReserveState storage reserve = _reserveStates[poolId];
        reserve.lockedBalance += compensation;

        emit CompensationReserved(poolId, positionId, lossValue, compensation);
    }

    function _lossValueForLiquiditySlice(
        PoolKey calldata key,
        PositionInfo storage position,
        uint128 liquidityToRemove,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 lossValue) {
        uint256 heldAmount0 = position.depositedAmount0 * liquidityToRemove / position.liquidity;
        uint256 heldAmount1 = position.depositedAmount1 * liquidityToRemove / position.liquidity;
        (uint256 positionAmount0, uint256 positionAmount1) =
            _positionAmountsForLiquidity(position.tickLower, position.tickUpper, liquidityToRemove, sqrtPriceX96);

        uint256 holdValue = _valueInPayoutToken(key, heldAmount0, heldAmount1, sqrtPriceX96);
        uint256 lpValue = _valueInPayoutToken(key, positionAmount0, positionAmount1, sqrtPriceX96);

        if (holdValue > lpValue) {
            lossValue = holdValue - lpValue;
        }
    }

    function _capCompensation(PoolId poolId, uint256 lossValue) internal view returns (uint256) {
        uint256 cappedByPolicy = lossValue * defaultPoolConfig.maxCoverageBps / BPS_DENOMINATOR;
        uint256 reserveAvailable = _availableReserve(poolId);
        return cappedByPolicy < reserveAvailable ? cappedByPolicy : reserveAvailable;
    }

    function _reducePositionDeposits(PositionInfo storage position, uint256 removedLiquidity) internal {
        uint256 previousLiquidity = uint256(position.liquidity);
        if (previousLiquidity == 0) return;

        uint256 removedAmount0 = position.depositedAmount0 * removedLiquidity / previousLiquidity;
        uint256 removedAmount1 = position.depositedAmount1 * removedLiquidity / previousLiquidity;
        position.depositedAmount0 -= removedAmount0;
        position.depositedAmount1 -= removedAmount1;
    }

    function _positionAmountsForLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        }
    }

    function _valueInPayoutToken(PoolKey calldata key, uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        if (defaultPoolConfig.payoutToken0) {
            return amount0 + _quoteToken1InToken0(amount1, sqrtPriceX96);
        }
        key;
        return amount1 + _quoteToken0InToken1(amount0, sqrtPriceX96);
    }

    function _quoteToken1InToken0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount1 == 0) return 0;
        uint256 intermediate = FullMath.mulDiv(amount1, Q96, sqrtPriceX96);
        return FullMath.mulDiv(intermediate, Q96, sqrtPriceX96);
    }

    function _quoteToken0InToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount0 == 0) return 0;
        uint256 intermediate = FullMath.mulDiv(amount0, sqrtPriceX96, Q96);
        return FullMath.mulDiv(intermediate, sqrtPriceX96, Q96);
    }

    function _recordOracleObservation(PoolId poolId, int24 currentTick) internal {
        OracleState storage state = _oracleStates[poolId];
        OracleObservation[ORACLE_BUFFER_SIZE] storage observations = _oracleObservations[poolId];
        uint32 timestamp = uint32(block.timestamp);

        if (!state.initialized) {
            observations[0] = OracleObservation({
                blockTimestamp: timestamp,
                tickCumulative: 0,
                tick: currentTick,
                initialized: true
            });
            state.index = 0;
            state.cardinality = 1;
            state.cardinalityNext = defaultPoolConfig.oracleCardinality;
            state.initialized = true;
            emit OracleObservationRecorded(poolId, 0, timestamp, 0, currentTick);
            return;
        }

        OracleObservation memory last = observations[state.index];
        if (last.blockTimestamp == timestamp) {
            observations[state.index].tick = currentTick;
            return;
        }

        int56 nextTickCumulative = last.tickCumulative + int56(last.tick) * int56(uint56(timestamp - last.blockTimestamp));
        uint16 nextIndex = state.index + 1;
        if (nextIndex == state.cardinalityNext) nextIndex = 0;

        observations[nextIndex] = OracleObservation({
            blockTimestamp: timestamp,
            tickCumulative: nextTickCumulative,
            tick: currentTick,
            initialized: true
        });
        state.index = nextIndex;
        if (state.cardinality < state.cardinalityNext) {
            state.cardinality++;
        }

        emit OracleObservationRecorded(poolId, nextIndex, timestamp, nextTickCumulative, currentTick);
    }

    function _consultSqrtPriceX96(PoolId poolId, uint32 secondsAgo) internal view returns (uint160) {
        OracleState storage state = _oracleStates[poolId];
        if (!state.initialized || state.cardinality == 0) revert OracleNotReady();

        uint32 nowTimestamp = uint32(block.timestamp);
        if (secondsAgo == 0) {
            return _currentSqrtPriceX96(poolId);
        }
        if (secondsAgo > nowTimestamp) revert OracleNotReady();

        uint32 targetTimestamp = nowTimestamp - secondsAgo;
        int56 currentCumulative = _currentTickCumulative(poolId, nowTimestamp);
        OracleObservation memory beforeOrAt = _observationBeforeOrAt(poolId, targetTimestamp);
        int56 pastCumulative = beforeOrAt.tickCumulative;

        if (targetTimestamp > beforeOrAt.blockTimestamp) {
            pastCumulative += int56(beforeOrAt.tick) * int56(uint56(targetTimestamp - beforeOrAt.blockTimestamp));
        }

        int24 averageTick = int24((currentCumulative - pastCumulative) / int56(uint56(secondsAgo)));
        return TickMath.getSqrtPriceAtTick(averageTick);
    }

    function _currentTickCumulative(PoolId poolId, uint32 nowTimestamp) internal view returns (int56) {
        OracleState storage state = _oracleStates[poolId];
        OracleObservation memory last = _oracleObservations[poolId][state.index];
        return last.tickCumulative + int56(last.tick) * int56(uint56(nowTimestamp - last.blockTimestamp));
    }

    function _observationBeforeOrAt(PoolId poolId, uint32 targetTimestamp)
        internal
        view
        returns (OracleObservation memory candidate)
    {
        OracleState storage state = _oracleStates[poolId];
        bool found;

        for (uint256 i = 0; i < state.cardinality; ++i) {
            OracleObservation memory observation = _oracleObservations[poolId][i];
            if (!observation.initialized) continue;
            if (observation.blockTimestamp <= targetTimestamp) {
                if (!found || observation.blockTimestamp > candidate.blockTimestamp) {
                    candidate = observation;
                    found = true;
                }
            }
        }

        if (!found) revert OracleNotReady();
    }

    function _currentSqrtPriceX96(PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    function _currentTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _availableReserve(PoolId poolId) internal view returns (uint256) {
        ReserveState storage reserve = _reserveStates[poolId];
        return reserve.balance - reserve.lockedBalance;
    }

    function _isRiskyRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) internal view returns (bool) {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        uint24 rangeWidth = uint24(uint24(tickUpper - tickLower));
        return currentTick >= tickLower && currentTick <= tickUpper && rangeWidth <= defaultPoolConfig.narrowRangeTicks;
    }

    function _activateRiskMode(PoolId poolId, PoolKey calldata key, uint256 swapSize) internal {
        PoolState storage state = _poolStates[poolId];
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        state.riskModeEndsAtBlock = uint40(block.number + defaultPoolConfig.riskModeBlocks);
        state.lastRiskBlock = uint40(block.number);
        state.lastObservedTick = currentTick;
        emit RiskModeActivated(poolId, state.riskModeEndsAtBlock, currentTick, swapSize);

        if (key.fee.isDynamicFee()) {
            // TODO: Consider using poolManager.updateDynamicLPFee for persistent fee changes if production policy requires it.
        }
    }

    function _expireRiskModeIfNeeded(PoolId poolId) internal {
        PoolState storage state = _poolStates[poolId];
        if (state.riskModeEndsAtBlock != 0 && block.number > state.riskModeEndsAtBlock) {
            state.riskModeEndsAtBlock = 0;
            emit RiskModeExpired(poolId);
        }
    }

    function _isRiskModeActive(PoolId poolId) internal view returns (bool) {
        uint40 endsAtBlock = _poolStates[poolId].riskModeEndsAtBlock;
        return endsAtBlock != 0 && block.number <= endsAtBlock;
    }

    function _selectDynamicFee(PoolId poolId) internal view returns (uint24) {
        if (_isRiskModeActive(poolId)) {
            return defaultPoolConfig.riskDynamicFee;
        }
        return defaultPoolConfig.baseDynamicFee;
    }

    function _transferPayoutTokenFrom(PoolKey calldata key, address from, address to, uint256 amount) internal {
        Currency payoutCurrency = _payoutCurrency(key);
        address token = Currency.unwrap(payoutCurrency);
        if (token == address(0)) revert UnsupportedPayoutCurrency();
        if (!IERC20(token).transferFrom(from, to, amount)) revert TransferFailed();
    }

    function _transferPayoutToken(PoolKey calldata key, address to, uint256 amount) internal {
        Currency payoutCurrency = _payoutCurrency(key);
        address token = Currency.unwrap(payoutCurrency);
        if (token == address(0)) revert UnsupportedPayoutCurrency();
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }

    function _payoutCurrency(PoolKey calldata key) internal view returns (Currency) {
        return defaultPoolConfig.payoutToken0 ? key.currency0 : key.currency1;
    }

    function _positiveAmount(int128 value) internal pure returns (uint256) {
        return value > 0 ? uint256(uint128(value)) : 0;
    }

    function _absolute(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function _absTick(int24 value) internal pure returns (int24) {
        return value >= 0 ? value : -value;
    }
}
