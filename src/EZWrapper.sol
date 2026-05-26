// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {
    ICLDexAdapter, ICLManager, ICLCore, IEZWrapper, INonfungiblePositionManager, Position
} from "./Interfaces.sol";

/**
 * @title EZWrapper
 * @notice Wrapper helper for CLManager ez positions.
 */
contract EZWrapper is Ownable, Pausable, ReentrancyGuard, IERC721Receiver, IEZWrapper {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    ICLCore public immutable CORE;
    IERC20 public immutable USDC;

    address public guardian;

    mapping(address => bytes32[]) internal userPositionKeys;
    mapping(bytes32 => address) internal keyUser;
    mapping(bytes32 => uint256) internal keyIndex;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event GuardianUpdated(address indexed guardian);
    event BotActionProceedsForwarded(address indexed user, bytes32 indexed key, uint256 amount, bool positionClosed);
    event EzNftReturned(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 dustReturned);
    event EzPositionOpened(
        address indexed user,
        bytes32 indexed key,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        address referrer
    );
    event EzCollateralAdded(
        address indexed user,
        bytes32 indexed key,
        uint256 usdcAmount
    );
    event EzCollateralRemoved(address indexed user, bytes32 indexed key, uint256 withdrawUsdc, uint256 returnedUsdc);
    event EzPositionExited(address indexed user, bytes32 indexed key, uint256 returnedUsdc);
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NotGuardian();
    error ZeroAmount();
    error NotPositionUser();
    error NotManager();
    error NotCore();
    error InvalidReturnedNft();
    error OwnershipRenounceDisabled();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address core_, address owner_) Ownable(owner_) {
        if (core_ == address(0) || owner_ == address(0)) revert ZeroAddress();

        CORE = ICLCore(core_);
        USDC = CORE.USDC();
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the guardian allowed to pause and unpause the ez wrapper.
    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    /// @notice Pauses wrapper and copy operations.
    function pause() external onlyGuardian {
        _pause();
    }

    /// @notice Unpauses wrapper and copy operations.
    function unpause() external onlyGuardian {
        _unpause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                             EZ USER FLOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Opens a wrapper-owned CLManager position for the caller.
    function ezOpen(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        uint256 slippageBps,
        address referrer
    ) external nonReentrant whenNotPaused returns (bytes32 key) {
        if (usdcAmount == 0) revert ZeroAmount();

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        ICLManager manager = _manager();
        _approveManager(manager, usdcAmount);
        key = manager.openPositionEz(msg.sender, pool, tickLower, tickUpper, usdcAmount, true, slippageBps, referrer);
        USDC.forceApprove(address(manager), 0);

        _storePosition(msg.sender, key);
        emit EzPositionOpened(msg.sender, key, pool, tickLower, tickUpper, usdcAmount, referrer);
    }

    /// @notice Adds collateral to a wrapper-owned position belonging to the caller.
    function ezAdd(bytes32 key, uint256 usdcAmount, uint256 slippageBps) external nonReentrant whenNotPaused {
        _requirePositionUser(key, msg.sender);
        if (usdcAmount == 0) revert ZeroAmount();

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        ICLManager manager = _manager();
        _approveManager(manager, usdcAmount);
        manager.addCollateral(key, usdcAmount, slippageBps);
        USDC.forceApprove(address(manager), 0);

        emit EzCollateralAdded(msg.sender, key, usdcAmount);
    }

    /// @notice Removes collateral from a wrapper-owned position belonging to the caller.
    function ezRemove(bytes32 key, uint256 withdrawUsdc, uint256 slippageBps)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 returnedUsdc)
    {
        _requirePositionUser(key, msg.sender);
        if (withdrawUsdc == 0) revert ZeroAmount();

        uint256 beforeBalance = USDC.balanceOf(address(this));
        _manager().removeCollateral(key, withdrawUsdc, slippageBps);
        returnedUsdc = USDC.balanceOf(address(this)) - beforeBalance;

        if (returnedUsdc > 0) {
            USDC.safeTransfer(msg.sender, returnedUsdc);
        }

        emit EzCollateralRemoved(msg.sender, key, withdrawUsdc, returnedUsdc);
    }

    /// @notice Exits a wrapper-owned position belonging to the caller.
    function ezExit(bytes32 key, uint256 slippageBps)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 returnedUsdc)
    {
        _requirePositionUser(key, msg.sender);

        uint256 beforeBalance = USDC.balanceOf(address(this));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        _manager().exitPosition(keys, slippageBps);
        returnedUsdc = USDC.balanceOf(address(this)) - beforeBalance;

        _removeStoredPosition(msg.sender, key);

        if (returnedUsdc > 0) {
            USDC.safeTransfer(msg.sender, returnedUsdc);
        }

        emit EzPositionExited(msg.sender, key, returnedUsdc);
    }

    /// @notice Emergency-return a wrapper-owned NFT to the mapped user.
    /// @dev Available while paused; any dust refunded by CLCore is forwarded to the caller.
    function ezReturnNft(bytes32 key) external nonReentrant returns (uint256 tokenId, uint256 dustReturned) {
        _requirePositionUser(key, msg.sender);

        Position memory p = CORE.getPosition(key);
        if (p.owner != address(this) || p.tokenId == 0) revert NotPositionUser();

        tokenId = p.tokenId;
        address npm = ICLDexAdapter(p.dex).getNPM();
        uint256 usdcBefore = USDC.balanceOf(address(this));

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        _manager().returnNft(keys);

        INonfungiblePositionManager(npm).safeTransferFrom(address(this), msg.sender, tokenId);

        dustReturned = USDC.balanceOf(address(this)) - usdcBefore;
        if (dustReturned > 0) {
            USDC.safeTransfer(msg.sender, dustReturned);
        }

        _removeStoredPosition(msg.sender, key);
        emit EzNftReturned(msg.sender, key, tokenId, dustReturned);
    }

    /// @notice Forwards wrapper-owned proceeds sent here by CLManager during direct bot actions.
    function creditBotActionProceeds(bytes32 key, uint256 amount, bool positionClosed) external override {
        if (msg.sender != CORE.manager()) revert NotManager();
        if (amount == 0 && !positionClosed) revert ZeroAmount();

        address user = keyUser[key];
        if (user == address(0)) revert NotPositionUser();

        if (amount > 0) USDC.safeTransfer(user, amount);
        if (positionClosed) _removeStoredPosition(user, key);

        emit BotActionProceedsForwarded(user, key, amount, positionClosed);
    }

    /// @notice Forwards a wrapper-owned NFT returned to this contract by CLCore during emergency manager returns.
    function creditReturnedNft(bytes32 key, address npm, uint256 tokenId, uint256 dustReturned) external override {
        if (msg.sender != CORE.manager()) revert NotManager();
        if (npm == address(0) || tokenId == 0) revert InvalidReturnedNft();

        address user = keyUser[key];
        if (user == address(0)) revert NotPositionUser();

        _removeStoredPosition(user, key);
        INonfungiblePositionManager(npm).safeTransferFrom(address(this), user, tokenId);
        if (dustReturned > 0) {
            USDC.safeTransfer(user, dustReturned);
        }

        emit EzNftReturned(user, key, tokenId, dustReturned);
    }

    /*//////////////////////////////////////////////////////////////
                              EXTERNAL VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns wrapper-owned position keys tracked for a user.
    function getKeysForUser(address user) external view returns (bytes32[] memory) {
        return userPositionKeys[user];
    }

    function userForKey(bytes32 key) external view override returns (address) {
        return keyUser[key];
    }

    function onERC721Received(address operator, address from, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (operator != address(CORE) || from != address(CORE)) revert NotCore();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _storePosition(address user, bytes32 key) internal {
        userPositionKeys[user].push(key);
        keyUser[key] = user;
        keyIndex[key] = userPositionKeys[user].length;
    }

    function _removeStoredPosition(address user, bytes32 key) internal {
        bytes32[] storage keys = userPositionKeys[user];
        uint256 index = keyIndex[key];
        if (index == 0 || keyUser[key] != user) revert NotPositionUser();

        uint256 keyIndexZero = index - 1;
        bytes32 lastKey = keys[keys.length - 1];
        keys[keyIndexZero] = lastKey;
        keyIndex[lastKey] = index;
        keys.pop();

        delete keyUser[key];
        delete keyIndex[key];
    }

    function _requirePositionUser(bytes32 key, address user) internal view {
        if (keyUser[key] != user) revert NotPositionUser();
    }

    function _approveManager(ICLManager manager, uint256 usdcAmount) internal {
        USDC.forceApprove(address(manager), usdcAmount);
    }

    function _manager() internal view returns (ICLManager manager) {
        manager = ICLManager(CORE.manager());
        if (address(manager) == address(0)) revert ZeroAddress();
    }
}
