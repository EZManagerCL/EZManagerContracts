// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ICLDexAdapter, RebalanceParams, Position, RegisterParams, PositionValueResult, PendingFeesResult, PositionDetails, ICLCore, IValuation, ICLPool, IAerodromeFactory, IUniswapV3Factory, IUniswapV3Pool, ISlipstreamPoolState, INonfungiblePositionManager} from "./Interfaces.sol";

/*────────────────────────────── External Interfaces ─────────────────────────────*/

/*────────────────────────────────── Contract ───────────────────────────────────*/

/**
 * @title RebalancePlanner
 * @notice Computes optimal swap amounts using Iterative Value Decomposition (Newton's Method).
 * @dev    Achieves <0.01% dust precision using a damped Newton solver.
 * Robust against "slot0" interface differences between UniV3 and Aerodrome.
 */
contract RebalancePlanner is Ownable {
    using FullMath for uint256;

    error UsdcDecimalsTooLow();

    constructor(address usdc_, address owner_) Ownable(owner_) { 
        if (usdc_ == address(0)) revert ZeroAddress();
        USDC = usdc_; 
        usdcDecimals = IERC20Metadata(address(USDC)).decimals();
        if (usdcDecimals < 3) revert UsdcDecimalsTooLow();
        // MIN_DELTA_USDC = $0.001 in token units.
        MIN_DELTA_USDC = 10 ** uint256(usdcDecimals - 3);
    }

    /*────────────────────────────── Types ───────────────────────────────────*/


    struct PoolContext {
        address token0; address token1;
        uint24 feePips;       // The actual fee used for math
        int24 tickSpacing;
        int24 tickLower; int24 tickUpper;
        uint160 sqrtPriceX96; uint160 sqrtLowerX96; uint160 sqrtUpperX96;
        uint128 poolLiquidity;
        address poolAddress;
        address dex;
        address factory;
        bool isSlip;
    }

    // Temp variable grouping to avoid "stack too deep" in _solveIterative
    struct Vars {
        uint256 C0;
        uint256 C1;
        uint256 priceX96;
        uint256 val0in1;
        uint256 valueUser;
        uint256 valC0in1;
        uint256 valuePerLiq;
        uint256 L_ideal;
        uint256 target0;
        uint256 delta;
        uint256 deltaValueIn1;
        uint256 amountInLessFee;
        uint256 amountOut;
        uint256 amtToBoundary;
        uint256 grossDelta;
        uint256 num;
        uint256 den;
        uint256 reduce;
        bool iterZeroForOne;
        bool hitBoundary;
        uint160 nextSqrtP;
    }

    /*────────────────────────────── Storage ──────────────────────────────────*/

    address public USDC;
    uint8 public usdcDecimals;

    // Used for pool allowlists
    address public CORE;

    // On-chain valuation contract used to normalize a small absolute floor (USDC-denominated).
    address public VALUATION;

    // Marks whether CORE has been set via the one-time setter
    bool public coreSet;
    
    // Allow up to SOLVER_ITERATIONS damped Newton iterations to survive multi-tick whale trades.
    uint256 public SOLVER_ITERATIONS = 16; // default value

    // Minimum delta in USDC token units to consider meaningful. Default = $0.001
    uint256 public MIN_DELTA_USDC;
    // Minimum relative delta (parts per 100_000) to consider meaningful (0.001% default = 1)
    uint256 public MIN_DELTA_BPS = 1;
    
    /*────────────────────────────── Errors ───────────────────────────────────*/

    error UnsupportedPool(); 
    error PoolNotFound();
    error InvalidTicks(); 
    error InvalidInput();
    error MissingDexAdapter(); 
    error ZeroAddress(); 
    error FeeFetchFailed();
    error Slot0Failed();
    error AlreadySet();

    /*────────────────────────────── Init/Admin ─────────────────────────────────────*/

    function setCore(address core) external onlyOwner {
        if (coreSet) revert AlreadySet();
        if (core == address(0)) revert ZeroAddress();
        CORE = core;
        coreSet = true;
    }
    
    function setValuation(address valuation) external onlyOwner {
        VALUATION = valuation;
    }

    /// @notice Set maximum solver iterations used in the damped Newton solver
    function setSolverIterations(uint256 iters) external onlyOwner {
        if (iters == 0 || iters > 36) revert InvalidInput();
        SOLVER_ITERATIONS = iters;
    }

    /// @notice Configure early-stop thresholds: absolute USDC floor and relative BPS threshold (parts per 100_000)
    function setEarlyStop(uint256 minDeltaUsdc_, uint256 minDeltaBps_) external onlyOwner {
        MIN_DELTA_USDC = minDeltaUsdc_;
        MIN_DELTA_BPS = minDeltaBps_;
    }

    /*────────────────────────────── Entrypoints ──────────────────────────────*/

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

        // Determine a small absolute floor converted into token1 units using the valuation contract.
        uint256 minDeltaToken1 = 0;
        if (VALUATION != address(0)) {
            // Use the token's decimals to request the valuation of "1 token" (i.e. 10**decimals)
            uint8 token1Decimals = IERC20Metadata(pc.token1).decimals();

            uint256 oneTokenUnit = 10 ** uint256(token1Decimals);
            uint256 oneToken1InUSDC = IValuation(VALUATION).usdcValue(dex, pc.token1, oneTokenUnit);
            if (oneToken1InUSDC > 0) {
                minDeltaToken1 = FullMath.mulDiv(MIN_DELTA_USDC, 1, oneToken1InUSDC);
                if (minDeltaToken1 == 0) minDeltaToken1 = 1; // ensure non-zero floor
            }
        }

        // Defensive handling: ensure input amounts align with the pool's token ordering.
        // _loadPoolContext guarantees the pool exists and exposes its token0/token1 via pc.token0/pc.token1.
        // If the caller provided token0/token1 in the opposite order, swap the amounts so that
        // `amount0` corresponds to `pc.token0` and `amount1` to `pc.token1`.
        if (pc.token0 != token0) {
            uint256 tmp = amount0;
            amount0 = amount1;
            amount1 = tmp;
        }

        params = _solveIterative(pc, amount0, amount1, minDeltaToken1);
    }

    /*──────────────── Optimization Algorithm (Newton-Raphson) ────────────────*/
    function _solveIterative(
        PoolContext memory pc,
        uint256 amount0,
        uint256 amount1,
        uint256 minDeltaToken1
    ) internal view returns (RebalanceParams memory params) {
        // 1. Boundary Checks
        if (pc.sqrtPriceX96 <= pc.sqrtLowerX96) {
            if (amount1 > 0) params.token1ToToken0 = amount1;
            return params;
        }
        if (pc.sqrtPriceX96 >= pc.sqrtUpperX96) {
            if (amount0 > 0) params.token0ToToken1 = amount0;
            return params;
        }

        uint256 currentAmt0 = amount0;
        uint256 currentAmt1 = amount1;
        uint160 currentSqrtP = pc.sqrtPriceX96;

        bool globalZeroForOne;
        uint256 totalSwapAmount = 0;
        bool isDirectionSet = false;
        uint256 feeComp = 1e6 - pc.feePips;

        Vars memory v;

        for (uint256 i = 0; i < SOLVER_ITERATIONS; ) {
            // A. Calculate Capacities (Tokens per unit of L at current price)
            v.C0 = FullMath.mulDiv(
                uint256(pc.sqrtUpperX96 - currentSqrtP),
                FixedPoint96.Q96,
                FullMath.mulDiv(currentSqrtP, pc.sqrtUpperX96, FixedPoint96.Q96)
            );

            v.C1 = uint256(currentSqrtP - pc.sqrtLowerX96);

            // B. Calculate Portfolio Value in "Liquidity Units"
            v.priceX96 = FullMath.mulDiv(currentSqrtP, currentSqrtP, FixedPoint96.Q96);

            v.val0in1 = FullMath.mulDiv(currentAmt0, v.priceX96, FixedPoint96.Q96);
            v.valueUser = currentAmt1 + v.val0in1;

            v.valC0in1 = FullMath.mulDiv(v.C0, v.priceX96, FixedPoint96.Q96);
            v.valuePerLiq = v.C1 + v.valC0in1;
            
            if (v.valuePerLiq == 0) break; 

            // C. Calculate Ideal Liquidity & Target Token0
            v.L_ideal = FullMath.mulDiv(v.valueUser, FixedPoint96.Q96, v.valuePerLiq);
            v.target0 = FullMath.mulDiv(v.L_ideal, v.C0, FixedPoint96.Q96);

            // D. Calculate Delta (Swap needed)
            v.delta = 0;
            if (currentAmt0 > v.target0) {
                v.iterZeroForOne = true;
                v.delta = currentAmt0 - v.target0;
            } else {
                v.iterZeroForOne = false;
                v.delta = v.target0 - currentAmt0;
                v.delta = FullMath.mulDiv(v.delta, v.priceX96, FixedPoint96.Q96);
            }

            // Convergence check
            v.deltaValueIn1 = v.iterZeroForOne
                ? FullMath.mulDiv(v.delta, v.priceX96, FixedPoint96.Q96) // token0 → value in token1
                : v.delta; // already token1

            // Early stop when relative change is below MIN_DELTA_BPS (parts per 100_000)
            if (MIN_DELTA_BPS > 0) {
                uint256 relThreshold = v.valueUser / (100_000 / MIN_DELTA_BPS);
                if (v.deltaValueIn1 <= relThreshold) break;
            }
            // Or when absolute USDC-based floor is reached
            if (minDeltaToken1 > 0 && v.deltaValueIn1 <= minDeltaToken1) break;

            // E. Apply Damping (Newton Derivative)
            if (pc.poolLiquidity > 0) {
                v.num = uint256(pc.poolLiquidity);
                v.den = v.num + v.L_ideal;
                // Use rounding-up to avoid truncation to zero for very small deltas.
                v.delta = FullMath.mulDivRoundingUp(v.delta, v.num, v.den);
            }

            // F. Simulate Step (Exact V3 Math)
            v.amountInLessFee = FullMath.mulDiv(v.delta, feeComp, 1e6);

            // Detect if the simulated input would cross the tick boundary. If so,
            // compute the exact amount required to move price to the boundary and
            // cap the step to that amount. This prevents library reverts from
            // attempting to move price past TickMath limits and avoids unsigned
            // underflow when recomputing capacities.
            v.hitBoundary = false;

            if (v.iterZeroForOne) {
                // Swapping token0 -> token1 moves price down towards sqrtLowerX96
                v.amtToBoundary = SqrtPriceMath.getAmount0Delta(pc.sqrtLowerX96, currentSqrtP, pc.poolLiquidity, true);
                if (v.amountInLessFee >= v.amtToBoundary) {
                    // Need to convert amtToBoundary (post-fee) to gross delta (pre-fee)
                    v.grossDelta = FullMath.mulDivRoundingUp(v.amtToBoundary, 1e6, feeComp);
                    v.delta = v.grossDelta;
                    v.amountInLessFee = v.amtToBoundary;
                    v.nextSqrtP = pc.sqrtLowerX96;
                    v.amountOut = SqrtPriceMath.getAmount1Delta(v.nextSqrtP, currentSqrtP, pc.poolLiquidity, false);
                    v.hitBoundary = true;
                }
            } else {
                // Swapping token1 -> token0 moves price up towards sqrtUpperX96
                v.amtToBoundary = SqrtPriceMath.getAmount1Delta(currentSqrtP, pc.sqrtUpperX96, pc.poolLiquidity, true);
                if (v.amountInLessFee >= v.amtToBoundary) {
                    v.grossDelta = FullMath.mulDivRoundingUp(v.amtToBoundary, 1e6, feeComp);
                    v.delta = v.grossDelta;
                    v.amountInLessFee = v.amtToBoundary;
                    v.nextSqrtP = pc.sqrtUpperX96;
                    v.amountOut = SqrtPriceMath.getAmount0Delta(currentSqrtP, v.nextSqrtP, pc.poolLiquidity, false);
                    v.hitBoundary = true;
                }
            }

            if (!v.hitBoundary) {
                v.nextSqrtP = SqrtPriceMath.getNextSqrtPriceFromInput(
                    currentSqrtP,
                    pc.poolLiquidity,
                    v.amountInLessFee,
                    v.iterZeroForOne
                );

                if (v.iterZeroForOne) {
                    v.amountOut = SqrtPriceMath.getAmount1Delta(v.nextSqrtP, currentSqrtP, pc.poolLiquidity, false);
                } else {
                    v.amountOut = SqrtPriceMath.getAmount0Delta(currentSqrtP, v.nextSqrtP, pc.poolLiquidity, false);
                }
            }

            // G. Update Globals & Handle Overshoot
            if (!isDirectionSet) {
                globalZeroForOne = v.iterZeroForOne;
                isDirectionSet = true;
                totalSwapAmount = v.delta;
            } else {
                if (globalZeroForOne == v.iterZeroForOne) {
                    totalSwapAmount += v.delta;
                } else {
                    // Overshoot: Backtrack by half the delta
                    v.reduce = v.delta < totalSwapAmount ? v.delta : totalSwapAmount / 2;
                    totalSwapAmount -= v.reduce;
                }
            }

            // H. Update Virtual Balances
            currentSqrtP = uint160(v.nextSqrtP);
            if (v.iterZeroForOne) {
                currentAmt0 = (v.delta >= currentAmt0) ? 0 : currentAmt0 - v.delta;
                currentAmt1 += v.amountOut;
            } else {
                currentAmt1 = (v.delta >= currentAmt1) ? 0 : currentAmt1 - v.delta;
                currentAmt0 += v.amountOut;
            }

            unchecked { ++i; }
        }
        
        // Final Safety Cap
        if (globalZeroForOne) {
            params.token0ToToken1 = (totalSwapAmount > amount0) ? amount0 : totalSwapAmount;
        } else {
            params.token1ToToken0 = (totalSwapAmount > amount1) ? amount1 : totalSwapAmount;
        }
    }

    /*──────────────── Context Loading & Helpers ──────────────────────────────*/
    
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

        pc.token0 = t0;
        pc.token1 = t1;
        pc.tickLower = tickLower;
        pc.tickUpper = tickUpper;
        pc.dex = dex;
        pc.factory = factory;
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

        if (!_poolAllowed(pool)) revert PoolNotFound();

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

        if (!((poolToken0 == t0 && poolToken1 == t1) || (poolToken0 == t1 && poolToken1 == t0))) {
            revert UnsupportedPool();
        }

        // 1. Load Slot0 Safely (Low-level call to handle Interface Mismatches)
        pc.sqrtPriceX96 = _safeGetSqrtPrice(pool);

        // Load Liquidity
        try IUniswapV3Pool(pool).liquidity() returns (uint128 l) {
            pc.poolLiquidity = l;
        } catch {}

        // 2. Strict Fee Logic
        bool feeFound = false;

        try IUniswapV3Pool(pool).fee() returns (uint24 f) {
            if (f > 0) {
                pc.feePips = f;
                feeFound = true;
            }
        } catch {}

        try IUniswapV3Pool(pool).tickSpacing() returns (int24 ts) {
            pc.tickSpacing = ts;
        } catch {
            revert PoolNotFound();
        }

        if (!feeFound && pc.isSlip) {
            try IAerodromeFactory(factory).tickSpacingToFee(pc.tickSpacing) returns (uint24 f) {
                if (f > 0) {
                    pc.feePips = f;
                    feeFound = true;
                }
            } catch {}
        }

        if (!feeFound) revert FeeFetchFailed();

        (address tokenA, address tokenB) = poolToken0 < poolToken1
            ? (poolToken0, poolToken1)
            : (poolToken1, poolToken0);

        if (pc.isSlip) {
            try IAerodromeFactory(factory).getPool(tokenA, tokenB, pc.tickSpacing) returns (address expected) {
                if (expected != pool) revert PoolNotFound();
            } catch {
                revert PoolNotFound();
            }
        } else {
            try IUniswapV3Factory(factory).getPool(tokenA, tokenB, pc.feePips) returns (address expected) {
                if (expected != pool) revert PoolNotFound();
            } catch {
                revert PoolNotFound();
            }
        }

        // 3. Tick Sanity
        if (
            tickLower >= tickUpper ||
            tickLower < TickMath.MIN_TICK ||
            tickUpper > TickMath.MAX_TICK ||
            (tickLower % pc.tickSpacing != 0) ||
            (tickUpper % pc.tickSpacing != 0)
        ) revert InvalidTicks();

        pc.sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        pc.sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    /**
     * @dev Low-level staticcall to read `slot0`. Safely decodes just the first word (sqrtPriceX96).
     * This avoids reverts when different forks return different struct lengths.
     */
    function _safeGetSqrtPrice(address pool) internal view returns (uint160 sqrtPriceX96) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!success || data.length < 32) revert Slot0Failed();
        
        // Only decode the first 32 bytes (sqrtPriceX96)
        // This is safe regardless of whether the return data is 192 bytes (Aerodrome) or 224 bytes (UniV3)
        sqrtPriceX96 = abi.decode(data, (uint160));
    }
    
    function _poolAllowed(address pool) internal view returns (bool) {
        if (pool == address(0)) return false;
        try ICLCore(CORE).isPoolAllowed(pool) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _isBridgeToken(address token) internal view returns (bool) {
        if (CORE == address(0) || token == address(0)) {
            return false;
        }

        try ICLCore(CORE).isBridgeToken(token) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}