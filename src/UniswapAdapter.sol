// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {ICLDexAdapter, RebalanceParams, ICLCore, IValuation, IUniswapV3Pool, IUniswapV3Factory, ISwapRouterV3, IUniswapQuoterV2Like, INonfungiblePositionManager} from "./Interfaces.sol";

contract UniswapAdapter is Ownable, ReentrancyGuard, Pausable, ICLDexAdapter {
    using SafeERC20 for IERC20;

    /* ──────────────── State Variables ──────────────── */

    uint256 public constant BPS = 10_000;

    INonfungiblePositionManager public immutable NPM;
    ISwapRouterV3 public immutable ROUTER;
    IUniswapV3Factory public immutable FACTORY;
    ICLCore public CORE;
    address public VALUATION;
    
    address public immutable uniswapQuoter; // Specific to Uniswap
    bool public immutable isPancakeSwap;    // Specific to Pancake logic

    address public guardian;
    address public manager;

    uint32 public TWAP_SECONDS = 60;
    bool public coreSet;

    struct TokenRoute {
        bool exists;
        bool isDirect;
        address poolA;
        address poolB;
        uint128 score;
    }

    /* ──────────────── Events ──────────────── */

    event ManagerUpdated(address indexed who);
    event GuardianUpdated(address indexed who);
    event ValuationUpdated(address indexed valuation);
    event TwapSecondsUpdated(uint32 twapSeconds);
    event CoreSet(address indexed core);
    event Minted(
        uint256 indexed tokenId,
        address token0,
        address token1,
        uint24 fee, // Uniswap uses fee instead of tickSpacing
        int24 tickLower,
        int24 tickUpper,
        uint256 used0,
        uint256 used1,
        uint256 leftoverUSDC
    );
    event Increased(uint256 indexed tokenId, uint256 used0, uint256 used1);
    event Removed(uint256 indexed tokenId, uint256 bps, uint256 out0, uint256 out1);
    event Unwound(uint256 indexed tokenId, address to, uint256 out0, uint256 out1);
    event Swapped(
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint256 minOut,
        uint256 out
    );

    /* ──────────────── Errors ──────────────── */

    error ZeroAddress();
    error NotManager();
    error NotGuardian();
    error InvalidParam();
    error PoolNotFound();
    error QuoterFailed();
    error QuoterNotConfigured();
    error SlippageExceeded(uint256 expectedMinOut, uint256 actualOut);
    error PoolUninitialized();
    error MintFailed(bytes reason);
    error IncreaseFailed(bytes reason);
    error NPMPositionsError();
    error AlreadySet();
    error BalanceTooLow();
    error UnsupportedPair();

    /* ──────────────── Modifiers ──────────────── */

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /* ──────────────── Constructor ──────────────── */

    constructor(
        address npm,
        address router,
        address factory_,
        address quoter,
        bool _isPancakeSwap,
        address owner_
    ) Ownable(owner_) {
        if (
            npm == address(0) ||
            router == address(0) ||
            factory_ == address(0) ||
            quoter == address(0) ||
            owner_ == address(0)
        ) {
            revert ZeroAddress();
        }
        NPM = INonfungiblePositionManager(npm);
        ROUTER = ISwapRouterV3(router);
        FACTORY = IUniswapV3Factory(factory_);
        uniswapQuoter = quoter;
        isPancakeSwap = _isPancakeSwap;
    }

    /* ──────────────── Admin Functions ──────────────── */

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    function setManager(address who) external onlyOwner {
        if (who == address(0)) revert InvalidParam();
        manager = who;
        emit ManagerUpdated(who);
    }

    function setGuardian(address g) external onlyOwner {
        if (g == address(0)) revert InvalidParam();
        guardian = g;
        emit GuardianUpdated(g);
    }

    function setCore(address core) external onlyOwner {
        if (coreSet) revert AlreadySet();
        if (core == address(0)) revert InvalidParam();
        CORE = ICLCore(core);
        coreSet = true;
        emit CoreSet(core);
    }

    function setTwapSeconds(uint32 s) external onlyOwner {
        if (s < 30 || s > 3600) revert InvalidParam();
        TWAP_SECONDS = s;
        emit TwapSecondsUpdated(s);
    }

    function setValuation(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        VALUATION = v;
        emit ValuationUpdated(v);
    }

    /* ──────────────── External View Helpers ──────────────── */

    function getQuoter() external view override returns (address) {
        return uniswapQuoter;
    }

    function getNPM() external view override returns (address) {
        return address(NPM);
    }

    function getFactory() external view override returns (address) {
        return address(FACTORY);
    }

    function isAerodrome() external pure override returns (bool) {
        return false;
    }

    function bestAllowlistedLiqScore(address tokenA, address tokenB) external view override returns (uint256) {
        return _bestAllowlistedLiqScore(tokenA, tokenB);
    }

    function validateAndGetPoolParams(address pool)
        external
        view
        override
        returns (address token0, address token1, uint24 fee, int24 tickSpacing)
    {
        if (pool == address(0)) revert PoolNotFound();
        if (!_poolAllowed(pool)) revert PoolNotFound();

        try IUniswapV3Pool(pool).token0() returns (address t0) {
            token0 = t0;
        } catch {
            revert PoolNotFound();
        }

        try IUniswapV3Pool(pool).token1() returns (address t1) {
            token1 = t1;
        } catch {
            revert PoolNotFound();
        }

        try IUniswapV3Pool(pool).fee() returns (uint24 f) {
            fee = f;
        } catch {
            revert PoolNotFound();
        }

        if (fee == 0) revert InvalidParam();

        try IUniswapV3Pool(pool).tickSpacing() returns (int24 spacing) {
            tickSpacing = spacing;
        } catch {
            revert PoolNotFound();
        }

        if (tickSpacing <= 0) revert InvalidParam();

        address derived = FACTORY.getPool(token0, token1, fee);
        if (derived == address(0) || derived != pool) revert PoolNotFound();
    }

    /* ──────────────── ICLDexAdapter: Core ──────────────── */

    function seedPairFromUSDC(
        address usdc,
        address token0,
        address token1,
        uint256 netUSDC,
        uint256 remainingLossUSDC
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (uint256 amount0In, uint256 amount1In, uint256 remainingLossUSDCOut)
    {
        if (token0 == token1) revert UnsupportedPair();

        remainingLossUSDCOut = remainingLossUSDC;
        if (netUSDC == 0) {
            return (0, 0, remainingLossUSDCOut);
        }

        _requireBalance(usdc, netUSDC);

        bool token0IsUSDC = token0 == usdc;
        bool token1IsUSDC = token1 == usdc;

        if (token0IsUSDC || token1IsUSDC) {
            amount0In = token0IsUSDC ? netUSDC : 0;
            amount1In = token1IsUSDC ? netUSDC : 0;
            return (amount0In, amount1In, remainingLossUSDCOut);
        }

        bool token0IsBridge = _isBridgeToken(token0);
        bool token1IsBridge = _isBridgeToken(token1);

        address seedToken;
        if (token0IsBridge && !token1IsBridge) {
            seedToken = token0;
        } else if (token1IsBridge && !token0IsBridge) {
            seedToken = token1;
        } else if (token0IsBridge && token1IsBridge) {
            uint256 score0 = _bestAllowlistedLiqScore(usdc, token0);
            uint256 score1 = _bestAllowlistedLiqScore(usdc, token1);
            if (score0 == 0 && score1 == 0) revert UnsupportedPair();
            seedToken = score0 >= score1 ? token0 : token1;
        } else {
            revert UnsupportedPair();
        }

        uint256 seedAmount;
        (seedAmount, remainingLossUSDCOut) = _swapUSDCToToken(usdc, seedToken, netUSDC, remainingLossUSDCOut, address(this));
        if (seedAmount == 0) revert UnsupportedPair();

        if (seedToken == token0) {
            amount0In = seedAmount;
            amount1In = 0;
        } else {
            amount0In = 0;
            amount1In = seedAmount;
        }
    }

    function mintPosition(
        address token0,
        address token1,
        address usdc,
        uint24 poolFee,
        int24 /*tickSpacing*/,
        int24 tickLower,
        int24 tickUpper,
        address nftRecipient,
        uint256 amount0,
        uint256 amount1,
        RebalanceParams calldata rebalance,
        uint256 remainingLossUSDC
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (uint256 tokenId, uint256 used0, uint256 used1, uint256 leftoverUSDC, uint256 remainingLossUSDCOut)
    {
        if (amount0 == 0 && amount1 == 0) revert InvalidParam();
        uint256 remainingLoss = remainingLossUSDC;

        _requireBalance(token0, amount0);
        _requireBalance(token1, amount1);

        remainingLoss = _executeRebalance(token0, token1, poolFee, rebalance, remainingLoss, usdc);

        uint256 finalBal0 = IERC20(token0).balanceOf(address(this));
        uint256 finalBal1 = IERC20(token1).balanceOf(address(this));

        if (finalBal0 == 0 && finalBal1 == 0) revert InvalidParam();

        address pool = _poolFor(token0, token1, poolFee);
        (uint256 min0, uint256 min1) = _computeSlippageMins(
            pool,
            finalBal0,
            finalBal1,
            tickLower,
            tickUpper,
            remainingLoss,
            usdc,
            token0,
            token1
        );

        _approveExact(IERC20(token0), address(NPM), finalBal0);
        _approveExact(IERC20(token1), address(NPM), finalBal1);

        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: poolFee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: finalBal0,
            amount1Desired: finalBal1,
            amount0Min: min0,
            amount1Min: min1,
            recipient: nftRecipient,
            deadline: block.timestamp
        });

        // Use try/catch pattern to align with AerodromeAdapter exactly, even if underlying mechanics are similar.
        try NPM.mint(mp) returns (uint256 mintedId, uint128, uint256 amt0, uint256 amt1) {
            tokenId = mintedId;
            used0 = amt0;
            used1 = amt1;
        } catch (bytes memory reason) {
             _approveExact(IERC20(token0), address(NPM), 0);
             _approveExact(IERC20(token1), address(NPM), 0);
             revert MintFailed(reason);
        }

        _approveExact(IERC20(token0), address(NPM), 0);
        _approveExact(IERC20(token1), address(NPM), 0);

        if (used0 == 0 && used1 == 0) revert InvalidParam();

        (leftoverUSDC, remainingLossUSDCOut) = _returnDust(token0, token1, usdc, msg.sender, remainingLoss);

        emit Minted(tokenId, token0, token1, poolFee, tickLower, tickUpper, used0, used1, leftoverUSDC);
    }

    function addLiquidity(
        bytes calldata positionRef,
        address usdc,
        uint256 amount0,
        uint256 amount1,
        RebalanceParams calldata rebalance,
        uint256 remainingLossUSDC
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (uint256 used0, uint256 used1, uint256 leftoverUSDC, uint256 remainingLossUSDCOut)
    {
        if (amount0 == 0 && amount1 == 0) revert InvalidParam();
        uint256 remainingLoss = remainingLossUSDC;

        uint256 tokenId = abi.decode(positionRef, (uint256));

        (,,,, uint24 poolFee,,,,,,,) = NPM.positions(tokenId);

        // Helper to get tokens from position for balance check / rebalance
        (address t0, address t1) = _getTokensFromPosition(tokenId);
        
        address pool = _poolFor(t0, t1, poolFee);
        if (pool == address(0)) revert PoolNotFound();
        
        _requireBalance(t0, amount0);
        _requireBalance(t1, amount1);

        remainingLoss = _executeRebalance(t0, t1, poolFee, rebalance, remainingLoss, usdc);

        uint256 fbal0 = IERC20(t0).balanceOf(address(this));
        uint256 fbal1 = IERC20(t1).balanceOf(address(this));

        _approveExact(IERC20(t0), address(NPM), fbal0);
        _approveExact(IERC20(t1), address(NPM), fbal1);

        int24 tickLower;
        int24 tickUpper;
        {
             (,,,,, int24 _tl, int24 _tu,,,,,) = NPM.positions(tokenId);
             tickLower = _tl;
             tickUpper = _tu;
        }

        (uint256 min0, uint256 min1) = _computeSlippageMins(
            pool,
            fbal0,
            fbal1,
            tickLower,
            tickUpper,
            remainingLoss,
            usdc,
            t0,
            t1
        );

        INonfungiblePositionManager.IncreaseLiquidityParams memory ip = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: fbal0,
                amount1Desired: fbal1,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp
            });

        try NPM.increaseLiquidity(ip) returns (uint128, uint256 amt0, uint256 amt1) {
            used0 = amt0;
            used1 = amt1;
        } catch (bytes memory reason) {
            _approveExact(IERC20(t0), address(NPM), 0);
            _approveExact(IERC20(t1), address(NPM), 0);
            revert IncreaseFailed(reason);
        }

        _approveExact(IERC20(t0), address(NPM), 0);
        _approveExact(IERC20(t1), address(NPM), 0);

        (leftoverUSDC, remainingLossUSDCOut) = _returnDust(t0, t1, usdc, msg.sender, remainingLoss);

        emit Increased(tokenId, used0, used1);
    }

    function removeLiquidityBpsUSDC(
        bytes calldata positionRef,
        uint256 bps,
        address usdc,
        address receiver,
        uint256 remainingLossUSDC
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (uint256 usdcOut)
    {
        if (bps == 0 || bps > 1e18) revert InvalidParam();

        uint256 tokenId = abi.decode(positionRef, (uint256));
        
        address t0;
        address t1;
        uint128 L;
        try NPM.positions(tokenId) returns (
            uint96, address, address _t0, address _t1, uint24, int24, int24, uint128 _L, uint256, uint256, uint128, uint128
        ) {
            t0 = _t0;
            t1 = _t1;
            L = _L;
        } catch {
            revert NPMPositionsError();
        }

        if (L == 0) {
            emit Removed(tokenId, bps, 0, 0);
            return 0;
        }

        uint128 lRemove = uint128(FullMath.mulDiv(uint256(L), bps, 1e18));
        uint256 out0;
        uint256 out1;

        if (lRemove > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory dp =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: lRemove,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                });

            (out0, out1) = NPM.decreaseLiquidity(dp);

            if (out0 > 0 || out1 > 0) {
                INonfungiblePositionManager.CollectParams memory cp =
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    });

                (out0, out1) = NPM.collect(cp);
            }
        }

        uint256 remainingLoss = remainingLossUSDC;
        uint256 totalUSDC;
        if (out0 > 0) {
            if (t0 == usdc) {
                totalUSDC += out0;
                IERC20(usdc).safeTransfer(receiver, out0);
            } else {
                uint256 got;
                (got, remainingLoss) = _swapTokenToUSDC(t0, usdc, out0, remainingLoss, receiver);
                totalUSDC += got;
            }
        }

        if (out1 > 0) {
            if (t1 == usdc) {
                totalUSDC += out1;
                IERC20(usdc).safeTransfer(receiver, out1);
            } else {
                uint256 got;
                (got, remainingLoss) = _swapTokenToUSDC(t1, usdc, out1, remainingLoss, receiver);
                totalUSDC += got;
            }
        }

        emit Removed(tokenId, bps, out0, out1);
        return totalUSDC;
    }

    function collectFeesToUSDC(bytes calldata positionRef, address usdc, uint256 remainingLossUSDC)
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (uint256 fee0, uint256 fee1, uint256 usdcOut, uint256 remainingLossUSDCOut)
    {
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        uint256 tokenId = abi.decode(positionRef, (uint256));
        (address t0, address t1) = _getTokensFromPosition(tokenId);

        (fee0, fee1) = _collectFeesToTokensInternal(tokenId);

        uint256 remainingLoss = remainingLossUSDC;
        if (fee0 > 0 && t0 != usdc) {
            (, remainingLoss) = _swapTokenToUSDC(t0, usdc, fee0, remainingLoss, address(this));
        }
        if (fee1 > 0 && t1 != usdc) {
            (, remainingLoss) = _swapTokenToUSDC(t1, usdc, fee1, remainingLoss, address(this));
        }

        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
        usdcOut = usdcAfter - usdcBefore;

        if (usdcOut > 0) {
            IERC20(usdc).safeTransfer(msg.sender, usdcOut);
        }

        remainingLossUSDCOut = remainingLoss;
    }

    function collectFeesToTokens(bytes calldata positionRef, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (address token0, address token1, uint256 fee0, uint256 fee1)
    {
        uint256 tokenId = abi.decode(positionRef, (uint256));
        (token0, token1) = _getTokensFromPosition(tokenId);
        (fee0, fee1) = _collectFeesToTokensInternal(tokenId);

        if (receiver != address(this)) {
            if (fee0 > 0) IERC20(token0).safeTransfer(receiver, fee0);
            if (fee1 > 0) IERC20(token1).safeTransfer(receiver, fee1);
        }
    }

    function unwindToTokens(bytes calldata positionRef, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        onlyManager
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 tokenId = abi.decode(positionRef, (uint256));

        (,, address t0, address t1,,,, uint128 L,,,,) = NPM.positions(tokenId);

        uint256 c0;
        uint256 c1;

        if (L > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory dp = INonfungiblePositionManager
                .DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: L,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                });
            (c0, c1) = NPM.decreaseLiquidity(dp);
        }

        {
            INonfungiblePositionManager.CollectParams memory cp = INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: receiver,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            (c0, c1) = NPM.collect(cp);
        }

        NPM.burn(tokenId);

        tokens = new address[](2);
        amounts = new uint256[](2);
        tokens[0] = t0;
        tokens[1] = t1;
        amounts[0] = c0;
        amounts[1] = c1;

        emit Unwound(tokenId, receiver, c0, c1);
    }

    function swapExactUSDCForToken(
        address usdc,
        address tokenOut,
        uint256 amountIn,
        uint256 remainingLossUSDC,
        address recipient
    ) external override nonReentrant whenNotPaused onlyManager returns (uint256 out, uint256 remainingLossUSDCOut) {
        if (amountIn == 0) return (0, remainingLossUSDC);
        address to = recipient == address(0) ? msg.sender : recipient;
        _requireBalance(usdc, amountIn);
        (out, remainingLossUSDCOut) = _swapUSDCToToken(usdc, tokenOut, amountIn, remainingLossUSDC, to);
    }

    function swapExactInToUSDC(
        address tokenIn,
        uint256 amountIn,
        address usdc,
        address receiver,
        uint256 remainingLossUSDC
    ) external override nonReentrant whenNotPaused onlyManager returns (uint256 amountOutUSDC, uint256 remainingLossUSDCOut) {
        if (amountIn == 0) return (0, remainingLossUSDC);
        _requireBalance(tokenIn, amountIn);
        (amountOutUSDC, remainingLossUSDCOut) = _swapTokenToUSDC(tokenIn, usdc, amountIn, remainingLossUSDC, receiver);
    }

    function quoteToToken(address tokenIn, uint256 amountIn, address tokenOut)
        external
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        if (tokenIn == tokenOut) return amountIn;

        TokenRoute memory route = _getBestPath(tokenIn, tokenOut);
        if (!route.exists) revert PoolNotFound();

        if (route.isDirect) {
            if (route.poolA == address(0)) revert PoolNotFound();
            uint24 feeDirect = _poolFee(route.poolA);
            return _quoteExactInSingleHop(tokenIn, tokenOut, feeDirect, amountIn);
        }

        if (route.poolA == address(0) || route.poolB == address(0)) revert PoolNotFound();

        (address bridgeToken, ) = _counterpartToken(route.poolA, tokenIn);
        uint24 feeIn = _poolFee(route.poolA);

        uint256 bridgeOut = _quoteExactInSingleHop(tokenIn, bridgeToken, feeIn, amountIn);
        if (bridgeOut == 0) return 0;

        (address finalToken, ) = _counterpartToken(route.poolB, bridgeToken);
        if (finalToken != tokenOut) revert PoolNotFound();

        uint24 feeOut = _poolFee(route.poolB);
        return _quoteExactInSingleHop(bridgeToken, tokenOut, feeOut, bridgeOut);
    }

    function getExpectedOutUSDC(address tokenIn, uint256 amountIn, address usdc) external view returns (uint256) {
        if (amountIn == 0) return 0;
        if (tokenIn == usdc) return amountIn;
        if (tokenIn == address(0) || usdc == address(0)) revert InvalidParam();

        TokenRoute memory route = _getBestPath(tokenIn, usdc);
        if (!route.exists || route.poolA == address(0)) revert PoolNotFound();

        if (route.isDirect) {
            return _minOutFromPool(route.poolA, tokenIn, amountIn, 0);
        }

        if (route.poolB == address(0)) revert PoolNotFound();

        (address connector, ) = _counterpartToken(route.poolA, tokenIn);
        uint256 midAmount = _minOutFromPool(route.poolA, tokenIn, amountIn, 0);
        if (midAmount == 0) return 0;

        return _minOutFromPool(route.poolB, connector, midAmount, 0);
    }

    /* ──────────────── Internal: Swap & Route Logic ──────────────── */

    function _getBestPath(address tokenIn, address tokenOut) internal view returns (TokenRoute memory best) {
        (address poolA, address poolB, uint256 scoreUSDC) =
            IValuation(VALUATION).getBestRoute(address(this), tokenIn, tokenOut);

        if (poolA == address(0)) return best;

        best.exists = true;
        best.poolA = poolA;
        best.poolB = poolB;
        best.isDirect = (poolB == address(0));
        best.score = scoreUSDC > type(uint128).max ? type(uint128).max : uint128(scoreUSDC);

        return best;
    }

    function _swapUSDCToToken(
        address usdc,
        address tokenOut,
        uint256 usdcIn,
        uint256 remainingLossUSDC,
        address recipient
    ) private returns (uint256 out, uint256 remainingLossUSDCOut) {
        if (usdcIn == 0) return (0, remainingLossUSDC);

        if (tokenOut == usdc) {
            if (recipient != address(this) && recipient != address(0)) {
                IERC20(usdc).safeTransfer(recipient, usdcIn);
            }
            return (usdcIn, remainingLossUSDC);
        }

        TokenRoute memory r = _getBestPath(usdc, tokenOut);
        if (!r.exists) revert PoolNotFound();
        if (r.poolA == address(0)) revert PoolNotFound();

        if (r.isDirect) {
            (address counterpart, ) = _counterpartToken(r.poolA, usdc);
            if (counterpart != tokenOut) revert PoolNotFound();

            uint24 fee = _poolFee(r.poolA);
            return _swapExactInSingleHop(usdc, tokenOut, fee, usdcIn, remainingLossUSDC, recipient, usdc);
        }

        // Two-hop route: usdc -> bridgeToken -> tokenOut
        (address bridgeToken, ) = _counterpartToken(r.poolA, usdc);
        uint24 feeIn = _poolFee(r.poolA);
        uint24 feeOut = _poolFee(r.poolB);

        uint256 remaining = remainingLossUSDC;

        uint256 bridgeAmount;
        (bridgeAmount, remaining) = _swapExactInSingleHop(
            usdc,
            bridgeToken,
            feeIn,
            usdcIn,
            remaining,
            address(this),
            usdc
        );
        if (bridgeAmount == 0) return (0, remaining);

        (address outToken, ) = _counterpartToken(r.poolB, bridgeToken);
        if (outToken != tokenOut) revert PoolNotFound();

        return _swapExactInSingleHop(bridgeToken, tokenOut, feeOut, bridgeAmount, remaining, recipient, usdc);
    }

    function _swapTokenToUSDC(
        address tokenIn,
        address usdc,
        uint256 amountIn,
        uint256 remainingLossUSDC,
        address receiver
    ) private returns (uint256 out, uint256 remainingLossUSDCOut) {
        if (amountIn == 0) return (0, remainingLossUSDC);

        if (tokenIn == usdc) {
            if (receiver != address(this) && receiver != address(0)) {
                IERC20(usdc).safeTransfer(receiver, amountIn);
            }
            return (amountIn, remainingLossUSDC);
        }

        TokenRoute memory route = _getBestPath(tokenIn, usdc);
        if (!route.exists) revert PoolNotFound();

        if (route.isDirect) {
            if (route.poolA == address(0)) revert PoolNotFound();

            (address counterpart, ) = _counterpartToken(route.poolA, tokenIn);
            if (counterpart != usdc) revert PoolNotFound();

            uint24 fee = _poolFee(route.poolA);
            return _swapExactInSingleHop(tokenIn, usdc, fee, amountIn, remainingLossUSDC, receiver, usdc);
        }

        if (route.poolA == address(0) || route.poolB == address(0)) revert PoolNotFound();

        // Two-hop route: tokenIn -> bridgeToken -> usdc
        (address bridgeToken, ) = _counterpartToken(route.poolA, tokenIn);
        uint24 feeIn = _poolFee(route.poolA);
        uint24 feeOut = _poolFee(route.poolB);

        uint256 remaining = remainingLossUSDC;

        uint256 bridgeAmount;
        (bridgeAmount, remaining) = _swapExactInSingleHop(tokenIn, bridgeToken, feeIn, amountIn, remaining, address(this), usdc);
        if (bridgeAmount == 0) return (0, remaining);

        (address outToken, ) = _counterpartToken(route.poolB, bridgeToken);
        if (outToken != usdc) revert PoolNotFound();

        return _swapExactInSingleHop(bridgeToken, usdc, feeOut, bridgeAmount, remaining, receiver, usdc);
    }

    function _swapExactInSingleHop(
        address tokenIn,
        address tokenOut,
        uint24 forcedFee,
        uint256 amountIn,
        uint256 remainingLossUSDC,
        address recipient,
        address usdc
    ) private returns (uint256 out, uint256 remainingLossUSDCOut) {
        if (amountIn == 0) return (0, remainingLossUSDC);

        if (tokenIn == tokenOut) {
            if (recipient != address(this) && recipient != address(0)) {
                IERC20(tokenIn).safeTransfer(recipient, amountIn);
            }
            return (amountIn, remainingLossUSDC);
        }

        uint24 fee = forcedFee;
        if (fee == 0) {
            fee = _bestFee(tokenIn, tokenOut);
        }

        address pool = _poolFor(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert PoolNotFound();

        uint256 expectedOut = _expectedOutFromPool(pool, tokenIn, amountIn);
        uint256 expectedOutUSDC_ = _expectedOutUSDC(usdc, tokenOut, expectedOut);
        uint256 minOut = _minOutFromLossBudget(expectedOut, expectedOutUSDC_, remainingLossUSDC);

        _approveExact(IERC20(tokenIn), address(ROUTER), amountIn);
        
        if (!isPancakeSwap) {
            ISwapRouterV3.ExactInputSingleParams memory p = ISwapRouterV3.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });
            out = ROUTER.exactInputSingle(p);
        } else {
             uint256 deadline = block.timestamp;
            bytes memory data = abi.encodeWithSignature(
                "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
                tokenIn,
                tokenOut,
                fee,
                recipient,
                deadline,
                amountIn,
                minOut,
                uint160(0)
            );
            (bool ok, bytes memory ret) = address(ROUTER).call{value: 0}(data);
            if (!ok) revert InvalidParam();
            out = abi.decode(ret, (uint256));
        }

        _approveExact(IERC20(tokenIn), address(ROUTER), 0);

        if (minOut > 0 && out < minOut) {
            revert SlippageExceeded(minOut, out);
        }

        emit Swapped(tokenIn, tokenOut, amountIn, fee, minOut, out);
        uint256 usedLossUSDC = _usedLossUSDC(expectedOut, out, expectedOutUSDC_);
        if (usedLossUSDC > remainingLossUSDC) usedLossUSDC = remainingLossUSDC;
        remainingLossUSDCOut = remainingLossUSDC - usedLossUSDC;
    }

    function _executeRebalance(
        address token0,
        address token1,
        uint24 fee,
        RebalanceParams calldata rebalance,
        uint256 remainingLossUSDC,
        address usdc
    ) private returns (uint256 remainingLossUSDCOut) {
        uint256 t0ToT1 = rebalance.token0ToToken1;
        uint256 t1ToT0 = rebalance.token1ToToken0;

        if (t0ToT1 == 0 && t1ToT0 == 0) return remainingLossUSDC;
        if (t0ToT1 > 0 && t1ToT0 > 0) revert InvalidParam();
        if (fee == 0) revert InvalidParam();
        
        // Use single hop swap directly
        if (t0ToT1 > 0) {
            uint256 bal0 = IERC20(token0).balanceOf(address(this));
            if (t0ToT1 > bal0) revert InvalidParam();
            (, remainingLossUSDCOut) =
                _swapExactInSingleHop(token0, token1, fee, t0ToT1, remainingLossUSDC, address(this), usdc);
        } else {
            uint256 bal1 = IERC20(token1).balanceOf(address(this));
            if (t1ToT0 > bal1) revert InvalidParam();
            (, remainingLossUSDCOut) =
                _swapExactInSingleHop(token1, token0, fee, t1ToT0, remainingLossUSDC, address(this), usdc);
        }
    }

    function _quoteExactInSingleHop(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) private returns (uint256 quoted) {
        if (amountIn == 0) return 0;
        if (uniswapQuoter == address(0)) revert QuoterNotConfigured();

        IUniswapQuoterV2Like.QuoteExactInputSingleParams memory qp = IUniswapQuoterV2Like
            .QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            });

        try IUniswapQuoterV2Like(uniswapQuoter).quoteExactInputSingle(qp) returns (
            uint256 amountOut,
            uint160,
            uint32,
            uint256
        ) {
            quoted = amountOut;
        } catch {
            revert QuoterFailed();
        }
    }

    /* ──────────────── Internal: Pool Helpers ──────────────── */

    function _bestFee(address tokenA, address tokenB) internal view returns (uint24 fee) {
        TokenRoute memory r = _getBestPath(tokenA, tokenB);
        bool found = r.exists && r.isDirect && r.poolA != address(0);
        if (!found) revert PoolNotFound();
        return _poolFee(r.poolA);
    }

    function _poolFor(address tokenA, address tokenB, uint24 fee) internal view returns (address pool) {
        (address ordered0, address ordered1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = FACTORY.getPool(ordered0, ordered1, fee);
        if (pool != address(0) && !_poolAllowed(pool)) revert PoolNotFound();
    }

    function _poolFee(address pool) internal view returns (uint24 fee) {
        if (pool == address(0)) revert PoolNotFound();
        try IUniswapV3Pool(pool).fee() returns (uint24 f) {
            fee = f;
        } catch {
            revert PoolNotFound();
        }
    }

    function _getTokensFromPosition(uint256 tokenId) internal view returns (address t0, address t1) {
        (,, address _t0, address _t1,,,,,,,,) = NPM.positions(tokenId);	
        t0 = _t0;	
        t1 = _t1;	
    }

    function _poolTokens(address pool) internal view returns (address token0, address token1) {
        if (pool == address(0)) revert PoolNotFound();
        try IUniswapV3Pool(pool).token0() returns (address t0) {
            token0 = t0;
        } catch {
            revert PoolNotFound();
        }
        try IUniswapV3Pool(pool).token1() returns (address t1) {
            token1 = t1;
        } catch {
            revert PoolNotFound();
        }
    }

    function _counterpartToken(address pool, address knownToken)
        internal
        view
        returns (address other, bool knownIsToken0)
    {
        (address token0, address token1) = _poolTokens(pool);
        if (knownToken == token0) return (token1, true);
        if (knownToken == token1) return (token0, false);
        revert InvalidParam();
    }

    function _minOutFromPool(
        address pool,
        address tokenIn,
        uint256 amountIn,
        uint256 slippageBps
    ) internal view returns (uint256 minOut) {
        if (amountIn == 0) return 0;
        if (pool == address(0)) revert PoolNotFound();

        IUniswapV3Pool p = IUniswapV3Pool(pool);

        address token0 = p.token0();
        address token1 = p.token1();
        if (tokenIn != token0 && tokenIn != token1) revert InvalidParam();
        bool zeroForOne = (tokenIn == token0);
        uint24 fee = p.fee();

        uint256 amountInPostFee = FullMath.mulDiv(amountIn, (1_000_000 - fee), 1_000_000);
        if (amountInPostFee == 0) return 0;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_SECONDS;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = p.observe(secondsAgos);

        int56 tickCumPast = tickCumulatives[0];
        int56 tickCumNow  = tickCumulatives[1];
        int56 tickDelta = tickCumNow - tickCumPast;
        int56 twapSeconds = int56(uint56(TWAP_SECONDS));

        int24 meanTick = int24(tickDelta / twapSeconds);
        if (tickDelta < 0 && (tickDelta % twapSeconds) != 0) {
            meanTick -= 1;
        }

        uint160 sqrtPriceTwapX96 = TickMath.getSqrtRatioAtTick(meanTick);
        uint256 priceX96 = FullMath.mulDiv(
            uint256(sqrtPriceTwapX96),
            uint256(sqrtPriceTwapX96),
            FixedPoint96.Q96
        );

        uint256 expectedOut = zeroForOne
            ? FullMath.mulDiv(amountInPostFee, priceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(amountInPostFee, FixedPoint96.Q96, priceX96);

        uint256 sl = _clampSlippage(slippageBps);
        minOut = FullMath.mulDiv(expectedOut, (BPS - sl), BPS);
    }

    function _minOutFromExpected(uint256 expectedOut, uint256 slippageBps) internal pure returns (uint256) {
        if (expectedOut == 0) return 0;
        uint256 sl = _clampSlippage(slippageBps);
        return FullMath.mulDiv(expectedOut, (BPS - sl), BPS);
    }

    function _expectedOutFromPool(address pool, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        if (amountIn == 0) return 0;
        if (pool == address(0)) revert PoolNotFound();

        IUniswapV3Pool p = IUniswapV3Pool(pool);

        address token0 = p.token0();
        address token1 = p.token1();
        if (tokenIn != token0 && tokenIn != token1) revert InvalidParam();
        bool zeroForOne = (tokenIn == token0);
        uint24 fee = p.fee();

        uint256 amountInPostFee = FullMath.mulDiv(amountIn, (1_000_000 - fee), 1_000_000);
        if (amountInPostFee == 0) return 0;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_SECONDS;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = p.observe(secondsAgos);

        int56 tickCumPast = tickCumulatives[0];
        int56 tickCumNow  = tickCumulatives[1];
        int56 tickDelta = tickCumNow - tickCumPast;
        int56 twapSeconds = int56(uint56(TWAP_SECONDS));

        int24 meanTick = int24(tickDelta / twapSeconds);
        if (tickDelta < 0 && (tickDelta % twapSeconds) != 0) {
            meanTick -= 1;
        }

        uint160 sqrtPriceTwapX96 = TickMath.getSqrtRatioAtTick(meanTick);
        uint256 priceX96 = FullMath.mulDiv(
            uint256(sqrtPriceTwapX96),
            uint256(sqrtPriceTwapX96),
            FixedPoint96.Q96
        );

        return zeroForOne
            ? FullMath.mulDiv(amountInPostFee, priceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(amountInPostFee, FixedPoint96.Q96, priceX96);
    }

    function _computeSlippageMins(
        address pool,
        uint256 balance0,
        uint256 balance1,
        int24 tickLower,
        int24 tickUpper,
        uint256 remainingLossUSDC,
        address usdc,
        address token0,
        address token1
    ) internal view returns (uint256 min0, uint256 min1) {
        uint256 used0Pred;
        uint256 used1Pred;

        if (pool == address(0)) {
            used0Pred = balance0;
            used1Pred = balance1;
        } else {
            uint160 sqrtPriceX96;
            {
                IUniswapV3Pool p = IUniswapV3Pool(pool);
                uint32[] memory secondsAgos = new uint32[](2);
                secondsAgos[0] = TWAP_SECONDS;
                secondsAgos[1] = 0;

                (int56[] memory tickCumulatives, ) = p.observe(secondsAgos);
                int56 tickCumPast = tickCumulatives[0];
                int56 tickCumNow = tickCumulatives[1];
                int56 tickDelta = tickCumNow - tickCumPast;
                int56 twapSeconds = int56(uint56(TWAP_SECONDS));

                int24 meanTick = int24(tickDelta / twapSeconds);
                if (tickDelta < 0 && (tickDelta % twapSeconds) != 0) {
                    meanTick -= 1;
                }

                sqrtPriceX96 = TickMath.getSqrtRatioAtTick(meanTick);
            }

            if (sqrtPriceX96 == 0) revert PoolUninitialized();

            uint160 sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtLowerX96,
                sqrtUpperX96,
                balance0,
                balance1
            );

            if (liquidity == 0) {
                used0Pred = balance0;
                used1Pred = balance1;
            } else {
                (used0Pred, used1Pred) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96,
                    sqrtLowerX96,
                    sqrtUpperX96,
                    liquidity
                );
            }
        }

        uint256 v0 = _usdcValue(usdc, token0, used0Pred);
        uint256 v1 = _usdcValue(usdc, token1, used1Pred);
        uint256 vt = v0 + v1;
        if (vt == 0) return (0, 0);

        uint256 loss0 = FullMath.mulDiv(remainingLossUSDC, v0, vt);
        uint256 loss1 = remainingLossUSDC - loss0;

        uint256 loss0Tok = v0 == 0 ? 0 : FullMath.mulDiv(used0Pred, loss0, v0);
        uint256 loss1Tok = v1 == 0 ? 0 : FullMath.mulDiv(used1Pred, loss1, v1);

        min0 = used0Pred > loss0Tok ? used0Pred - loss0Tok : 0;
        if (min0 > balance0) min0 = balance0;

        min1 = used1Pred > loss1Tok ? used1Pred - loss1Tok : 0;
        if (min1 > balance1) min1 = balance1;
    }

    /* ──────────────── Internal: Misc ──────────────── */

    function _bestAllowlistedLiqScore(address tokenA, address tokenB) internal view returns (uint256) {
        (address poolA, , uint256 scoreUSDC) =
            IValuation(VALUATION).getBestRoute(address(this), tokenA, tokenB);
        if (poolA == address(0)) return 0;
        return scoreUSDC;
    }

    function _requireBalance(address token, uint256 amount) internal view {
        if (token == address(0)) return;
        if (amount == 0) return;
        if (IERC20(token).balanceOf(address(this)) < amount) revert BalanceTooLow();
    }

    function _poolAllowed(address pool) internal view returns (bool) {
        if (pool == address(0)) return false;
        try CORE.isPoolAllowed(pool) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _isBridgeToken(address token) internal view returns (bool) {
        if (address(CORE) == address(0)) return false;
        try CORE.isBridgeToken(token) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _usdcValue(address usdc, address token, uint256 amount) internal view returns (uint256 valueUSDC) {
        if (amount == 0) return 0;
        if (token == usdc) return amount;
        return IValuation(VALUATION).usdcValue(address(this), token, amount);
    }

    function _expectedOutUSDC(address usdc, address tokenOut, uint256 expectedOut) internal view returns (uint256) {
        return _usdcValue(usdc, tokenOut, expectedOut);
    }

    function _lossBpsFromBudget(uint256 remainingLossUSDC, uint256 expectedOutUSDC) internal pure returns (uint256 lossBps) {
        if (expectedOutUSDC == 0) {
            return remainingLossUSDC > 0 ? (BPS - 1) : 0;
        }
        lossBps = FullMath.mulDivRoundingUp(remainingLossUSDC, BPS, expectedOutUSDC);
        if (lossBps >= BPS) lossBps = BPS - 1;
    }

    function _minOutFromLossBudget(uint256 expectedOut, uint256 expectedOutUSDC, uint256 remainingLossUSDC)
        internal
        pure
        returns (uint256 minOut)
    {
        if (expectedOut == 0) return 0;
        uint256 lossBps = _lossBpsFromBudget(remainingLossUSDC, expectedOutUSDC);
        return FullMath.mulDiv(expectedOut, (BPS - lossBps), BPS);
    }

    function _usedLossUSDC(uint256 expectedOut, uint256 actualOut, uint256 expectedOutUSDC)
        internal
        pure
        returns (uint256 usedLossUSDC)
    {
        if (expectedOut == 0) return 0;
        if (expectedOutUSDC == 0) return 0;
        if (actualOut >= expectedOut) return 0;
        return FullMath.mulDivRoundingUp(expectedOutUSDC, (expectedOut - actualOut), expectedOut);
    }

    function _clampSlippage(uint256 slippageBps) internal pure returns (uint256) {
        return slippageBps >= BPS ? BPS - 1 : slippageBps;
    }

    function _approveExact(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current == amount) return;
        token.forceApprove(spender, amount);
    }

    function _convertDustToUSDC(address token, address usdc, uint256 remainingLossUSDC)
        internal
        returns (uint256 usedLossUSDC, uint256 remainingLossUSDCOut)
    {
        remainingLossUSDCOut = remainingLossUSDC;
        if (token == usdc) return (0, remainingLossUSDCOut);
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return (0, remainingLossUSDCOut);
        (, remainingLossUSDCOut) = _swapTokenToUSDC(token, usdc, bal, remainingLossUSDC, address(this));
        usedLossUSDC = remainingLossUSDC - remainingLossUSDCOut;
    }

    function _returnDust(
        address token0,
        address token1,
        address usdc,
        address recipient,
        uint256 remainingLossUSDC
    ) internal returns (uint256 leftoverUSDC, uint256 remainingLossUSDCOut) {
        bool need0 = token0 != usdc && IERC20(token0).balanceOf(address(this)) > 0;
        bool need1 = token1 != usdc && IERC20(token1).balanceOf(address(this)) > 0;

        uint256 remainingLoss = remainingLossUSDC;
        if (need0) {
            (, remainingLoss) = _convertDustToUSDC(token0, usdc, remainingLoss);
        }
        if (need1) {
            (, remainingLoss) = _convertDustToUSDC(token1, usdc, remainingLoss);
        }

        // Drain all USDC currently held; adapters are not meant to retain balance across calls.
        leftoverUSDC = IERC20(usdc).balanceOf(address(this));
        if (leftoverUSDC > 0 && recipient != address(this) && recipient != address(0)) {
            IERC20(usdc).safeTransfer(recipient, leftoverUSDC);
        }

        remainingLossUSDCOut = remainingLoss;
    }

    function _collectFeesToTokensInternal(uint256 tokenId)
        internal
        returns (uint256 fee0, uint256 fee1)
    {
        INonfungiblePositionManager.CollectParams memory cp = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (fee0, fee1) = NPM.collect(cp);
    }
}
