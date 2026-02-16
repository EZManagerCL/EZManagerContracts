// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/* ────────────────────────────────────────────────────────────────────────────
                                   Shared Structs
   ──────────────────────────────────────────────────────────────────────────── */

struct RebalanceParams {
    uint256 token0ToToken1;
    uint256 token1ToToken0;
}

struct Position {
    address owner;
    uint256 tokenId;
    address token0;
    address token1;
    uint24 fee;       
    int24 tickSpacing;  
    int24 tickLower;
    int24 tickUpper;
    uint256 totalDepositedUSDC;
    uint256 dustUSDC;
    bool botAllowed;
    uint48 openedAt;
    address dex;
    address pool;
}

struct RegisterParams {
    address owner;
    uint256 tokenId;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint256 totalDepositedUSDC;
    address dex;
}

struct PositionValueResult {
    bytes32 key;
    uint256 valueUSDC;
}

struct PendingFeesResult {
    bytes32 key;
    uint256 owed0;
    uint256 owed1;
}

struct PositionDetails {
    bytes32 key;
    address owner;
    uint256 tokenId;
    address pool;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    int24 currentTick;
    uint128 liquidity;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
    uint256 pendingFees0;
    uint256 pendingFees1;
    uint256 pendingFeesUSDC;
    uint256 amount0Now;
    uint256 amount1Now;
    uint256 valueUSDCNow;
    uint256 dustUSDC;
    uint256 totalDepositedUSDC;
    uint256 openedAt;
    address dex;
    bool botAllowed;
}

/* ────────────────────────────────────────────────────────────────────────────
                                   Core Interfaces
   ──────────────────────────────────────────────────────────────────────────── */

interface ICLDexAdapter {
    function validateAndGetPoolParams(address pool)
        external
        view
        returns (address token0, address token1, uint24 fee, int24 tickSpacing);

    function seedPairFromUSDC(
        address usdc,
        address token0,
        address token1,
        uint256 netUSDC,
        uint256 remainingLossUSDC
    ) external returns (uint256 amount0In, uint256 amount1In, uint256 remainingLossUSDCOut);

    function mintPosition(
        address token0,
        address token1,
        address usdc,
        uint24 fee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        address nftRecipient,
        uint256 amount0,
        uint256 amount1,
        RebalanceParams calldata rebalance,
        uint256 remainingLossUSDC
    ) external returns (uint256 tokenId, uint256 used0, uint256 used1, uint256 leftoverUSDC, uint256 remainingLossUSDCOut);

    function addLiquidity(
        bytes calldata positionRef,
        address usdc,
        uint256 amount0,
        uint256 amount1,
        RebalanceParams calldata rebalance,
        uint256 remainingLossUSDC
    ) external returns (uint256 used0, uint256 used1, uint256 leftoverUSDC, uint256 remainingLossUSDCOut);

    function removeLiquidityBpsUSDC(
        bytes calldata positionRef,
        uint256 bps,
        address usdc,
        address receiver,
        uint256 remainingLossUSDC
    ) external returns (uint256 usdcOut);

    function getExpectedOutUSDC(address tokenIn, uint256 amountIn, address usdc) external view returns (uint256);

    function unwindToTokens(bytes calldata positionRef, address receiver)
        external
        returns (address[] memory tokens, uint256[] memory amounts);

    function swapExactUSDCForToken(
        address usdc,
        address tokenOut,
        uint256 amountIn,
        uint256 remainingLossUSDC,
        address recipient
    ) external returns (uint256 amountOutToken, uint256 remainingLossUSDCOut);

    function swapExactInToUSDC(
        address tokenIn,
        uint256 amountIn,
        address usdc,
        address receiver,
        uint256 remainingLossUSDC
    ) external returns (uint256 amountOutUSDC, uint256 remainingLossUSDCOut);

    function collectFeesToUSDC(bytes calldata positionRef, address usdc, uint256 remainingLossUSDC)
        external
        returns (uint256 fee0, uint256 fee1, uint256 usdcOut, uint256 remainingLossUSDCOut);

    function collectFeesToTokens(bytes calldata positionRef, address receiver)
        external
        returns (address token0, address token1, uint256 fee0, uint256 fee1);

    function quoteToToken(address tokenIn, uint256 amountIn, address tokenOut) external returns (uint256 amountOut);

