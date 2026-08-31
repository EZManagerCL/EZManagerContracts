// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {ICLDexAdapter, RebalanceParams, Position, PositionDetails, RegisterParams, ICLCore, IValuation, IRebalancePlanner, IEZWrapper, IReferralManager, INonfungiblePositionManager} from "./Interfaces.sol";
import {CLManagerUtils} from "./libraries/CLManagerUtils.sol";

/* ─────────────────────────── CLManager ─────────────────────────── */

contract CLManager is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    error UsdcDecimalsTooLow();
    error OwnershipRenounceDisabled();
    
    constructor(address core_, address owner_) Ownable(owner_) {
        if (core_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        CORE = ICLCore(core_);
        USDC = CORE.USDC();
        usdcDecimals = IERC20Metadata(address(USDC)).decimals();
        if (usdcDecimals < 3) revert UsdcDecimalsTooLow();
        // MINIMUM_OPEN_USDC defaults to $1 in token units.
        MINIMUM_OPEN_USDC = 10 ** uint256(usdcDecimals);

        VALUATION = CORE.VALUATION();
    }

    /* ───────────── Variables ───────────── */
    address public guardian;

    uint8 public usdcDecimals;

    uint256 public constant BPS = 10_000;

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
    IReferralManager public REFERRAL_MANAGER;
    IEZWrapper public EZ_WRAPPER;
    uint16 public botFeeMultiplierForEarnedFees = 20;
    uint16 public earnedFeesProtocolFeeBps = 1_000;
    uint16 public maxProtocolFeeSlippageBps = 1_500;
    mapping(address => uint16) public discountedFeeWallets;

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
        address referrer,
        uint256 referralFeeUSDC,
        uint256 dustAdded
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

    event CollateralAdded(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        uint256 depositedUSDC,
        uint256 addedUSDC,
        uint256 totalCollateralUSDC,
        uint256 protocolFeeUSDC,
        address referrer
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

    event PositionCopied(
        address indexed user,
        bytes32 indexed sourceKey,
        bytes32 indexed key,
        address sourceOwner,
        bool botAllowed
    );

    event PositionImported(
        address indexed user,
        bytes32 indexed key,
        uint256 indexed tokenId,
        address dex,
        address pool,
        address token0,
        address token1,
        uint256 importedUSDC,
        address referrer
    );

    event PlannerUpdated(address indexed planner);
    event ValuationUpdated(address indexed valuation);
    event GuardianUpdated(address indexed guardian);
    event EZWrapperUpdated(address indexed ezWrapper);
    event ReferralManagerUpdated(address indexed referralManager);
    event DiscountedWalletBpsUpdated(address indexed wallet, uint16 discountBps);
    event BotFeeMultiplierForEarnedFeesUpdated(uint16 multiplier);
    event EarnedFeesProtocolFeeBpsUpdated(uint16 feeBps);
    event MaxProtocolFeeSlippageBpsUpdated(uint16 slippageBps);
    event MinimumOpenUSDCUpdated(uint256 minimumOpenUSDC);
    event MaxBatchKeysUpdated(uint256 maxBatchKeys);

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
    error RangeUnchanged();
    error EmptyKeys();
    error ZeroAddress();
    error TickAlignmentError();
    error PoolNotInitialized();
    error NotEZWrapper();
    error InvalidReferrer();
    error FeeTooHigh();
    error AlreadySet();
    error ReferralManagerNotSet();

    /* ───────────── Internal Types ───────────── */

    enum FeeType {
        Open,
        Collect,
        CollateralAdd,
        ChangeRange,
        Exit,
        Compound,
        CollateralRemove
    }

    struct ReferralInfo {
        address referrer;
        uint16 shareBps;
    }

    /* ───────────── Initialization & Admin ───────────── */

    /// @notice Set the RebalancePlanner contract used for getting optimal rebalance plans.
    function setPlanner(address planner_) external onlyOwner {
        if (planner_ == address(0)) revert ZeroAddress();
        PLANNER = IRebalancePlanner(planner_);
        emit PlannerUpdated(planner_);
    }

    /// @notice Set the valuation contract used for token -> USDC pricing
    function setValuation(address valuation_) external onlyOwner {
        if (valuation_ == address(0)) revert ZeroAddress();
        VALUATION = IValuation(valuation_);
        emit ValuationUpdated(valuation_);
    }

    /// @notice Set the guardian address for quick pause/unpause.
    function setGuardian(address g) external onlyOwner {
        if (g == address(0)) revert ZeroAddress();
        guardian = g;
        emit GuardianUpdated(g);
    }

    function setEZWrapper(address ezWrapper_) external onlyOwner {
        if (ezWrapper_ == address(0)) revert ZeroAddress();
        if (address(EZ_WRAPPER) != address(0)) revert AlreadySet();
        EZ_WRAPPER = IEZWrapper(ezWrapper_);
        emit EZWrapperUpdated(ezWrapper_);
    }

    function setReferralManager(address referralManager_) external onlyOwner {
        if (referralManager_ == address(0)) revert ZeroAddress();
        REFERRAL_MANAGER = IReferralManager(referralManager_);
        emit ReferralManagerUpdated(referralManager_);
    }

    function setDiscountedWalletBps(address wallet, uint16 discountBps) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        if (discountBps > BPS) revert FeeTooHigh();
        discountedFeeWallets[wallet] = discountBps;
        emit DiscountedWalletBpsUpdated(wallet, discountBps);
    }

    function setBotFeeMultiplierForEarnedFees(uint16 multiplier) external onlyOwner {
        if (multiplier > 50) revert FeeTooHigh();
        botFeeMultiplierForEarnedFees = multiplier;
        emit BotFeeMultiplierForEarnedFeesUpdated(multiplier);
    }

    function setEarnedFeesProtocolFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > 2_000) revert FeeTooHigh();
        earnedFeesProtocolFeeBps = feeBps;
        emit EarnedFeesProtocolFeeBpsUpdated(feeBps);
    }

    function setMaxProtocolFeeSlippageBps(uint16 slippageBps) external onlyOwner {
        if (slippageBps >= BPS) revert FeeTooHigh();
        maxProtocolFeeSlippageBps = slippageBps;
        emit MaxProtocolFeeSlippageBpsUpdated(slippageBps);
    }

    /// @notice Set the minimum USDC (in token units) required to open a position
    function setMinimumOpenUSDC(uint256 min_) external onlyOwner {
        if (min_ == 0) revert InvalidParams();
        MINIMUM_OPEN_USDC = min_;
        emit MinimumOpenUSDCUpdated(min_);
    }

    /// @notice Set the maximum number of keys that can be processed in batch operations
    function setMaxBatchKeys(uint256 maxKeys_) external onlyOwner {
        if (maxKeys_ == 0) revert InvalidParams();
        MAX_BATCH_KEYS = maxKeys_;
        emit MaxBatchKeysUpdated(maxKeys_);
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenounceDisabled();
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

    function _utilsConfig() internal view returns (CLManagerUtils.Config memory cfg) {
        cfg = CLManagerUtils.Config({
            CORE: CORE,
            USDC: USDC,
            VALUATION: VALUATION,
            PLANNER: PLANNER,
            MAX_BATCH_KEYS: MAX_BATCH_KEYS,
            MINIMUM_OPEN_USDC: MINIMUM_OPEN_USDC,
            botFeeMultiplierForEarnedFees: botFeeMultiplierForEarnedFees,
            earnedFeesProtocolFeeBps: earnedFeesProtocolFeeBps,
            maxProtocolFeeSlippageBps: maxProtocolFeeSlippageBps,
            EZ_WRAPPER: EZ_WRAPPER,
            REFERRAL_MANAGER: REFERRAL_MANAGER
        });
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
        bool botAllowed,
        uint256 slippageBps
    ) external nonReentrant whenNotPaused returns (bytes32 key) {
        return _openPosition(
            msg.sender,
            msg.sender,
            pool,
            tickLower,
            tickUpper,
            usdcAmount,
            botAllowed,
            slippageBps,
            _resolveDepositReferrer(msg.sender, address(0))
        );
    }

    function openPosition(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bool botAllowed,
        uint256 slippageBps,
        address referrer
    ) external nonReentrant whenNotPaused returns (bytes32 key) {
        return _openPosition(
            msg.sender,
            msg.sender,
            pool,
            tickLower,
            tickUpper,
            usdcAmount,
            botAllowed,
            slippageBps,
            _resolveDepositReferrer(msg.sender, referrer)
        );
    }

    function openPositionEz(
        address user,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bool botAllowed,
        uint256 slippageBps,
        address referrer
    ) external nonReentrant whenNotPaused returns (bytes32 key) {
        if (msg.sender != address(EZ_WRAPPER)) revert NotEZWrapper();
        return _openPosition(
            msg.sender,
            user,
            pool,
            tickLower,
            tickUpper,
            usdcAmount,
            botAllowed,
            slippageBps,
            _resolveDepositReferrer(user, referrer)
        );
    }

    function copyPosition(
        bytes32 sourceKey,
        uint256 usdcAmount,
        bool botAllowed,
        uint256 slippageBps
    ) external nonReentrant whenNotPaused returns (bytes32 key) {
        Position memory source = CORE.getPosition(sourceKey);
        if (source.owner == address(0) || source.tokenId == 0) revert PositionNotFound();

        address sourceOwner = source.owner;
        if (sourceOwner == address(EZ_WRAPPER)) {
            sourceOwner = EZ_WRAPPER.userForKey(sourceKey);
        }
        if (sourceOwner == msg.sender) revert InvalidReferrer();

        if (address(REFERRAL_MANAGER) == address(0)) revert ReferralManagerNotSet();
        REFERRAL_MANAGER.storeReferrer(msg.sender, sourceOwner);
        key = _openPosition(
            msg.sender,
            msg.sender,
            source.pool,
            source.tickLower,
            source.tickUpper,
            usdcAmount,
            botAllowed,
            slippageBps,
            ReferralInfo({referrer: sourceOwner, shareBps: REFERRAL_MANAGER.copyReferralShareBps()})
        );
        emit PositionCopied(msg.sender, sourceKey, key, sourceOwner, botAllowed);
    }

    function importNft(uint256 tokenId, address pool, bool botAllowed)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 key)
    {
        return _importNft(tokenId, pool, botAllowed, address(0));
    }

    function importNft(uint256 tokenId, address pool, bool botAllowed, address referrer)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 key)
    {
        return _importNft(tokenId, pool, botAllowed, referrer);
    }

    function _importNft(uint256 tokenId, address pool, bool botAllowed, address referrer) internal returns (bytes32 key) {
        if (tokenId == 0 || pool == address(0)) revert InvalidParams();
        address resolvedReferrer = _storeReferrer(msg.sender, referrer);

        (address dex, address token0, address token1, uint24 fee, int24 tickSpacing) = _resolveDexForPool(pool);
        _requirePoolInitialized(pool);
        ICLDexAdapter adapter = ICLDexAdapter(dex);
        address npm = adapter.getNPM();
        if (npm == address(0)) revert InvalidParams();
        if (INonfungiblePositionManager(npm).ownerOf(tokenId) != msg.sender) revert NotOwner();

        (,, address nftToken0, address nftToken1, uint24 nftFeeOrTickSpacing, int24 tickLower, int24 tickUpper,,,,,) =
            INonfungiblePositionManager(npm).positions(tokenId);
        if (token0 != nftToken0 || token1 != nftToken1) revert InvalidParams();
        if (adapter.isAerodrome()) {
            int24 nftTickSpacing = int24(nftFeeOrTickSpacing);
            if (nftTickSpacing <= 0 || nftTickSpacing != tickSpacing) revert InvalidParams();
        } else if (nftFeeOrTickSpacing == 0 || nftFeeOrTickSpacing != fee) {
            revert InvalidParams();
        }

        INonfungiblePositionManager(npm).safeTransferFrom(msg.sender, address(CORE), tokenId);

        key = CORE.registerPosition(RegisterParams({
            owner: msg.sender,
            tokenId: tokenId,
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            totalDepositedUSDC: 0,
            dex: dex
        }));

        if (botAllowed) CORE.setBotAllowedForPosition(key, true);
        uint256 importedUSDC = CORE.positionValueUSDCSingle(key);
        if (importedUSDC < MINIMUM_OPEN_USDC) revert PositionTooSmall();
        if (importedUSDC > 0) {
            CORE.adjustTotalDeposited(key, int256(importedUSDC));
        }

        emit PositionImported(
            msg.sender,
            key,
            tokenId,
            dex,
            pool,
            token0,
            token1,
            importedUSDC,
            resolvedReferrer
        );
    }

    function _openPosition(
        address owner_,
        address effectiveUser,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bool botAllowed,
        uint256 slippageBps,
        ReferralInfo memory feeReferrer
    ) internal returns (bytes32 key) {
        slippageBps = slippageBps >= BPS ? BPS - 1 : slippageBps;
        if (usdcAmount == 0) revert InvalidParams();
        if (pool == address(0)) revert InvalidParams();

        // Don't allow tiny positions to avoid DOS on backend.
        if (usdcAmount < MINIMUM_OPEN_USDC) revert PositionTooSmall();

        (address dex, address token0, address token1, uint24 fee, int24 tickSpacing) = _resolveDexForPool(pool);
        ICLDexAdapter adapter = ICLDexAdapter(dex);

        // Basic validation: ticks must align with spacing and form a valid range.
        if ((tickLower % tickSpacing) != 0 || (tickUpper % tickSpacing) != 0) revert TickAlignmentError();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower < -887272 || tickUpper > 887272) revert InvalidTickRange();

        _requirePoolInitialized(pool);

        (uint16 protocolFeeBps_, address reserve) = _discountedProtocolFeeConfig(owner_, 0);

        // Pull gross USDC from the user.
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Protocol fee is taken from the deposit but does not reduce totalDepositedUSDC
        // since totalDepositedUSDC tracks the full gross external USDC the owner contributed.
        (uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 seedNet) =
            _depositFees(usdcAmount, protocolFeeBps_, feeReferrer);

        uint256 reserveFeeUSDC = protocolFeeUSDC - referralFeeUSDC;
        if (reserveFeeUSDC > 0) {
            USDC.safeTransfer(reserve, reserveFeeUSDC);
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
        (uint256 tokenId, , , uint256 leftoverUSDC, ) = ICLDexAdapter(dex).mintPosition(
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

        RegisterParams memory params = RegisterParams({
            owner: owner_,
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
        if (botAllowed) CORE.setBotAllowedForPosition(key, true);

        // Track adapter leftover as per-position dust in CORE.
        _addDust(key, leftoverUSDC);

        if (protocolFeeUSDC > 0) {
            emit ProtocolFeePaid(
                owner_,
                key,
                tokenId,
                usdcAmount,
                reserveFeeUSDC,
                seedNet,
                FeeType.Open
            );
        }
        if (referralFeeUSDC > 0) {
            _payReferralFee(feeReferrer.referrer, effectiveUser, key, usdcAmount, referralFeeUSDC, seedNet, FeeType.Open);
        }

        emit PositionOpened(
            owner_,
            key,
            tokenId,
            dex,
            pool,
            token0,
            token1,
            usdcAmount,
            reserveFeeUSDC,
            feeReferrer.referrer,
            referralFeeUSDC,
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
        CLManagerUtils.exitPosition(_utilsConfig(), keys, slippageBps);
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
        CLManagerUtils.returnNft(_utilsConfig(), keys, paused(), owner());
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
        return CLManagerUtils.collectFeesToUSDC(_utilsConfig(), keys, slippageBps);
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
        return CLManagerUtils.compoundFees(_utilsConfig(), keys, slippageBps);
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

        address effectiveUser = p.owner == address(EZ_WRAPPER) ? EZ_WRAPPER.userForKey(key) : p.owner;
        (uint16 protocolFeeBps_, address reserve) = _discountedProtocolFeeConfig(p.owner, 0);
        if (address(REFERRAL_MANAGER) == address(0)) revert ReferralManagerNotSet();
        ReferralInfo memory resolvedReferrer;
        resolvedReferrer.referrer = REFERRAL_MANAGER.storeReferrer(effectiveUser, address(0));

        uint256 add = usdcAmount;
        (uint256 protocolFeeUSDC,, uint256 net) =
            _depositFees(add, protocolFeeBps_, resolvedReferrer);

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

        (, , uint256 leftoverAdd, ) = ICLDexAdapter(p.dex).addLiquidity(
            abi.encode(p.tokenId),
            address(USDC),
            amount0In,
            amount1In,
            plan,
            remainingLossUSDCOut
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

        emit CollateralAdded(
            p.owner,
            key,
            p.tokenId,
            depositedUSDC,
            addedUSDC,
            positionValueAfter,
            protocolFeeUSDC,
            resolvedReferrer.referrer
        );

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
        CLManagerUtils.removeCollateral(_utilsConfig(), key, withdrawUSDC, slippageBps);
    }

    /**
     * @notice Change the tick range of an existing position by fully unwinding and re-minting.
     * @dev Rebalances charge protocol fees only on pending fees moved into the new range; bots additionally pay bot fee to caller bot.
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
        CLManagerUtils.changeRange(_utilsConfig(), key, newTickLower, newTickUpper, slippageBps);
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
     * @dev Decrements `totalDepositedUSDC` by the withdrawn dust amount, capped at current deposited accounting.
     */
    function withdrawDust(bytes32 key) external nonReentrant onlyKeyOwner(key) whenNotPaused {
        Position memory p = CORE.getPosition(key);

        // Withdraw dust from CORE; returns amount of USDC transferred to manager
        uint256 dust = CORE.withdrawDustForPosition(key, address(this), type(uint256).max);
        if (dust == 0) revert ZeroAmount();

        uint256 depositedDebit = dust < p.totalDepositedUSDC ? dust : p.totalDepositedUSDC;

        // Decrease totalDepositedUSDC by the deposited amount represented by the withdrawal.
        if (depositedDebit > 0) {
            CORE.adjustTotalDeposited(key, -int256(depositedDebit));
        }

        // Transfer USDC to the position owner
        USDC.safeTransfer(p.owner, dust);
    }

    /* ───────────── Internal Helpers ───────────── */

    function _addDust(bytes32 key, uint256 amount) internal {
        if (amount == 0) return;
        USDC.safeTransfer(address(CORE), amount);
        CORE.addDustToPosition(key, amount);
    }

    function _corePositionValue(bytes32 key) internal view returns (uint256) {
        return CORE.positionValueUSDCSingle(key);
    }

    function _resolveDexForPool(address pool)
        internal
        view
        returns (address dex, address token0, address token1, uint24 fee, int24 tickSpacing)
    {
        address[] memory dexes = CORE.listAllowedDexes();
        for (uint256 i = 0; i < dexes.length; ++i) {
            address tryDex = dexes[i];
            if (tryDex == address(0)) continue;
            try ICLDexAdapter(tryDex).validateAndGetPoolParams(pool) returns (address t0, address t1, uint24 f, int24 ts) {
                dex = tryDex;
                token0 = t0;
                token1 = t1;
                fee = f;
                tickSpacing = ts;
                break;
            } catch {}
        }
        if (dex == address(0)) revert DexNotAllowed();
        if (!CORE.isPoolAllowed(pool)) revert PoolNotAllowed();
        if (CORE.isPoolDeprecated(pool)) revert PoolDeprecated();
    }

    function _requirePoolInitialized(address pool) internal view {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || data.length < 32) revert PoolNotInitialized();
        (uint256 w0) = abi.decode(data, (uint256));
        if (uint160(w0) == 0) revert PoolNotInitialized();
    }

    function _discountedProtocolFeeConfig(address wallet, uint16 extraDiscountBps)
        internal
        view
        returns (uint16 bps, address reserve)
    {
        bps = CORE.protocolFeeBps();
        reserve = CORE.protocolReserve();
        if (bps > 0 && reserve == address(0)) revert ReserveNotSet();
        uint16 discountBps = discountedFeeWallets[wallet];
        if (extraDiscountBps != 0) {
            discountBps = discountBps + extraDiscountBps > BPS ? uint16(BPS) : discountBps + extraDiscountBps;
        }
        if (discountBps != 0) {
            bps = bps - uint16(FullMath.mulDiv(bps, discountBps, BPS));
        }
    }

    function _protocolFeeAmount(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return bps == 0 ? 0 : FullMath.mulDiv(amount, bps, BPS);
    }

    function _storeReferrer(address user, address referrer) internal returns (address resolvedReferrer) {
        if (address(REFERRAL_MANAGER) == address(0)) revert ReferralManagerNotSet();
        resolvedReferrer = REFERRAL_MANAGER.storeReferrer(user, referrer);
    }

    function _resolveDepositReferrer(address user, address referrer)
        internal
        returns (ReferralInfo memory info)
    {
        if (address(REFERRAL_MANAGER) == address(0)) revert ReferralManagerNotSet();
        info.referrer = REFERRAL_MANAGER.storeReferrer(user, referrer);
    }

    function _depositFees(uint256 amount, uint16 protocolFeeBps_, ReferralInfo memory referral)
        internal
        pure
        returns (uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 netUSDC)
    {
        uint256 totalFeeUSDC = _protocolFeeAmount(amount, protocolFeeBps_);
        referralFeeUSDC =
            referral.referrer == address(0) ? 0 : _protocolFeeAmount(totalFeeUSDC, referral.shareBps);
        protocolFeeUSDC = totalFeeUSDC;
        netUSDC = amount - totalFeeUSDC;
    }

    function _payReferralFee(
        address referrer,
        address user,
        bytes32 key,
        uint256 grossUSDC,
        uint256 referralFeeUSDC,
        uint256 netUSDC,
        FeeType feeType
    ) internal {
        if (referralFeeUSDC > 0) {
            USDC.safeTransfer(address(REFERRAL_MANAGER), referralFeeUSDC);
        }
        REFERRAL_MANAGER.creditReferralFee(referrer, user, key, grossUSDC, referralFeeUSDC, netUSDC, uint8(feeType));
        emit ReferralFeePaid(referrer, user, key, grossUSDC, referralFeeUSDC, netUSDC, feeType);
    }

    function _lossBudgetUSDC(uint256 baseUSDC, uint256 slippageBps) internal pure returns (uint256 remainingLossUSDC) {
        if (baseUSDC == 0) return 0;
        if (slippageBps == 0) return 0;
        uint256 sl = slippageBps >= BPS ? BPS - 1 : slippageBps;
        return FullMath.mulDivRoundingUp(baseUSDC, sl, BPS);
    }

}
