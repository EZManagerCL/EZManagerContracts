// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {BitMath} from "@uniswap/v3-core/contracts/libraries/BitMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v3-core/contracts/libraries/SwapMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    ICLDexAdapter,
    RebalanceParams,
    ICLCore,
    IAerodromeFactory,
    IUniswapV3Pool,
    ISlipstreamPoolState
} from "./Interfaces.sol";

/**
 * @title RebalancePlanner
 * @notice Computes optimal swap amounts for a target CL range.
 * @dev Internals walk the bundle across initialized ticks when needed and then
 *      solve inside the active segment using exact swap math.
 */
contract RebalancePlanner is Ownable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address public immutable USDC;
    ICLCore public immutable CORE;
    uint256 public MAX_WALK_TICKS = 256;
    uint256 internal constant FEE_SCALE = 1e6;
    uint256 internal constant CLOSED_FORM_MAX_CORRECTION_STEPS = 2;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct PoolContext {
        address token0;
        address token1;
        uint24 feePips; // The actual fee used for math
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint160 sqrtPriceX96;
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        uint128 poolLiquidity;
        address poolAddress;
        bool isSlip;
    }

    struct ExactEval {
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        uint256 grossAmountIn;
        uint128 liquidity;
        uint256 dustValueIn1;
        int256 signedDustImbalanceIn1;
    }

    struct PlanningState {
        uint160 sqrtPriceX96;
        int24 searchTick;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 totalSwapAmount;
    }

    struct SegmentBoundary {
        uint160 sqrtTargetX96;
        int24 nextTick;
        bool initialized;
    }

    struct BitmapCursor {
        int16 wordPos;
        uint256 word;
        bool loaded;
    }

    struct SegmentStep {
        PlanningState state;
        SegmentBoundary boundary;
        ExactEval eval_;
        uint256 grossToBoundary;
        uint256 available;
    }

    struct EntryTransition {
        PlanningState state;
        uint256 walkBudgetRemaining;
        bool earlyReturn;
        bool hasEntryDirection;
        bool entryZeroForOne;
    }

    struct WalkResult {
        PlanningState state;
        PlanningState bracketState;
        ExactEval lastEval;
        ExactEval bracketLowEval;
        ExactEval bracketHighEval;
        uint160 bracketSqrtTargetX96;
        uint256 bracketHighGross;
        uint256 walkBudgetRemaining;
        bool bracketed;
        bool terminalReached;
    }

    enum WalkMode {
        BracketSearch,
        Entry
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => bool) internal isBridgeTokenCached;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error UsdcDecimalsTooLow();
    error UnsupportedPool();
    error PoolNotFound();
    error InvalidTicks();
    error InvalidInput();
    error MissingDexAdapter();
    error ZeroAddress();
    error FeeFetchFailed();
    error Slot0Failed();
    error UnsupportedBitmap();
    error InvalidPoolLiquidityState();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address usdc_, address core_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || core_ == address(0)) revert ZeroAddress();
        USDC = usdc_;
        CORE = ICLCore(core_);
        uint8 usdcDecimals = IERC20Metadata(address(USDC)).decimals();
        if (usdcDecimals < 3) revert UsdcDecimalsTooLow();

        address[] memory bridges = CORE.bridgeTokens();
        uint256 bridgesLen = bridges.length;
        for (uint256 i = 0; i < bridgesLen; ++i) {
            address bridge = bridges[i];
            if (bridge == address(0) || bridge == USDC || isBridgeTokenCached[bridge]) continue;
            isBridgeTokenCached[bridge] = true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the maximum number of exact boundary-walk steps before approximation.
    function setMaxWalkTicks(uint256 maxWalkTicks) external onlyOwner {
        if (maxWalkTicks == 0 || maxWalkTicks > 96) revert InvalidInput();
        MAX_WALK_TICKS = maxWalkTicks;
    }

    /*//////////////////////////////////////////////////////////////
                               USER FLOWS
    //////////////////////////////////////////////////////////////*/

    function planFromTokenBundle(
        address dex,
        address pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external view returns (RebalanceParams memory params) {
        if (dex == address(0)) revert MissingDexAdapter();
        if (pool == address(0)) revert PoolNotFound();
        if (amount0 == 0 && amount1 == 0) revert InvalidInput();

        address factory = ICLDexAdapter(dex).getFactory();
        PoolContext memory pc = _loadPoolContext(dex, pool, factory, token0, token1, tickLower, tickUpper);

        // Defensive handling: ensure input amounts align with the pool's token ordering.
        // _loadPoolContext guarantees the pool exists and exposes its token0/token1 via pc.token0/pc.token1.
        // If the caller provided token0/token1 in the opposite order, swap the amounts so that
        // `amount0` corresponds to `pc.token0` and `amount1` to `pc.token1`.
        if (pc.token0 != token0) {
            uint256 tmp = amount0;
            amount0 = amount1;
            amount1 = tmp;
        }

        params = _solveIterative(pc, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Planner flow:
     * 1. If price starts outside the requested range, spend into the range first.
     * 2. Walk initialized segments until the solution is bracketed in the active segment.
     * 3. Solve the in-segment target with the closed form and polish with exact swap evals.
     */
    function _solveIterative(PoolContext memory pc, uint256 amount0, uint256 amount1)
        internal
        view
        returns (RebalanceParams memory params)
    {
        if (pc.poolLiquidity == 0) return params;
        BitmapCursor memory cursor;
        PlanningState memory state = _initialPlanningState(pc, amount0, amount1);
        EntryTransition memory entry = _enterRangeIfNeeded(pc, state, cursor);
        if (entry.earlyReturn) {
            return _finalizeParams(params, entry.entryZeroForOne, entry.state.totalSwapAmount, amount0, amount1);
        }

        ExactEval memory currentEval =
            _scoreState(pc, entry.state.sqrtPriceX96, entry.state.amount0, entry.state.amount1, 0);
        if (currentEval.signedDustImbalanceIn1 == 0) {
            bool finalizeZeroForOne = entry.hasEntryDirection ? entry.entryZeroForOne : false;
            return _finalizeParams(params, finalizeZeroForOne, entry.state.totalSwapAmount, amount0, amount1);
        }

        bool zeroForOne = currentEval.signedDustImbalanceIn1 > 0;
        int24 terminalTick = zeroForOne ? pc.tickLower : pc.tickUpper;
        uint160 terminalSqrtX96 = zeroForOne ? pc.sqrtLowerX96 : pc.sqrtUpperX96;

        WalkResult memory walk = _walkSegments(
            pc,
            entry.state,
            currentEval,
            zeroForOne,
            terminalTick,
            terminalSqrtX96,
            entry.walkBudgetRemaining,
            cursor,
            WalkMode.BracketSearch
        );

        if (walk.bracketed) {
            ExactEval memory best = _solveInsideSegment(
                pc,
                walk.bracketState,
                zeroForOne,
                walk.bracketSqrtTargetX96,
                walk.bracketHighGross,
                walk.bracketLowEval,
                walk.bracketHighEval
            );
            walk.state = walk.bracketState;
            walk.state.totalSwapAmount += best.grossAmountIn;
        }

        return _finalizeParams(params, zeroForOne, walk.state.totalSwapAmount, amount0, amount1);
    }

    function _initialPlanningState(PoolContext memory pc, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (PlanningState memory state)
    {
        state.sqrtPriceX96 = pc.sqrtPriceX96;
        state.searchTick = pc.currentTick;
        state.liquidity = pc.poolLiquidity;
        state.amount0 = amount0;
        state.amount1 = amount1;
    }

    function _enterRangeIfNeeded(PoolContext memory pc, PlanningState memory state, BitmapCursor memory cursor)
        internal
        view
        returns (EntryTransition memory transition)
    {
        transition.state = state;
        transition.walkBudgetRemaining = MAX_WALK_TICKS;

        if (state.sqrtPriceX96 < pc.sqrtLowerX96) {
            transition.hasEntryDirection = true;
            transition.entryZeroForOne = false;

            WalkResult memory walk = _walkSegments(
                pc,
                state,
                _zeroEval(),
                false,
                pc.tickLower,
                pc.sqrtLowerX96,
                transition.walkBudgetRemaining,
                cursor,
                WalkMode.Entry
            );
            transition.state = walk.state;
            transition.walkBudgetRemaining = walk.walkBudgetRemaining;
            transition.earlyReturn = !walk.terminalReached || transition.state.amount1 == 0;
            return transition;
        }

        if (state.sqrtPriceX96 > pc.sqrtUpperX96) {
            transition.hasEntryDirection = true;
            transition.entryZeroForOne = true;

            WalkResult memory walk = _walkSegments(
                pc,
                state,
                _zeroEval(),
                true,
                pc.tickUpper,
                pc.sqrtUpperX96,
                transition.walkBudgetRemaining,
                cursor,
                WalkMode.Entry
            );
            transition.state = walk.state;
            transition.walkBudgetRemaining = walk.walkBudgetRemaining;
            transition.earlyReturn = !walk.terminalReached || transition.state.amount0 == 0;
        }
    }

    function _segmentIsBracketed(ExactEval memory lowEval, ExactEval memory highEval) internal pure returns (bool) {
        return !_sameSign(lowEval.signedDustImbalanceIn1, highEval.signedDustImbalanceIn1)
            || highEval.signedDustImbalanceIn1 == 0;
    }

    function _walkSegments(
        PoolContext memory pc,
        PlanningState memory state,
        ExactEval memory currentEval,
        bool zeroForOne,
        int24 terminalTick,
        uint160 terminalSqrtX96,
        uint256 walkBudgetRemaining,
        BitmapCursor memory cursor,
        WalkMode mode
    ) internal view returns (WalkResult memory result) {
        result.state = state;
        result.lastEval = currentEval;
        result.walkBudgetRemaining = walkBudgetRemaining;

        while (result.walkBudgetRemaining > 0) {
            if (result.state.sqrtPriceX96 == terminalSqrtX96) {
                result.terminalReached = true;
                return result;
            }

            SegmentStep memory step =
                _stepTowardBoundary(pc, result.state, zeroForOne, terminalTick, terminalSqrtX96, cursor);
            if (step.eval_.grossAmountIn == 0) {
                return result;
            }

            if (mode == WalkMode.BracketSearch && _segmentIsBracketed(result.lastEval, step.eval_)) {
                result.bracketed = true;
                result.bracketState = result.state;
                result.bracketLowEval = result.lastEval;
                result.bracketHighEval = step.eval_;
                result.bracketSqrtTargetX96 = step.boundary.sqrtTargetX96;
                result.bracketHighGross = step.eval_.grossAmountIn;
                return result;
            }

            result.state = step.state;
            result.lastEval = step.eval_;

            bool crossedTerminal = step.boundary.initialized && step.boundary.nextTick == terminalTick
                && result.state.sqrtPriceX96 == terminalSqrtX96;
            if (crossedTerminal && mode == WalkMode.Entry) {
                result.state.liquidity =
                    _crossInitializedTick(pc.poolAddress, result.state.liquidity, terminalTick, zeroForOne, pc.isSlip);
            }

            if (_shouldStopAfterStep(step.eval_, step.grossToBoundary, step.available)) {
                result.terminalReached = result.state.sqrtPriceX96 == terminalSqrtX96;
                return result;
            }

            if (
                step.boundary.initialized && step.boundary.nextTick != terminalTick
                    && (
                        mode == WalkMode.Entry
                            || (step.boundary.nextTick > pc.tickLower && step.boundary.nextTick < pc.tickUpper)
                    )
            ) {
                result.state.liquidity = _crossInitializedTick(
                    pc.poolAddress, result.state.liquidity, step.boundary.nextTick, zeroForOne, pc.isSlip
                );
            }

            if (result.state.sqrtPriceX96 == terminalSqrtX96) {
                result.terminalReached = true;
                return result;
            }

            unchecked {
                --result.walkBudgetRemaining;
            }
        }

        SegmentStep memory finalStep =
            _constantLiquidityStep(pc, result.state, zeroForOne, terminalTick, terminalSqrtX96, mode == WalkMode.Entry);
        if (finalStep.eval_.grossAmountIn == 0) return result;

        if (mode == WalkMode.BracketSearch && _segmentIsBracketed(result.lastEval, finalStep.eval_)) {
            result.bracketed = true;
            result.bracketState = result.state;
            result.bracketLowEval = result.lastEval;
            result.bracketHighEval = finalStep.eval_;
            result.bracketSqrtTargetX96 = terminalSqrtX96;
            result.bracketHighGross = finalStep.eval_.grossAmountIn;
            return result;
        }

        result.state = finalStep.state;
        result.terminalReached = result.state.sqrtPriceX96 == terminalSqrtX96;
        result.lastEval = finalStep.eval_;
    }

    function _segmentBoundary(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        int24 terminalTick,
        uint160 terminalSqrtX96,
        BitmapCursor memory cursor
    ) internal view returns (SegmentBoundary memory boundary) {
        boundary.sqrtTargetX96 = terminalSqrtX96;
        boundary.nextTick = terminalTick;

        (int24 nextTick, bool initialized, bool supported) =
            _nextInitializedTickWithinOneWord(pc.poolAddress, state.searchTick, pc.tickSpacing, zeroForOne, cursor);
        if (!supported) revert UnsupportedBitmap();

        if (zeroForOne) {
            if (nextTick < terminalTick) nextTick = terminalTick;
        } else {
            if (nextTick > terminalTick) nextTick = terminalTick;
        }

        uint160 nextSqrt = TickMath.getSqrtRatioAtTick(nextTick);
        if ((zeroForOne && nextSqrt < state.sqrtPriceX96) || (!zeroForOne && nextSqrt > state.sqrtPriceX96)) {
            boundary.sqrtTargetX96 = nextSqrt;
            boundary.nextTick = nextTick;
            boundary.initialized = initialized;
        }
    }

    function _stepTowardBoundary(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        int24 terminalTick,
        uint160 terminalSqrtX96,
        BitmapCursor memory cursor
    ) internal view returns (SegmentStep memory step) {
        step.boundary = _segmentBoundary(pc, state, zeroForOne, terminalTick, terminalSqrtX96, cursor);
        step.grossToBoundary = _grossToReachTarget(
            state.sqrtPriceX96, step.boundary.sqrtTargetX96, state.liquidity, zeroForOne, pc.feePips
        );
        step.available = zeroForOne ? state.amount0 : state.amount1;
        step.eval_ = _moveTowardBoundary(pc, state, zeroForOne, step.boundary.sqrtTargetX96, step.grossToBoundary);
        if (step.eval_.grossAmountIn == 0) return step;
        step.state = _applyEval(state, step.eval_, zeroForOne, step.boundary, step.grossToBoundary);
    }

    function _constantLiquidityStep(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        int24 terminalTick,
        uint160 terminalSqrtX96,
        bool crossTerminal
    ) internal view returns (SegmentStep memory step) {
        step.boundary = SegmentBoundary({
            sqrtTargetX96: terminalSqrtX96,
            nextTick: terminalTick,
            initialized: crossTerminal && _tickInitialized(pc.poolAddress, terminalTick, pc.isSlip)
        });
        step.grossToBoundary =
            _grossToReachTarget(state.sqrtPriceX96, terminalSqrtX96, state.liquidity, zeroForOne, pc.feePips);
        step.available = zeroForOne ? state.amount0 : state.amount1;
        step.eval_ = _moveTowardBoundary(pc, state, zeroForOne, terminalSqrtX96, step.grossToBoundary);
        if (step.eval_.grossAmountIn == 0) return step;

        step.state = _applyEval(state, step.eval_, zeroForOne, step.boundary, step.grossToBoundary);
        if (step.boundary.initialized && step.state.sqrtPriceX96 == terminalSqrtX96) {
            step.state.liquidity =
                _crossInitializedTick(pc.poolAddress, step.state.liquidity, terminalTick, zeroForOne, pc.isSlip);
        }
    }

    function _moveTowardBoundary(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96,
        uint256 grossToBoundary
    ) internal pure returns (ExactEval memory eval_) {
        uint256 availableIn = zeroForOne ? state.amount0 : state.amount1;
        if (availableIn == 0 || sqrtTargetX96 == state.sqrtPriceX96) {
            return _scoreState(pc, state.sqrtPriceX96, state.amount0, state.amount1, 0);
        }

        uint256 grossAmountIn = grossToBoundary > availableIn ? availableIn : grossToBoundary;
        return _simulateSegmentExactIn(pc, state, zeroForOne, sqrtTargetX96, grossAmountIn);
    }

    function _simulateSegmentExactIn(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96,
        uint256 grossAmountIn
    ) internal pure returns (ExactEval memory eval_) {
        uint256 availableIn = zeroForOne ? state.amount0 : state.amount1;
        if (grossAmountIn > availableIn) grossAmountIn = availableIn;
        if (grossAmountIn == 0) return _scoreState(pc, state.sqrtPriceX96, state.amount0, state.amount1, 0);

        uint256 amountInLessFee;
        uint256 amountOut;
        uint256 feeAmount;
        uint160 sqrtPriceX96;
        (sqrtPriceX96, amountInLessFee, amountOut, feeAmount) = SwapMath.computeSwapStep(
            state.sqrtPriceX96, sqrtTargetX96, state.liquidity, int256(grossAmountIn), pc.feePips
        );

        grossAmountIn = amountInLessFee + feeAmount;
        uint256 amount0 = state.amount0;
        uint256 amount1 = state.amount1;
        if (zeroForOne) {
            amount0 = grossAmountIn >= state.amount0 ? 0 : state.amount0 - grossAmountIn;
            amount1 = state.amount1 + amountOut;
        } else {
            amount1 = grossAmountIn >= state.amount1 ? 0 : state.amount1 - grossAmountIn;
            amount0 = state.amount0 + amountOut;
        }

        eval_ = _scoreState(pc, sqrtPriceX96, amount0, amount1, grossAmountIn);
    }

    function _solveInsideSegment(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96,
        uint256 highGross,
        ExactEval memory lowEval,
        ExactEval memory highEval
    ) internal pure returns (ExactEval memory bestEval) {
        bestEval = _isBetterEval(highEval, lowEval) ? highEval : lowEval;
        (uint160 root0X96, uint160 root1X96) = _solveClosedFormRootCandidates(pc, state, zeroForOne, sqrtTargetX96);

        ExactEval memory correctionSeed;
        bool hasCorrectionSeed;

        if (root0X96 != 0) {
            (bestEval, correctionSeed, hasCorrectionSeed) = _evaluateClosedFormCandidate(
                pc, state, zeroForOne, sqrtTargetX96, highGross, lowEval, highEval, bestEval, root0X96
            );
            if (correctionSeed.signedDustImbalanceIn1 == 0) return correctionSeed;
        }

        if (root1X96 != 0 && root1X96 != root0X96) {
            ExactEval memory candidateEval;
            bool candidateSeed;
            (bestEval, candidateEval, candidateSeed) = _evaluateClosedFormCandidate(
                pc, state, zeroForOne, sqrtTargetX96, highGross, lowEval, highEval, bestEval, root1X96
            );
            if (candidateEval.signedDustImbalanceIn1 == 0) return candidateEval;
            if (!hasCorrectionSeed || _isBetterEval(candidateEval, correctionSeed)) {
                correctionSeed = candidateEval;
                hasCorrectionSeed = candidateSeed;
            }
        }

        if (!hasCorrectionSeed) return bestEval;

        return _correctDiscreteClosedForm(
            pc,
            state,
            zeroForOne,
            sqrtTargetX96,
            correctionSeed.grossAmountIn,
            correctionSeed,
            lowEval,
            highEval,
            bestEval,
            highGross
        );
    }

    function _evaluateClosedFormCandidate(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96,
        uint256 highGross,
        ExactEval memory lowEval,
        ExactEval memory highEval,
        ExactEval memory bestEval,
        uint160 solvedSqrtX96
    ) internal pure returns (ExactEval memory nextBestEval, ExactEval memory candidateEval, bool hasCandidate) {
        uint256 predictedGross =
            _grossToReachTarget(state.sqrtPriceX96, solvedSqrtX96, state.liquidity, zeroForOne, pc.feePips);
        if (predictedGross > highGross) predictedGross = highGross;

        candidateEval = _simulateSegmentExactIn(pc, state, zeroForOne, sqrtTargetX96, predictedGross);
        nextBestEval = _isBetterEval(candidateEval, bestEval) ? candidateEval : bestEval;
        hasCandidate = _closedFormCorrectionDirection(candidateEval, lowEval, highEval) != 0;
    }

    function _correctDiscreteClosedForm(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96,
        uint256 predictedGross,
        ExactEval memory predictedEval,
        ExactEval memory lowEval,
        ExactEval memory highEval,
        ExactEval memory bestEval,
        uint256 highGross
    ) internal pure returns (ExactEval memory) {
        int256 direction = _closedFormCorrectionDirection(predictedEval, lowEval, highEval);
        if (direction == 0) return bestEval;

        uint256 gross = predictedGross;
        ExactEval memory currentEval = predictedEval;

        for (uint256 i = 0; i < CLOSED_FORM_MAX_CORRECTION_STEPS; ++i) {
            if (direction > 0) {
                if (gross == highGross) break;
                unchecked {
                    ++gross;
                }
            } else {
                if (gross == 0) break;
                unchecked {
                    --gross;
                }
            }

            ExactEval memory nextEval = _simulateSegmentExactIn(pc, state, zeroForOne, sqrtTargetX96, gross);
            if (_isBetterEval(nextEval, bestEval)) bestEval = nextEval;
            if (nextEval.signedDustImbalanceIn1 == 0) return nextEval;
            if (!_sameSign(currentEval.signedDustImbalanceIn1, nextEval.signedDustImbalanceIn1)) break;
            if (!_isBetterEval(nextEval, currentEval)) break;

            currentEval = nextEval;
        }

        return bestEval;
    }

    function _solveClosedFormRootCandidates(
        PoolContext memory pc,
        PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96
    ) internal pure returns (uint160 root0X96, uint160 root1X96) {
        return RebalancePlannerUtils.solveClosedFormRootCandidates(pc, state, zeroForOne, sqrtTargetX96);
    }

    function _applyEval(
        PlanningState memory state,
        ExactEval memory eval_,
        bool zeroForOne,
        SegmentBoundary memory boundary,
        uint256 grossToBoundary
    ) internal pure returns (PlanningState memory) {
        PlanningState memory nextState;
        nextState.sqrtPriceX96 = state.sqrtPriceX96;
        nextState.searchTick = state.searchTick;
        nextState.liquidity = state.liquidity;
        nextState.amount0 = state.amount0;
        nextState.amount1 = state.amount1;
        nextState.totalSwapAmount = state.totalSwapAmount;
        nextState.sqrtPriceX96 = eval_.sqrtPriceX96;
        nextState.amount0 = eval_.amount0;
        nextState.amount1 = eval_.amount1;
        nextState.totalSwapAmount += eval_.grossAmountIn;
        if (eval_.grossAmountIn >= grossToBoundary && eval_.sqrtPriceX96 == boundary.sqrtTargetX96) {
            if (zeroForOne) {
                nextState.searchTick =
                    boundary.nextTick == TickMath.MIN_TICK ? TickMath.MIN_TICK : boundary.nextTick - 1;
            } else {
                nextState.searchTick = boundary.nextTick;
            }
        } else {
            nextState.searchTick = TickMath.getTickAtSqrtRatio(eval_.sqrtPriceX96);
        }
        return nextState;
    }

    function _finalizeParams(
        RebalanceParams memory params,
        bool zeroForOne,
        uint256 totalSwapAmount,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (RebalanceParams memory) {
        if (zeroForOne) {
            params.token0ToToken1 = totalSwapAmount > amount0 ? amount0 : totalSwapAmount;
        } else {
            params.token1ToToken0 = totalSwapAmount > amount1 ? amount1 : totalSwapAmount;
        }
        return params;
    }

    function _grossToReachTarget(
        uint160 sqrtStartX96,
        uint160 sqrtTargetX96,
        uint128 liquidity,
        bool zeroForOne,
        uint24 feePips
    ) internal pure returns (uint256) {
        if (sqrtStartX96 == sqrtTargetX96) return 0;
        uint256 netAmountIn = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtTargetX96, sqrtStartX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtStartX96, sqrtTargetX96, liquidity, true);
        return FullMath.mulDivRoundingUp(netAmountIn, 1e6, 1e6 - feePips);
    }

    function _crossInitializedTick(address pool, uint128 liquidity, int24 nextTick, bool zeroForOne, bool isSlip)
        internal
        view
        returns (uint128 nextLiquidity)
    {
        nextLiquidity = liquidity;
        int128 liquidityNet = _tickLiquidityNet(pool, nextTick, isSlip);
        if (zeroForOne && liquidityNet == type(int128).min) revert InvalidPoolLiquidityState();
        if (zeroForOne) liquidityNet = -liquidityNet;

        if (liquidityNet < 0) {
            uint128 liquidityDelta = uint128(-liquidityNet);
            if (liquidityDelta > nextLiquidity) revert InvalidPoolLiquidityState();
            nextLiquidity -= liquidityDelta;
        } else {
            uint128 liquidityDelta = uint128(liquidityNet);
            if (type(uint128).max - nextLiquidity < liquidityDelta) revert InvalidPoolLiquidityState();
            nextLiquidity += liquidityDelta;
        }
    }

    function _tickLiquidityNet(address pool, int24 tick, bool isSlip) internal view returns (int128 liquidityNet) {
        if (isSlip) {
            // Slipstream tracks staked liquidity as a subset of the same active liquidity.
            // Tick crossing for swap math should use the pool's total liquidity net, not add
            // the staked subset delta a second time.
            (, liquidityNet,,,,,,,,) = ISlipstreamPoolState(pool).ticks(tick);
        } else {
            (, liquidityNet,,,,,,) = IUniswapV3Pool(pool).ticks(tick);
        }
    }

    function _tickInitialized(address pool, int24 tick, bool isSlip) internal view returns (bool initialized) {
        if (isSlip) {
            (,,,,,,,,, initialized) = ISlipstreamPoolState(pool).ticks(tick);
        } else {
            (,,,,,,, initialized) = IUniswapV3Pool(pool).ticks(tick);
        }
    }

    function _nextInitializedTickWithinOneWord(
        address pool,
        int24 tick,
        int24 tickSpacing,
        bool lte,
        BitmapCursor memory cursor
    ) internal view returns (int24 next, bool initialized, bool supported) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;

        if (lte) {
            (int16 wordPos, uint8 bitPos) = _bitmapPosition(compressed);
            (uint256 word, bool ok) = _tickBitmapWord(pool, wordPos, cursor);
            if (!ok) return (0, false, false);

            uint256 mask = (uint256(1) << bitPos) - 1 + (uint256(1) << bitPos);
            uint256 masked = word & mask;
            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = _bitmapPosition(compressed + 1);
            (uint256 word, bool ok) = _tickBitmapWord(pool, wordPos, cursor);
            if (!ok) return (0, false, false);

            uint256 mask = ~((uint256(1) << bitPos) - 1);
            uint256 masked = word & mask;
            initialized = masked != 0;
            next = initialized
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }

        supported = true;
    }

    function _bitmapPosition(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(int8(tick % 256));
    }

    function _tickBitmapWord(address pool, int16 wordPos, BitmapCursor memory cursor)
        internal
        view
        returns (uint256 word, bool ok)
    {
        if (cursor.loaded && cursor.wordPos == wordPos) return (cursor.word, true);

        bytes memory data;
        (ok, data) = pool.staticcall(abi.encodeWithSelector(IUniswapV3Pool.tickBitmap.selector, wordPos));
        if (!ok || data.length < 32) return (0, false);
        word = abi.decode(data, (uint256));
        cursor.wordPos = wordPos;
        cursor.word = word;
        cursor.loaded = true;
    }

    function _scoreState(
        PoolContext memory pc,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        uint256 grossAmountIn
    ) internal pure returns (ExactEval memory eval_) {
        eval_.sqrtPriceX96 = sqrtPriceX96;
        eval_.amount0 = amount0;
        eval_.amount1 = amount1;
        eval_.grossAmountIn = grossAmountIn;

        uint128 liquidity0;
        uint128 liquidity1;
        uint256 used0;
        uint256 used1;
        uint256 dust0;
        uint256 dust1;
        uint256 dust0ValueIn1;

        if (sqrtPriceX96 <= pc.sqrtLowerX96) {
            liquidity0 = LiquidityAmounts.getLiquidityForAmount0(pc.sqrtLowerX96, pc.sqrtUpperX96, amount0);
            eval_.liquidity = liquidity0;
        } else if (sqrtPriceX96 >= pc.sqrtUpperX96) {
            liquidity1 = LiquidityAmounts.getLiquidityForAmount1(pc.sqrtLowerX96, pc.sqrtUpperX96, amount1);
            eval_.liquidity = liquidity1;
        } else {
            liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, pc.sqrtUpperX96, amount0);
            liquidity1 = LiquidityAmounts.getLiquidityForAmount1(pc.sqrtLowerX96, sqrtPriceX96, amount1);
            eval_.liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        (used0, used1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, pc.sqrtLowerX96, pc.sqrtUpperX96, eval_.liquidity);

        dust0 = amount0 > used0 ? amount0 - used0 : 0;
        dust1 = amount1 > used1 ? amount1 - used1 : 0;
        dust0ValueIn1 =
            FullMath.mulDiv(dust0, FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96), FixedPoint96.Q96);
        eval_.dustValueIn1 = dust1 + dust0ValueIn1;

        if (dust0ValueIn1 >= dust1) {
            eval_.signedDustImbalanceIn1 = int256(dust0ValueIn1 - dust1);
        } else {
            eval_.signedDustImbalanceIn1 = -int256(dust1 - dust0ValueIn1);
        }
    }

    function _isBetterEval(ExactEval memory a, ExactEval memory b) internal pure returns (bool) {
        bool aMintable = a.liquidity != 0;
        bool bMintable = b.liquidity != 0;
        if (aMintable != bMintable) return aMintable;

        if (a.liquidity != b.liquidity) return a.liquidity > b.liquidity;

        if (a.dustValueIn1 != b.dustValueIn1) return a.dustValueIn1 < b.dustValueIn1;

        uint256 absA = _abs(a.signedDustImbalanceIn1);
        uint256 absB = _abs(b.signedDustImbalanceIn1);
        if (absA != absB) return absA < absB;

        return a.grossAmountIn < b.grossAmountIn;
    }

    function _closedFormCorrectionDirection(
        ExactEval memory predictedEval,
        ExactEval memory lowEval,
        ExactEval memory highEval
    ) internal pure returns (int256) {
        if (predictedEval.signedDustImbalanceIn1 == 0) return 0;
        // Matching the low-side sign means the candidate is still below the root, so increase gross.
        // Matching the high-side sign means the candidate is above the root, so decrease gross.
        if (_sameSign(predictedEval.signedDustImbalanceIn1, lowEval.signedDustImbalanceIn1)) return 1;
        if (_sameSign(predictedEval.signedDustImbalanceIn1, highEval.signedDustImbalanceIn1)) return -1;
        return 0;
    }

    function _zeroEval() internal pure returns (ExactEval memory eval_) {}

    function _shouldStopAfterStep(ExactEval memory eval_, uint256 grossToBoundary, uint256 available)
        internal
        pure
        returns (bool)
    {
        return eval_.grossAmountIn < grossToBoundary || eval_.grossAmountIn == available;
    }

    function _sameSign(int256 a, int256 b) internal pure returns (bool) {
        if (a == 0 || b == 0) return false;
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function _loadPoolContext(
        address dex,
        address pool,
        address factory,
        address t0,
        address t1,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (PoolContext memory pc) {
        if (t0 == address(0) || t1 == address(0) || t0 == t1) revert InvalidInput();

        pc.tickLower = tickLower;
        pc.tickUpper = tickUpper;
        pc.poolAddress = pool;

        bool isUSDC0 = t0 == USDC;
        bool isUSDC1 = t1 == USDC;
        bool isBridge0 = _isBridgeToken(t0);
        bool isBridge1 = _isBridgeToken(t1);

        if (!isUSDC0 && !isUSDC1) {
            if (!isBridge0 && !isBridge1) revert UnsupportedPool();
        }

        try ICLDexAdapter(dex).isAerodrome() returns (bool b) {
            pc.isSlip = b;
        } catch {
            pc.isSlip = false;
        }

        address poolToken0;
        address poolToken1;
        try IUniswapV3Pool(pool).token0() returns (address p0) {
            poolToken0 = p0;
        } catch {
            revert PoolNotFound();
        }
        try IUniswapV3Pool(pool).token1() returns (address p1) {
            poolToken1 = p1;
        } catch {
            revert PoolNotFound();
        }

        pc.token0 = poolToken0;
        pc.token1 = poolToken1;

        if (!((poolToken0 == t0 && poolToken1 == t1) || (poolToken0 == t1 && poolToken1 == t0))) {
            revert UnsupportedPool();
        }

        // 1. Load Slot0 Safely (Low-level call to handle Interface Mismatches)
        (pc.sqrtPriceX96, pc.currentTick) = _safeGetSlot0(pool);

        // Load Liquidity
        try IUniswapV3Pool(pool).liquidity() returns (uint128 l) {
            pc.poolLiquidity = l;
        } catch {}

        try IUniswapV3Pool(pool).tickSpacing() returns (int24 ts) {
            pc.tickSpacing = ts;
        } catch {
            revert PoolNotFound();
        }

        bool feeFound = false;
        if (pc.isSlip) {
            try IAerodromeFactory(factory).getSwapFee(pool) returns (uint24 f) {
                if (f > 0) {
                    pc.feePips = f;
                    feeFound = true;
                }
            } catch {}
        } else {
            try IUniswapV3Pool(pool).fee() returns (uint24 f) {
                if (f > 0) {
                    pc.feePips = f;
                    feeFound = true;
                }
            } catch {}
        }

        if (!feeFound) revert FeeFetchFailed();

        // 3. Tick Sanity
        if (
            tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK
                || (tickLower % pc.tickSpacing != 0) || (tickUpper % pc.tickSpacing != 0)
        ) revert InvalidTicks();

        pc.sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        pc.sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    function _safeGetSlot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!success || data.length < 64) revert Slot0Failed();

        (sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
    }

    function _isBridgeToken(address token) internal view returns (bool) {
        return token != address(0) && isBridgeTokenCached[token];
    }
}

library RebalancePlannerUtils {
    uint256 internal constant FEE_SCALE = 1e6;

    error InvalidInput();

    function solveClosedFormRootCandidates(
        RebalancePlanner.PoolContext memory pc,
        RebalancePlanner.PlanningState memory state,
        bool zeroForOne,
        uint160 sqrtTargetX96
    ) public pure returns (uint160 root0X96, uint160 root1X96) {
        (int256 a, int256 b, int256 c) = closedFormQuadratic(pc, state, zeroForOne);
        if (a == 0 && b == 0) return (0, 0);

        uint256 aAbs = abs(a);
        uint256 bAbs = abs(b);
        uint256 cAbs = abs(c);

        uint256 shift = quadraticNormalizationShift(aAbs, bAbs, cAbs);
        if (shift > 0) {
            a >>= shift;
            b >>= shift;
            c >>= shift;
            aAbs = abs(a);
            bAbs = abs(b);
            cAbs = abs(c);
        }

        if (a == 0) {
            root0X96 = boundedRoot(scaledLinearRootQ96(b, c), state.sqrtPriceX96, sqrtTargetX96);
            return (root0X96, 0);
        }

        uint256 fourAC = aAbs == 0 || cAbs == 0 ? 0 : 4 * aAbs * cAbs;
        uint256 b2 = bAbs * bAbs;
        uint256 discriminant;

        if ((a > 0 && c >= 0) || (a < 0 && c <= 0)) {
            if (b2 < fourAC) return (0, 0);
            discriminant = b2 - fourAC;
        } else {
            discriminant = b2 + fourAC;
        }

        uint256 sqrtDiscriminant = Math.sqrt(discriminant);
        int256 root0Q96Signed = scaledQuadraticRootQ96(a, b, sqrtDiscriminant, true);
        int256 root1Q96Signed = scaledQuadraticRootQ96(a, b, sqrtDiscriminant, false);

        root0X96 = boundedRoot(root0Q96Signed, state.sqrtPriceX96, sqrtTargetX96);
        root1X96 = boundedRoot(root1Q96Signed, state.sqrtPriceX96, sqrtTargetX96);
    }

    function closedFormQuadratic(
        RebalancePlanner.PoolContext memory pc,
        RebalancePlanner.PlanningState memory state,
        bool zeroForOne
    ) private pure returns (int256 a, int256 b, int256 c) {
        uint256 feeDenom = FEE_SCALE - pc.feePips;
        uint256 liq = state.liquidity;
        uint256 lower = pc.sqrtLowerX96;
        uint256 upper = pc.sqrtUpperX96;
        uint256 sqrtStart = state.sqrtPriceX96;

        if (zeroForOne) {
            a = toInt(state.amount0) + toInt(grossMulDiv(liq, FixedPoint96.Q96, feeDenom, sqrtStart))
                - toInt(FullMath.mulDiv(liq, FixedPoint96.Q96, upper));

            b = toInt(liq) - toInt(grossScaled(liq, feeDenom))
                + toInt(FullMath.mulDiv(state.amount1, FixedPoint96.Q96, upper))
                + toInt(FullMath.mulDiv(liq, sqrtStart, upper))
                - toInt(FullMath.mulDiv(lower, state.amount0, FixedPoint96.Q96))
                - toInt(grossMulDiv(liq, lower, feeDenom, sqrtStart));

            c = toInt(grossMulDiv(liq, lower, feeDenom, FixedPoint96.Q96)) - toInt(state.amount1)
                - toInt(FullMath.mulDiv(liq, sqrtStart, FixedPoint96.Q96));
        } else {
            a = toInt(state.amount0) + toInt(FullMath.mulDiv(liq, FixedPoint96.Q96, sqrtStart))
                - toInt(grossMulDiv(liq, FixedPoint96.Q96, feeDenom, upper));

            b = toInt(grossScaled(liq, feeDenom)) - toInt(liq)
                - toInt(FullMath.mulDiv(lower, state.amount0, FixedPoint96.Q96))
                - toInt(FullMath.mulDiv(liq, lower, sqrtStart)) + toInt(grossMulDiv(liq, sqrtStart, feeDenom, upper))
                + toInt(FullMath.mulDiv(state.amount1, FixedPoint96.Q96, upper));

            c = toInt(FullMath.mulDiv(liq, lower, FixedPoint96.Q96)) - toInt(state.amount1)
                - toInt(grossMulDiv(liq, sqrtStart, feeDenom, FixedPoint96.Q96));
        }
    }

    function boundedRoot(int256 rootQ96, uint160 sqrtStartX96, uint160 sqrtTargetX96) private pure returns (uint160) {
        if (rootQ96 <= 0 || rootQ96 > int256(uint256(type(uint160).max))) return 0;

        uint160 root = uint160(uint256(rootQ96));
        uint160 minRoot = sqrtStartX96 < sqrtTargetX96 ? sqrtStartX96 : sqrtTargetX96;
        uint160 maxRoot = sqrtStartX96 > sqrtTargetX96 ? sqrtStartX96 : sqrtTargetX96;
        if (root < minRoot || root > maxRoot) return 0;
        return root;
    }

    function scaledQuadraticRootQ96(int256 a, int256 b, uint256 sqrtDiscriminant, bool addRoot)
        private
        pure
        returns (int256)
    {
        int256 signedSqrt = int256(sqrtDiscriminant);
        int256 numerator = -b + (addRoot ? signedSqrt : -signedSqrt);
        int256 denominator = 2 * a;
        return scaledSignedDiv(numerator, denominator, FixedPoint96.Q96);
    }

    function scaledLinearRootQ96(int256 b, int256 c) private pure returns (int256) {
        return scaledSignedDiv(-c, b, FixedPoint96.Q96);
    }

    function scaledSignedDiv(int256 numerator, int256 denominator, uint256 scale) private pure returns (int256) {
        if (numerator == 0 || denominator == 0) return 0;

        bool negative = (numerator < 0) != (denominator < 0);
        uint256 result = FullMath.mulDiv(abs(numerator), scale, abs(denominator));
        if (result > uint256(type(int256).max)) return negative ? type(int256).min + 1 : type(int256).max;
        return negative ? -int256(result) : int256(result);
    }

    function quadraticNormalizationShift(uint256 aAbs, uint256 bAbs, uint256 cAbs) private pure returns (uint256) {
        uint256 shift;
        if (bAbs > 0) {
            uint256 bBits = Math.log2(bAbs) + 1;
            if (bBits > 127) shift = bBits - 127;
        }
        if (aAbs > 0 && cAbs > 0) {
            uint256 acBits = Math.log2(aAbs) + Math.log2(cAbs) + 2;
            if (acBits > 253) {
                uint256 acShift = (acBits - 253 + 1) / 2;
                if (acShift > shift) shift = acShift;
            }
        }
        return shift;
    }

    function grossMulDiv(uint256 left, uint256 numerator, uint256 feeDenom, uint256 denominator)
        private
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(left * FEE_SCALE, numerator, feeDenom * denominator);
    }

    function grossScaled(uint256 value, uint256 feeDenom) private pure returns (uint256) {
        return FullMath.mulDiv(value, FEE_SCALE, feeDenom);
    }

    function toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert InvalidInput();
        return int256(x);
    }

    function abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}
