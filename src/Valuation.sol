// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import {ICLDexAdapter, RebalanceParams, Position, RegisterParams, PositionValueResult, PendingFeesResult, PositionDetails, ICLCore, IValuation, ICLPool, IAerodromeFactory, IUniswapV3Factory, IUniswapV3Pool, ISlipstreamPoolState, INonfungiblePositionManager} from "./Interfaces.sol";

contract Valuation is Ownable, ReentrancyGuard {
    error ZeroAddress();
    error ValuationFailed();
    error CoreNotSet();
    error DexNotAllowed();
    error DexFactoryNotFound();
    error AlreadySet();
    error InvalidTWAPSeconds();
    error InvalidDepthTicks();
    error CorePoolsLookupFailed();
    error NoPoolsToRefresh();
    error InvalidEdgeInputs();
    error PoolHasZeroReserves();
    error AnchorPoolNotFound();
    error QuotingFailed();
    error InvalidPoolTokens();
    error TWAPObservationFailed();
    error TWAPTickOutOfRange();
    error RouteNotFound();

    address public USDC;
    address public CORE;
    bool public coreSet;

    // Uniswap v3 fee tiers (0.01%, 0.05%, 0.25%, 0.30%, 1.00%)
    uint24[5] public feeTiers = [uint24(100), uint24(500), uint24(2500), uint24(3000), uint24(10_000)];
    uint32 public TWAP_SECONDS = 60;
    int24 public DEPTH_TICKS = 50;

    uint256 private constant Q192 = 1 << 192;
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant Q64  = 1 << 64;

    struct DexContext {
        address factory;
        bool isAerodrome;
        int24[] spacings; // only used if isAerodrome
    }

    struct CachedEdge {
        address pool;       // pool for (token, connector)
        uint256 scoreUSDC;  // bottleneck score in USDC units
    }

    // Cache ONLY edges "token -> connector", where connector ∈ {USDC ∪ bridgeTokens()}.
    // For connector->token swaps, callers look up edge[token][connector] and use the same pool.
    // dex => token => connector => edge. Dex in this case is the dex factory address.
    mapping(address => mapping(address => mapping(address => CachedEdge))) internal edgeToConnector;

    event CoreSet(address indexed core);
    event TWAPSecondsUpdated(uint32 twapSeconds);
    event DepthTicksUpdated(int24 depthTicks);
    event Refreshed(address indexed dexFactory, uint256 tokensCount, uint256 connectorsCount);
    event RefreshFailed(address indexed pool, bytes reason);

    constructor(address usdc_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        USDC = usdc_;
    }

    function setCore(address core) external onlyOwner {
        if (coreSet) revert AlreadySet();
        if (core == address(0)) revert ZeroAddress();
        CORE = core;
        coreSet = true;
        emit CoreSet(core);
    }

    function setTWAPSeconds(uint32 seconds_) external onlyOwner {
        if (seconds_ < 30 || seconds_ > 3600) revert InvalidTWAPSeconds();
        TWAP_SECONDS = seconds_;
        emit TWAPSecondsUpdated(seconds_);
    }

    function setDepthTicks(int24 depthTicks_) external onlyOwner {
         if (depthTicks_ <= 0 || depthTicks_ > 2000) revert InvalidDepthTicks();
        DEPTH_TICKS = depthTicks_;
        emit DepthTicksUpdated(depthTicks_);
    }

    /// @notice Refresh all cached edges for the given dexes/tokens using the current allowlist + bridgeTokens().
    /// @dev Include *every* non-connector token you want routing to support in `tokens`.
    ///      This function also refreshes edges for connectors themselves (USDC + bridges).
    ///      Called by timelock owner at a consistent interval to keep data fresh.
    function refreshAll() external onlyOwner nonReentrant {
        if (CORE == address(0)) revert CoreNotSet();

        // connectors = [USDC] + bridges
        address[] memory bridges = _bridgeTokens();
        address[] memory connectors = new address[](bridges.length + 1);
        connectors[0] = USDC;
        for (uint256 i = 0; i < bridges.length; ++i) {
            connectors[i + 1] = bridges[i];
        }

        // Gather pools from CORE (includes Allowed and Deprecated pools)
        address[] memory pools;
        try ICLCore(CORE).listAllowedPools() returns (address[] memory list) {
            pools = list;
        } catch {
            revert CorePoolsLookupFailed();
        }
        if (pools.length == 0) revert NoPoolsToRefresh();

        // Derive dex factories from the pool list (unique). Valuation caches
        // per-dex factory address when adapters are not available.

        // Collect (possibly duplicated) candidates: up to 2 per pool
        address[] memory tokenCandidates = new address[](pools.length * 2);
        uint256 candidateCount;

        for (uint256 p = 0; p < pools.length; ++p) {
            address pool = pools[p];
            if (pool == address(0)) continue;

            // best-effort: skip bad pools rather than bricking the whole refresh
            address t0;
            address t1;
            try IUniswapV3Pool(pool).token0() returns (address _t0) { t0 = _t0; } catch { continue; }
            try IUniswapV3Pool(pool).token1() returns (address _t1) { t1 = _t1; } catch { continue; }

            if (t0 != address(0) && !_isConnector(t0, connectors)) tokenCandidates[candidateCount++] = t0;
            if (t1 != address(0) && !_isConnector(t1, connectors)) tokenCandidates[candidateCount++] = t1;
        }

        // Deduplicate in-memory (O(n^2), fine for admin calls)
        address[] memory tokens = new address[](candidateCount);
        uint256 tokensCount;

        for (uint256 i = 0; i < candidateCount; ++i) {
            address t = tokenCandidates[i];
            if (t == address(0)) continue;

            bool seen;
            for (uint256 j = 0; j < tokensCount; ++j) {
                if (tokens[j] == t) { seen = true; break; }
            }
            if (!seen) tokens[tokensCount++] = t;
        }
        assembly { mstore(tokens, tokensCount) }
        // Build unique factory list from pools (best-effort)
        address[] memory dexFactories = _uniqueFactoriesFromPools(pools);

        // For each discovered factory (dex): compute anchor pools and refresh edges.
        for (uint256 d = 0; d < dexFactories.length; ++d) {
            address factory = dexFactories[d];
            DexContext memory ctx = DexContext({factory: factory, isAerodrome: false, spacings: new int24[](0)});
            int24[] memory spacings = _aerodromeSpacings(factory);
            if (spacings.length != 0) {
                ctx.isAerodrome = true;
                ctx.spacings = spacings;
            }

            if (ctx.factory == address(0)) continue;

            // Precompute connector->USDC chosen pool (by same bottleneck score)
            address[] memory connectorUsdcPools = new address[](connectors.length);
            connectorUsdcPools[0] = address(0); // USDC itself

            for (uint256 c = 1; c < connectors.length; ++c) {
                address connectorToken = connectors[c];
                if (connectorToken == address(0) || connectorToken == USDC) continue;

                (address bestPool, uint256 bestScore) =
                    _bestEdgePoolAndScore(ctx, connectorToken, USDC, connectors, connectorUsdcPools);

                edgeToConnector[factory][connectorToken][USDC] = CachedEdge(bestPool, bestScore);
                connectorUsdcPools[c] = bestPool;
            }

            // Refresh token -> connector edges for all discovered non-connector tokens
            for (uint256 i = 0; i < tokens.length; ++i) {
                _refreshTokenToConnectors(factory, ctx, tokens[i], connectors, connectorUsdcPools);
            }

            // Refresh connector -> connector edges too (so connectors can route via connectors)
            for (uint256 i = 0; i < connectors.length; ++i) {
                _refreshTokenToConnectors(factory, ctx, connectors[i], connectors, connectorUsdcPools);
            }

            emit Refreshed(factory, tokens.length, connectors.length);
        }
    }

    function _uniqueFactoriesFromPools(address[] memory pools) internal view returns (address[] memory) {
        address[] memory tmp = new address[](pools.length);
        uint256 count;
        for (uint256 i = 0; i < pools.length; ++i) {
            address pool = pools[i];
            if (pool == address(0)) continue;
            address factory;
            try IUniswapV3Pool(pool).factory() returns (address f) { factory = f; } catch { continue; }
            if (factory == address(0)) continue;

            bool seen;
            for (uint256 j = 0; j < count; ++j) {
                if (tmp[j] == factory) { seen = true; break; }
            }
            if (!seen) tmp[count++] = factory;
        }
        assembly { mstore(tmp, count) }
        return tmp;
    }

    /// @notice Value an amount of `token` in USDC using the best cached route (direct or 1-connector hop),
    ///         and TWAP spot quotes along that route. Not a price-impact quote.
    function usdcValue(address dex, address token, uint256 amount) external view returns (uint256) {
        if (amount == 0) return 0;
        if (token == USDC) return amount;
        if (CORE == address(0)) revert CoreNotSet();
        if (!ICLCore(CORE).allowedDexes(dex)) revert DexNotAllowed();
        DexContext memory ctx = _ctx(dex);
        if (ctx.factory == address(0)) revert DexFactoryNotFound();

        (address poolA, address poolB, ) = _bestRouteCached(dex, token, USDC);
        if (poolA == address(0)) revert RouteNotFound();

        // Allow zero-valued quotes (e.g. extremely small amounts) to return 0
        // instead of reverting; hard failures should already have been caught
        // by earlier checks (missing CORE, dex not allowed, or no viable route).
        uint256 out = _quoteRoute(poolA, poolB, token, USDC, amount);

        if (out == 0) return 0;
        return out;
    }

    /// @notice Return the deepest route (by cached bottleneck score), direct or 1-connector hop.
    /// @dev Assumption: "direct" is only allowed when one side is USDC or a bridge token.
    function getBestRoute(address dex, address tokenIn, address tokenOut)
        external
        view
        returns (address poolA, address poolB, uint256 scoreUSDC)
    {
        if (CORE == address(0)) revert RouteNotFound();
        if (!ICLCore(CORE).allowedDexes(dex)) revert RouteNotFound();

        DexContext memory ctx = _ctx(dex);
        if (ctx.factory == address(0)) revert RouteNotFound();

        (poolA, poolB, scoreUSDC) = _bestRouteCached(dex, tokenIn, tokenOut);
        if (poolA == address(0) || scoreUSDC == 0) revert RouteNotFound();
    }

    // =============================================================
    // Runtime routing (cached)
    // =============================================================

    function _bestRouteCached(address dex, address tokenIn, address tokenOut)
        internal
        view
        returns (address poolA, address poolB, uint256 scoreUSDC)
    {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) return (address(0), address(0), 0);

        address[] memory connectors = _connectors();
        if (connectors.length == 0) return (address(0), address(0), 0);

        bool tokenInIsConnector = _isConnector(tokenIn, connectors);
        bool tokenOutIsConnector = _isConnector(tokenOut, connectors);

        // When reading cached edges at runtime we index by factory address
        // (the refresh step caches edges keyed by factory). Resolve adapter->factory.
        DexContext memory ctx = _ctx(dex);
        address factory = ctx.factory;
        if (factory == address(0)) return (address(0), address(0), 0);

        // ---------------------------------------------------------
        // Direct candidate (only if one side is a connector)
        // - If tokenOut is connector, use edge[tokenIn][tokenOut]
        // - Else if tokenIn is connector, use edge[tokenOut][tokenIn] (same pool, reverse direction)
        // Re-check allowlist at runtime in case CORE pool status changed
        // since the last refreshAll.
        // ---------------------------------------------------------
        if (tokenOutIsConnector) {
            CachedEdge memory direct = edgeToConnector[factory][tokenIn][tokenOut];
            if (
                direct.pool != address(0) &&
                direct.scoreUSDC != 0 &&
                _poolAllowed(direct.pool)
            ) {
                poolA = direct.pool;
                poolB = address(0);
                scoreUSDC = direct.scoreUSDC;
            }
        } else if (tokenInIsConnector) {
            CachedEdge memory directReverse = edgeToConnector[factory][tokenOut][tokenIn];
            if (
                directReverse.pool != address(0) &&
                directReverse.scoreUSDC != 0 &&
                _poolAllowed(directReverse.pool)
            ) {
                poolA = directReverse.pool;
                poolB = address(0);
                scoreUSDC = directReverse.scoreUSDC;
            }
        }

        // ---------------------------------------------------------
        // 1-connector hop: tokenIn -> connector -> tokenOut
        // pathScore = min( edge[tokenIn][connector], edge[tokenOut][connector] )
        // (poolB is the same pool as edge[tokenOut][connector], used in reverse direction)
        // ---------------------------------------------------------
        for (uint256 i = 0; i < connectors.length; ++i) {
            address connector = connectors[i];
            if (connector == address(0)) continue;

            CachedEdge memory edgeIn = edgeToConnector[factory][tokenIn][connector];
            if (edgeIn.pool == address(0) || edgeIn.scoreUSDC == 0) continue;

            CachedEdge memory edgeOut = edgeToConnector[factory][tokenOut][connector];
            if (edgeOut.pool == address(0) || edgeOut.scoreUSDC == 0) continue;

            // Ignore paths that involve pools no longer allowed by CORE.
            if (!_poolAllowed(edgeIn.pool) || !_poolAllowed(edgeOut.pool)) continue;

            uint256 pathScore = edgeIn.scoreUSDC < edgeOut.scoreUSDC ? edgeIn.scoreUSDC : edgeOut.scoreUSDC;
            if (pathScore > scoreUSDC) {
                scoreUSDC = pathScore;
                poolA = edgeIn.pool;
                poolB = edgeOut.pool;
            }
        }
    }

    function _connectors() internal view returns (address[] memory connectors) {
        address[] memory bridges = _bridgeTokens();
        connectors = new address[](bridges.length + 1);
        connectors[0] = USDC;
        for (uint256 i = 0; i < bridges.length; ++i) connectors[i + 1] = bridges[i];
    }

    function _isConnector(address token, address[] memory connectors) internal pure returns (bool) {
        for (uint256 i = 0; i < connectors.length; ++i) {
            if (connectors[i] == token) return true;
        }
        return false;
    }

    // =============================================================
    // Refresh logic (non-recursive, deterministic)
    // =============================================================

    function _refreshTokenToConnectors(
        address dex,
        DexContext memory ctx,
        address token,
        address[] memory connectors,
        address[] memory connectorUsdcPools
    ) internal {
        if (token == address(0)) return;

        for (uint256 c = 0; c < connectors.length; ++c) {
            address connector = connectors[c];
            if (connector == address(0) || connector == token) continue;

            (address bestPool, uint256 bestScore) =
                _bestEdgePoolAndScore(ctx, token, connector, connectors, connectorUsdcPools);

            edgeToConnector[dex][token][connector] = CachedEdge(bestPool, bestScore);
        }
    }

    function _bestEdgePoolAndScore(
        DexContext memory ctx,
        address token,
        address connector,
        address[] memory connectors,
        address[] memory connectorUsdcPools
    ) internal returns (address bestPool, uint256 bestScoreUSDC) {
        address[] memory candidates = _poolCandidates(ctx, token, connector);
        for (uint256 i = 0; i < candidates.length; ++i) {
            address pool = candidates[i];
            try this._edgePoolScoreUSDCExternal(pool, token, connector, connectors, connectorUsdcPools) returns (uint256 s) {
                if (s > bestScoreUSDC) {
                    bestScoreUSDC = s;
                    bestPool = pool;
                }
            } catch (bytes memory reason) {
                emit RefreshFailed(pool, reason);
            }
        }
    }

    /// @dev Score a (token, connector) pool by the same bottleneck philosophy as the rest of the system:
    ///      score = min( tokenDepth valued to USDC, connectorDepth valued to USDC ) using TWAP active liquidity.
    ///      Non-recursive: values are always anchored via connector->USDC direct pool choice.
    function _edgePoolScoreUSDC(
        address pool,
        address token,
        address connector,
        address[] memory connectors,
        address[] memory connectorUsdcPools
    ) internal view returns (uint256) {
        if (pool == address(0) || token == address(0) || connector == address(0) || token == connector) {
            revert InvalidEdgeInputs();
        }
        

        (address token0, address token1) = _poolTokens(pool);
        if (token0 == address(0) || token1 == address(0)) revert InvalidPoolTokens();

        if (!((token == token0 && connector == token1) || (token == token1 && connector == token0))) {
            revert InvalidPoolTokens();
        }

        (int24 twapTick, uint160 sqrtP, uint128 avgL) = _twapSqrtPriceX96(pool);
        if (avgL == 0) revert PoolHasZeroReserves();

        // Small symmetric band around TWAP tick to approximate active depth
        int24 lowerTick = twapTick - DEPTH_TICKS;
        if (lowerTick < TickMath.MIN_TICK) lowerTick = TickMath.MIN_TICK;
        int24 upperTick = twapTick + DEPTH_TICKS;
        if (upperTick > TickMath.MAX_TICK) upperTick = TickMath.MAX_TICK;

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(upperTick);

        uint256 depth0In = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtP, avgL, true);
        uint256 depth1In = SqrtPriceMath.getAmount1Delta(sqrtP, sqrtUpper, avgL, true);

        uint256 tokenDepth;
        uint256 connectorDepth;
        if (token == token0) {
            tokenDepth = depth0In;
            connectorDepth = depth1In;
        } else if (token == token1) {
            tokenDepth = depth1In;
            connectorDepth = depth0In;
        } else {
            revert InvalidPoolTokens();
        }

        if (tokenDepth == 0 || connectorDepth == 0) revert PoolHasZeroReserves();

        // Connector is USDC: anchor is trivial
        if (connector == USDC) {
            uint256 tokenDepthAsUSDC_direct = _quoteThroughPool(pool, token, USDC, tokenDepth);
            if (tokenDepthAsUSDC_direct == 0) revert QuotingFailed();
            return tokenDepthAsUSDC_direct < connectorDepth ? tokenDepthAsUSDC_direct : connectorDepth;
        }

        // Find the chosen (connector, USDC) pool for anchoring
        address connectorUsdcPool = _connectorUsdcPool(connector, connectors, connectorUsdcPools);
        if (connectorUsdcPool == address(0)) revert AnchorPoolNotFound();

        // connectorDepth -> USDC
        uint256 connectorDepthAsUSDC = _quoteThroughPool(connectorUsdcPool, connector, USDC, connectorDepth);
        if (connectorDepthAsUSDC == 0) revert QuotingFailed();

        // tokenDepth -> connector (via this pool) -> USDC (via connectorUsdcPool)
        uint256 tokenDepthAsConnector = _quoteThroughPool(pool, token, connector, tokenDepth);
        if (tokenDepthAsConnector == 0) revert QuotingFailed();
        uint256 tokenDepthAsUSDC = _quoteThroughPool(connectorUsdcPool, connector, USDC, tokenDepthAsConnector);
        if (tokenDepthAsUSDC == 0) revert QuotingFailed();

        return tokenDepthAsUSDC < connectorDepthAsUSDC ? tokenDepthAsUSDC : connectorDepthAsUSDC;
    }

    function _connectorUsdcPool(address connector, address[] memory connectors, address[] memory connectorUsdcPools)
        internal
        pure
        returns (address)
    {
        if (connector == address(0)) return address(0);
        if (connector == connectors[0]) return address(0); // USDC
        for (uint256 i = 0; i < connectors.length; ++i) {
            if (connectors[i] == connector) return connectorUsdcPools[i];
        }
        return address(0);
    }

    // =============================================================
    // Quoting along selected route
    // =============================================================

    function _edgePoolScoreUSDCExternal(
        address pool,
        address token,
        address connector,
        address[] memory connectors,
        address[] memory connectorUsdcPools
    ) external view  returns (uint256) {
        return _edgePoolScoreUSDC(pool, token, connector, connectors, connectorUsdcPools);
    }

    function _quoteRoute(address poolA, address poolB, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        // Trivial zero-amount input always values to 0.
        if (amountIn == 0) return 0;
        // At this point a missing pool is a hard failure.
        if (poolA == address(0)) revert RouteNotFound();

        // -----------------------------------------------------
        // Direct route: tokenIn -> tokenOut via poolA
        // -----------------------------------------------------
        if (poolB == address(0)) {
            uint256 out = _quoteThroughPool(poolA, tokenIn, tokenOut, amountIn);
            return out;
        }

        // -----------------------------------------------------
        // Two-hop route: tokenIn -> connector -> tokenOut
        // -----------------------------------------------------

        // infer connector from poolA relative to tokenIn; if this fails the
        // cached route is inconsistent and we should revert.
        (address a0, address a1) = _poolTokens(poolA);
        if (a0 == address(0) || a1 == address(0)) revert InvalidPoolTokens();

        address connector;
        if (a0 == tokenIn) connector = a1;
        else if (a1 == tokenIn) connector = a0;
        else revert InvalidPoolTokens();

        uint256 midAmount = _quoteThroughPool(poolA, tokenIn, connector, amountIn);

        uint256 outFinal = _quoteThroughPool(poolB, connector, tokenOut, midAmount);

        return outFinal;
    }

    // =============================================================
    // Pool candidates / allowlist
    // =============================================================

    function _poolCandidates(DexContext memory ctx, address tokenA, address tokenB)
        internal
        view
        returns (address[] memory pools)
    {
        if (ctx.factory == address(0) || tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) {
            return new address[](0);
        }

        if (!ctx.isAerodrome) {
            address[] memory tmpFeePools = new address[](feeTiers.length);
            uint256 countFee;
            for (uint256 i = 0; i < feeTiers.length; ++i) {
                address pool = _uniswapPool(ctx.factory, tokenA, tokenB, feeTiers[i]);
                if (pool == address(0)) continue;
                tmpFeePools[countFee++] = pool;
            }
            assembly { mstore(tmpFeePools, countFee) }
            return tmpFeePools;
        }

        int24[] memory spacings = ctx.spacings;
        address[] memory tmpSpacingPools = new address[](spacings.length);
        uint256 countSpacing;
        for (uint256 i = 0; i < spacings.length; ++i) {
            address pool = _aerodromePool(ctx.factory, tokenA, tokenB, spacings[i]);
            if (pool == address(0)) continue;
            tmpSpacingPools[countSpacing++] = pool;
        }
        assembly { mstore(tmpSpacingPools, countSpacing) }
        return tmpSpacingPools;
    }

    function _uniswapPool(address factory, address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        if (factory == address(0) || tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) return address(0);

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        if (pool == address(0)) return address(0);
        if (!_poolAllowed(pool)) return address(0);
        return pool;
    }

    function _aerodromePool(address factory, address tokenA, address tokenB, int24 tickSpacing)
        internal
        view
        returns (address)
    {
        if (factory == address(0) || tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) return address(0);

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pool = IAerodromeFactory(factory).getPool(token0, token1, tickSpacing);
        if (pool == address(0)) return address(0);
        if (!_poolAllowed(pool)) return address(0);
        return pool;
    }

    function _poolAllowed(address pool) internal view returns (bool) {
        if (pool == address(0) || CORE == address(0)) return false;
        try ICLCore(CORE).isPoolAllowed(pool) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _poolTokens(address pool) internal view returns (address token0, address token1) {
        if (pool == address(0)) return (address(0), address(0));
        try IUniswapV3Pool(pool).token0() returns (address t0) { token0 = t0; } catch { return (address(0), address(0)); }
        try IUniswapV3Pool(pool).token1() returns (address t1) { token1 = t1; } catch { return (address(0), address(0)); }
    }

    function _ctx(address dex) internal view returns (DexContext memory ctx) {
        address factory = ICLDexAdapter(dex).getFactory();
        if (factory == address(0)) {
            return DexContext({factory: address(0), isAerodrome: false, spacings: new int24[](0)});
        }

        bool isAerodrome = ICLDexAdapter(dex).isAerodrome();
        if (isAerodrome) {
            int24[] memory spacings = _aerodromeSpacings(factory);
            return DexContext({factory: factory, isAerodrome: isAerodrome, spacings: spacings});
        }
        return DexContext({factory: factory, isAerodrome: isAerodrome, spacings: new int24[](0)});
    }

    function _aerodromeSpacings(address factory) internal view returns (int24[] memory spacings) {
        if (factory == address(0)) return new int24[](0);
        try IAerodromeFactory(factory).tickSpacings() returns (int24[] memory listed) {
            return listed;
        } catch {
            return new int24[](0);
        }
    }

    function _bridgeTokens() internal view returns (address[] memory bridges) {
        if (CORE == address(0)) return new address[](0);
        try ICLCore(CORE).bridgeTokens() returns (address[] memory list) {
            return list;
        } catch {
            return new address[](0);
        }
    }

    // =============================================================
    // TWAP quote
    // =============================================================

    function _quoteThroughPool(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (pool == address(0)) revert RouteNotFound();
        if (amountIn == 0) return 0;

        (address t0, address t1) = _poolTokens(pool);
        bool inIs0;

        if (tokenIn == t0 && tokenOut == t1) inIs0 = true;
        else if (tokenIn == t1 && tokenOut == t0) inIs0 = false;
        else revert InvalidPoolTokens();
        (, uint160 sqrtP, ) = _twapSqrtPriceX96(pool);
        if (sqrtP == 0) revert TWAPObservationFailed();

        // Overflow-safe price math mirroring Uniswap v3 periphery OracleLibrary logic.
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * uint256(sqrtP);
            return inIs0
                ? FullMath.mulDiv(amountIn, ratioX192, Q192)
                : FullMath.mulDiv(amountIn, Q192, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q64);
            return inIs0
                ? FullMath.mulDiv(amountIn, ratioX128, Q128)
                : FullMath.mulDiv(amountIn, Q128, ratioX128);
        }
    }

    function _twapSqrtPriceX96(address pool) internal view returns (int24 arithmeticMeanTick, uint160, uint128) {
        if (pool == address(0) || TWAP_SECONDS == 0) revert InvalidTWAPSeconds();

        // Price window (tick / sqrtP) uses TWAP_SECONDS
        uint32[] memory secondsAgosPrice = new uint32[](2);
        secondsAgosPrice[0] = TWAP_SECONDS;
        secondsAgosPrice[1] = 0;

        int56[] memory tickCumulatives;
        uint160[] memory splCumulativesPrice;

        try IUniswapV3Pool(pool).observe(secondsAgosPrice)
            returns (int56[] memory tCumulatives, uint160[] memory splPrice)
        {
            tickCumulatives = tCumulatives;
            splCumulativesPrice = splPrice;
        } catch {
            revert TWAPObservationFailed();
        }

        if (tickCumulatives.length < 2) revert TWAPObservationFailed();
        if (splCumulativesPrice.length < 2) revert TWAPObservationFailed();

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 windowPrice = int56(uint56(TWAP_SECONDS));
        if (windowPrice == 0) revert InvalidTWAPSeconds();

        arithmeticMeanTick = int24(tickDelta / windowPrice);
        if (tickDelta < 0 && (tickDelta % windowPrice) != 0) arithmeticMeanTick -= 1;

        if (arithmeticMeanTick < TickMath.MIN_TICK || arithmeticMeanTick > TickMath.MAX_TICK) {
            revert TWAPTickOutOfRange();
        }

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);

        uint160 splDelta = splCumulativesPrice[1] - splCumulativesPrice[0];
        if (splDelta == 0) revert TWAPObservationFailed();
        uint256 avgL256 = (uint256(TWAP_SECONDS) << 128) / uint256(splDelta);
        uint128 avgL = avgL256 > type(uint128).max ? type(uint128).max : uint128(avgL256);

        return (arithmeticMeanTick, sqrtP, avgL);
    }
}
