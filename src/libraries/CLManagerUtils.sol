// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {
    ICLDexAdapter,
    ICLCore,
    IValuation,
    IEZWrapper,
    IReferralManager,
    IRebalancePlanner,
    PendingFeesResult,
    Position,
    PositionDetails,
    RebalanceParams
} from "../Interfaces.sol";

interface ICLManagerDiscounts {
    function discountedFeeWallets(address wallet) external view returns (uint16);
}

library CLManagerUtils {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant LIQUIDITY_PERCENTAGE_PRECISION = 1e18;

    struct Config {
        ICLCore CORE;
        IERC20 USDC;
        IValuation VALUATION;
        IRebalancePlanner PLANNER;
        uint256 MAX_BATCH_KEYS;
        uint256 MINIMUM_OPEN_USDC;
        uint16 botFeeMultiplierForEarnedFees;
        uint16 earnedFeesProtocolFeeBps;
        uint16 maxProtocolFeeSlippageBps;
        IEZWrapper EZ_WRAPPER;
        IReferralManager REFERRAL_MANAGER;
    }

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
        Compound,
        CollateralRemove
    }

    event FeesCollected(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 fee0,
        uint256 fee1,
        uint256 usdcOut,
        uint256 protocolFeeUSDC,
        uint256 referralFeeUSDC
    );

    event PositionExited(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 returnedUSDC,
        uint256 feesCollected,
        uint256 protocolFeeUSDC,
        uint256 referralFeeUSDC
    );

    event PositionNftReturned(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 returnedUSDC,
        uint256 feesCollected
    );

    event FeesCompounded(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 compoundedUSDC,
        uint256 used0,
        uint256 used1,
        uint256 protocolFeeUSDC,
        uint256 referralFeeUSDC,
        uint256 dustAdded
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
        uint256 referralFeeUSDC,
        uint256 feesCollected
    );

    event CollateralRemoved(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 returnedUSDC,
        uint256 feesCollected,
        uint256 protocolFeeUSDC,
        uint256 referralFeeUSDC,
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

    event ReferralFeePaid(
        address indexed referrer,
        address indexed user,
        bytes32 indexed key,
        uint256 grossUSDC,
        uint256 referralFeeUSDC,
        uint256 netUSDC,
        FeeType feeType
    );

    error NotOwner();
    error EmptyKeys();
    error TooManyInBatch(uint256 maxKeys);
    error PositionNotFound();
    error PoolNotFound();
    error PoolNotAllowed();
    error NothingRemoved();
    error PositionValueZero();
    error TooMuchWithdraw();
    error BpsZero();
    error ZeroAmount();
    error InvalidTickRange();
    error RangeUnchanged();
    error InvalidToken();
    error NoTokensUnwound();
    error NoPositionMinted();
    error ReserveNotSet();
    error FeeTooHigh();

    function exitPosition(Config memory cfg, bytes32[] calldata keys, uint256 slippageBps)
        external
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > cfg.MAX_BATCH_KEYS) revert TooManyInBatch(cfg.MAX_BATCH_KEYS);
        bool callerIsBot = cfg.CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = cfg.CORE.botFeeBps();

        for (uint256 k = 0; k < keys.length; ++k) {
            bytes32 key = keys[k];
            Position memory p = cfg.CORE.getPosition(key);
            if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

            _requireOwnerOrBot(p.owner, p.botAllowed, callerIsBot);

            // Use CORE's on-chain computed pending USDC for the position.
            PositionDetails memory det = cfg.CORE.getPositionDetails(key);
            uint256 feesCollectedAtStart = det.pendingFeesUSDC;

            uint16 botFeeBpsLocal = _applyFeeDiscount(p.owner, botFeeBps_, 0);
            (uint16 earnedProtocolFeeBps, address reserve) = _earnedProtocolFeeConfig(cfg, p.owner);

            uint256 usdcBefore = cfg.USDC.balanceOf(address(this));

            // Unwind NFT to underlying tokens (may include USDC already).
            (address[] memory toks, uint256[] memory amts) =
                ICLDexAdapter(p.dex).unwindToTokens(abi.encode(p.tokenId), address(this));

            // Swap all non-USDC tokens to USDC using a single USDC-denominated loss budget.
            uint256 swapBaseUSDC = 0;
            for (uint256 i = 0; i < toks.length; ++i) {
                if (amts[i] > 0 && toks[i] != address(cfg.USDC)) {
                    swapBaseUSDC += _tokenValueUSDC(cfg, p.dex, toks[i], amts[i]);
                }
            }

            uint256 remainingLossUSDC = _lossBudgetUSDC(swapBaseUSDC, slippageBps);
            for (uint256 i = 0; i < toks.length; ++i) {
                address token = toks[i];
                uint256 amount = amts[i];
                if (amount == 0) continue;
                if (token == address(cfg.USDC)) continue;

                // Transfer token to adapter so it can swap from its own balance.
                IERC20(token).safeTransfer(p.dex, amount);
                (, remainingLossUSDC) = ICLDexAdapter(p.dex).swapExactInToUSDC(
                    token,
                    amount,
                    address(cfg.USDC),
                    address(this),
                    remainingLossUSDC
                );
            }

            // Withdraw tracked dust from CORE before deregistration to refund it.
            uint256 dustFromCore = cfg.CORE.withdrawDustForPosition(key, address(this), type(uint256).max);

            cfg.CORE.deregisterPosition(key);

            uint256 usdcAfter = cfg.USDC.balanceOf(address(this));
            uint256 returnedUSDC = usdcAfter - usdcBefore;
            uint256 protocolFeeUSDC = 0;
            uint256 referralFeeUSDC = 0;

            if (returnedUSDC > dustFromCore) {
                uint256 nonDustUSDC = returnedUSDC - dustFromCore;
                uint256 protocolBasisUSDC = feesCollectedAtStart < nonDustUSDC ? feesCollectedAtStart : nonDustUSDC;
                uint256 protocolTargetUSDC = earnedProtocolFeeBps == 0
                    ? 0
                    : FullMath.mulDiv(protocolBasisUSDC, earnedProtocolFeeBps, BPS);
                uint256 botTargetUSDC = callerIsBot && botFeeBpsLocal > 0
                    ? FullMath.mulDiv(nonDustUSDC, botFeeBpsLocal, BPS)
                    : 0;
                uint256 botFeeUSDC;
                (protocolFeeUSDC, referralFeeUSDC, botFeeUSDC,) = _payUSDCFeeTargets(
                    cfg,
                    reserve,
                    callerIsBot ? msg.sender : address(0),
                    p.owner,
                    key,
                    p.tokenId,
                    protocolBasisUSDC,
                    nonDustUSDC,
                    protocolTargetUSDC,
                    botTargetUSDC,
                    FeeType.Exit
                );
                uint256 totalFeeUSDC = protocolFeeUSDC + referralFeeUSDC + botFeeUSDC;
                returnedUSDC = returnedUSDC > totalFeeUSDC ? returnedUSDC - totalFeeUSDC : 0;
            }

            if (returnedUSDC > 0) {
                cfg.USDC.safeTransfer(p.owner, returnedUSDC);
            }
            if (p.owner == address(cfg.EZ_WRAPPER) && msg.sender != address(cfg.EZ_WRAPPER)) {
                cfg.EZ_WRAPPER.creditBotActionProceeds(key, returnedUSDC, true);
            }

            emit PositionExited(p.owner, key, p.tokenId, returnedUSDC, feesCollectedAtStart, protocolFeeUSDC, referralFeeUSDC);
        }
    }

    function returnNft(
        Config memory cfg,
        bytes32[] calldata keys,
        bool isPaused,
        address protocolOwner
    ) external {
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > cfg.MAX_BATCH_KEYS) revert TooManyInBatch(cfg.MAX_BATCH_KEYS);
        bool isProtocolOwner = msg.sender == protocolOwner;

        for (uint256 i = 0; i < keys.length; ++i) {
            bytes32 key = keys[i];

            Position memory p = cfg.CORE.getPosition(key);
            if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

            // Only the position owner or the protocol owner (when paused in emergencies) may return the NFT.
            if(isPaused) {
                if (!isProtocolOwner && p.owner != msg.sender) revert NotOwner();
            } else {
                if (p.owner != msg.sender) revert NotOwner();
            }

            uint256 feesCollectedAtStart = 0;
            uint256 returnedUSDC = 0;

            // try catch so Valuation or non-essential accounting errors can't brick emergency exit.
            // This is the only place where we tolerate this.
            try cfg.CORE.getPositionDetails(key) returns (PositionDetails memory det) {
                // Snapshot pending USDC-denominated fees at the time of return.
                feesCollectedAtStart = det.pendingFeesUSDC;
            } catch {
                feesCollectedAtStart = 0;
            }

            try cfg.CORE.positionValueUSDCSingle(key) returns (uint256 returnedUSDC_) {
                returnedUSDC = returnedUSDC_;
            } catch {
                returnedUSDC = 0;
            }

            address npm = ICLDexAdapter(p.dex).getNPM();
            uint256 dustReturned = p.dustUSDC;

            // CORE will transfer the NFT (and any tracked dust) to the owner
            // and deregister the position.
            cfg.CORE.returnPosition(key);
            if (p.owner == address(cfg.EZ_WRAPPER) && msg.sender != address(cfg.EZ_WRAPPER)) {
                cfg.EZ_WRAPPER.creditReturnedNft(key, npm, p.tokenId, dustReturned);
            }

            emit PositionNftReturned(p.owner, key, p.tokenId, returnedUSDC, feesCollectedAtStart);
        }
    }

    function collectFeesToUSDC(Config memory cfg, bytes32[] calldata keys, uint256 slippageBps)
        external
        returns (uint256 usdcSent)
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > cfg.MAX_BATCH_KEYS) revert TooManyInBatch(cfg.MAX_BATCH_KEYS);

        bool callerIsBot = cfg.CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = cfg.CORE.botFeeBps();

        uint256 total = 0;

        for (uint256 i = 0; i < keys.length; ++i) {
            bytes32 key = keys[i];

            Position memory p = cfg.CORE.getPosition(key);

            if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();
            _requireOwnerOrBot(p.owner, p.botAllowed, callerIsBot);

            PositionDetails memory det = cfg.CORE.getPositionDetails(key);
            uint256 remainingLossUSDC = _lossBudgetUSDC(det.pendingFeesUSDC, slippageBps);
            (uint16 earnedProtocolFeeBps, address reserve) = _earnedProtocolFeeConfig(cfg, p.owner);

            (uint256 fee0, uint256 fee1, uint256 outUSDC, ) =
                ICLDexAdapter(p.dex).collectFeesToUSDC(abi.encode(p.tokenId), address(cfg.USDC), remainingLossUSDC);

            uint16 botFeeBpsLocal =
                _applyFeeDiscount(p.owner, _scaledFeeBps(botFeeBps_, cfg.botFeeMultiplierForEarnedFees), 0);

            (uint256 protocolTargetUSDC, uint256 botTargetUSDC) =
                _feeAmountsFromBasis(outUSDC, earnedProtocolFeeBps, callerIsBot ? botFeeBpsLocal : 0);
            (uint256 protocolFeeUSDC, uint256 referralFeeUSDC,, uint256 netUSDC) = _payUSDCFeeTargets(
                cfg,
                reserve,
                callerIsBot ? msg.sender : address(0),
                p.owner,
                key,
                p.tokenId,
                outUSDC,
                outUSDC,
                protocolTargetUSDC,
                botTargetUSDC,
                FeeType.Collect
            );

            if (netUSDC > 0) {
                cfg.USDC.safeTransfer(p.owner, netUSDC);
                if (p.owner == address(cfg.EZ_WRAPPER) && msg.sender != address(cfg.EZ_WRAPPER)) {
                    cfg.EZ_WRAPPER.creditBotActionProceeds(key, netUSDC, false);
                }
                total = total + netUSDC;
            }

            emit FeesCollected(p.owner, key, p.tokenId, fee0, fee1, outUSDC, protocolFeeUSDC, referralFeeUSDC);
        }

        return total;
    }

    function compoundFees(Config memory cfg, bytes32[] calldata keys, uint256 slippageBps)
        external
        returns (uint256 compoundedUSDCTotal)
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (keys.length == 0) revert EmptyKeys();
        if (keys.length > cfg.MAX_BATCH_KEYS) revert TooManyInBatch(cfg.MAX_BATCH_KEYS);

        bool callerIsBot = cfg.CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = cfg.CORE.botFeeBps();

        PendingFeesResult[] memory pending = cfg.CORE.pendingFees(keys);

        for (uint256 i = 0; i < keys.length; ++i) {
            (uint256 compoundedUSDC) =
                _compoundOne(cfg, keys[i], pending[i], slippageBps, callerIsBot, botFeeBps_);

            compoundedUSDCTotal += compoundedUSDC;
        }
    }

    function _compoundOne(
        Config memory cfg,
        bytes32 key,
        PendingFeesResult memory pending,
        uint256 slippageBps,
        bool callerIsBot,
        uint16 botFeeBps_
    ) internal returns (uint256 compoundedUSDCOut) {
        if (pending.owed0 == 0 && pending.owed1 == 0) {
            return 0;
        }

        Position memory p = cfg.CORE.getPosition(key);
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();
        _requireOwnerOrBot(p.owner, p.botAllowed, callerIsBot);

        CompoundContext memory ctx;
        ctx.owner = p.owner;
        ctx.tokenId = p.tokenId;
        ctx.token0 = p.token0;
        ctx.token1 = p.token1;
        ctx.dex = p.dex;

        (, , uint256 fee0, uint256 fee1) = ICLDexAdapter(ctx.dex).collectFeesToTokens(abi.encode(ctx.tokenId), address(this));
        uint256 grossFee0 = fee0;
        uint256 grossFee1 = fee1;

        if (fee0 == 0 && fee1 == 0) {
            emit FeesCollected(p.owner, key, ctx.tokenId, grossFee0, grossFee1, 0, 0, 0);
            return 0;
        }

        address pool = p.pool;
        if (pool == address(0)) revert PoolNotFound();
        if (!cfg.CORE.isPoolAllowed(pool)) revert PoolNotAllowed();

        uint16 botFeeBpsLocal =
            _applyFeeDiscount(p.owner, _scaledFeeBps(botFeeBps_, cfg.botFeeMultiplierForEarnedFees), 0);
        (uint16 earnedProtocolFeeBps, address reserve) = _earnedProtocolFeeConfig(cfg, p.owner);

        uint256 protocolFeeUSDC;
        uint256 referralFeeUSDC;
        (protocolFeeUSDC, referralFeeUSDC,, fee0, fee1) = _payEarnedFeesFromCollectedTokens(
            cfg,
            reserve,
            callerIsBot ? msg.sender : address(0),
            ctx.dex,
            ctx.token0,
            ctx.token1,
            p.owner,
            key,
            ctx.tokenId,
            fee0,
            fee1,
            earnedProtocolFeeBps,
            callerIsBot ? botFeeBpsLocal : 0,
            slippageBps,
            FeeType.Compound
        );
        emit FeesCollected(p.owner, key, ctx.tokenId, grossFee0, grossFee1, 0, protocolFeeUSDC, referralFeeUSDC);

        if (fee0 > 0) IERC20(ctx.token0).safeTransfer(ctx.dex, fee0);
        if (fee1 > 0) IERC20(ctx.token1).safeTransfer(ctx.dex, fee1);

        RebalanceParams memory plan = cfg.PLANNER.planFromTokenBundle(
            ctx.dex,
            pool,
            ctx.token0,
            ctx.token1,
            p.tickLower,
            p.tickUpper,
            fee0,
            fee1
        );

        uint256 compoundBaseUSDC = _tokenValueUSDC(cfg, ctx.dex, ctx.token0, fee0) + _tokenValueUSDC(cfg, ctx.dex, ctx.token1, fee1);
        uint256 remainingLossUSDC = _lossBudgetUSDC(compoundBaseUSDC, slippageBps);

        (uint256 used0, uint256 used1, uint256 leftoverUSDC, ) =
            ICLDexAdapter(ctx.dex).addLiquidity(
                abi.encode(ctx.tokenId),
                address(cfg.USDC),
                fee0,
                fee1,
                plan,
                remainingLossUSDC
            );

        uint256 compoundedUSDC = _tokenValueUSDC(cfg, ctx.dex, ctx.token0, used0) + _tokenValueUSDC(cfg, ctx.dex, ctx.token1, used1);

        _addDust(cfg, key, leftoverUSDC);

        emit FeesCompounded(p.owner, key, ctx.tokenId, compoundedUSDC, used0, used1, protocolFeeUSDC, referralFeeUSDC, leftoverUSDC);
        return compoundedUSDC;
    }

    function removeCollateral(Config memory cfg, bytes32 key, uint256 withdrawUSDC, uint256 slippageBps) external {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (withdrawUSDC == 0) revert ZeroAmount();

        Position memory p = cfg.CORE.getPosition(key);

        uint256 positionValueInitial = cfg.CORE.positionValueUSDCSingle(key);
        uint256 positionValueExcludingDust = positionValueInitial - p.dustUSDC;

        if (positionValueInitial == 0) revert PositionValueZero();

        uint256 remainingTarget = withdrawUSDC;
        uint256 totalReturned = 0;
        uint256 feesCollected = 0;

        if (p.dustUSDC > 0) {
            uint256 dustToWithdraw = remainingTarget < p.dustUSDC ? remainingTarget : p.dustUSDC;
            if (dustToWithdraw > 0) {
                uint256 dustWithdrawn = cfg.CORE.withdrawDustForPosition(key, address(this), dustToWithdraw);
                if (dustWithdrawn > 0) {
                    remainingTarget -= dustWithdrawn;
                    totalReturned += dustWithdrawn;
                }
            }
        }

        if (remainingTarget == 0) {
            p = cfg.CORE.getPosition(key);
            uint256 positionValueAfterDust = cfg.CORE.positionValueUSDCSingle(key);
            feesCollected = 0;
            uint256 removedUSDC = totalReturned;
            uint256 dustDepositedDebit =
                totalReturned < p.totalDepositedUSDC ? totalReturned : p.totalDepositedUSDC;
            if (dustDepositedDebit > 0) {
                cfg.CORE.adjustTotalDeposited(key, -int256(dustDepositedDebit));
            }
            cfg.USDC.safeTransfer(p.owner, totalReturned);
            emit CollateralRemoved(
                p.owner,
                key,
                p.tokenId,
                totalReturned,
                feesCollected,
                0,
                0,
                removedUSDC,
                positionValueAfterDust
            );
            return;
        }

        uint256 quotedPositionValueBefore = _quotedPositionValue(cfg, key, p);

        if (quotedPositionValueBefore == 0) {
            quotedPositionValueBefore = positionValueExcludingDust;
        }

        if (quotedPositionValueBefore == 0) revert PositionValueZero();

        uint256 remainingAfter = quotedPositionValueBefore > remainingTarget
            ? quotedPositionValueBefore - remainingTarget
            : 0;
        if (remainingAfter < cfg.MINIMUM_OPEN_USDC) revert TooMuchWithdraw();

        uint256 withdrawFraction = FullMath.mulDiv(
            remainingTarget,
            LIQUIDITY_PERCENTAGE_PRECISION,
            quotedPositionValueBefore
        );

        if (withdrawFraction == 0) revert BpsZero();
        if (withdrawFraction >= LIQUIDITY_PERCENTAGE_PRECISION) {
            withdrawFraction = LIQUIDITY_PERCENTAGE_PRECISION - 1;
        }

        PositionDetails memory detBefore = cfg.CORE.getPositionDetails(key);

        uint256 remainingLossUSDC = _lossBudgetUSDC(remainingTarget, slippageBps);
        uint256 usdcOut = ICLDexAdapter(p.dex).removeLiquidityBpsUSDC(
            abi.encode(p.tokenId),
            withdrawFraction,
            address(cfg.USDC),
            address(this),
            remainingLossUSDC
        );
        if (usdcOut == 0) revert NothingRemoved();

        totalReturned += usdcOut;

        uint256 positionValueAfter = cfg.CORE.positionValueUSDCSingle(key);

        uint256 deltaValue =
            positionValueInitial > positionValueAfter
                ? positionValueInitial - positionValueAfter
                : 0;
        uint256 depositedDebit = deltaValue < p.totalDepositedUSDC ? deltaValue : p.totalDepositedUSDC;
        if (depositedDebit > 0) {
            cfg.CORE.adjustTotalDeposited(key, -int256(depositedDebit));
        }

        PositionDetails memory detAfter = cfg.CORE.getPositionDetails(key);
        feesCollected = 0;
        if (detAfter.pendingFeesUSDC > detBefore.pendingFeesUSDC) {
            feesCollected = 0;
        } else {
            feesCollected = detBefore.pendingFeesUSDC > detAfter.pendingFeesUSDC
                ? detBefore.pendingFeesUSDC - detAfter.pendingFeesUSDC
                : 0;
        }

        (uint16 earnedProtocolFeeBps, address reserve) = _earnedProtocolFeeConfig(cfg, p.owner);
        uint256 feeBasisUSDC = feesCollected < usdcOut ? feesCollected : usdcOut;
        uint256 protocolFeeUSDC = earnedProtocolFeeBps == 0
            ? 0
            : FullMath.mulDiv(feeBasisUSDC, earnedProtocolFeeBps, BPS);
        uint256 referralFeeUSDC;
        if (protocolFeeUSDC > 0) {
            referralFeeUSDC = _payProtocolFee(cfg, reserve, p.owner, key, p.tokenId, feeBasisUSDC, protocolFeeUSDC, FeeType.CollateralRemove);
            protocolFeeUSDC -= referralFeeUSDC;
        }

        uint256 netReturned = totalReturned - protocolFeeUSDC - referralFeeUSDC;
        cfg.USDC.safeTransfer(p.owner, netReturned);

        emit CollateralRemoved(
            p.owner,
            key,
            p.tokenId,
            netReturned,
            feesCollected,
            protocolFeeUSDC,
            referralFeeUSDC,
            deltaValue,
            positionValueAfter
        );
    }

    function changeRange(Config memory cfg, bytes32 key, int24 newTickLower, int24 newTickUpper, uint256 slippageBps)
        external
    {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (newTickLower >= newTickUpper) revert InvalidTickRange();

        Position memory p = cfg.CORE.getPosition(key);
        if (newTickLower == p.tickLower && newTickUpper == p.tickUpper) revert RangeUnchanged();

        PositionDetails memory det = cfg.CORE.getPositionDetails(key);
        uint256 feesCollectedAtStart = det.pendingFeesUSDC;

        if ((newTickLower % p.tickSpacing) != 0 || (newTickUpper % p.tickSpacing) != 0) revert InvalidTickRange();
        if (newTickLower < -887272 || newTickUpper > 887272) revert InvalidTickRange();

        bool callerIsBot = cfg.CORE.allowedBots(msg.sender);
        uint16 botFeeBps_ = cfg.CORE.botFeeBps();
        (uint16 earnedProtocolFeeBps, address reserve) = _earnedProtocolFeeConfig(cfg, p.owner);

        uint256 positionValueBefore = cfg.CORE.positionValueUSDCSingle(key);
        (uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 collectedFee0, uint256 collectedFee1) =
            _collectChangeRangeFees(cfg, p, key, feesCollectedAtStart, earnedProtocolFeeBps, reserve, slippageBps);

        (address[] memory toks, uint256[] memory amts) =
            ICLDexAdapter(p.dex).unwindToTokens(abi.encode(p.tokenId), address(this));

        uint256 bal0 = collectedFee0;
        uint256 bal1 = collectedFee1;
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
        if (!cfg.CORE.isPoolAllowed(pool)) revert PoolNotAllowed();

        RebalanceParams memory plan = cfg.PLANNER.planFromTokenBundle(
            p.dex,
            pool,
            p.token0,
            p.token1,
            newTickLower,
            newTickUpper,
            bal0,
            bal1
        );

        if (bal0 > 0) IERC20(p.token0).safeTransfer(p.dex, bal0);
        if (bal1 > 0) IERC20(p.token1).safeTransfer(p.dex, bal1);
        uint256 changeBaseUSDC = _tokenValueUSDC(cfg, p.dex, p.token0, bal0) + _tokenValueUSDC(cfg, p.dex, p.token1, bal1);
        uint256 remainingLossUSDC = _lossBudgetUSDC(changeBaseUSDC, slippageBps);

        (uint256 newTokenId, , , uint256 leftoverUSDC, ) = ICLDexAdapter(p.dex).mintPosition(
            p.token0,
            p.token1,
            address(cfg.USDC),
            p.fee,
            p.tickSpacing,
            newTickLower,
            newTickUpper,
            address(cfg.CORE),
            bal0,
            bal1,
            plan,
            remainingLossUSDC
        );

        if (newTokenId == 0) revert NoPositionMinted();

        cfg.CORE.updateTokenMetadata(key, newTokenId, newTickLower, newTickUpper);

        _payChangeRangeFees(
            cfg,
            p,
            key,
            newTokenId,
            callerIsBot,
            botFeeBps_,
            slippageBps
        );

        _addDust(cfg, key, leftoverUSDC);

        uint256 positionValueAfter = cfg.CORE.positionValueUSDCSingle(key);

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
            referralFeeUSDC,
            feesCollectedAtStart
        );
    }

    function _payChangeRangeFees(
        Config memory cfg,
        Position memory p,
        bytes32 key,
        uint256 newTokenId,
        bool callerIsBot,
        uint16 botFeeBps_,
        uint256 slippageBps
    ) internal returns (uint256 protocolFeeUSDC) {
        uint16 botFeeBpsLocal = callerIsBot ? _applyFeeDiscount(p.owner, botFeeBps_, 0) : 0;
        if (botFeeBpsLocal == 0) return 0;

        uint256 positionValueForFee = cfg.CORE.positionValueUSDCSingle(key);
        uint256 feeBaseUSDC = FullMath.mulDiv(positionValueForFee, botFeeBpsLocal, BPS);
        uint256 feeFraction = uint256(botFeeBpsLocal) * (LIQUIDITY_PERCENTAGE_PRECISION / BPS);

        uint256 botFeeUSDC = ICLDexAdapter(p.dex).removeLiquidityBpsUSDC(
            abi.encode(newTokenId),
            feeFraction,
            address(cfg.USDC),
            address(this),
            _lossBudgetUSDC(feeBaseUSDC, slippageBps)
        );

        if (botFeeUSDC > 0) {
            cfg.USDC.safeTransfer(msg.sender, botFeeUSDC);
            emit BotFeePaid(msg.sender, key, newTokenId, botFeeUSDC, FeeType.ChangeRange);
        }
    }

    function tokenValueUSDC(IValuation valuation, IERC20 usdc, address dex, address token, uint256 amount) external view returns (uint256) {
        if (amount == 0) return 0;
        if (token == address(usdc)) return amount;
        uint256 value = valuation.usdcValue(dex, token, amount);
        return value;
    }

    function _earnedProtocolFeeConfig(Config memory cfg, address wallet)
        internal
        view
        returns (uint16 bps, address reserve)
    {
        bps = cfg.earnedFeesProtocolFeeBps;
        reserve = cfg.CORE.protocolReserve();
        bps = _applyFeeDiscount(wallet, bps, 0);
    }

    function _collectChangeRangeFees(
        Config memory cfg,
        Position memory p,
        bytes32 key,
        uint256 feesCollectedAtStart,
        uint16 earnedProtocolFeeBps,
        address reserve,
        uint256 slippageBps
    ) internal returns (uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 collectedFee0, uint256 collectedFee1) {
        if (feesCollectedAtStart == 0) return (0, 0, 0, 0);

        (address feeToken0, address feeToken1, uint256 fee0, uint256 fee1) =
            ICLDexAdapter(p.dex).collectFeesToTokens(abi.encode(p.tokenId), address(this));
        if (feeToken0 != p.token0 || feeToken1 != p.token1) revert InvalidToken();

        (protocolFeeUSDC, referralFeeUSDC,, collectedFee0, collectedFee1) = _payEarnedFeesFromCollectedTokens(
            cfg,
            reserve,
            address(0),
            p.dex,
            p.token0,
            p.token1,
            p.owner,
            key,
            p.tokenId,
            fee0,
            fee1,
            earnedProtocolFeeBps,
            0,
            slippageBps,
            FeeType.ChangeRange
        );
    }

    function _payUSDCFeeTargets(
        Config memory cfg,
        address reserve,
        address botReceiver,
        address payer,
        bytes32 key,
        uint256 tokenId,
        uint256 protocolBasisUSDC,
        uint256 availableUSDC,
        uint256 protocolTargetUSDC,
        uint256 botTargetUSDC,
        FeeType feeType
    ) internal returns (uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 botFeeUSDC, uint256 netUSDC) {
        netUSDC = availableUSDC;
        uint256 totalTargetUSDC = protocolTargetUSDC + botTargetUSDC;
        if (totalTargetUSDC == 0) return (0, 0, 0, netUSDC);
        if (protocolTargetUSDC > 0 && reserve == address(0)) revert ReserveNotSet();

        if (totalTargetUSDC > availableUSDC) {
            protocolFeeUSDC = FullMath.mulDiv(availableUSDC, protocolTargetUSDC, totalTargetUSDC);
            botFeeUSDC = availableUSDC - protocolFeeUSDC;
        } else {
            protocolFeeUSDC = protocolTargetUSDC;
            botFeeUSDC = botTargetUSDC;
        }

        if (protocolFeeUSDC > 0) {
            referralFeeUSDC = _payProtocolFee(cfg, reserve, payer, key, tokenId, protocolBasisUSDC, protocolFeeUSDC, feeType);
            protocolFeeUSDC -= referralFeeUSDC;
        }

        if (botFeeUSDC > 0) {
            cfg.USDC.safeTransfer(botReceiver, botFeeUSDC);
            emit BotFeePaid(botReceiver, key, tokenId, botFeeUSDC, feeType);
        }

        uint256 totalFees = protocolFeeUSDC + referralFeeUSDC + botFeeUSDC;
        netUSDC = availableUSDC > totalFees ? availableUSDC - totalFees : 0;
    }

    function _feeAmountsFromBasis(uint256 basisUSDC, uint16 protocolFeeBps, uint16 botFeeBps)
        internal
        pure
        returns (uint256 protocolFeeUSDC, uint256 botFeeUSDC)
    {
        if (basisUSDC == 0) return (0, 0);
        protocolFeeUSDC = protocolFeeBps == 0 ? 0 : FullMath.mulDiv(basisUSDC, protocolFeeBps, BPS);
        botFeeUSDC = botFeeBps == 0 ? 0 : FullMath.mulDiv(basisUSDC, botFeeBps, BPS);

        uint256 totalFees = protocolFeeUSDC + botFeeUSDC;
        if (totalFees <= basisUSDC) return (protocolFeeUSDC, botFeeUSDC);

        protocolFeeUSDC = FullMath.mulDiv(basisUSDC, protocolFeeUSDC, totalFees);
        botFeeUSDC = basisUSDC - protocolFeeUSDC;
    }

    function _payProtocolFee(
        Config memory cfg,
        address reserve,
        address payer,
        bytes32 key,
        uint256 tokenId,
        uint256 grossUSDC,
        uint256 protocolFeeUSDC,
        FeeType feeType
    ) internal returns (uint256 referralFeeUSDC) {
        if (protocolFeeUSDC == 0) return 0;
        if (reserve == address(0)) revert ReserveNotSet();

        uint256 netUSDC = grossUSDC > protocolFeeUSDC ? grossUSDC - protocolFeeUSDC : 0;
        referralFeeUSDC = _referralFeeAmount(cfg, payer, key, protocolFeeUSDC);
        uint256 reserveFeeUSDC = protocolFeeUSDC - referralFeeUSDC;

        if (reserveFeeUSDC > 0) {
            cfg.USDC.safeTransfer(reserve, reserveFeeUSDC);
        }
        if (referralFeeUSDC > 0) {
            address user = _effectiveUser(cfg, payer, key);
            address referrer = cfg.REFERRAL_MANAGER.referrers(user);
            cfg.USDC.safeTransfer(address(cfg.REFERRAL_MANAGER), referralFeeUSDC);
            cfg.REFERRAL_MANAGER.creditReferralFee(
                referrer,
                user,
                key,
                grossUSDC,
                referralFeeUSDC,
                netUSDC,
                uint8(feeType)
            );
            emit ReferralFeePaid(referrer, user, key, grossUSDC, referralFeeUSDC, netUSDC, feeType);
        }

        emit ProtocolFeePaid(payer, key, tokenId, grossUSDC, reserveFeeUSDC, netUSDC, feeType);
    }

    function _referralFeeAmount(Config memory cfg, address payer, bytes32 key, uint256 protocolFeeUSDC)
        internal
        view
        returns (uint256)
    {
        if (protocolFeeUSDC == 0 || address(cfg.REFERRAL_MANAGER) == address(0)) return 0;
        address user = _effectiveUser(cfg, payer, key);
        if (user == address(0) || cfg.REFERRAL_MANAGER.referrers(user) == address(0)) return 0;

        uint16 referralShareBps = cfg.REFERRAL_MANAGER.referralShareBps();
        return referralShareBps == 0 ? 0 : FullMath.mulDiv(protocolFeeUSDC, referralShareBps, BPS);
    }

    function _payEarnedFeesFromCollectedTokens(
        Config memory cfg,
        address reserve,
        address botReceiver,
        address dex,
        address token0,
        address token1,
        address payer,
        bytes32 key,
        uint256 tokenId,
        uint256 fee0,
        uint256 fee1,
        uint16 protocolFeeBps,
        uint16 botFeeBps,
        uint256 slippageBps,
        FeeType feeType
    ) internal returns (
        uint256 protocolFeeUSDC,
        uint256 referralFeeUSDC,
        uint256 botFeeUSDC,
        uint256 remainingFee0,
        uint256 remainingFee1
    ) {
        remainingFee0 = fee0;
        remainingFee1 = fee1;

        uint256 splitFeeBps = uint256(protocolFeeBps) + uint256(botFeeBps);
        if (splitFeeBps == 0) return (0, 0, 0, remainingFee0, remainingFee1);
        if (protocolFeeBps > 0 && reserve == address(0)) revert ReserveNotSet();

        uint256 totalFeeBps = splitFeeBps > BPS ? BPS : splitFeeBps;
        (uint256 initialUSDCIn, uint256 expectedSellUSDC, uint256 sell0, uint256 sell1) =
            _earnedFeeSalePlan(cfg, dex, token0, token1, fee0, fee1, totalFeeBps);
        if (initialUSDCIn == 0) return (0, 0, 0, remainingFee0, remainingFee1);

        uint256 remainingLossUSDC =
            _lossBudgetUSDC(expectedSellUSDC, _protocolFeeSlippageBps(cfg, slippageBps));
        uint256 paidUSDC;
        (paidUSDC, remainingFee0, remainingFee1) =
            _sellEarnedFeeSlice(cfg, dex, token0, token1, fee0, fee1, sell0, sell1, remainingLossUSDC);

        if (paidUSDC == 0) return (0, 0, 0, remainingFee0, remainingFee1);

        protocolFeeUSDC = protocolFeeBps == 0 ? 0 : FullMath.mulDiv(paidUSDC, protocolFeeBps, splitFeeBps);
        botFeeUSDC = paidUSDC > protocolFeeUSDC ? paidUSDC - protocolFeeUSDC : 0;

        if (protocolFeeUSDC > 0) {
            referralFeeUSDC = _payProtocolFee(cfg, reserve, payer, key, tokenId, initialUSDCIn, protocolFeeUSDC, feeType);
            protocolFeeUSDC -= referralFeeUSDC;
        }

        if (botFeeUSDC > 0) {
            cfg.USDC.safeTransfer(botReceiver, botFeeUSDC);
            emit BotFeePaid(botReceiver, key, tokenId, botFeeUSDC, feeType);
        }
    }

    function _earnedFeeSalePlan(
        Config memory cfg,
        address dex,
        address token0,
        address token1,
        uint256 fee0,
        uint256 fee1,
        uint256 totalFeeBps
    ) internal view returns (uint256 initialUSDCIn, uint256 expectedSellUSDC, uint256 sell0, uint256 sell1) {
        uint256 val0 = _tokenValueUSDC(cfg, dex, token0, fee0);
        uint256 val1 = _tokenValueUSDC(cfg, dex, token1, fee1);
        initialUSDCIn = val0 + val1;

        sell0 = FullMath.mulDiv(fee0, totalFeeBps, BPS);
        sell1 = FullMath.mulDiv(fee1, totalFeeBps, BPS);

        if (token0 != address(cfg.USDC) && sell0 > 0 && fee0 > 0) {
            expectedSellUSDC += FullMath.mulDivRoundingUp(val0, sell0, fee0);
        }
        if (token1 != address(cfg.USDC) && sell1 > 0 && fee1 > 0) {
            expectedSellUSDC += FullMath.mulDivRoundingUp(val1, sell1, fee1);
        }
    }

    function _sellEarnedFeeSlice(
        Config memory cfg,
        address dex,
        address token0,
        address token1,
        uint256 fee0,
        uint256 fee1,
        uint256 sell0,
        uint256 sell1,
        uint256 remainingLossUSDC
    ) internal returns (uint256 paidUSDC, uint256 remainingFee0, uint256 remainingFee1) {
        remainingFee0 = fee0;
        remainingFee1 = fee1;

        if (sell0 > 0) {
            uint256 outUSDC = sell0;
            uint256 remainingLossUSDCOut = remainingLossUSDC;
            if (token0 != address(cfg.USDC)) {
                IERC20(token0).safeTransfer(dex, sell0);
                (outUSDC, remainingLossUSDCOut) = ICLDexAdapter(dex).swapExactInToUSDC(
                    token0,
                    sell0,
                    address(cfg.USDC),
                    address(this),
                    remainingLossUSDC
                );
            }
            paidUSDC += outUSDC;
            remainingFee0 = remainingFee0 > sell0 ? remainingFee0 - sell0 : 0;
            remainingLossUSDC = remainingLossUSDCOut;
        }

        if (sell1 > 0) {
            uint256 outUSDC = sell1;
            if (token1 != address(cfg.USDC)) {
                IERC20(token1).safeTransfer(dex, sell1);
                (outUSDC,) = ICLDexAdapter(dex).swapExactInToUSDC(
                    token1,
                    sell1,
                    address(cfg.USDC),
                    address(this),
                    remainingLossUSDC
                );
            }
            paidUSDC += outUSDC;
            remainingFee1 = remainingFee1 > sell1 ? remainingFee1 - sell1 : 0;
        }
    }

    function _addDust(Config memory cfg, bytes32 key, uint256 amount) internal {
        if (amount == 0) return;
        cfg.USDC.safeTransfer(address(cfg.CORE), amount);
        cfg.CORE.addDustToPosition(key, amount);
    }

    function _tokenValueUSDC(Config memory cfg, address dex, address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (token == address(cfg.USDC)) return amount;
        uint256 value = cfg.VALUATION.usdcValue(dex, token, amount);
        return value;
    }

    function _quotedPositionValue(Config memory cfg, bytes32 key, Position memory p)
        internal
        view
        returns (uint256 valueExcludingDust)
    {
        if (p.tokenId == 0 || p.dex == address(0)) {
            return 0;
        }

        (uint256 amt0, uint256 amt1, uint128 owed0, uint128 owed1) = cfg.CORE.spotAmounts(key);

        address token0 = p.token0;
        address token1 = p.token1;

        uint256 total0 = amt0 + uint256(owed0);
        uint256 total1 = amt1 + uint256(owed1);

        uint256 value0 = 0;
        if (total0 > 0) {
            value0 = ICLDexAdapter(p.dex).getExpectedOutUSDC(token0, total0, address(cfg.USDC));
        }

        uint256 value1 = 0;
        if (total1 > 0) {
            value1 = ICLDexAdapter(p.dex).getExpectedOutUSDC(token1, total1, address(cfg.USDC));
        }

        valueExcludingDust = value0 + value1;
    }

    function _effectiveUser(Config memory cfg, address owner, bytes32 key) internal view returns (address) {
        return owner == address(cfg.EZ_WRAPPER) ? cfg.EZ_WRAPPER.userForKey(key) : owner;
    }

    function _protocolFeeConfig(Config memory cfg) internal view returns (uint16 bps, address reserve) {
        bps = cfg.CORE.protocolFeeBps();
        reserve = cfg.CORE.protocolReserve();
        if (bps > 0 && reserve == address(0)) revert ReserveNotSet();
    }

    function _discountedProtocolFeeConfig(
        Config memory cfg,
        address wallet,
        uint16 extraDiscountBps
    ) internal view returns (uint16 bps, address reserve) {
        (bps, reserve) = _protocolFeeConfig(cfg);
        bps = _applyFeeDiscount(wallet, bps, extraDiscountBps);
    }

    function _applyFeeDiscount(address wallet, uint16 feeBps, uint16 extraDiscountBps) internal view returns (uint16) {
        if (feeBps == 0) return feeBps;
        uint16 discountBps = ICLManagerDiscounts(address(this)).discountedFeeWallets(wallet);
        if (extraDiscountBps != 0) {
            discountBps = discountBps + extraDiscountBps > BPS ? uint16(BPS) : discountBps + extraDiscountBps;
        }
        if (discountBps == 0) return feeBps;
        return feeBps - uint16(FullMath.mulDiv(feeBps, discountBps, BPS));
    }

    function _scaledFeeBps(uint16 feeBps, uint16 multiplier) internal pure returns (uint16) {
        uint256 scaled = uint256(feeBps) * multiplier;
        if (scaled > type(uint16).max) revert FeeTooHigh();
        return uint16(scaled);
    }

    function _lossBudgetUSDC(uint256 baseUSDC, uint256 slippageBps) internal pure returns (uint256 remainingLossUSDC) {
        if (baseUSDC == 0) return 0;
        if (slippageBps == 0) return 0;
        uint256 sl = slippageBps >= BPS ? BPS - 1 : slippageBps;
        return FullMath.mulDivRoundingUp(baseUSDC, sl, BPS);
    }

    function _protocolFeeSlippageBps(Config memory cfg, uint256 slippageBps) internal pure returns (uint256) {
        return slippageBps > cfg.maxProtocolFeeSlippageBps ? cfg.maxProtocolFeeSlippageBps : slippageBps;
    }

    function _requireOwnerOrBot(address owner, bool botAllowed, bool callerIsBot) internal view {
        if (owner == msg.sender) return;
        if (!callerIsBot || !botAllowed) revert NotOwner();
    }
}
