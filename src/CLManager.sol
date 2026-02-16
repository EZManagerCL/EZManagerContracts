// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {ICLDexAdapter, RebalanceParams, Position, RegisterParams, PositionValueResult, PendingFeesResult, PositionDetails, ICLCore, IValuation, ICLPool, IAerodromeFactory, IUniswapV3Factory, IUniswapV3Pool, ISlipstreamPoolState, INonfungiblePositionManager, IRebalancePlanner} from "./Interfaces.sol";

/* ─────────────────────────── CLManager ─────────────────────────── */

contract CLManager is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    error UsdcDecimalsTooLow();
    
    constructor(address core_, address owner_) Ownable(owner_) {
        if (core_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        CORE = ICLCore(core_);
        USDC = CORE.USDC();
        usdcDecimals = IERC20Metadata(address(USDC)).decimals();
        if (usdcDecimals < 3) revert UsdcDecimalsTooLow();
        // SECOND_PASS_MIN_USDC = $0.001 in token units.
        SECOND_PASS_MIN_USDC = 10 ** uint256(usdcDecimals - 3);

        // MINIMUM_OPEN_USDC defaults to $1 in token units.
        MINIMUM_OPEN_USDC = 10 ** uint256(usdcDecimals);

        VALUATION = CORE.VALUATION();
    }

    /* ───────────── Variables ───────────── */
    address public guardian;

    uint8 public usdcDecimals;

    uint256 public constant BPS = 10_000;

    // Threshold bps to trigger second pass liquidity addition 
    // if leftover USDC is large enough.
    uint256 public SECOND_PASS_THRESHOLD_BPS = 1; // 0.01%

    // Minimum USDC (in token units) to trigger second pass.
    uint256 public SECOND_PASS_MIN_USDC;

    // Minimum USDC (in token units) required to open a new position (defaults to $1)
    uint256 public MINIMUM_OPEN_USDC;

    uint256 public constant LIQUIDITY_PERCENTAGE_PRECISION = 1e18;

    // Limits the number of position keys that can be processed in batch operations.
    uint256 public MAX_BATCH_KEYS = 25;

    /* ───────────── Storage ───────────── */

    ICLCore public CORE;
    IERC20 public USDC;
    IValuation public VALUATION;
    IRebalancePlanner public PLANNER;

    /* ───────────── Events ───────────── */

    event PositionOpened(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        address dex,
        address pool,
        address token0,
        address token1,
        uint256 depositedUSDC,
        uint256 protocolFeeUSDC,
        uint256 dustAdded
    );

    event PositionExited(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 returnedUSDC,
        uint256 feesCollected
    );

    event PositionNftReturned(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 returnedUSDC,
        uint256 feesCollected
    );

    event FeesCollected(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 fee0,
        uint256 fee1,
        uint256 usdcOut
    );

    event FeesCompounded(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 compoundedUSDC,
        uint256 used0,
        uint256 used1
    );

    event RangeChanged(
        address indexed user,
        bytes32 indexed key,
        uint256 oldTokenId,
        uint256 newTokenId,
        int24 oldLower,
        int24 oldUpper,
        int24 newLower,
        int24 newUpper,
        uint256 positionValueBefore,
        uint256 positionValueAfter,
        uint256 protocolFeeUSDC,
        uint256 feesCollected
    );

    event CollateralAdded(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 depositedUSDC,
        uint256 addedUSDC,
        uint256 totalCollateralUSDC,
        uint256 protocolFeeUSDC
    );

    event CollateralRemoved(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 returnedUSDC,
        uint256 feesCollected,
        uint256 removedUSDC,
        uint256 totalCollateralUSDC
    );

    event ProtocolFeePaid(
        address indexed payer,
        bytes32 indexed key,
        uint256 tokenId,
        uint256 grossUSDC,
        uint256 feeUSDC,
        uint256 netUSDC,
        FeeType feeType
    );

    event BotFeePaid(
        address indexed bot,
        bytes32 indexed key,
        uint256 tokenId,
        uint256 feeUSDC,
        FeeType feeType
    );

    /* ───────────── Errors ───────────── */
    error NotGuardian();
    error NotOwner();
    error InvalidParams();
    error PositionNotFound();
    error ReserveNotSet();
    error NothingRemoved();
    error TooManyInBatch(uint256 maxKeys);
    error PositionValueZero();
    error TooMuchWithdraw();
    error BpsZero();
    error NoTokensUnwound();
    error NoPositionMinted();
    error DexNotAllowed();
    error PoolNotAllowed();
    error PoolDeprecated();
    error PoolNotFound();
    error ZeroAmount();
    error PositionTooSmall();
    error InvalidTickRange();
    error EmptyKeys();
    error ZeroAddress();
    error TickAlignmentError();
    error PoolNotInitialized();

    /* ───────────── Internal Types ───────────── */

    struct CompoundContext {
        address owner;
        uint256 tokenId;
        address token0;
        address token1;
        address dex;
    }

    enum FeeType {
        Open,
        Collect,
        CollateralAdd,
        ChangeRange,
        Exit,
        Compound
    }

    /* ───────────── Initialization & Admin ───────────── */

    /// @notice Set the RebalancePlanner contract used for getting optimal rebalance plans.
    function setPlanner(address planner_) external onlyOwner {
        if (planner_ == address(0)) revert ZeroAddress();
        PLANNER = IRebalancePlanner(planner_);
    }

    /// @notice Set the valuation contract used for token -> USDC pricing
    function setValuation(address valuation_) external onlyOwner {
        if (valuation_ == address(0)) revert ZeroAddress();
        VALUATION = IValuation(valuation_);
    }

    /// @notice Set the guardian address for quick pause/unpause.
    function setGuardian(address g) external onlyOwner {
        if (g == address(0)) revert ZeroAddress();
        guardian = g;
    }

    /// @notice Set the minimum USDC (in token units) required to open a position
    function setMinimumOpenUSDC(uint256 min_) external onlyOwner {
        if (min_ == 0) revert InvalidParams();
        MINIMUM_OPEN_USDC = min_;
    }

    /// @notice Set the maximum number of keys that can be processed in batch operations
    function setMaxBatchKeys(uint256 maxKeys_) external onlyOwner {
        if (maxKeys_ == 0) revert InvalidParams();
        MAX_BATCH_KEYS = maxKeys_;
    }

    /// @notice Configure second-pass behavior: leftover threshold (bps) and minimum USDC
    function setSecondPassParams(uint256 thresholdBps_, uint256 minUsdc_) external onlyOwner {
        if (thresholdBps_ > BPS) revert InvalidParams();
        SECOND_PASS_THRESHOLD_BPS = thresholdBps_;
        SECOND_PASS_MIN_USDC = minUsdc_;
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    /* ───────────── Modifiers/Permissions ───────────── */

    modifier onlyKeyOwner(bytes32 key) {
        Position memory p = CORE.getPosition(key);
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();
        if (p.owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyKeyOwnerOrBot(bytes32 key) {
        Position memory p = CORE.getPosition(key);
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();
        if (p.owner != msg.sender) {
            // Allow whitelisted bots only if the position explicitly allows bots
            if (!CORE.allowedBots(msg.sender) || !p.botAllowed) revert NotOwner();
        }
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    function _requireOwnerOrBot(address owner, bool botAllowed, bool callerIsBot) internal view {
        if (owner == msg.sender) return;
        if (!callerIsBot || !botAllowed) revert NotOwner();
    }

    /* ───────────── Core User Flows ───────────── */

    /**
     * @notice Open a new concentrated liquidity position from USDC.
     * @param pool Target pool address.
     * @param tickLower Lower tick for the initial position.
     * @param tickUpper Upper tick for the initial position.
     * @param usdcAmount Gross USDC deposited by the user.
     * @param slippageBps Maximum allowed slippage in basis points.
     */
    function openPosition(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        uint256 slippageBps
    ) external nonReentrant whenNotPaused returns (bytes32 key) {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (usdcAmount == 0) revert InvalidParams();
        if (pool == address(0)) revert InvalidParams();

        // Don't allow tiny positions to avoid DOS on backend.
        if (usdcAmount < MINIMUM_OPEN_USDC) revert PositionTooSmall();

        // Select a validated adapter from CORE's allowlist by attempting to validate the pool.
        address[] memory dexes = CORE.listAllowedDexes();
        address dex = address(0);
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;

        for (uint256 i = 0; i < dexes.length; ++i) {
            address tryDex = dexes[i];
            if (tryDex == address(0)) continue;
            try ICLDexAdapter(tryDex).validateAndGetPoolParams(pool) returns (address t0, address t1, uint24 f, int24 ts) {
                // success: use this adapter
                dex = tryDex;
                token0 = t0;
                token1 = t1;
                fee = f;
                tickSpacing = ts;
                break;
            } catch {
                // try next adapter
            }
        }
        // No supported dex found for pool
        if (dex == address(0)) revert DexNotAllowed();

        // Require pool is allowlisted by CORE registry.
        if (!CORE.isPoolAllowed(pool)) revert PoolNotAllowed();
        // Disallow opening new positions on deprecated (phasing out) pools.
        if (CORE.isPoolDeprecated(pool)) revert PoolDeprecated();

        ICLDexAdapter adapter = ICLDexAdapter(dex);

        // Basic validation: ticks must align with spacing and form a valid range.
        if ((tickLower % tickSpacing) != 0 || (tickUpper % tickSpacing) != 0) revert TickAlignmentError();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower < -887272 || tickUpper > 887272) revert InvalidTickRange();

        // Ensure pool is initialized (has non-zero sqrtPriceX96) to avoid low-level NPM reverts.
        {
            (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
            if (!ok || data.length < 32) revert PoolNotInitialized();
            // decode first uint256 (sqrtPriceX96)
            (uint256 w0) = abi.decode(data, (uint256));
            uint160 sqrtPriceX96 = uint160(w0);
            if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        }

        (uint16 protocolFeeBps_, address reserve) = _protocolFeeConfig();
        if (_isZeroFee(msg.sender)) {
            protocolFeeBps_ = 0;
        }

        // Pull gross USDC from the user.
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Protocol fee is taken from the deposit but does not reduce totalDepositedUSDC
        // since totalDepositedUSDC tracks the full gross external USDC the owner contributed.
        uint256 protocolFeeUSDC = _protocolFeeAmount(usdcAmount, protocolFeeBps_);
        uint256 seedNet = usdcAmount - protocolFeeUSDC;

        if (protocolFeeUSDC > 0) {
            USDC.safeTransfer(reserve, protocolFeeUSDC);
        }

        // Seed either directly with USDC or via a configured bridge token through the adapter.
        if (seedNet > 0) {
            USDC.safeTransfer(dex, seedNet);
        }

        uint256 remainingLossUSDC = _lossBudgetUSDC(seedNet, slippageBps);
        (uint256 amount0In, uint256 amount1In, uint256 remainingLossUSDCOut) = adapter.seedPairFromUSDC(
            address(USDC),
            token0,
            token1,
            seedNet,
            remainingLossUSDC
        );

        // Gets the amounts to swap for optimal liquidity provision.
        RebalanceParams memory plan = PLANNER.planFromTokenBundle(
            dex,
            pool,
            token0,
            token1,
            tickLower,
            tickUpper,
            amount0In,
            amount1In
        );

        // Mints position via user-specified allowlisted adapter.
        (uint256 tokenId, , , uint256 leftoverUSDC, uint256 remainingLossUSDCFinal) = ICLDexAdapter(dex).mintPosition(
            token0,
            token1,
            address(USDC),
            fee,
            tickSpacing,
            tickLower,
            tickUpper,
            address(CORE),
            amount0In,
            amount1In,
            plan,
            remainingLossUSDCOut
        );

        leftoverUSDC = _maybeSecondPass(
            dex,
            pool,
            token0,
            token1,
            tickLower,
            tickUpper,
            tokenId,
            leftoverUSDC,
            usdcAmount,
            remainingLossUSDCFinal
        );

        RegisterParams memory params = RegisterParams({
            owner: msg.sender,
            tokenId: tokenId,
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            totalDepositedUSDC: usdcAmount,
            dex: dex
        });

        key = CORE.registerPosition(params);

        // Track adapter leftover as per-position dust in CORE.
        _addDust(key, leftoverUSDC);

        if (protocolFeeUSDC > 0) {
            emit ProtocolFeePaid(
                msg.sender,
                key,
                tokenId,
                usdcAmount,
                protocolFeeUSDC,
                seedNet,
                FeeType.Open
            );
        }

        emit PositionOpened(
            msg.sender,
            key,
            tokenId,
            dex,
            pool,
            token0,
            token1,
            usdcAmount,
            protocolFeeUSDC,
            leftoverUSDC
        );
    }

    /**
     * @notice Exit positions, unwinding all liquidity and refunding dust.
     * @dev Bot callers receive a bot fee cut of the realized USDC.
     */
    function exitPosition(bytes32[] calldata keys, uint256 slippageBps)
        external
        nonReentrant
        whenNotPaused
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > MAX_BATCH_KEYS) revert TooManyInBatch(MAX_BATCH_KEYS);
        bool callerIsBot = CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = CORE.botFeeBps();

        for (uint256 k = 0; k < keys.length; ++k) {
            bytes32 key = keys[k];
            Position memory p = CORE.getPosition(key);
            if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

            _requireOwnerOrBot(p.owner, p.botAllowed, callerIsBot);

            // Use CORE's on-chain computed pending USDC for the position.
            PositionDetails memory det = CORE.getPositionDetails(key);
            uint256 feesCollectedAtStart = det.pendingFeesUSDC;

            bool zeroFeeOwner = _isZeroFee(p.owner);
            uint16 botFeeBpsLocal = zeroFeeOwner ? 0 : botFeeBps_;

            uint256 usdcBefore = USDC.balanceOf(address(this));

            // Unwind NFT to underlying tokens (may include USDC already).
            (address[] memory toks, uint256[] memory amts) =
                ICLDexAdapter(p.dex).unwindToTokens(abi.encode(p.tokenId), address(this));

            // Swap all non-USDC tokens to USDC using a single USDC-denominated loss budget.
            uint256 swapBaseUSDC = 0;
            for (uint256 i = 0; i < toks.length; ++i) {
                if (amts[i] > 0 && toks[i] != address(USDC)) {
                    swapBaseUSDC += _tokenValueUSDC(p.dex, toks[i], amts[i]);
                }
            }

            uint256 remainingLossUSDC = _lossBudgetUSDC(swapBaseUSDC, slippageBps);
            for (uint256 i = 0; i < toks.length; ++i) {
                address token = toks[i];
                uint256 amount = amts[i];
                if (amount == 0) continue;
                if (token == address(USDC)) continue;

                // Transfer token to adapter so it can swap from its own balance.
                IERC20(token).safeTransfer(p.dex, amount);
                (, remainingLossUSDC) = ICLDexAdapter(p.dex).swapExactInToUSDC(
                    token,
                    amount,
                    address(USDC),
                    address(this),
                    remainingLossUSDC
                );
            }

            // Withdraw tracked dust from CORE before deregistration to refund it.
            uint256 dustFromCore = CORE.withdrawDustForPosition(key, address(this), type(uint256).max);

            CORE.deregisterPosition(key);

            uint256 usdcAfter = USDC.balanceOf(address(this));
            uint256 returnedUSDC = usdcAfter - usdcBefore;

            // Bot fee is taken from the non-dust portion of exit proceeds.
            if (callerIsBot && botFeeBpsLocal > 0 && returnedUSDC > 0) {
                uint256 feeBase = returnedUSDC > dustFromCore ? returnedUSDC - dustFromCore : 0;
                uint256 botFeeUSDC = FullMath.mulDiv(feeBase, botFeeBpsLocal, BPS);
                if (botFeeUSDC > 0) {
                    returnedUSDC = returnedUSDC > botFeeUSDC ? returnedUSDC - botFeeUSDC : 0;
                    USDC.safeTransfer(msg.sender, botFeeUSDC);
                    emit BotFeePaid(msg.sender, key, p.tokenId, botFeeUSDC, FeeType.Exit);
                }
            }

            if (returnedUSDC > 0) {
                USDC.safeTransfer(p.owner, returnedUSDC);
            }

            emit PositionExited(p.owner, key, p.tokenId, returnedUSDC, feesCollectedAtStart);
        }
    }

    /**
     * @notice Return position NFTs to their owners without unwinding liquidity.
     * @dev Can be called by the position owner or the protocol owner timelock in emergencies. 
     * For each key,
     *      this records the current canonical position value and pending fees, then
     *      asks CORE to return the NFT (and any tracked dust) to the owner and
     *      deregister the position. 
     *      Available even when protocol is paused so users, or in emergencies, 
     *      the protocol owner can send positions out of the system to position owners.
     *      When paused, try/catch is used in just this function 
     *      so Valuation or non-essential accounting errors can't brick emergency exit.
     * 
     */
    function returnNft(bytes32[] calldata keys)
        external
        nonReentrant
    {
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > MAX_BATCH_KEYS) revert TooManyInBatch(MAX_BATCH_KEYS);
        bool isProtocolOwner = msg.sender == owner();

        for (uint256 i = 0; i < keys.length; ++i) {
            bytes32 key = keys[i];

            Position memory p = CORE.getPosition(key);
            if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

            // Only the position owner or the protocol owner (when paused in emergencies) may return the NFT.
            if(paused()) {
                if (!isProtocolOwner && p.owner != msg.sender) revert NotOwner();
            } else {
                if (p.owner != msg.sender) revert NotOwner();
            }

            uint256 feesCollectedAtStart = 0;
            uint256 returnedUSDC = 0;

            // try catch so Valuation or non-essential accounting errors can't brick emergency exit. 
            // This is the only place where we tolerate this.
            try CORE.getPositionDetails(key) returns (PositionDetails memory det) {
                // Snapshot pending USDC-denominated fees at the time of return.
                feesCollectedAtStart = det.pendingFeesUSDC;
            } catch {
                feesCollectedAtStart = 0;
            }

            try CORE.positionValueUSDCSingle(key) returns (uint256 returnedUSDC_) {
                returnedUSDC = returnedUSDC_;
            } catch { 
                returnedUSDC = 0;
            }

            // CORE will transfer the NFT (and any tracked dust) to the owner
            // and deregister the position.
            CORE.returnPosition(key);

            emit PositionNftReturned(p.owner, key, p.tokenId, returnedUSDC, feesCollectedAtStart);
        }
    }

    /**
     * @notice Collect fees for multiple positions and swap to USDC.
     * @dev Owner or whitelisted bot can call. Bot receives a fee share.
     */
    function collectFeesToUSDC(bytes32[] calldata keys, uint256 slippageBps)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcSent)
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > MAX_BATCH_KEYS) revert TooManyInBatch(MAX_BATCH_KEYS);

        bool callerIsBot = CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = CORE.botFeeBps();

        uint256 total = 0;

        for (uint256 i = 0; i < keys.length; ++i) {
            bytes32 key = keys[i];

            Position memory p = CORE.getPosition(key);

            if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();
            _requireOwnerOrBot(p.owner, p.botAllowed, callerIsBot);

            PositionDetails memory det = CORE.getPositionDetails(key);
            uint256 remainingLossUSDC = _lossBudgetUSDC(det.pendingFeesUSDC, slippageBps);

            (uint256 fee0, uint256 fee1, uint256 outUSDC, ) =
                ICLDexAdapter(p.dex).collectFeesToUSDC(abi.encode(p.tokenId), address(USDC), remainingLossUSDC);

            uint16 botFeeBpsLocal = _isZeroFee(p.owner) ? 0 : botFeeBps_;
            uint256 netUSDC = outUSDC;

            if (callerIsBot && botFeeBpsLocal > 0 && outUSDC > 0) {
                uint256 botFeeUSDC = FullMath.mulDiv(outUSDC, botFeeBpsLocal, BPS);
                if (botFeeUSDC > 0) {
                    netUSDC = netUSDC > botFeeUSDC ? netUSDC - botFeeUSDC : 0;
                    USDC.safeTransfer(msg.sender, botFeeUSDC);
                    emit BotFeePaid(msg.sender, key, p.tokenId, botFeeUSDC, FeeType.Collect);
                }
            }

            if (netUSDC > 0) {
                USDC.safeTransfer(p.owner, netUSDC);
                total = total + netUSDC;
            }


            emit FeesCollected(p.owner, key, p.tokenId, fee0, fee1, outUSDC);
        }

        return total;
    }

    /**
     * @notice Compound fees for multiple positions by adding them back into liquidity.
     * @dev Owner or bot can call; compounded fees do not change totalDepositedUSDC.
     */
    function compoundFees(bytes32[] calldata keys, uint256 slippageBps)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 compoundedUSDCTotal)
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > MAX_BATCH_KEYS) revert TooManyInBatch(MAX_BATCH_KEYS);

        bool callerIsBot = CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = CORE.botFeeBps();

        // Fetch pending fees for the whole batch and use as pre-check to avoid wasting on-chain work.
        PendingFeesResult[] memory pending = CORE.pendingFees(keys);

        for (uint256 i = 0; i < keys.length; ++i) {
            (uint256 compoundedUSDC) =
                _compoundOne(keys[i], pending[i], slippageBps, callerIsBot, botFeeBps_);

            compoundedUSDCTotal += compoundedUSDC;
        }
    }

    function _compoundOne(
        bytes32 key,
        PendingFeesResult memory pending,
        uint256 slippageBps,
        bool callerIsBot,
        uint16 botFeeBps_
    ) internal returns (uint256 compoundedUSDCOut) {
        if (pending.owed0 == 0 && pending.owed1 == 0) {
            return 0;
        }

        Position memory p = CORE.getPosition(key);
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();
        _requireOwnerOrBot(p.owner, p.botAllowed, callerIsBot);

        CompoundContext memory ctx;
        ctx.owner = p.owner;
        ctx.tokenId = p.tokenId;
        ctx.token0 = p.token0;
        ctx.token1 = p.token1;
        ctx.dex = p.dex;

        (, , uint256 fee0, uint256 fee1) = ICLDexAdapter(ctx.dex).collectFeesToTokens(abi.encode(ctx.tokenId), address(this));
        emit FeesCollected(p.owner, key, ctx.tokenId, fee0, fee1, 0);

        if (fee0 == 0 && fee1 == 0) {
            return 0;
        }

        address pool = p.pool;
        if (pool == address(0)) revert PoolNotFound();
        if (!CORE.isPoolAllowed(pool)) revert PoolNotAllowed();

        uint16 botFeeBpsLocal = _isZeroFee(p.owner) ? 0 : botFeeBps_;
        if (callerIsBot && botFeeBpsLocal > 0) {
            (uint256 botPaidUSDC, uint256 remainingFee0, uint256 remainingFee1) = _handleBotFeeOnCollected(
                ctx.dex,
                ctx.token0,
                ctx.token1,
                fee0,
                fee1,
                botFeeBpsLocal,
                slippageBps
            );
            fee0 = remainingFee0;
            fee1 = remainingFee1;
            if (botPaidUSDC > 0) {
                emit BotFeePaid(msg.sender, key, ctx.tokenId, botPaidUSDC, FeeType.Compound);
            }
        }

        if (fee0 > 0) IERC20(ctx.token0).safeTransfer(ctx.dex, fee0);
        if (fee1 > 0) IERC20(ctx.token1).safeTransfer(ctx.dex, fee1);

        RebalanceParams memory plan = PLANNER.planFromTokenBundle(
            ctx.dex,
            pool,
            ctx.token0,
            ctx.token1,
            p.tickLower,
            p.tickUpper,
            fee0,
            fee1
        );

        uint256 compoundBaseUSDC = _tokenValueUSDC(ctx.dex, ctx.token0, fee0) + _tokenValueUSDC(ctx.dex, ctx.token1, fee1);
        uint256 remainingLossUSDC = _lossBudgetUSDC(compoundBaseUSDC, slippageBps);

        (uint256 used0, uint256 used1, uint256 leftoverUSDC, uint256 remainingLossUSDCFinal) =
            ICLDexAdapter(ctx.dex).addLiquidity(
                abi.encode(ctx.tokenId),
                address(USDC),
                fee0,
                fee1,
                plan,
                remainingLossUSDC
            );

        uint256 compoundedUSDC = _tokenValueUSDC(ctx.dex, ctx.token0, used0) + _tokenValueUSDC(ctx.dex, ctx.token1, used1);

        leftoverUSDC = _maybeSecondPass(
            ctx.dex,
            pool,
            ctx.token0,
            ctx.token1,
            p.tickLower,
            p.tickUpper,
            ctx.tokenId,
            leftoverUSDC,
            p.totalDepositedUSDC,
            remainingLossUSDCFinal
        );

        compoundedUSDC += leftoverUSDC;
        _addDust(key, leftoverUSDC);

        emit FeesCompounded(p.owner, key, ctx.tokenId, compoundedUSDC, used0, used1);
        return compoundedUSDC;
    }

    /**
     * @notice Add USDC collateral to an existing position.
     * @dev totalDepositedUSDC increases by the full gross user deposit; protocol fee is tracked separately.
     */
    function addCollateral(
        bytes32 key,
        uint256 usdcAmount,
        uint256 slippageBps
    )
        external
        nonReentrant
        onlyKeyOwner(key)
        whenNotPaused
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (usdcAmount == 0) revert ZeroAmount();

        Position memory p = CORE.getPosition(key);
        // Snapshot canonical position value before any changes
        uint256 positionValueBefore = _corePositionValue(key);

        (uint16 protocolFeeBps_, address reserve) = _protocolFeeConfig();
        if (_isZeroFee(p.owner)) {
            protocolFeeBps_ = 0;
        }

        uint256 add = usdcAmount;
        uint256 baseUSDC = p.totalDepositedUSDC + usdcAmount;
        uint256 protocolFeeUSDC = _protocolFeeAmount(add, protocolFeeBps_);
        uint256 net = add - protocolFeeUSDC;

        // Pull USDC from the owner
        USDC.safeTransferFrom(p.owner, address(this), add);

        if (protocolFeeUSDC > 0) {
            USDC.safeTransfer(reserve, protocolFeeUSDC);
            emit ProtocolFeePaid(p.owner, key, p.tokenId, add, protocolFeeUSDC, net, FeeType.CollateralAdd);
        }

        address pool = p.pool;
        if (pool == address(0)) revert PoolNotFound();
        if (!CORE.isPoolAllowed(pool)) revert PoolNotAllowed();
        if (net > 0) {
            USDC.safeTransfer(p.dex, net);
        }

        uint256 remainingLossUSDC = _lossBudgetUSDC(net, slippageBps);
        (uint256 amount0In, uint256 amount1In, uint256 remainingLossUSDCOut) = ICLDexAdapter(p.dex).seedPairFromUSDC(
            address(USDC),
            p.token0,
            p.token1,
            net,
            remainingLossUSDC
        );

        // Determine optimal swap amounts for liquidity addition.
        RebalanceParams memory plan = PLANNER.planFromTokenBundle(
            p.dex,
            pool,
            p.token0,
            p.token1,
            p.tickLower,
            p.tickUpper,
            amount0In,
            amount1In
        );

        (, , uint256 leftoverAdd, uint256 remainingLossUSDCFinal) = ICLDexAdapter(p.dex).addLiquidity(
            abi.encode(p.tokenId),
            address(USDC),
            amount0In,
            amount1In,
            plan,
            remainingLossUSDCOut
        );

        leftoverAdd = _maybeSecondPass(
            p.dex,
            pool,
            p.token0,
            p.token1,
            p.tickLower,
            p.tickUpper,
            p.tokenId,
            leftoverAdd,
            baseUSDC,
            remainingLossUSDCFinal
        );

        // Track any residual USDC from add-liquidity attempts as per-position dust.
        _addDust(key, leftoverAdd);

        // totalDepositedUSDC increases by the full gross external USDC deposit (depositedUSDC).
        uint256 depositedUSDC = add;
        CORE.adjustTotalDeposited(key, int256(depositedUSDC));

        // Compute the delta in canonical position value to report the actual
        // USDC-denominated increase in position value caused by this operation.
        uint256 positionValueAfter = _corePositionValue(key);
        uint256 addedUSDC = positionValueAfter > positionValueBefore
            ? positionValueAfter - positionValueBefore
            : 0;

        emit CollateralAdded(p.owner, key, p.tokenId, depositedUSDC, addedUSDC, positionValueAfter, protocolFeeUSDC);

    }

    /**
    * @notice Remove a target USDC amount from a position by burning a fraction of liquidity.
    * @dev `totalDepositedUSDC` is reduced by the measured decrease in canonical position value.
    */
    function removeCollateral(
        bytes32 key,
        uint256 withdrawUSDC,
        uint256 slippageBps
    )
        external
        nonReentrant
        onlyKeyOwner(key)
        whenNotPaused
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (withdrawUSDC == 0) revert ZeroAmount();

        Position memory p = CORE.getPosition(key);

        uint256 positionValueInitial = _corePositionValue(key);
        uint256 positionValueExcludingDust = positionValueInitial - p.dustUSDC;

        if (positionValueInitial == 0) revert PositionValueZero();

        uint256 remainingTarget = withdrawUSDC;
        uint256 totalReturned = 0;
        uint256 feesCollected = 0;

        // 1. Use tracked dust first, possibly satisfying the full request.
        if (p.dustUSDC > 0) {
            uint256 dustToWithdraw = remainingTarget < p.dustUSDC ? remainingTarget : p.dustUSDC;
            if (dustToWithdraw > 0) {
                uint256 dustWithdrawn = CORE.withdrawDustForPosition(key, address(this), dustToWithdraw);
                if (dustWithdrawn > 0) {
                    remainingTarget -= dustWithdrawn;
                    totalReturned += dustWithdrawn; // to be transferred once at the end
                }
            }
        }

        // If dust covered the full request, emit event and stop.
        if (remainingTarget == 0) {
            p = CORE.getPosition(key);
            uint256 positionValueAfterDust = _corePositionValue(key);
            // No on-chain fee collection happened during dust-only withdraws.
            feesCollected = 0;
            // removedUSDC should represent the decrease in totalDepositedUSDC/position value.
            // which is exactly the dust amount we withdrew and already adjusted above.
            uint256 removedUSDC = totalReturned;
            CORE.adjustTotalDeposited(key, -int256(totalReturned));
            USDC.safeTransfer(p.owner, totalReturned);
            emit CollateralRemoved(p.owner, key, p.tokenId, totalReturned, feesCollected, removedUSDC, positionValueAfterDust);
            return;
        }

        // 2. Dust was insufficient; remove liquidity for the remainder.

        // Use live quoted value strictly for computing withdrawal BPS for accuracy.
        uint256 quotedPositionValueBefore = _quotedPositionValue(key, p);

        // If quoted value fails (returns 0), fall back to on-chain valuation minus dust.
        if (quotedPositionValueBefore == 0) {
            quotedPositionValueBefore = positionValueExcludingDust;
        }

        if (quotedPositionValueBefore == 0) revert PositionValueZero();

        // Prevent withdrawing so much that the remaining position (excluding dust)
        // would fall below the protocol minimum open threshold.
        uint256 remainingAfter = quotedPositionValueBefore > remainingTarget
            ? quotedPositionValueBefore - remainingTarget
            : 0;
        if (remainingAfter < MINIMUM_OPEN_USDC) revert TooMuchWithdraw();

        uint256 withdrawFraction = FullMath.mulDiv(
            remainingTarget,
            LIQUIDITY_PERCENTAGE_PRECISION,
            quotedPositionValueBefore
        );

        if (withdrawFraction == 0) revert BpsZero();
        if (withdrawFraction >= LIQUIDITY_PERCENTAGE_PRECISION) {
            withdrawFraction = LIQUIDITY_PERCENTAGE_PRECISION - 1;
        }

        // If there are tokens already in tokensOwed, they get automatically collected on decreaseLiquidity.
        // For proper accounting, we need to log them as feesCollected.
        // Snapshot pending fees before liquidity change to compute collected fees.
        PositionDetails memory detBefore = CORE.getPositionDetails(key);

        uint256 remainingLossUSDC = _lossBudgetUSDC(remainingTarget, slippageBps);
        uint256 usdcOut = ICLDexAdapter(p.dex).removeLiquidityBpsUSDC(
            abi.encode(p.tokenId),
            withdrawFraction,
            address(USDC),
            address(this),
            remainingLossUSDC
        );
        if (usdcOut == 0) revert NothingRemoved();

        totalReturned += usdcOut;
        USDC.safeTransfer(p.owner, totalReturned);
        
        uint256 positionValueAfter = _corePositionValue(key);

        // `positionValueInitial` was taken before we withdrew any tracked dust above.
        // After withdrawing dust (and then burning liquidity for the remaining target),
        // the observed decrease in canonical position value (`positionValueInitial - positionValueAfter`)
        // naturally includes both the dust withdrawn earlier and the value removed via liquidity burn.
        // We therefore decrement `totalDepositedUSDC` by this single `deltaValue` to avoid
        // double-adjusting (i.e. avoid separately subtracting dust and the burn delta).
        uint256 deltaValue =
            positionValueInitial > positionValueAfter
                ? positionValueInitial - positionValueAfter
                : 0;
        if (deltaValue > 0) {
            CORE.adjustTotalDeposited(key, -int256(deltaValue));
        }

        // Snapshot pending fees after liquidity change and compute fees collected to manager in USDC.
        PositionDetails memory detAfter = CORE.getPositionDetails(key);
        feesCollected = 0;
        if (detAfter.pendingFeesUSDC > detBefore.pendingFeesUSDC) {
            // This should not normally happen, but guard against underflow.
            feesCollected = 0;
        } else {
            feesCollected = detBefore.pendingFeesUSDC > detAfter.pendingFeesUSDC
                ? detBefore.pendingFeesUSDC - detAfter.pendingFeesUSDC
                : 0;
        }

        emit CollateralRemoved(p.owner, key, p.tokenId, totalReturned, feesCollected, deltaValue, positionValueAfter);
    }

    /**
     * @notice Change the tick range of an existing position by fully unwinding and re-minting.
     * @dev Owner calls pay protocol fee to reserve; bots additionally pay bot fee to caller bot. 
     * totalDepositedUSDC is unchanged.
     */
    function changeRange(
        bytes32 key,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 slippageBps
    )
        external
        nonReentrant
        onlyKeyOwnerOrBot(key)
        whenNotPaused
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (newTickLower >= newTickUpper) revert InvalidTickRange();

        Position memory p = CORE.getPosition(key);
        uint256 baseUSDC = p.totalDepositedUSDC;

        // Use CORE's on-chain computed pending USDC for the position.
        PositionDetails memory det = CORE.getPositionDetails(key);
        uint256 feesCollectedAtStart = det.pendingFeesUSDC;

        // Validate new ticks align with stored spacing.
        if ((newTickLower % p.tickSpacing) != 0 || (newTickUpper % p.tickSpacing) != 0) revert InvalidTickRange();
        if (newTickLower < -887272 || newTickUpper > 887272) revert InvalidTickRange();

        bool callerIsBot = CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = CORE.botFeeBps();
        bool zeroFeeOwner = _isZeroFee(p.owner);

        // Snapshot position value before any operations.
        uint256 positionValueBefore = _corePositionValue(key);

        // Fully unwind the old NFT into underlying tokens.
        (address[] memory toks, uint256[] memory amts) =
            ICLDexAdapter(p.dex).unwindToTokens(abi.encode(p.tokenId), address(this));

        uint256 bal0 = 0;
        uint256 bal1 = 0;
        for (uint256 idx = 0; idx < toks.length; ++idx) {
            if (toks[idx] == p.token0) {
                bal0 += amts[idx];
            } else if (toks[idx] == p.token1) {
                bal1 += amts[idx];
            }
        }

        if (bal0 == 0 && bal1 == 0) revert NoTokensUnwound();

        address pool = p.pool;
        if (pool == address(0)) revert PoolNotFound();
        if (!CORE.isPoolAllowed(pool)) revert PoolNotAllowed();

        // From the unwound tokens, determine optimal swap amounts for the new range.
        RebalanceParams memory plan = PLANNER.planFromTokenBundle(
            p.dex,
            pool,
            p.token0,
            p.token1,
            newTickLower,
            newTickUpper,
            bal0,
            bal1
        );

        // Transfer the exact unwound token amounts to adapter for minting.
        // Mint new NFT in the requested range using the unwound tokens only.
        if (bal0 > 0) IERC20(p.token0).safeTransfer(p.dex, bal0);
        if (bal1 > 0) IERC20(p.token1).safeTransfer(p.dex, bal1);
        uint256 changeBaseUSDC = _tokenValueUSDC(p.dex, p.token0, bal0) + _tokenValueUSDC(p.dex, p.token1, bal1);
        uint256 remainingLossUSDC = _lossBudgetUSDC(changeBaseUSDC, slippageBps);

        (uint256 newTokenId, , , uint256 leftoverUSDC, uint256 remainingLossUSDCFinal) = ICLDexAdapter(p.dex).mintPosition(
            p.token0,
            p.token1,
            address(USDC),
            p.fee,
            p.tickSpacing,
            newTickLower,
            newTickUpper,
            address(CORE),
            bal0,
            bal1,
            plan,
            remainingLossUSDC
        );

        if (newTokenId == 0) revert NoPositionMinted();

        leftoverUSDC = _maybeSecondPass(
            p.dex,
            pool,
            p.token0,
            p.token1,
            newTickLower,
            newTickUpper,
            newTokenId,
            leftoverUSDC,
            baseUSDC,
            remainingLossUSDCFinal
        );

        CORE.updateTokenMetadata(key, newTokenId, newTickLower, newTickUpper);

        uint256 botFeeUSDC = 0;
        uint256 protocolFeeUSDC = 0;

        (uint16 protocolFeeBpsLocal, address reserve) = _protocolFeeConfig();
        if (zeroFeeOwner) {
            protocolFeeBpsLocal = 0;
        }
        uint16 botFeeBpsLocal = callerIsBot && !zeroFeeOwner ? botFeeBps_ : 0;
        uint16 totalFeeBps = protocolFeeBpsLocal + botFeeBpsLocal;

        if (totalFeeBps > 0) {
            // Protocol/bot fee conversions are outside the user budget model, but should use
            // the caller's full slippage tolerance. Derive a USDC loss budget for the expected
            // notional being removed.
            uint256 positionValueForFee = _corePositionValue(key);
            uint256 feeBaseUSDC = FullMath.mulDiv(positionValueForFee, totalFeeBps, BPS);
            uint256 feeLossBudgetUSDC = _lossBudgetUSDC(feeBaseUSDC, slippageBps);

            uint256 feeFractionTotal = uint256(totalFeeBps) * 1e14; // bps -> 18-dec fraction
            uint256 totalFeeUSDC = ICLDexAdapter(p.dex).removeLiquidityBpsUSDC(
                abi.encode(newTokenId),
                feeFractionTotal,
                address(USDC),
                address(this),
                feeLossBudgetUSDC
            );

            if (totalFeeUSDC > 0) {
                if (protocolFeeBpsLocal > 0) {
                    protocolFeeUSDC = FullMath.mulDiv(totalFeeUSDC, protocolFeeBpsLocal, totalFeeBps);
                    if (protocolFeeUSDC > 0) {
                        USDC.safeTransfer(reserve, protocolFeeUSDC);
                        emit ProtocolFeePaid(
                            p.owner,
                            key,
                            newTokenId,
                            totalFeeUSDC,
                            protocolFeeUSDC,
                            totalFeeUSDC > protocolFeeUSDC ? totalFeeUSDC - protocolFeeUSDC : 0,
                            FeeType.ChangeRange
                        );
                    }
                }

                botFeeUSDC = totalFeeUSDC > protocolFeeUSDC ? totalFeeUSDC - protocolFeeUSDC : 0;
                if (botFeeUSDC > 0 && botFeeBpsLocal > 0) {
                    USDC.safeTransfer(msg.sender, botFeeUSDC);
                    emit BotFeePaid(msg.sender, key, newTokenId, botFeeUSDC, FeeType.ChangeRange);
                }
            }
        }

        // Track mint leftover USDC as dust on the position.
        _addDust(key, leftoverUSDC);

        // Snapshot position value after fees and dust tracking.
        uint256 positionValueAfter = _corePositionValue(key);

        emit RangeChanged(
            p.owner,
            key,
            p.tokenId,
            newTokenId,
            p.tickLower,
            p.tickUpper,
            newTickLower,
            newTickUpper,
            positionValueBefore,
            positionValueAfter,
            protocolFeeUSDC,
            feesCollectedAtStart
        );
    }

    /**
     * @notice Allow or disallow bots for a specific position.
     * @dev Callable by the position owner. This updates a per-position flag in CORE.
     */
    function allowBotForPosition(bytes32 key, bool allowed) external nonReentrant onlyKeyOwner(key) whenNotPaused {
        CORE.setBotAllowedForPosition(key, allowed);
    }

    /**
     * @notice Withdraw tracked dust (USDC) for a position and send to the owner.
     * @dev Decrements `totalDepositedUSDC` by the withdrawn dust amount.
     */
    function withdrawDust(bytes32 key) external nonReentrant onlyKeyOwner(key) whenNotPaused {
        Position memory p = CORE.getPosition(key);

        // Withdraw dust from CORE; returns amount of USDC transferred to manager
        uint256 dust = CORE.withdrawDustForPosition(key, address(this), type(uint256).max);
        if (dust == 0) revert ZeroAmount();

        // Decrease totalDepositedUSDC by the withdrawn amount
        CORE.adjustTotalDeposited(key, -int256(dust));

        // Transfer USDC to the position owner
        USDC.safeTransfer(p.owner, dust);
    }

    /* ───────────── Internal Helpers ───────────── */

    function _addDust(bytes32 key, uint256 amount) internal {
        if (amount == 0) return;
        USDC.safeTransfer(address(CORE), amount);
        CORE.addDustToPosition(key, amount);
    }

    /// @dev Live position value using adapter quoter-based routing (includes owed fees).
    function _quotedPositionValue(bytes32 key, Position memory p)
        internal
        view
        returns (uint256 valueExcludingDust)
    {
        if (p.tokenId == 0 || p.dex == address(0)) {
            return 0;
        }

        (uint256 amt0, uint256 amt1, uint128 owed0, uint128 owed1) = CORE.spotAmounts(key);

        address token0 = p.token0;
        address token1 = p.token1;

        uint256 total0 = amt0 + uint256(owed0);
        uint256 total1 = amt1 + uint256(owed1);

        uint256 value0 = 0;
        if (total0 > 0) {
            value0 = ICLDexAdapter(p.dex).getExpectedOutUSDC(token0, total0, address(USDC));
        }
        
        uint256 value1 = 0;
        if (total1 > 0) {
            value1 = ICLDexAdapter(p.dex).getExpectedOutUSDC(token1, total1, address(USDC));
        }

        valueExcludingDust = value0 + value1;
    }

    function _corePositionValue(bytes32 key) internal view returns (uint256) {
        // Use a single-key accessor on CORE to avoid allocating small arrays
        // and to reduce external call overhead for common single-key paths.
        return CORE.positionValueUSDCSingle(key);
    }

    function _tokenValueUSDC(address dex, address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (token == address(USDC)) return amount;
        uint256 value = VALUATION.usdcValue(dex, token, amount);
        return value;
    }

    function _isZeroFee(address owner) internal view returns (bool) {
        return CORE.zeroFeeWallets(owner);
    }

    function _protocolFeeConfig() internal view returns (uint16 bps, address reserve) {
        bps = CORE.protocolFeeBps();
        reserve = CORE.protocolReserve();
        if (bps > 0 && reserve == address(0)) revert ReserveNotSet();
    }

    function _protocolFeeAmount(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return bps == 0 ? 0 : FullMath.mulDiv(amount, bps, BPS);
    }

    function _lossBudgetUSDC(uint256 baseUSDC, uint256 slippageBps) internal pure returns (uint256 remainingLossUSDC) {
        if (baseUSDC == 0) return 0;
        if (slippageBps == 0) return 0;
        uint256 sl = slippageBps >= BPS ? BPS - 1 : slippageBps;
        return FullMath.mulDivRoundingUp(baseUSDC, sl, BPS);
    }

    function _maybeSecondPass(
        address dex,
        address pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenId,
        uint256 leftoverUSDC,
        uint256 baseUSDC,
        uint256 remainingLossUSDC
    ) internal returns (uint256) {
        if (leftoverUSDC == 0 || tokenId == 0 || baseUSDC == 0 || remainingLossUSDC == 0) {
            return leftoverUSDC;
        }

        uint256 leftoverRatioBps = FullMath.mulDiv(leftoverUSDC, BPS, baseUSDC);
        // If leftover is <= SECOND_PASS_THRESHOLD_BPS of base OR less than $0.001, skip second pass.
        if (leftoverRatioBps <= SECOND_PASS_THRESHOLD_BPS || leftoverUSDC < SECOND_PASS_MIN_USDC) {
            return leftoverUSDC;
        }

        if (leftoverUSDC > 0) {
            USDC.safeTransfer(dex, leftoverUSDC);
        }

        (uint256 amount0In, uint256 amount1In, uint256 remainingLossUSDCOut) = ICLDexAdapter(dex).seedPairFromUSDC(
            address(USDC),
            token0,
            token1,
            leftoverUSDC,
            remainingLossUSDC
        );

        if (amount0In == 0 && amount1In == 0) {
            return leftoverUSDC;
        }

        RebalanceParams memory plan = PLANNER.planFromTokenBundle(
            dex,
            pool,
            token0,
            token1,
            tickLower,
            tickUpper,
            amount0In,
            amount1In
        );
        (, , uint256 newLeftoverUSDC, ) = ICLDexAdapter(dex).addLiquidity(
            abi.encode(tokenId),
            address(USDC),
            amount0In,
            amount1In,
            plan,
            remainingLossUSDCOut
        );

        return newLeftoverUSDC;
    }

    /// @dev Handles selling collected fee tokens to pay bot fee and returns (paidUSDC, remainingFee0, remainingFee1)
    function _handleBotFeeOnCollected(
        address dex,
        address token0,
        address token1,
        uint256 fee0,
        uint256 fee1,
        uint16 botFeeBpsLocal,
        uint256 slippageBps
    ) internal returns (uint256 paidUSDC, uint256 remainingFee0, uint256 remainingFee1) {
        paidUSDC = 0;
        remainingFee0 = fee0;
        remainingFee1 = fee1;

        // Compute USDC-equivalent of fees we collected
        uint256 val0 = _tokenValueUSDC(dex, token0, fee0);
        uint256 val1 = _tokenValueUSDC(dex, token1, fee1);
        uint256 initialUSDCIn = val0 + val1;
        if (initialUSDCIn == 0) return (0, remainingFee0, remainingFee1);

        uint256 targetFeeUSDC = FullMath.mulDiv(initialUSDCIn, botFeeBpsLocal, BPS);

        uint256 sell0 = 0;
        uint256 sell1 = 0;

        // Prefer selling from token0 first; if insufficient, use token1.
        if (val0 >= targetFeeUSDC) {
            sell0 = FullMath.mulDiv(fee0, targetFeeUSDC, val0);
        } else {
            sell0 = fee0;
            uint256 remainingUSDC = targetFeeUSDC > val0 ? targetFeeUSDC - val0 : 0;
            if (remainingUSDC > 0 && val1 > 0) {
                sell1 = FullMath.mulDiv(fee1, remainingUSDC, val1);
            }
        }

        if (sell0 > fee0) sell0 = fee0;
        if (sell1 > fee1) sell1 = fee1;

        // Protocol/bot fee conversions are outside the user budget model, but still need a
        // slippage tolerance to avoid unnecessary reverts. Derive a fresh USDC loss budget
        // from the expected notional being swapped and apply it sequentially.
        uint256 expectedSellUSDC = 0;
        if (sell0 > 0 && fee0 > 0) expectedSellUSDC += FullMath.mulDivRoundingUp(val0, sell0, fee0);
        if (sell1 > 0 && fee1 > 0) expectedSellUSDC += FullMath.mulDivRoundingUp(val1, sell1, fee1);
        uint256 remainingLossUSDC = _lossBudgetUSDC(expectedSellUSDC, slippageBps);

        if (sell0 > 0) {
            IERC20(token0).safeTransfer(dex, sell0);
            (uint256 outUSDC, uint256 remainingLossUSDCOut) = ICLDexAdapter(dex).swapExactInToUSDC(
                token0,
                sell0,
                address(USDC),
                msg.sender,
                remainingLossUSDC
            );
            paidUSDC += outUSDC;
            remainingFee0 = remainingFee0 > sell0 ? remainingFee0 - sell0 : 0;
            remainingLossUSDC = remainingLossUSDCOut;
        }

        if (sell1 > 0) {
            IERC20(token1).safeTransfer(dex, sell1);
            (uint256 outUSDC,) = ICLDexAdapter(dex).swapExactInToUSDC(
                token1,
                sell1,
                address(USDC),
                msg.sender,
                remainingLossUSDC
            );
            paidUSDC += outUSDC;
            remainingFee1 = remainingFee1 > sell1 ? remainingFee1 - sell1 : 0;
        }

        return (paidUSDC, remainingFee0, remainingFee1);
    }
}
