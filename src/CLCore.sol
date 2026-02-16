// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {ICLDexAdapter, RebalanceParams, Position, RegisterParams, PositionValueResult, PendingFeesResult, PositionDetails, ICLCore, IValuation, ICLPool, IAerodromeFactory, IUniswapV3Factory, IUniswapV3Pool, ISlipstreamPoolState, INonfungiblePositionManager} from "./Interfaces.sol";

/**
 * @title CLCore
 * @notice Canonical state + accounting for concentrated liquidity positions.
 *         This contract:
 *           - Tracks per-position metadata (ticks, fee tier, dex).
 *           - Tracks principal (`totalDepositedUSDC`) and tracked USDC dust (`dustUSDC`).
 *           - Computes canonical USDC value for each position.
 *           - Provides fee accounting for Uniswap V3 and Aerodrome Slipstream pools.
 *
 *         All owner-facing accounting rules are documented in ACCOUNTING.md.
 *         Off-chain systems should treat `positionValueUSDC(...)` and `positions(key)`
 *         as the single source of truth.
 */
contract CLCore is Ownable, IERC721Receiver, Pausable, ReentrancyGuard, ICLCore {
    using SafeERC20 for IERC20;

    constructor(address usdc_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        USDC = IERC20(usdc_);
        // Default protocol + bot fee configuration (can be changed by owner).
        protocolFeeBps = 40; // 0.4%
        botFeeBps = 20;      // 0.2% (on top of protocol fee if bot is caller)
    }

    /* ─────────────────────────────── Constants ────────────────────────────── */

    uint256 public constant BPS = 10_000;

    /* ─────────────────────────────── Storage ──────────────────────────────── */

    IERC20 public USDC;
    IValuation public VALUATION;

    address public protocolReserve;
    uint16 public protocolFeeBps;
    // Bot fee basis points used by CLManager for bot compensation.
    uint16 public botFeeBps;

    // Total tracked USDC dust across all positions.
    uint256 public totalDustUSDC;

    // Single manager address allowed to mutate core state.
    address public manager;
    // Guardian address allowed to pause/unpause contracts (multisig via timelock proposer)
    address public guardian;

    // Dex adapters that can be referenced from positions.
    mapping(address => bool) public allowedDexes;
    // Enumerable list of allowed dex adapters for efficient listing.
    address[] private allowedDexList;
    mapping(address => uint256) private allowedDexIndexPlus1;

    // Pools explicitly tracked by core and their lifecycle status.
    enum PoolStatus { NotAllowed, Allowed, Deprecated }
    mapping(address => PoolStatus) public allowedPools;
    address[] private allowedPoolList;
    mapping(address => uint256) private allowedPoolIndexPlus1;

    // Automation bots allowed for bot-aware flows in CLManager.
    mapping(address => bool) public allowedBots;

    // Addresses exempt from protocol and bot fees.
    mapping(address => bool) public zeroFeeWallets;

    // Bridge tokens available for routing. Managed by owner, max length 3.
    address[] private _bridgeTokens;

    // Position registry
    mapping(bytes32 => Position) public positions;

    // Monotonic counter used to generate globally-unique position keys.
    uint256 public positionCounter;

    // Per-user index of keys for enumeration.
    mapping(address => bytes32[]) private _userPositionKeys;
    mapping(bytes32 => uint256) private _userPositionIndexPlus1;

    /* ─────────────────────────────── Errors ───────────────────────────────── */

    error NotManager();
    error NotGuardian();
    error PositionAlreadyExists();
    error PositionNotFound();
    error NpmLookupFailed();
    error InvalidRegisterParams();
    error InvalidTokenId();
    error InvalidTickSpacing();
    error ApproveFailed();
    error RevokeFailed();
    error InvalidTickRange();
    error TickAlignmentError();
    error InvalidFee();
    error InsufficientCoreBalance();
    error ReserveNotSet();
    error ArithmeticOverflow();
    error PoolNotFound();
    error PoolNotAllowed();
    error PoolDeprecated();
    error FeeTooHigh();
    error ZeroAddress();
    error InvalidBot();
    error BridgeTokensTooMany();
    error BridgeTokenDuplicate();
    error BridgeTokenIsUSDC();
    error DustRemaining();

    /* ─────────────────────────────── Events ───────────────────────────────── */

    event PositionRegistered(address indexed owner, bytes32 indexed key, uint256 tokenId);
    event PositionRemoved(address indexed owner, bytes32 indexed key, uint256 tokenId);
    event PositionUpdated(bytes32 indexed key, uint256 oldTokenId, uint256 newTokenId, int24 oldLower, int24 oldUpper);

    event ManagerUpdated(address indexed manager);
    event AllowedDexUpdated(address indexed dex, bool allowed);
    event AllowedBotUpdated(address indexed bot, bool allowed);
    event PoolStatusUpdated(address indexed pool, PoolStatus status);

    event ProtocolFeeUpdated(uint16 oldBps, uint16 newBps);
    event BotFeeUpdated(uint16 oldBps, uint16 newBps);

    event DustAdded(address indexed owner, bytes32 indexed key, uint256 amount, uint256 timestamp);
    event DustRefunded(address indexed owner, bytes32 indexed key, uint256 amount, uint256 timestamp);
    event TotalDepositedUpdated(bytes32 indexed key, int256 delta, uint256 currentValue, uint256 timestamp);
    event BotAllowedForPositionUpdated(bytes32 indexed key, bool allowed);
    event BridgeTokensUpdated(address[] bridges);
    event ZeroFeeWalletUpdated(address indexed wallet, bool isZeroFee);

    /* ─────────────────────────────── Modifiers ────────────────────────────── */

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /* ───────────────────────────── Admin Controls ─────────────────────────── */

    /**
     * @notice Owner-only setter to configure the external Valuation contract.
     * @dev Allows changing VALUATION after initialization (used in upgrades/deploy flows).
     */
    function setValuation(address valuation) external onlyOwner {
        if (valuation == address(0)) revert ZeroAddress();
        VALUATION = IValuation(valuation);
    }

    /**
     * @notice Owner-only setter for the protocol reserve address.
     * @dev Allows deploying the ProtocolReserve proxy before wiring into CORE.
     */
    function setProtocolReserve(address reserve) external onlyOwner {
        if (reserve == address(0)) revert ZeroAddress();
        protocolReserve = reserve;
    }

    /// @notice Owner-only setter for the manager address.
    function setManager(address mgr) external onlyOwner {
        if (mgr == address(0)) revert ZeroAddress();
        manager = mgr;
        emit ManagerUpdated(mgr);
    }

    /// @notice Owner-only setter for the guardian address.
    function setGuardian(address g) external onlyOwner {
        if (g == address(0)) revert ZeroAddress();
        guardian = g;
    }

    /**
     * @notice Approve a DEX adapter address and set NPM approval for all.
     * @dev Owner-only. Sets approval for all on the associated NPM and marks the adapter allowed.
     */
    function addAllowedDex(address dex) external onlyOwner {
        if (dex == address(0)) revert ZeroAddress();
        address npm = address(0);
        try ICLDexAdapter(dex).getNPM() returns (address n) {
            npm = n;
        } catch {
            revert NpmLookupFailed();
        }
        try INonfungiblePositionManager(npm).setApprovalForAll(dex, true) {
            // mark allowed and add to enumeration if not present
            allowedDexes[dex] = true;
            if (allowedDexIndexPlus1[dex] == 0) {
                allowedDexList.push(dex);
                allowedDexIndexPlus1[dex] = allowedDexList.length; // 1-based
            }
            emit AllowedDexUpdated(dex, true);
        } catch {
            revert ApproveFailed();
        }
    }

    /**
     * @notice Revoke a DEX adapter address and clear NPM approval for all.
     * @dev Owner-only. Revokes approval for all on the associated NPM and unmarks the adapter.
     */
    function removeAllowedDex(address dex) external onlyOwner {
        if (dex == address(0)) revert ZeroAddress();
        address npm = address(0);
        try ICLDexAdapter(dex).getNPM() returns (address n) {
            npm = n;
        } catch {
            revert NpmLookupFailed();
        }
        try INonfungiblePositionManager(npm).setApprovalForAll(dex, false) {
            allowedDexes[dex] = false;
            // remove from enumeration if present
            uint256 idxPlus1 = allowedDexIndexPlus1[dex];
            if (idxPlus1 != 0) {
                uint256 idx = idxPlus1 - 1;
                uint256 lastIndex = allowedDexList.length - 1;
                if (idx != lastIndex) {
                    address lastDex = allowedDexList[lastIndex];
                    allowedDexList[idx] = lastDex;
                    allowedDexIndexPlus1[lastDex] = idx + 1;
                }
                allowedDexList.pop();
                delete allowedDexIndexPlus1[dex];
            }
            emit AllowedDexUpdated(dex, false);
        } catch {
            revert RevokeFailed();
        }
    }

    /**
     * @notice Return all allowed dex adapter addresses.
     * @dev Gas-efficient view that returns the stored enumeration.
     */
    function listAllowedDexes() external view returns (address[] memory) {
        return allowedDexList;
    }

    function addBot(address bot) external onlyOwner {
        if (bot == address(0)) revert InvalidBot();
        allowedBots[bot] = true;
        emit AllowedBotUpdated(bot, true);
    }

    function removeBot(address bot) external onlyOwner {
        if (bot == address(0)) revert InvalidBot();
        allowedBots[bot] = false;
        emit AllowedBotUpdated(bot, false);
    }

    /// @notice Set pool lifecycle status.
    function setPoolStatus(address pool, PoolStatus status) public onlyOwner {
        if (pool == address(0)) revert ZeroAddress();

        // If setting to NotAllowed, clear tracking and remove from enumeration if present.
        if (status == PoolStatus.NotAllowed) {
            allowedPools[pool] = PoolStatus.NotAllowed;

            uint256 idxPlus1 = allowedPoolIndexPlus1[pool];
            if (idxPlus1 != 0) {
                // remove from allowedPoolList by swapping with last and popping
                uint256 idx = idxPlus1 - 1;
                uint256 lastIndex = allowedPoolList.length - 1;
                if (idx != lastIndex) {
                    address lastPool = allowedPoolList[lastIndex];
                    allowedPoolList[idx] = lastPool;
                    allowedPoolIndexPlus1[lastPool] = idx + 1;
                }
                allowedPoolList.pop();
                delete allowedPoolIndexPlus1[pool];
            }

            emit PoolStatusUpdated(pool, PoolStatus.NotAllowed);
            return;
        }

        // For Allowed or Deprecated, ensure it's in the enumeration list.
        if (allowedPoolIndexPlus1[pool] == 0) {
            allowedPoolList.push(pool);
            allowedPoolIndexPlus1[pool] = allowedPoolList.length; // 1-based
        }

        allowedPools[pool] = status;
        emit PoolStatusUpdated(pool, status);
    }


    function setBridgeTokens(address[] calldata bridges) external onlyOwner {
        if (bridges.length > 3) revert BridgeTokensTooMany();

        delete _bridgeTokens;

        for (uint256 i = 0; i < bridges.length; ++i) {
            address bridge = bridges[i];
            if (bridge == address(0)) revert ZeroAddress();
            if (bridge == address(USDC)) revert BridgeTokenIsUSDC();

            for (uint256 j = 0; j < _bridgeTokens.length; ++j) {
                if (_bridgeTokens[j] == bridge) revert BridgeTokenDuplicate();
            }

            _bridgeTokens.push(bridge);
        }

        address[] memory emitted = new address[](_bridgeTokens.length);
        for (uint256 k = 0; k < _bridgeTokens.length; ++k) {
            emitted[k] = _bridgeTokens[k];
        }

        emit BridgeTokensUpdated(emitted);
    }

    function setZeroFeeWallet(address wallet, bool isZeroFee) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        zeroFeeWallets[wallet] = isZeroFee;
        emit ZeroFeeWalletUpdated(wallet, isZeroFee);
    }

    function setProtocolFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > 100) revert FeeTooHigh(); // Max 1%
        uint16 old = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeUpdated(old, newBps);
    }

    function setBotFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > 100) revert FeeTooHigh(); // Max 1%
        uint16 old = botFeeBps;
        botFeeBps = newBps;
        emit BotFeeUpdated(old, newBps);
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    /* ─────────────────────────── Position Registry ────────────────────────── */

    /**
     * @notice Register a newly minted LP NFT as a tracked position.
     * @dev Manager-only; see ACCOUNTING.md for semantics of totalDepositedUSDC.
     */
    function registerPosition(RegisterParams calldata params) external nonReentrant onlyManager whenNotPaused returns (bytes32 key) {
        if (
            params.owner == address(0) ||
            params.tokenId == 0 ||
            params.token0 == address(0) ||
            params.token1 == address(0) ||
            !allowedDexes[params.dex]
        ) {
            revert InvalidRegisterParams();
        }

        // Basic tick validations: ensure tickSpacing positive, ordered range, and alignment.
        if (params.tickSpacing <= 0) revert InvalidTickSpacing();
        if (params.tickLower >= params.tickUpper) revert InvalidTickRange();
        if ((params.tickLower % params.tickSpacing) != 0 || (params.tickUpper % params.tickSpacing) != 0) revert TickAlignmentError();
        if (params.tickLower < -887272 || params.tickUpper > 887272) revert InvalidTickRange();

        // Enforce pool allowlist to prevent registering positions that would later revert in core flows.
        address poolAddr = _pool(params.dex, params.token0, params.token1, params.fee, params.tickSpacing);

        // Ensure CORE actually holds the NFT being registered.
        address npm = ICLDexAdapter(params.dex).getNPM();
        try INonfungiblePositionManager(npm).ownerOf(params.tokenId) returns (address ownerOfToken) {
            if (ownerOfToken != address(this)) revert InvalidTokenId();
        } catch {
            revert InvalidTokenId();
        }

        key = _nextKey();
        if (positions[key].owner != address(0)) revert PositionAlreadyExists();

        positions[key] = Position({
            owner: params.owner,
            tokenId: params.tokenId,
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            totalDepositedUSDC: params.totalDepositedUSDC,
            dustUSDC: 0,
            botAllowed: false,
            openedAt: uint48(block.timestamp),
            dex: params.dex,
            pool: poolAddr
        });

        _registerPosition(params.owner, key);
        emit PositionRegistered(params.owner, key, params.tokenId);
    }

    /**
     * @notice Deregister a position. Called by CLManager during exit.
     */
    function deregisterPosition(bytes32 key) external nonReentrant onlyManager whenNotPaused returns (Position memory p) {
        p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();

        // Only allow deregister if all dust has been withdrawn for a position.
        if (p.dustUSDC > 0) revert DustRemaining();

        delete positions[key];
        _deregisterPosition(p.owner, key);
        emit PositionRemoved(p.owner, key, p.tokenId);
    }

    /**
     * @notice Add tracked dust USDC to a position.
     * @dev Manager-only; expects USDC to have been transferred to CORE beforehand (push model).
     */
    function addDustToPosition(bytes32 key, uint256 amount) external nonReentrant onlyManager whenNotPaused {
        if (amount == 0) return;
        Position storage p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();

        // In the push model the manager must transfer USDC to CORE before calling.
        // Verify CORE currently holds at least the previously tracked total dust
        // plus the new amount. This prevents double-counting when multiple
        // positions track dust simultaneously.
        uint256 coreBal = USDC.balanceOf(address(this));
        if (coreBal < totalDustUSDC + amount) revert InsufficientCoreBalance();

        p.dustUSDC = p.dustUSDC + amount;
        // Update aggregate tracker.
        totalDustUSDC = totalDustUSDC + amount;
        emit DustAdded(p.owner, key, amount, block.timestamp);
    }

    /**
     * @notice Withdraw tracked dust USDC for a position.
     * @dev Manager-only; used during exitPosition() before deregistration.
     */
    function withdrawDustForPosition(bytes32 key, address to, uint256 amount)
        external
        nonReentrant
        onlyManager
        whenNotPaused
        returns (uint256)
    {
        Position storage p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();

        if (amount == 0) return 0;

        uint256 available = p.dustUSDC;
        if (available == 0) return 0;

        uint256 withdrawal = amount > available ? available : amount;

        p.dustUSDC = available - withdrawal;

        // Decrease aggregate tracker before transfer to maintain consistency.
        if (totalDustUSDC <= withdrawal) {
            totalDustUSDC = 0;
        } else {
            totalDustUSDC = totalDustUSDC - withdrawal;
        }
        USDC.safeTransfer(to, withdrawal);
        emit DustRefunded(p.owner, key, withdrawal, block.timestamp);
        return withdrawal;
    }

    /**
     * @notice Return a tracked position's NFT (and any tracked dust) to the given address and deregister it.
     * @dev Manager-only.
     *      This function:
     *        - Refunds all tracked dustUSDC to position owner.
     *        - Transfers the LP NFT from CORE to position owner via the appropriate NPM.
     *        - Removes the position from the registry and user index.
     *      Available even when protocol is paused so users, or in emergencies, 
     *      the protocol owner can send positions out of the system to position owner.
     */
    function returnPosition(bytes32 key)
        external
        nonReentrant
        onlyManager
    {
        Position storage p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();

        // 1. Refund all tracked dust to the position owner.
        uint256 dust = p.dustUSDC;
        if (dust > 0) {
            p.dustUSDC = 0;

            if (totalDustUSDC <= dust) {
                totalDustUSDC = 0;
            } else {
                totalDustUSDC = totalDustUSDC - dust;
            }

            USDC.safeTransfer(p.owner, dust);
            emit DustRefunded(p.owner, key, dust, block.timestamp);
        }

        // 2. Transfer the NFT from CORE to the position owner using the adapter's NPM.
        address npm = ICLDexAdapter(p.dex).getNPM();
        INonfungiblePositionManager(npm).safeTransferFrom(address(this), p.owner, p.tokenId);

        // 3. Remove the position from registry and per-user index.
        uint256 tokenId = p.tokenId;
        address owner_ = p.owner;

        delete positions[key];
        _deregisterPosition(owner_, key);
        emit PositionRemoved(owner_, key, tokenId);
    }

    /**
     * @notice Update NFT id and tick range metadata for a position (e.g., after changeRange).
     * @dev Manager-only. Position must exist.
     */
    function updateTokenMetadata(bytes32 key, uint256 newTokenId, int24 newTickLower, int24 newTickUpper)
        external
        nonReentrant
        onlyManager
        whenNotPaused
    {
        if (newTokenId == 0) revert InvalidTokenId();

        Position storage p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();
        if (newTickLower >= newTickUpper) revert InvalidTickRange();
        if ((newTickLower % p.tickSpacing) != 0 || (newTickUpper % p.tickSpacing) != 0) revert TickAlignmentError();
        if (newTickLower < -887272 || newTickUpper > 887272) revert InvalidTickRange();

        uint256 oldId = p.tokenId;
        int24 oldLower = p.tickLower;
        int24 oldUpper = p.tickUpper;

        p.tokenId = newTokenId;
        p.tickLower = newTickLower;
        p.tickUpper = newTickUpper;

        emit PositionUpdated(key, oldId, newTokenId, oldLower, oldUpper);
    }

    /**
     * @notice Adjust `totalDepositedUSDC` by a signed delta.
     * @dev Manager-only; used by CLManager for add/remove collateral and withdrawDust.
     */
    function adjustTotalDeposited(bytes32 key, int256 usdcDelta) external nonReentrant onlyManager whenNotPaused {
        if (usdcDelta == 0) return;
        if (usdcDelta == type(int256).min) revert ArithmeticOverflow();

        Position storage p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();

        if (usdcDelta > 0) {
            uint256 delta = uint256(usdcDelta);
            uint256 newValue = p.totalDepositedUSDC + delta;
            if (newValue < p.totalDepositedUSDC) revert ArithmeticOverflow();
            p.totalDepositedUSDC = newValue;
            emit TotalDepositedUpdated(key, usdcDelta, _positionValueUSDCSingle(p), block.timestamp);
        } else {
            uint256 dec = uint256(-usdcDelta);
            if (dec >= p.totalDepositedUSDC) {
                // Clamp to zero, never negative.
                p.totalDepositedUSDC = 0;
                emit TotalDepositedUpdated(key, int256(-int256(dec)), _positionValueUSDCSingle(p), block.timestamp);
            } else {
                p.totalDepositedUSDC -= dec;
                emit TotalDepositedUpdated(key, usdcDelta, _positionValueUSDCSingle(p), block.timestamp);
            }
        }
    }

    /**
     * @notice Set whether bots are allowed to operate on a specific position.
     * @dev Manager-only. Position must exist.
     */
    function setBotAllowedForPosition(bytes32 key, bool allowed) external nonReentrant onlyManager whenNotPaused {
        Position storage p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();
        p.botAllowed = allowed;
        emit BotAllowedForPositionUpdated(key, allowed);
    }

    /* ───────────────────────────── View Helpers ───────────────────────────── */

    function isPoolAllowed(address pool) external view returns (bool) {
        return _isPoolAllowed(pool);
    }

    /// @notice List all tracked pool addresses.
    function listAllowedPools() external view returns (address[] memory) {
        return allowedPoolList;
    }

    function bridgeTokens() external view returns (address[] memory) {
        return _bridgeTokens;
    }

    function isBridgeToken(address token) public view returns (bool) {
        uint256 len = _bridgeTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_bridgeTokens[i] == token) {
                return true;
            }
        }
        return false;
    }

    function listUserPositionKeys(address user) external view returns (bytes32[] memory) {
        return _userPositionKeys[user];
    }

    /**
     * @notice Generate the next unique position key using an internal monotonic counter.
     * @dev This provides a collision-free source of uniqueness.
     */
    function _nextKey() internal returns (bytes32) {
        positionCounter++;
        return keccak256(abi.encodePacked(address(this), positionCounter, block.chainid));
    }

    function getPosition(bytes32 key) external view returns (Position memory p) {
        p = positions[key];
        if (p.owner == address(0)) revert PositionNotFound();
        p.pool = _positionPool(p);
    }

    /**
     * @notice Full position details including live amounts, fees, and valuation.
     */
    function getPositionDetails(bytes32 key) public view returns (PositionDetails memory d) {
        Position memory p = positions[key];

        d.key = key;
        d.owner = p.owner;
        d.tokenId = p.tokenId;
        d.pool = p.pool;
        d.token0 = p.token0;
        d.token1 = p.token1;
        d.fee = p.fee;
        d.tickSpacing = p.tickSpacing;
        d.tickLower = p.tickLower;
        d.tickUpper = p.tickUpper;
        d.totalDepositedUSDC = p.totalDepositedUSDC;
        d.openedAt = p.openedAt;
        d.dustUSDC = p.dustUSDC;
        d.dex = p.dex;
        d.botAllowed = p.botAllowed;

        if (p.owner == address(0) || p.tokenId == 0) {
            // Uninitialized / removed position;
            revert PositionNotFound();
        }

        address poolAddr = _positionPool(p);
        d.pool = poolAddr;

        // Spot amounts and owed fees from NPM + pool.
        (uint256 amt0, uint256 amt1, uint128 owed0, uint128 owed1) = _spotAmountsForPosition(p);

        d.tokensOwed0 = owed0;
        d.tokensOwed1 = owed1;
        d.amount0Now = amt0;
        d.amount1Now = amt1;

        // Pending fees (tokens owed including newly accrued inside-range fees)
        (uint256 pf0, uint256 pf1) = _pendingFeesForPosition(p);
        d.pendingFees0 = pf0;
        d.pendingFees1 = pf1;

        // Compute USDC-equivalent for pending fees using VALUATION (external).
        uint256 pendingUSDC = 0;
        // If token equals USDC, use raw amount; otherwise ask VALUATION.
        if (pf0 > 0) {
            if (p.token0 == address(USDC)) {
                pendingUSDC += pf0;
            } else {
                uint256 v0Quote = VALUATION.usdcValue(p.dex, p.token0, pf0);
                pendingUSDC += v0Quote;
            }
        }
        if (pf1 > 0) {
            if (p.token1 == address(USDC)) {
                pendingUSDC += pf1;
            } else {
                uint256 v1Quote = VALUATION.usdcValue(p.dex, p.token1, pf1);
                pendingUSDC += v1Quote;
            }
        }
        d.pendingFeesUSDC = pendingUSDC;

        // Current tick + raw liquidity.
        (, int24 currentTick) = _readSlot0(poolAddr);
        d.currentTick = currentTick;
        d.liquidity = p.tokenId == 0 ? 0 : _liquidityOf(p.tokenId, ICLDexAdapter(p.dex).getNPM());

        // Canonical USDC valuation (includes tracked dustUSDC).
        uint256 v0 = _valueTokenToUSDC(p.dex, p.token0, amt0);
        uint256 v1 = _valueTokenToUSDC(p.dex, p.token1, amt1);
        d.valueUSDCNow = v0 + v1 + p.dustUSDC;
    }

    function listUserPositionDetails(address user) external view returns (PositionDetails[] memory out) {
        bytes32[] storage keys = _userPositionKeys[user];
        uint256 n = keys.length;
        out = new PositionDetails[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = getPositionDetails(keys[i]);
        }
    }

    /**
     * @notice Canonical USDC-equivalent values for a batch of position keys.
     * @dev Includes tracked `dustUSDC` per position.
     */
    function positionValueUSDC(bytes32[] calldata keys)
        external
        view
        returns (PositionValueResult[] memory results)
    {
        uint256 len = keys.length;
        results = new PositionValueResult[](len);
        for (uint256 i = 0; i < len; ++i) {
            bytes32 key = keys[i];
            results[i].key = key;
            Position memory p = positions[key];
            results[i].valueUSDC = _positionValueUSDCSingle(p);
        }
    }

    /**
     * @notice Gas-optimized single-key accessor for position value.
     * @dev Avoids allocating a single-element array and reduces calldata/memory work
     *      for common single-key on-chain callers.
     */
    function positionValueUSDCSingle(bytes32 key) external view returns (uint256 valueUSDC) {
        Position memory p = positions[key];
        valueUSDC = _positionValueUSDCSingle(p);
    }

    /**
     * @dev Reads live amounts & owed fees for a given NFT.
     */
    function spotAmounts(bytes32 key)
        external
        view
        returns (uint256 amt0, uint256 amt1, uint128 owed0, uint128 owed1)
    {
        Position memory p = positions[key];
        if (p.owner == address(0) || p.tokenId == 0) {
            revert PositionNotFound();
        }
        return _spotAmountsForPosition(p);
    }

    /**
     * @notice Pending fees (token0/token1) for a set of positions.
     */
    function pendingFees(bytes32[] calldata keys)
        external
        view
        returns (PendingFeesResult[] memory results)
    {
        uint256 len = keys.length;
        results = new PendingFeesResult[](len);
        for (uint256 i = 0; i < len; ++i) {
            bytes32 key = keys[i];
            results[i].key = key;
            Position memory p = positions[key];
            (uint256 owed0Now, uint256 owed1Now) = _pendingFeesForPosition(p);
            results[i].owed0 = owed0Now;
            results[i].owed1 = owed1Now;
        }
    }

    /* ───────────────────────── Fee / Value Internals ──────────────────────── */

    function _pendingFeesForPosition(Position memory p)
        internal
        view
        returns (uint256 owed0Now, uint256 owed1Now)
    {
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

        (
            ,
            ,
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
        ) = INonfungiblePositionManager(ICLDexAdapter(p.dex).getNPM()).positions(p.tokenId);

        if (liquidity == 0) {
            // No active liquidity; just return already-owed tokens.
            return (tokensOwed0, tokensOwed1);
        }

        (uint256 o0, uint256 o1) = _pendingFeesCalc(
            p.dex,
            token0,
            token1,
            fee,
            p.tickSpacing,
            tickLower,
            tickUpper,
            liquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1
        );
        return (o0, o1);
    }

    function _positionValueUSDCSingle(Position memory p) internal view returns (uint256) {
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

        (uint256 amt0, uint256 amt1, , ) = _spotAmountsForPosition(p);

        uint256 v0 = _valueTokenToUSDC(p.dex, p.token0, amt0);
        uint256 v1 = _valueTokenToUSDC(p.dex, p.token1, amt1);
        return v0 + v1 + p.dustUSDC;
    }

    /**
     * @dev EVM-style modular subtraction on uint256.
     *      Matches unchecked(uint256) behavior in Uniswap V3 core.
     */
    function _subUint256(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a - b;
        }
    }

    /**
     * @dev Calculates current fees owed (tokensOwed + newly accrued inside range).
     *
     *      IMPORTANT: uses modular uint256 subtraction (unchecked) to mirror
     *      Uniswap V3 core behavior for feeGrowth math.
     */
    function _pendingFeesCalc(
        address dex,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal view returns (uint256 owed0Now, uint256 owed1Now) {
        address poolAddr = _pool(dex, token0, token1, fee, tickSpacing);

        // Read current tick from slot0 (compatible with both UniV3 + Slipstream).
        (, int24 tickCurrent) = _readSlot0(poolAddr);

        // Detect Slipstream (Aerodrome) via adapter.
        bool isSlip = false;
        try ICLDexAdapter(dex).isAerodrome() returns (bool aeroFlag) {
            isSlip = aeroFlag;
        } catch {
            isSlip = false;
        }

        uint256 feeGrowthOutside0LowerX128;
        uint256 feeGrowthOutside1LowerX128;
        uint256 feeGrowthOutside0UpperX128;
        uint256 feeGrowthOutside1UpperX128;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;

        if (isSlip) {
            ISlipstreamPoolState slip = ISlipstreamPoolState(poolAddr);

            (
                ,
                ,
                ,
                feeGrowthOutside0LowerX128,
                feeGrowthOutside1LowerX128,
                ,
                ,
                ,
                ,
                
            ) = slip.ticks(tickLower);

            (
                ,
                ,
                ,
                feeGrowthOutside0UpperX128,
                feeGrowthOutside1UpperX128,
                ,
                ,
                ,
                ,
                
            ) = slip.ticks(tickUpper);

            feeGrowthGlobal0X128 = slip.feeGrowthGlobal0X128();
            feeGrowthGlobal1X128 = slip.feeGrowthGlobal1X128();
        } else {
            IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);

            (
                ,
                ,
                feeGrowthOutside0LowerX128,
                feeGrowthOutside1LowerX128,
                ,
                ,
                ,
                
            ) = pool.ticks(tickLower);

            (
                ,
                ,
                feeGrowthOutside0UpperX128,
                feeGrowthOutside1UpperX128,
                ,
                ,
                ,
                
            ) = pool.ticks(tickUpper);

            feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
        }

        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;

        // Standard Uniswap V3 inside-fee math, but using modular subtraction.
        if (tickCurrent < tickLower) {
            // below the range
            feeGrowthInside0X128 = _subUint256(
                feeGrowthOutside0LowerX128,
                feeGrowthOutside0UpperX128
            );
            feeGrowthInside1X128 = _subUint256(
                feeGrowthOutside1LowerX128,
                feeGrowthOutside1UpperX128
            );
        } else if (tickCurrent >= tickUpper) {
            // above the range
            feeGrowthInside0X128 = _subUint256(
                feeGrowthOutside0UpperX128,
                feeGrowthOutside0LowerX128
            );
            feeGrowthInside1X128 = _subUint256(
                feeGrowthOutside1UpperX128,
                feeGrowthOutside1LowerX128
            );
        } else {
            // inside the range
            uint256 sum0 = feeGrowthOutside0LowerX128 + feeGrowthOutside0UpperX128;
            uint256 sum1 = feeGrowthOutside1LowerX128 + feeGrowthOutside1UpperX128;

            feeGrowthInside0X128 = _subUint256(
                feeGrowthGlobal0X128,
                sum0
            );
            feeGrowthInside1X128 = _subUint256(
                feeGrowthGlobal1X128,
                sum1
            );
        }

        // Modular delta vs last recorded inside growth.
        uint256 growthDelta0 = _subUint256(feeGrowthInside0X128, feeGrowthInside0LastX128);
        uint256 growthDelta1 = _subUint256(feeGrowthInside1X128, feeGrowthInside1LastX128);

        uint256 denom = (1 << 128);
        uint256 feesAccrued0 = FullMath.mulDiv(uint256(liquidity), growthDelta0, denom);
        uint256 feesAccrued1 = FullMath.mulDiv(uint256(liquidity), growthDelta1, denom);

        owed0Now = uint256(tokensOwed0) + feesAccrued0;
        owed1Now = uint256(tokensOwed1) + feesAccrued1;
    }

    /* ─────────────────────── Internal User-Key Indexing ───────────────────── */

    function _registerPosition(address user, bytes32 key) internal {
        if (_userPositionIndexPlus1[key] != 0) return;
        _userPositionKeys[user].push(key);
        _userPositionIndexPlus1[key] = _userPositionKeys[user].length;
    }

    function _deregisterPosition(address user, bytes32 key) internal {
        uint256 idxPlus1 = _userPositionIndexPlus1[key];
        if (idxPlus1 == 0) return;

        uint256 idx = idxPlus1 - 1;
        bytes32[] storage arr = _userPositionKeys[user];
        uint256 lastIndex = arr.length - 1;

        if (idx != lastIndex) {
            bytes32 lastKey = arr[lastIndex];
            arr[idx] = lastKey;
            _userPositionIndexPlus1[lastKey] = idx + 1;
        }

        arr.pop();
        delete _userPositionIndexPlus1[key];
    }

    /* ───────────────────────── Pool / Valuation Internals ─────────────────── */

    function _positionPool(Position memory p) internal view returns (address poolAddr) {
        poolAddr = p.pool;
        if (poolAddr != address(0)) {
            return poolAddr;
        }

        if (p.dex == address(0) || p.token0 == address(0) || p.token1 == address(0)) {
            revert PoolNotFound();
        }

        return _pool(p.dex, p.token0, p.token1, p.fee, p.tickSpacing);
    }

    function _spotAmountsForPosition(Position memory p)
        internal
        view
        returns (uint256 amt0, uint256 amt1, uint128 owed0, uint128 owed1)
    {
        if (p.owner == address(0) || p.tokenId == 0) revert PositionNotFound();

        (
            ,
            ,
            address t0,
            address t1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(ICLDexAdapter(p.dex).getNPM()).positions(p.tokenId);

        owed0 = tokensOwed0;
        owed1 = tokensOwed1;

        // If no active liquidity, amounts are 0 but owed still matters.
        if (liquidity == 0) return (0, 0, owed0, owed1);

        bool metadataMismatch = (t0 != p.token0) || (t1 != p.token1) || (fee != p.fee);

        address pool = metadataMismatch
            ? _pool(p.dex, t0, t1, fee, p.tickSpacing)
            : _positionPool(p);

        (uint160 sqrtPriceX96,) = _readSlot0(pool);

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
    }

    function _liquidityOf(uint256 tokenId, address npm) internal view returns (uint128 L) {
        (, , , , , , , L, , , , ) = INonfungiblePositionManager(npm).positions(tokenId);
    }

    /**
     * @dev Resolve pool address for UniV3 vs Slipstream (Aerodrome) via adapter.
     */
    function _pool(address dex, address token0, address token1, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (address pool)
    {
        address factoryAddr = ICLDexAdapter(dex).getFactory();

        bool isSlip = false;
        try ICLDexAdapter(dex).isAerodrome() returns (bool aeroFlag) {
            isSlip = aeroFlag;
        } catch {
            isSlip = false;
        }

        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);

        if (isSlip) {
            if (tickSpacing <= 0) revert InvalidTickSpacing();
            address p;
            try IAerodromeFactory(factoryAddr).getPool(t0, t1, tickSpacing) returns (address poolOut) {
                p = poolOut;
            } catch {}
            if (p == address(0)) revert PoolNotFound();
            if (!_isPoolAllowed(p)) revert PoolNotAllowed();
            return p;
        } else {
            if (fee == 0) revert InvalidFee();
            address p;
            try IUniswapV3Factory(factoryAddr).getPool(t0, t1, fee) returns (address poolOut) {
                p = poolOut;
            } catch {}
            if (p == address(0)) revert PoolNotFound();
            if (!_isPoolAllowed(p)) revert PoolNotAllowed();
            return p;
        }
    }

    function isPoolDeprecated(address pool) external view returns (bool) {
        // So users cannot open positions on deprecated pools
        return allowedPools[pool] == PoolStatus.Deprecated;
    }

    function _isPoolAllowed(address pool) internal view returns (bool) {
        PoolStatus s = allowedPools[pool];
        // Allows users to manage existing positions in deprecated pools
        return (s == PoolStatus.Allowed || s == PoolStatus.Deprecated);
    }

    /**
     * @dev Minimal slot0 reader
     */
    function _readSlot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        if (pool == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok) revert PoolNotFound();
        (sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
    }

    /**
     * @dev Convert any ERC20 amount to USDC-equivalent using VALUATION.
     */
    function _valueTokenToUSDC(address dex, address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (token == address(USDC)) return amount;
        uint256 v = VALUATION.usdcValue(dex, token, amount);
        return v;
    }

    /* ───────────────────────── ERC721 Receiver ────────────────────────────── */

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