    function bestAllowlistedLiqScore(address tokenA, address tokenB) external view returns (uint256);

    function getNPM() external view returns (address);
    function getQuoter() external view returns (address);
    function getFactory() external view returns (address);
    function isAerodrome() external view returns (bool);
}

interface ICLCore {
    function isPoolAllowed(address pool) external view returns (bool);
    function isBridgeToken(address token) external view returns (bool);
    function bridgeTokens() external view returns (address[] memory);
    function listAllowedPools() external view returns (address[] memory);
    function allowedDexes(address dex) external view returns (bool);
    function listAllowedDexes() external view returns (address[] memory);
    function positionValueUSDC(bytes32[] calldata keys) external view returns (PositionValueResult[] memory);
    function positionValueUSDCSingle(bytes32 key) external view returns (uint256 valueUSDC);
    
    function pendingFees(bytes32[] calldata keys) external view returns (PendingFeesResult[] memory);
    function getPositionDetails(bytes32 key) external view returns (PositionDetails memory);
    function getPosition(bytes32 key) external view returns (Position memory);

    function USDC() external view returns (IERC20);
    function VALUATION() external view returns (IValuation);
    function protocolFeeBps() external view returns (uint16);
    function botFeeBps() external view returns (uint16);
    function protocolReserve() external view returns (address);
    function positions(bytes32 key) external view returns (
        address owner,
        uint256 tokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint256 totalDepositedUSDC,
        uint256 dustUSDC,
        bool botAllowed,
        uint48 openedAt,
        address dex,
        address pool
    );

    // State reading helpers
    function allowedBots(address bot) external view returns (bool);
    function zeroFeeWallets(address wallet) external view returns (bool);
    function isPoolDeprecated(address pool) external view returns (bool);

    // Write functions called by Manager
    function registerPosition(RegisterParams calldata params) external returns (bytes32);
    function deregisterPosition(bytes32 key) external returns (Position memory);
    function updateTokenMetadata(bytes32 key, uint256 newTokenId, int24 newLower, int24 newUpper) external;
    function adjustTotalDeposited(bytes32 key, int256 usdcDelta) external;
    function setBotAllowedForPosition(bytes32 key, bool allowed) external;
    function addDustToPosition(bytes32 key, uint256 amount) external;
    function withdrawDustForPosition(bytes32 key, address to, uint256 amount) external returns (uint256);
    function returnPosition(bytes32 key) external;
    function spotAmounts(bytes32 key) external view returns (uint256 amt0, uint256 amt1, uint128 owed0, uint128 owed1);
}

interface ICLManager {
    function protocolFeeBps() external view returns (uint256);
    function botFeeBps() external view returns (uint256);
}

interface IValuation {
    function usdcValue(address dex, address token, uint256 amount) external view returns (uint256);
    function getBestRoute(address dex, address tokenIn, address tokenOut)
        external
        view
        returns (address poolA, address poolB, uint256 scoreUSDC);
}

interface IRebalancePlanner {
    function planFromTokenBundle(
        address dex,
        address pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external view returns (RebalanceParams memory);
}

/* ────────────────────────────────────────────────────────────────────────────
                                   DEX Interfaces
   ──────────────────────────────────────────────────────────────────────────── */

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface ISlipstreamNonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;  // Slipstream-specific
    }
    
    // Increase, Decrease, Collect are same as standard but explicit for clarity
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    // Aerodrome signature (tickSpacing instead of fee)
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface IUniswapV3Factory {
    function getPool(address token0, address token1, uint24 fee) external view returns (address);
}

interface IAerodromeFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function tickSpacings() external view returns (int24[] memory);
    function tickSpacingToFee(int24 tickSpacing) external view returns (uint24);
}

interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function factory() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross,
        int128 liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56 tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32 secondsOutside,
        bool initialized
    );
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
}

interface ICLPool is IUniswapV3Pool {
    // Aerodrome/Slipstream specific additions if any, aliases to IUniswapV3Pool mostly
}

interface ISlipstreamPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, bool locked);
}

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface ISlipstreamSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapQuoterV2Like {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

interface ISlipstreamQuoterV2Like {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

interface ISlipstreamPoolState {
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);

    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            int128 stakedLiquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            uint256 rewardGrowthOutsideX128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function liquidity() external view returns (uint128);
}
